// Programa de carga do Sienge (Edge Function do Supabase, Deno). Cada chamada dá UM passo de UMA carga
// e para; quem chama de minuto em minuto é o pg_cron do banco (supabase/dev/sienge_carga_agenda.sql).
// Só LÊ o Sienge: a única chamada de rede é lerSienge(), que faz GET e nada mais.
// Segredos (Edge Functions › Secrets): SIENGE_USUARIO e SIENGE_SENHA. SUPABASE_DB_URL vem do Supabase.
// A chave de quem chama fica no Vault do banco (sienge_carga_chave), lida aqui e pelo pg_cron.
import postgres from 'npm:postgres@3.4.4';
import { cabecalhosParaGuardar, esperaDoSienge, marcaAusentes, montarConsulta, proximaAcaoMassa, type Carga, type Cota } from './logica.ts';

const SUB = Deno.env.get('SIENGE_SUBDOMINIO') ?? 'bkmincorporadora';
const MASSA = `https://api.sienge.com.br/${SUB}/public/api/bulk-data/v1`;
const RESERVA_MASSA = Number(Deno.env.get('SIENGE_RESERVA_MASSA') ?? '6');

const CAMINHOS: Record<string, string> = { 'bulk:outcome': '/outcome' };

function credencial(): string {
  const u = Deno.env.get('SIENGE_USUARIO'), s = Deno.env.get('SIENGE_SENHA');
  if (!u || !s) throw new Error('faltam os segredos SIENGE_USUARIO e SIENGE_SENHA');
  return 'Basic ' + btoa(`${u}:${s}`);
}

// A única chamada ao Sienge: sempre GET.
async function lerSienge(base: string, consulta: string): Promise<Response> {
  return await fetch(base + consulta, {
    method: 'GET',
    headers: { Authorization: credencial(), Accept: 'application/json' },
    signal: AbortSignal.timeout(120_000),
  });
}

