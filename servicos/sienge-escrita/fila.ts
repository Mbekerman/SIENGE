// A fila do envio ao Sienge (erp.sienge_envios): cada chamada de processarUm() põe na fila os títulos
// recém-aprovados e envia UM título vencido da fila. Quem chama de minuto em minuto é o agendador
// (Edge Function index.ts, ou o executor local de teste local.ts).
//
// Sem dependência de Deno nem de Node: o banco chega como a interface Banco (bancoPostgres() a monta
// sobre o postgres.js) e o Sienge como Http (httpSienge() a monta sobre fetch). Testado em fila.test.ts.
//
// Situações da fila: pendente → enviado; erro (tenta de novo com espera crescente, até 6 h);
// manual (divergência entre o Sienge e o ERP: ninguém tenta de novo até alguém olhar).
import { Divergencia, enviarTitulo, ErroSienge, proximaTentativa, type PedidoTitulo, type Resposta } from './envio.ts';
import { gravarComTrava, type Ambiente } from './trava.ts';

export type ItemFila = { titulo_id: string; sienge_id: number | null; tentativas: number };

export interface Banco {
  enfileirar(): Promise<number>;
  // Pega um título vencido e o reserva por 15 minutos (outra execução não pega o mesmo).
  pegar(): Promise<ItemFila | null>;
  pedido(tituloId: string): Promise<PedidoTitulo>; // erp.sienge_pedido: recusa com o motivo
  registrar(tituloId: string, siengeId: number): Promise<void>; // erp.sienge_registrar
  idsNoSienge(): Promise<number[]>; // os sienge_id da fila (criados por este programa)
  terminar(tituloId: string, r: { situacao: 'enviado' | 'erro' | 'manual'; passo?: string | null; erro?: string | null; tentativas: number; proxima: Date }): Promise<void>;
}

export interface Http {
  ler(caminho: string): Promise<unknown>; // GET; erro se não for 2xx
  enviar(metodo: string, caminho: string, corpo: unknown): Promise<Resposta>; // erro se não for 2xx
}

export type Config = { ambiente: Ambiente; credoresTeste: number[]; agora?: () => Date };

export type Resultado =
  | { passo: 'nada a fazer'; enfileirados: number }
  | { passo: 'enviado'; titulo: string; siengeId: number; criado: boolean; enfileirados: number }
  | { passo: 'erro' | 'manual'; titulo: string; erro: string; enfileirados: number };

export async function processarUm(banco: Banco, http: Http, cfg: Config): Promise<Resultado> {
  const agora = cfg.agora ?? (() => new Date());
  const enfileirados = await banco.enfileirar();
  const item = await banco.pegar();
  if (!item) return { passo: 'nada a fazer', enfileirados };

  const tentativas = item.tentativas + 1;
  try {
    const ped = await banco.pedido(item.titulo_id);
    // Em teste, a trava só deixa gravar em título criado por este programa: os da fila.
    const criados = new Set((await banco.idsNoSienge()).map((id) => `bills:${id}`));
    const ctx = { credoresTeste: new Set(cfg.credoresTeste), criadosPeloTeste: criados };
    const r = await enviarTitulo({
      ler: (c) => http.ler(c),
      gravar: (metodo, caminho, corpo) =>
        gravarComTrava({ metodo, caminho, corpo, empresa: ped.empresa }, cfg.ambiente, (c) => http.ler(c), (m, c, b) => http.enviar(m, c, b), ctx),
      registrarCriado: async (id) => { await banco.registrar(item.titulo_id, id); criados.add(`bills:${id}`); },
      hoje: () => dataSaoPaulo(agora()),
    }, ped, item.sienge_id);
    await banco.terminar(item.titulo_id, { situacao: 'enviado', passo: 'pagamento', erro: null, tentativas, proxima: agora() });
    return { passo: 'enviado', titulo: item.titulo_id, siengeId: r.siengeId, criado: r.criado, enfileirados };
  } catch (e) {
    const msg = (e instanceof Error ? e.message : String(e)).slice(0, 1000);
    const situacao = e instanceof Divergencia ? 'manual' : 'erro';
    await banco.terminar(item.titulo_id, { situacao, erro: msg, tentativas, proxima: proximaTentativa(tentativas, agora()) });
    return { passo: situacao, titulo: item.titulo_id, erro: msg, enfileirados };
  }
}

