// A fila do envio ao Sienge (erp.sienge_envios, os títulos; erp.sienge_previsoes, as previsões como
// título PRV): cada chamada de processarUm() põe na fila os títulos e as previsões recém-aprovados e
// envia UM item vencido da fila; sem item, confere se uma linha PRV a apagar já sumiu do Sienge. Quem chama de minuto em minuto é o agendador
// (Edge Function index.ts, ou o executor local de teste local.ts).
//
// Sem dependência de Deno nem de Node: o banco chega como a interface Banco (bancoPostgres() a monta
// sobre o postgres.js) e o Sienge como Http (httpSienge() a monta sobre fetch). Testado em fila.test.ts.
//
// Situações da fila: pendente → enviado; erro (tenta de novo com espera crescente, até 6 h, ou o que o
// Sienge pedir no Retry-After); manual (divergência entre o Sienge e o ERP, ou o Sienge recusando o
// pedido com 4xx em TENTATIVAS_4XX tentativas seguidas: ninguém tenta de novo até alguém olhar).
import { Divergencia, enviarTitulo, erroPermanente, ErroSienge, proximaTentativa, segundosRetryAfter, type PedidoTitulo, type Resposta } from './envio.ts';
import { gravarComTrava, type Ambiente } from './trava.ts';

// id: o título ou a previsão (o banco sabe qual).
export type ItemFila = { item_id: string; sienge_id: number | null; tentativas: number };

export interface Banco {
  enfileirar(): Promise<number>;
  // Pega um item vencido e o reserva por 15 minutos (outra execução não pega o mesmo).
  pegar(): Promise<ItemFila | null>;
  pedido(itemId: string): Promise<PedidoTitulo>; // erp.sienge_pedido_item: recusa com o motivo
  registrar(itemId: string, siengeId: number): Promise<void>; // erp.sienge_registrar_item
  idsNoSienge(): Promise<number[]>; // os sienge_id das filas (criados por este programa)
  terminar(itemId: string, r: { situacao: 'enviado' | 'erro' | 'manual'; passo?: string | null; erro?: string | null; tentativas: number; proxima: Date }): Promise<void>;
  // A linha PRV a apagar mais antiga sem conferência há 30 minutos (marca a conferência).
  pegarConferencia(): Promise<{ item_id: string; sienge_id: number } | null>;
  marcarApagado(itemId: string): Promise<void>; // o título sumiu do Sienge
}

export interface Http {
  ler(caminho: string): Promise<unknown>; // GET; erro se não for 2xx
  enviar(metodo: string, caminho: string, corpo: unknown): Promise<Resposta>; // erro se não for 2xx
}

export type Config = { ambiente: Ambiente; credoresTeste: number[]; agora?: () => Date };

export type Resultado =
  | { passo: 'nada a fazer'; enfileirados: number }
  | { passo: 'apagado'; previsao: string; siengeId: number; enfileirados: number }
  | { passo: 'enviado'; titulo: string; siengeId: number; criado: boolean; enfileirados: number }
  | { passo: 'erro' | 'manual'; titulo: string; erro: string; enfileirados: number };

// Depois de tantas recusas 4xx seguidas (o pedido está errado, não o momento), o título vai para manual.
export const TENTATIVAS_4XX = 3;