function iguais(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { max: 1, prepare: false });
  let cargaId: number | null = null; // a carga deste passo, para o erro cair nela e não em outra
  try {
    const [k] = await sql`select decrypted_secret as v from vault.decrypted_secrets where name = 'sienge_carga_chave'`;
    if (!k?.v || !iguais(req.headers.get('x-carga-chave') ?? '', k.v)) return new Response('não autorizado', { status: 401 });

    const resultado = await sql.begin(async (tx) => {
      const [c] = await tx<Carga[]>`
        select id, recurso, parametros, situacao, pedido_assincrono, pedacos, pedacos_lidos, iniciada_em
          from sienge.cargas
         where situacao in ('pendente', 'rodando') and (retomar_depois is null or retomar_depois <= now())
         order by id limit 1 for update skip locked`;
      if (!c) return { passo: 'nada a fazer' };
      cargaId = c.id;
      if (!CAMINHOS[c.recurso]) throw new Error(`recurso sem programa: ${c.recurso}`);

      const [cota] = await tx<NonNullable<Cota>[]>`select restante_dia, lido_em from sienge.cota_api where tipo = 'massa'`;
      const acao = proximaAcaoMassa(c, cota ?? null, new Date(), RESERVA_MASSA);
      if (acao.tipo === 'esperar_cota') {
        await tx`update sienge.cargas set retomar_depois = ${acao.ate} where id = ${c.id}`;
        return { carga: c.id, passo: 'esperando a cota de massa', ate: acao.ate };
      }
      if (acao.tipo === 'concluir') {
        await tx`update sienge.cargas set situacao = 'concluida', concluida_em = now() where id = ${c.id}`;
        if (!marcaAusentes(c.parametros)) return { carga: c.id, passo: 'concluida', removidas: null };
        const [m] = await tx`select sienge.marcar_ausentes_pagar(${c.id}) as n`;
        return { carga: c.id, passo: 'concluida', removidas: m.n };
      }

      const consulta = acao.tipo === 'pedir'
        ? montarConsulta(CAMINHOS[c.recurso], { ...c.parametros, _async: 'true', _asyncChunkMaxSize: '8192' })
        : acao.tipo === 'andamento'
          ? montarConsulta(`/async/${encodeURIComponent(c.pedido_assincrono!)}`, {})
          : montarConsulta(`/async/${encodeURIComponent(c.pedido_assincrono!)}/result/${acao.pedaco}`, {});
      const lido = new Date();
      const r = await lerSienge(MASSA, consulta);
      const cab = cabecalhosParaGuardar(r.headers);
      if (cab['x-ratelimit-remaining-day'] !== undefined) {
        await tx`insert into sienge.cota_api (tipo, limite_dia, restante_dia, lido_em)
                 values ('massa', ${Number(cab['x-ratelimit-limit-day'] ?? null) || null}, ${Number(cab['x-ratelimit-remaining-day'])}, ${lido})
                 on conflict (tipo) do update set limite_dia = excluded.limite_dia, restante_dia = excluded.restante_dia, lido_em = excluded.lido_em`;
      }
      const corpo = await r.text();

      if (r.status === 429) {
        const s = esperaDoSienge(r.headers.get('retry-after'));
        await tx`update sienge.cargas set retomar_depois = now() + make_interval(secs => ${s}), ultimo_erro = 'Sienge recusou por cota (429)' where id = ${c.id}`;
        return { carga: c.id, passo: 'cota', espera_s: s };
      }
      if (r.status === 404 && acao.tipo !== 'pedir') {
        // pedido assíncrono expirado (24 h): pede de novo, do começo
        await tx`update sienge.cargas set pedido_assincrono = null, pedacos = null, pedacos_lidos = 0 where id = ${c.id}`;
        return { carga: c.id, passo: 'pedido expirado, refazendo' };
      }
      if (r.status !== 200) throw new Error(`Sienge respondeu ${r.status}: ${corpo.slice(0, 300)}`);

      if (acao.tipo === 'pedir') {
        const id = JSON.parse(corpo).identifier;
        if (!id) throw new Error('resposta sem identifier');
        await tx`update sienge.cargas set pedido_assincrono = ${id}, situacao = 'rodando',
                   iniciada_em = coalesce(iniciada_em, now()), ultimo_erro = null, tentativas = 0, retomar_depois = now() + interval '1 minute'
                 where id = ${c.id}`;
        return { carga: c.id, passo: 'pedido feito' };
      }
      if (acao.tipo === 'andamento') {
        const st = JSON.parse(corpo);
        if (st.status === 'Finished') {
          if (!Number.isInteger(st.chunks) || st.chunks < 1) throw new Error(`massa terminou sem pedaços (${st.chunks})`);
          await tx`update sienge.cargas set pedacos = ${st.chunks}, tentativas = 0, ultimo_erro = null where id = ${c.id}`;
          return { carga: c.id, passo: 'pronto', pedacos: st.chunks };
        }
        if (st.status === 'Failed') {
          await tx`update sienge.cargas set pedido_assincrono = null, ultimo_erro = ${'massa falhou: ' + (st.error ?? '')},
                     tentativas = tentativas + 1, retomar_depois = now() + interval '30 minutes',
                     situacao = case when tentativas + 1 >= 5 then 'erro' else situacao end where id = ${c.id}`;
          return { carga: c.id, passo: 'massa falhou' };
        }
        await tx`update sienge.cargas set retomar_depois = now() + interval '1 minute' where id = ${c.id}`;
        return { carga: c.id, passo: st.status };
      }
      // baixar um pedaço: grava a resposta bruta e carrega no espelho
      const [g] = await tx`select sienge.gravar_resposta(${c.id}, ${c.recurso}, ${consulta}, ${acao.pedaco}, ${r.status},
                             ${tx.json(cab)}, ${corpo}, ${lido}) as id`;
      const [e] = await tx`select sienge.carregar_parcelas_pagar(${g.id}) as n`;
      await tx`update sienge.cargas set pedacos_lidos = ${acao.pedaco}, ultimo_erro = null, tentativas = 0 where id = ${c.id}`;
      return { carga: c.id, passo: `pedaço ${acao.pedaco}`, espelho: e.n };
    });
    return Response.json(resultado);
  } catch (err) {
    const msg = String((err as Error)?.message ?? err).slice(0, 500);
    // erro antes de escolher a carga (banco, Vault): não é de carga nenhuma
    if (cargaId !== null) {
      try {
        await sql`update sienge.cargas set tentativas = tentativas + 1, ultimo_erro = ${msg},
                    retomar_depois = now() + interval '5 minutes',
                    situacao = case when tentativas + 1 >= 5 then 'erro' else situacao end
                  where id = ${cargaId}`;
      } catch { /* o erro original é o que importa */ }
    }
    return Response.json({ erro: msg }, { status: 500 });
  } finally {
    await sql.end();
  }
});
