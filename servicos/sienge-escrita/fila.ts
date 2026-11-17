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
import type { LinhaApagar } from './planilha.ts';

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
  // Cruzamento das linhas PRV (de madrugada, uma empresa por vez; o banco escolhe e reserva).
  pegarCruzamento(): Promise<{ empresa: number; desde: string } | null>;
  prvNossas(empresa: number): Promise<{ sienge_id: number; previsao_id: string; esperada: boolean }[]>;
  recriarPrv(previsaoId: string, siengeId: number, motivo: string): Promise<void>;
  terminarCruzamento(empresa: number, estranhas: Estranha[], resumo: Record<string, number>, erro?: string | null): Promise<number>;
  linhasApagar(): Promise<LinhaApagar[]>; // erp.v_sienge_prv_apagar, para a planilha do financeiro
}

export type Estranha = { sienge_id: number; numero: string | null; emissao: string | null; valor: number | null; observacoes: string | null; motivo: string };

export interface Http {
  ler(caminho: string): Promise<unknown>; // GET; erro se não for 2xx
  enviar(metodo: string, caminho: string, corpo: unknown): Promise<Resposta>; // erro se não for 2xx
}

export type Config = { ambiente: Ambiente; credoresTeste: number[]; agora?: () => Date };

export type Resultado =
  | { passo: 'nada a fazer'; enfileirados: number }
  | { passo: 'apagado'; previsao: string; siengeId: number; enfileirados: number }
  | { passo: 'cruzado'; empresa: number; lidas: number; recriadas: number; estranhas: number; novas: number; enfileirados: number }
  | { passo: 'cruzamento com erro'; empresa: number; erro: string; enfileirados: number }
  | { passo: 'enviado'; titulo: string; siengeId: number; criado: boolean; enfileirados: number }
  | { passo: 'erro' | 'manual'; titulo: string; erro: string; enfileirados: number };

// Depois de tantas recusas 4xx seguidas (o pedido está errado, não o momento), o título vai para manual.
export const TENTATIVAS_4XX = 3;