export async function processarUm(banco: Banco, http: Http, cfg: Config): Promise<Resultado> {
  const agora = cfg.agora ?? (() => new Date());
  const enfileirados = await banco.enfileirar();
  const item = await banco.pegar();
  if (!item) return await conferirApagado(banco, http, enfileirados);

  const tentativas = item.tentativas + 1;
  try {
    const ped = await banco.pedido(item.item_id);
    // Em teste, a trava só deixa gravar em título criado por este programa: os da fila.
    const criados = new Set((await banco.idsNoSienge()).map((id) => `bills:${id}`));
    const ctx = { credoresTeste: new Set(cfg.credoresTeste), criadosPeloTeste: criados };
    const r = await enviarTitulo({
      ler: (c) => http.ler(c),
      gravar: (metodo, caminho, corpo) =>
        gravarComTrava({ metodo, caminho, corpo, empresa: ped.empresa }, cfg.ambiente, (c) => http.ler(c), (m, c, b) => http.enviar(m, c, b), ctx),
      registrarCriado: async (id) => { await banco.registrar(item.item_id, id); criados.add(`bills:${id}`); },
      hoje: () => dataSaoPaulo(agora()),
    }, ped, item.sienge_id);
    await banco.terminar(item.item_id, { situacao: 'enviado', passo: 'pagamento', erro: null, tentativas, proxima: agora() });
    return { passo: 'enviado', titulo: item.item_id, siengeId: r.siengeId, criado: r.criado, enfileirados };
  } catch (e) {
    let msg = (e instanceof Error ? e.message : String(e)).slice(0, 1000);
    let situacao: 'erro' | 'manual' = e instanceof Divergencia ? 'manual' : 'erro';
    if (situacao === 'erro' && erroPermanente(e) && tentativas >= TENTATIVAS_4XX) {
      situacao = 'manual';
      msg = `recusado pelo Sienge em ${tentativas} tentativas: ${msg}`.slice(0, 1000);
    }
    let proxima = proximaTentativa(tentativas, agora());
    if (e instanceof ErroSienge && e.retryAfter !== null) {
      const pedido = new Date(agora().getTime() + e.retryAfter * 1000);
      if (pedido > proxima) proxima = pedido;
    }
    await banco.terminar(item.item_id, { situacao, erro: msg, tentativas, proxima });
    return { passo: situacao, titulo: item.item_id, erro: msg, enfileirados };
  }
}

// A linha PRV que o financeiro apaga à mão: o GET do título responde 404 quando ela sumiu. Outro erro
// fica para a próxima conferência (daqui a 30 minutos); só leitura, não passa pela trava.
async function conferirApagado(banco: Banco, http: Http, enfileirados: number): Promise<Resultado> {
  const c = await banco.pegarConferencia();
  if (!c) return { passo: 'nada a fazer', enfileirados };
  try {
    await http.ler(`/bills/${c.sienge_id}`);
  } catch (e) {
    if (e instanceof ErroSienge && e.status === 404) {
      await banco.marcarApagado(c.item_id);
      return { passo: 'apagado', previsao: c.item_id, siengeId: c.sienge_id, enfileirados };
    }
  }
  return { passo: 'nada a fazer', enfileirados };
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
    if (r.status < 200 || r.status > 299) {
      throw new ErroSienge(r.status, `Sienge ${metodo} ${caminho.split('?')[0]} respondeu ${r.status}: ${texto.slice(0, 300)}`,
        segundosRetryAfter(r.headers.get('retry-after'), new Date()));
    }
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
      const [r] = await tx`select item_id, sienge_id, tentativas from erp.sienge_pegar()`;
      return r ? { item_id: r.item_id, sienge_id: r.sienge_id, tentativas: r.tentativas } : null;
    }),
    pedido: (id) => comoSistema(async (tx) => (await tx`select erp.sienge_pedido_item(${id}::uuid) as p`)[0].p),
    registrar: (id, s) => comoSistema(async (tx) => { await tx`select erp.sienge_registrar_item(${id}::uuid, ${s}::int)`; }),
    idsNoSienge: () => comoSistema(async (tx) =>
      (await tx`select erp.sienge_ids() as sienge_id`).map((r: { sienge_id: number }) => r.sienge_id)),
    terminar: (id, r) => comoSistema(async (tx) => {
      await tx`select erp.sienge_terminar(${id}::uuid, ${r.situacao}::text, ${r.passo ?? null}::text, ${r.erro ?? null}::text,
                                          ${r.tentativas}::int, ${r.proxima}::timestamptz)`;
    }),
    pegarConferencia: () => comoSistema(async (tx) => {
      const [r] = await tx`select item_id, sienge_id from erp.sienge_pegar_conferencia()`;
      return r ? { item_id: r.item_id, sienge_id: r.sienge_id } : null;
    }),
    marcarApagado: (id) => comoSistema(async (tx) => { await tx`select erp.sienge_marcar_apagado(${id}::uuid)`; }),
  };
}