export function dataSaoPaulo(d: Date): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
}

// O Sienge pela rede. base = https://api.sienge.com.br/<subdomínio>/public/api/v1
export function httpSienge(base: string, autorizacao: string, buscar: typeof fetch = fetch): Http {
  const chamar = async (metodo: string, caminho: string, corpo?: unknown) => {
    const r = await buscar(base + caminho, {
      method: metodo,
      headers: { Authorization: autorizacao, Accept: 'application/json', ...(corpo === undefined ? {} : { 'Content-Type': 'application/json' }) },
      body: corpo === undefined ? undefined : JSON.stringify(corpo),
      signal: AbortSignal.timeout(60_000),
    });
    const texto = await r.text();
    if (r.status < 200 || r.status > 299) throw new ErroSienge(r.status, `Sienge ${metodo} ${caminho.split('?')[0]} respondeu ${r.status}: ${texto.slice(0, 300)}`);
    let json: unknown = null;
    try { json = texto ? JSON.parse(texto) : null; } catch { json = texto; }
    return { status: r.status, location: r.headers.get('location'), corpo: json };
  };
  return {
    ler: async (c) => (await chamar('GET', c)).corpo,
    enviar: (m, c, b) => chamar(m, c, b),
  };
}

// O banco pelo postgres.js (Deno: npm:postgres; Node: postgres). Cada passo numa transação curta como
// erp_sistema, para o id do Sienge ficar gravado assim que o POST responde.
// deno-lint-ignore no-explicit-any
type Sql = any;
export function bancoPostgres(sql: Sql): Banco {
  // deno-lint-ignore no-explicit-any
  const comoSistema = <T>(f: (tx: any) => Promise<T>): Promise<T> =>
    sql.begin(async (tx: Sql) => { await tx`set local role erp_sistema`; return await f(tx); });
  return {
    enfileirar: () => comoSistema(async (tx) => (await tx`select erp.sienge_enfileirar() as n`)[0].n),
    pegar: () => comoSistema(async (tx) => {
      const [r] = await tx`
        update erp.sienge_envios set proxima_em = now() + interval '15 minutes'
         where titulo_id = (select titulo_id from erp.sienge_envios
                             where situacao in ('pendente','erro') and proxima_em <= now()
                             order by proxima_em limit 1 for update skip locked)
        returning titulo_id, sienge_id, tentativas`;
      return r ? { titulo_id: r.titulo_id, sienge_id: r.sienge_id, tentativas: r.tentativas } : null;
    }),
    pedido: (id) => comoSistema(async (tx) => (await tx`select erp.sienge_pedido(${id}::uuid) as p`)[0].p),
    registrar: (id, s) => comoSistema(async (tx) => { await tx`select erp.sienge_registrar(${id}::uuid, ${s}::int)`; }),
    idsNoSienge: () => comoSistema(async (tx) =>
      (await tx`select sienge_id from erp.sienge_envios where sienge_id is not null`).map((r: { sienge_id: number }) => r.sienge_id)),
    terminar: (id, r) => comoSistema(async (tx) => {
      await tx`update erp.sienge_envios
                  set situacao = ${r.situacao}, passo = coalesce(${r.passo ?? null}::text, passo), erro = ${r.erro ?? null}::text,
                      tentativas = ${r.tentativas}::int, proxima_em = ${r.proxima}::timestamptz
                where titulo_id = ${id}::uuid`;
    }),
  };
}