export async function processarUm(banco: Banco, http: Http, cfg: Config): Promise<Resultado> {
  const agora = cfg.agora ?? (() => new Date());
  const enfileirados = await banco.enfileirar();
  const item = await banco.pegar();
  if (!item) {
    const c = await conferirApagado(banco, http, enfileirados);
    return c.passo === 'nada a fazer' ? await cruzarPrv(banco, http, enfileirados, dataSaoPaulo(agora())) : c;
  }

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

// Cruzamento das linhas PRV de uma empresa com o Sienge (só leitura no Sienge):
// - a nossa esperada que não está na lista e cujo GET responde 404 sumiu: a previsão volta à fila e vai
//   outra linha (erp.sienge_recriar_prv); fora da lista sem 404 (outro erro, ou emissão fora da janela)
//   não se mexe;
// - a linha PRV da empresa que não é nossa (nem atual, nem a apagar, nem trocada) é estranha: a AF é
//   avisada das novas. Com a marca "ERP <id>" nas observações, é provável duplicada de um envio nosso.
export const PAGINA_PRV = 200;
const MAX_PAGINAS = 50;
const MARCA_ERP = /^ERP [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

type LinhaPrv = { id: number; documentNumber?: string; issueDate?: string; totalInvoiceAmount?: number; notes?: string };

async function cruzarPrv(banco: Banco, http: Http, enfileirados: number, hoje: string): Promise<Resultado> {
  const c = await banco.pegarCruzamento();
  if (!c) return { passo: 'nada a fazer', enfileirados };
  try {
    const linhas = await listarPrv(http, c.empresa, c.desde, hoje);
    const nossas = await banco.prvNossas(c.empresa);
    const naLista = new Set(linhas.map((l) => l.id));
    const conhecidas = new Set(nossas.map((n) => n.sienge_id));
    let recriadas = 0, naoConfirmadas = 0;
    for (const n of nossas) {
      if (!n.esperada || naLista.has(n.sienge_id)) continue;
      if (await sumiu(http, n.sienge_id)) {
        await banco.recriarPrv(n.previsao_id, n.sienge_id, `linha PRV ${n.sienge_id} fora da lista da empresa ${c.empresa} e 404 no Sienge`);
        recriadas++;
      } else naoConfirmadas++;
    }
    const estranhas: Estranha[] = linhas.filter((l) => !conhecidas.has(l.id)).map((l) => ({
      sienge_id: l.id, numero: l.documentNumber ?? null, emissao: l.issueDate ?? null,
      valor: typeof l.totalInvoiceAmount === 'number' ? l.totalInvoiceAmount : null, observacoes: l.notes ?? null,
      motivo: MARCA_ERP.test(l.notes ?? '') ? 'tem a marca do ERP, mas não está ligada a nenhuma previsão (duplicada?)' : 'sem a marca do ERP',
    }));
    const novas = await banco.terminarCruzamento(c.empresa, estranhas,
      { lidas: linhas.length, recriadas, nao_confirmadas: naoConfirmadas });
    return { passo: 'cruzado', empresa: c.empresa, lidas: linhas.length, recriadas, estranhas: estranhas.length, novas, enfileirados };
  } catch (e) {
    const msg = (e instanceof Error ? e.message : String(e)).slice(0, 1000);
    await banco.terminarCruzamento(c.empresa, [], {}, msg);
    return { passo: 'cruzamento com erro', empresa: c.empresa, erro: msg, enfileirados };
  }
}

// GET /bills pede startDate e endDate (emissão). Lista vazia responde 404.
async function listarPrv(http: Http, empresa: number, desde: string, hoje: string): Promise<LinhaPrv[]> {
  const todas: LinhaPrv[] = [];
  for (let pagina = 0; pagina < MAX_PAGINAS; pagina++) {
    const q = new URLSearchParams({ startDate: desde, endDate: hoje, debtorId: String(empresa),
      documentsIdentificationId: 'PRV', limit: String(PAGINA_PRV), offset: String(pagina * PAGINA_PRV) });
    let r: { results?: LinhaPrv[]; resultSetMetadata?: { total?: number } };
    try {
      r = (await http.ler(`/bills?${q}`)) as typeof r;
    } catch (e) {
      if (e instanceof ErroSienge && e.status === 404 && pagina === 0) return [];
      throw e;
    }
    const lote = Array.isArray(r?.results) ? r.results : [];
    for (const l of lote) {
      if (!Number.isInteger(l?.id)) throw new Error('lista de títulos do Sienge sem id');
      todas.push(l);
    }
    const total = r?.resultSetMetadata?.total;
    if (lote.length < PAGINA_PRV || (typeof total === 'number' && todas.length >= total)) return todas;
  }
  throw new Error(`mais de ${MAX_PAGINAS * PAGINA_PRV} linhas PRV na empresa ${empresa}: cruzamento parado`);
}

async function sumiu(http: Http, id: number): Promise<boolean> {
  try { await http.ler(`/bills/${id}`); return false; }
  catch (e) { if (e instanceof ErroSienge && e.status === 404) return true; return false; }
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
    pegarCruzamento: () => comoSistema(async (tx) => {
      const [r] = await tx`select empresa_sienge, desde::text as desde from erp.sienge_pegar_cruzamento()`;
      return r ? { empresa: r.empresa_sienge, desde: r.desde } : null;
    }),
    prvNossas: (e) => comoSistema(async (tx) =>
      (await tx`select sienge_id, previsao_id::text as previsao_id, esperada from erp.sienge_prv_nossas(${e}::int)`)
        .map((r: { sienge_id: number; previsao_id: string; esperada: boolean }) => ({ ...r }))),
    recriarPrv: (p, s, m) => comoSistema(async (tx) => { await tx`select erp.sienge_recriar_prv(${p}::uuid, ${s}::int, ${m}::text)`; }),
    terminarCruzamento: (e, est, resumo, erro) => comoSistema(async (tx) =>
      (await tx`select erp.sienge_terminar_cruzamento(${e}::int, ${JSON.stringify(est)}::jsonb, ${JSON.stringify(resumo)}::jsonb,
                                                      ${erro ?? null}::text) as n`)[0].n),
    linhasApagar: () => comoSistema(async (tx) =>
      (await tx`select previsao_id::text as previsao_id, sienge_id, empresa_sienge, data_prevista::text as data_prevista,
                       valor::text as valor, situacao_previsao, to_json(apagar_desde) #>> '{}' as apagar_desde
                  from erp.v_sienge_prv_apagar`).map((r: LinhaApagar) => ({ ...r }))),
  };
}
