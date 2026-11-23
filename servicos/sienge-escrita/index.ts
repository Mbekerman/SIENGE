// Envio de títulos aprovados ao Sienge (Edge Function do Supabase, Deno). Cada chamada põe na fila os
// títulos recém-aprovados e envia UM título (fila.ts); quem chama de minuto em minuto é o pg_cron
// (supabase/dev/sienge_escrita_agenda.sql). Toda gravação passa pela trava (trava.ts).
// Segredos (Edge Functions › Secrets): SIENGE_USUARIO e SIENGE_SENHA; SIENGE_AMBIENTE só na produção,
// com a palavra exata "producao" (sem ela, a trava só deixa gravar na empresa 11 com credor de teste);
// SIENGE_CREDORES_TESTE (padrão 823). SUPABASE_DB_URL vem do Supabase.
// A chave de quem chama fica no Vault do banco (sienge_escrita_chave), lida aqui e pelo pg_cron.
// Com {"tarefa": "avisos"}, só processa os avisos do Sienge pendentes (chamado pelo recebedor, sienge-aviso).
import postgres from 'npm:postgres@3.4.4';
import { bancoPostgres, httpSienge, processarAvisos, processarUm } from './fila.ts';

const SUB = Deno.env.get('SIENGE_SUBDOMINIO') ?? 'bkmincorporadora';
const BASE = `https://api.sienge.com.br/${SUB}/public/api/v1`;

function credencial(): string {
  const u = Deno.env.get('SIENGE_USUARIO'), s = Deno.env.get('SIENGE_SENHA');
  if (!u || !s) throw new Error('faltam os segredos SIENGE_USUARIO e SIENGE_SENHA');
  return 'Basic ' + btoa(`${u}:${s}`);
}

function iguais(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// A resposta vai só com ok: o pg_net guarda as respostas por horas numa tabela que qualquer login direto lê (S-143).
// O detalhe da rodada fica no log da função (Supabase > Edge Functions > Logs).
Deno.serve(async (req) => {
  const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { max: 1, prepare: false });
  try {
    const [k] = await sql`select decrypted_secret as v from vault.decrypted_secrets where name = 'sienge_escrita_chave'`;
    if (!k?.v || !iguais(req.headers.get('x-escrita-chave') ?? '', k.v)) return new Response('não autorizado', { status: 401 });
    const pedido = await req.json().catch(() => ({}));
    // ritmo (residual do S-143): a rotina de minuto roda no máximo a cada 50 s e o atalho dos avisos a cada 5 s; o que
    // for recusado aqui a rotina de minuto pega depois
    const rotina = pedido?.tarefa === 'avisos' ? 'escrita-avisos' : 'escrita';
    const [rt] = await sql`select sienge.ritmo(${rotina}, ${rotina === 'escrita' ? 50 : 5}) as v`;
    if (!rt?.v) return Response.json({ ok: false }, { status: 429 });
    if (pedido?.tarefa === 'avisos') {
      console.log(JSON.stringify({ avisos: await processarAvisos(bancoPostgres(sql), httpSienge(BASE, credencial())) }));
      return Response.json({ ok: true });
    }
    const credores = (Deno.env.get('SIENGE_CREDORES_TESTE') ?? '823').split(',').map((x) => Number(x.trim())).filter(Number.isInteger);
    const r = await processarUm(bancoPostgres(sql), httpSienge(BASE, credencial()), {
      ambiente: Deno.env.get('SIENGE_AMBIENTE'), credoresTeste: credores,
    });
    console.log(JSON.stringify(r));
    return Response.json({ ok: true });
  } catch (err) {
    console.error(String((err as Error)?.message ?? err).slice(0, 500));
    return Response.json({ ok: false }, { status: 500 });
  } finally {
    await sql.end();
  }
});
