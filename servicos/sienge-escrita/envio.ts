// Envio de um título aprovado do ERP ao Sienge (Moises, 17/11/2026: "Faça a adaptação da escrita").
//
// O banco monta o pedido (erp.sienge_pedido: corpo do POST /bills e as parcelas com a forma de
// pagamento) e guarda a fila (erp.sienge_envios). Aqui fica o que fala com o Sienge, em passos que
// podem ser repetidos sem duplicar nada:
//   1. Achar ou criar: se a fila ainda não tem o id do Sienge, procura um título com o marcador
//      "ERP <id>" nas observações (o programa pode ter caído entre o POST e o registro); só sem
//      achar faz o POST /bills. O id volta pelo cabeçalho Location e é registrado na hora.
//   2. Parcelas: lê as parcelas que o Sienge criou e confere com as nossas. Quantidade ou total
//      diferente é divergência: para em "manual". Vencimento diferente é corrigido (PATCH da parcela);
//      valor diferente com o mesmo total (parcelas com o valor do documento) é corrigido num PATCH em
//      massa e conferido de novo (teste de 20/11/2026, título 8677).
//   3. Pagamento: PIX ou boleto de cada parcela (PATCH, que sobrescreve; pode repetir). A previsão
//      (título PRV) não tem forma de pagamento e para no passo 2.
// Toda gravação passa por gravarComTrava() (trava.ts): a função gravar() que o programa recebe já é
// a trava. Funções puras exportadas para o teste (envio.test.ts).

export type Parcela = {
  numero: number;
  vencimento: string; // yyyy-mm-dd
  valor: number;
  forma?: 'pix' | 'boleto'; // sem forma: título PRV da previsão (não tem passo de pagamento)
  pix_tipo?: 'cpf_cnpj' | 'email' | 'telefone' | 'aleatoria';
  pix_chave?: string;
  boleto_linha?: string;
  boleto_tipo?: 1 | 2; // 1 = próprio banco, 2 = outros bancos (formas de pagamento do Sienge)
};

export type PedidoTitulo = {
  titulo_id: string;
  empresa: number;
  titulo: Record<string, unknown> & { debtorId: number; creditorId: number; documentNumber: string; issueDate: string; notes: string };
  parcelas: Parcela[];
};

export type Resposta = { status: number; location?: string | null; corpo?: unknown };

export type Api = {
  ler: (caminho: string) => Promise<unknown>; // GET; erro se não for 2xx
  gravar: (metodo: string, caminho: string, corpo: unknown) => Promise<Resposta>; // já passa pela trava
  registrarCriado: (siengeId: number) => Promise<void>; // erp.sienge_registrar, antes de seguir
  hoje: () => string; // yyyy-mm-dd
};

export class Divergencia extends Error {}

// Resposta do Sienge fora de 2xx. A pesquisa de títulos sem resultado responde 404 "Resource not found"
// (visto em 17/11/2026), por isso quem pesquisa trata 404 como lista vazia.
// retryAfter: segundos pedidos pelo Sienge no cabeçalho Retry-After (429 e 503), quando vem (S-044).
export class ErroSienge extends Error {
  readonly status: number;
  readonly retryAfter: number | null;
  constructor(status: number, mensagem: string, retryAfter: number | null = null) {
    super(mensagem);
    this.status = status;
    this.retryAfter = retryAfter;
  }
}

// Erro que não se resolve tentando de novo: 4xx, menos tempo esgotado (408) e limite de chamadas (429).
export function erroPermanente(e: unknown): boolean {
  return e instanceof ErroSienge && e.status >= 400 && e.status < 500 && e.status !== 408 && e.status !== 429;
}

// Retry-After em segundos ou em data HTTP; null quando não vem ou não se entende.
export function segundosRetryAfter(valor: string | null, agora: Date): number | null {
  if (!valor) return null;
  const v = valor.trim();
  if (/^\d+$/.test(v)) return Number(v);
  const d = Date.parse(v);
  return Number.isNaN(d) ? null : Math.max(0, Math.ceil((d - agora.getTime()) / 1000));
}

export const PIX_SIENGE = 14; // forma de pagamento PIX no Sienge (lida no título 8547, 17/11/2026)

export function marcador(tituloId: string): string {
  return `ERP ${tituloId}`;
}

// As observações começam pelo marcador inteiro (seguido de espaço ou fim): "ERP u1" não casa com "ERP u12".
export function temMarcador(notes: unknown, tituloId: string): boolean {
  if (typeof notes !== 'string') return false;
  const m = marcador(tituloId);
  return notes === m || notes.startsWith(`${m} `);
}

// Location: .../bills/8547 → 8547
export function idDoLocation(location: string | null | undefined): number | null {
  const m = /\/bills\/(\d+)\/?$/.exec((location ?? '').trim());
  return m ? Number(m[1]) : null;
}

// Linha digitável (47) → código de barras (44), conferindo os dígitos.
export function barrasDaLinha(linha: string): string {
  if (!/^\d{47}$/.test(linha)) throw new Error('linha digitável precisa de 47 dígitos');
  const m10 = (s: string) => {
    let t = 0, m = 2;
    for (let i = s.length - 1; i >= 0; i--) {
      const d = Number(s[i]) * m;
      t += Math.floor(d / 10) + (d % 10);
      m = m === 2 ? 1 : 2;
    }
    return (10 - (t % 10)) % 10;
  };
  const campos: [string, string][] = [[linha.slice(0, 9), linha[9]], [linha.slice(10, 20), linha[20]], [linha.slice(21, 31), linha[31]]];
  for (const [c, dv] of campos) if (m10(c) !== Number(dv)) throw new Error('dígito de campo da linha digitável não confere');
  const barras = linha.slice(0, 4) + linha[32] + linha.slice(33, 47) + linha.slice(4, 9) + linha.slice(10, 20) + linha.slice(21, 31);
  let s = 0, m = 2;
  for (let i = 43; i >= 0; i--) {
    if (i === 4) continue;
    s += Number(barras[i]) * m;
    m = m === 9 ? 2 : m + 1;
  }
  let dv = 11 - (s % 11);
  if (dv === 0 || dv === 10 || dv === 11) dv = 1;
  if (dv !== Number(barras[4])) throw new Error('dígito geral do boleto não confere');
  return barras;
}

// O Sienge pede a chave "com máscara" (CPF e CNPJ formatados). O CNPJ alfanumérico (com letras) não vai: o Sienge
// recusa letras no CNPJ (GET /creditors, 400 em 23/nov/2026); a parcela fica para pôr à mão no Sienge.
export function chavePix(tipo: Parcela['pix_tipo'], chave: string): { keyPixType: string; keyPix: string } {
  switch (tipo) {
    case 'cpf_cnpj': {
      const d = chave.toUpperCase().replace(/[^0-9A-Z]/g, '');
      if (/[A-Z]/.test(d)) throw new Divergencia('o Sienge ainda não aceita chave PIX com CNPJ alfanumérico: ponha a forma de pagamento à mão no Sienge');
      if (d.length === 11) return { keyPixType: 'C', keyPix: `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}` };
      if (d.length === 14) return { keyPixType: 'C', keyPix: `${d.slice(0, 2)}.${d.slice(2, 5)}.${d.slice(5, 8)}/${d.slice(8, 12)}-${d.slice(12)}` };
      throw new Error('CPF ou CNPJ da chave PIX com tamanho errado');
    }
    case 'email': return { keyPixType: 'E', keyPix: chave };
    case 'telefone': return { keyPixType: 'T', keyPix: chave };
    case 'aleatoria': return { keyPixType: 'A', keyPix: chave };
    default: throw new Error(`tipo de chave PIX desconhecido: ${tipo}`);
  }
}

// O PATCH da forma de pagamento de uma parcela: caminho (sem a base) e corpo.
// isUsingCreditorData sempre "N": o PIX do cadastro do credor nunca é usado (regra de 8/11/2026).
export function pagamentoDaParcela(siengeId: number, p: Parcela, tituloId: string): { caminho: string; corpo: Record<string, unknown> } {
  const base = `/bills/${siengeId}/installments/${p.numero}/payment-information`;
  const notes = `${marcador(tituloId)} parcela ${p.numero}`;
  if (p.forma === 'pix') {
    if (!p.pix_chave) throw new Error(`parcela ${p.numero} sem chave PIX`);
    return { caminho: `${base}/pix`, corpo: { paymentTypeId: PIX_SIENGE, notes, isUsingCreditorData: 'N', ...chavePix(p.pix_tipo, p.pix_chave) } };
  }
  if (p.forma === 'boleto') {
    if (!p.boleto_linha || !p.boleto_tipo) throw new Error(`parcela ${p.numero} sem boleto`);
    return {
      caminho: `${base}/boleto-bancario`,
      corpo: { paymentTypeId: p.boleto_tipo, notes, boletoBancarioBarCodeNumber: barrasDaLinha(p.boleto_linha), boletoBancarioManualBarCodeNumber: p.boleto_linha },
    };
  }
  throw new Error(`forma de pagamento desconhecida na parcela ${p.numero}`);
}

type ParcelaSienge = { installmentNumber: number; dueDate: string; amount: number };

function lista(r: unknown): Record<string, unknown>[] {
  const x = (r && typeof r === 'object' && 'results' in (r as object)) ? (r as { results: unknown }).results : r;
  return Array.isArray(x) ? (x as Record<string, unknown>[]) : [];
}

// Compara as parcelas do Sienge com as nossas: devolve o que corrigir em cada parcela (vencimento e,
// com parcelas de valores diferentes, o valor), ou Divergencia. O POST /bills divide o total igual; o
// valor de cada parcela se corrige depois, só sem mudar o total (teste de 20/11/2026, título 8677:
// PATCH em massa de 1,50 + 1,50 para 1,00 + 2,00 deu 204 e o total ficou 3,00; mudar o total é recusado
// com 400). Quantidade ou total diferente é divergência.
export type Correcao = { numero: number; dueDate?: string; amount?: number };
export function conferirParcelas(nossas: Parcela[], doSienge: ParcelaSienge[]): Correcao[] {
  if (nossas.length !== doSienge.length) {
    throw new Divergencia(`o Sienge criou ${doSienge.length} parcelas; o ERP tem ${nossas.length}`);
  }
  const cent = (v: number) => Math.round(v * 100);
  const soma = (xs: number[]) => xs.reduce((a, b) => a + cent(b), 0);
  const totalSienge = soma(doSienge.map((x) => x.amount));
  const totalErp = soma(nossas.map((x) => x.valor));
  if (totalSienge !== totalErp) {
    throw new Divergencia(`total das parcelas: Sienge ${(totalSienge / 100).toFixed(2)}, ERP ${(totalErp / 100).toFixed(2)}`);
  }
  const corrigir: Correcao[] = [];
  for (const p of nossas) {
    const s = doSienge.find((x) => x.installmentNumber === p.numero);
    if (!s) throw new Divergencia(`parcela ${p.numero} não existe no Sienge`);
    const c: Correcao = { numero: p.numero };
    if (cent(s.amount) !== cent(p.valor)) c.amount = cent(p.valor) / 100;
    if (s.dueDate !== p.vencimento) c.dueDate = p.vencimento;
    if (c.amount !== undefined || c.dueDate !== undefined) corrigir.push(c);
  }
  return corrigir;
}

async function parcelasDoSienge(api: Api, id: number): Promise<ParcelaSienge[]> {
  return lista(await api.ler(`/bills/${id}/installments`)).map((x) => ({
    installmentNumber: Number(x.installmentNumber), dueDate: String(x.dueDate), amount: Number(x.amount),
  }));
}

// Procura no Sienge o título com o nosso marcador (mesma empresa, credor e número do documento, emitido
// de issueDate até hoje). Achou um com o marcador: é o nosso (o programa caiu entre o POST e o registro).
// Achou só sem o marcador: título lançado fora do ERP com o mesmo número, divergência.
export async function acharPeloMarcador(api: Api, ped: PedidoTitulo): Promise<number | null> {
  const t = ped.titulo;
  const q = new URLSearchParams({
    startDate: String(t.issueDate), endDate: api.hoje() > String(t.issueDate) ? api.hoje() : String(t.issueDate),
    debtorId: String(t.debtorId), creditorId: String(t.creditorId), documentNumber: String(t.documentNumber), limit: '200',
  });
  let r: unknown;
  try { r = await api.ler(`/bills?${q}`); } catch (e) {
    if (e instanceof ErroSienge && e.status === 404) r = [];
    else throw e;
  }
  const todos = lista(r);
  const achados = todos.filter((b) => temMarcador(b.notes, ped.titulo_id));
  if (achados.length > 1) throw new Divergencia(`${achados.length} títulos no Sienge com o marcador ${marcador(ped.titulo_id)}`);
  if (achados.length) return Number(achados[0].id);
  // Mesmo credor e número, sem o nosso marcador: alguém lançou a nota direto no Sienge (S-044). Não cria outro.
  if (todos.length) {
    throw new Divergencia(`já existe no Sienge título do mesmo credor e número sem o marcador do ERP: ${todos.map((b) => b.id).join(', ')}`);
  }
  return null;
}

// Os três passos. siengeId: o que a fila já tem (nulo na primeira vez).
export async function enviarTitulo(api: Api, ped: PedidoTitulo, siengeId: number | null): Promise<{ siengeId: number; criado: boolean }> {
  if (!temMarcador(ped.titulo.notes, ped.titulo_id)) throw new Error('pedido sem o marcador do ERP nas observações');
  let criado = false;
  let id = siengeId;
  if (id === null) {
    id = await acharPeloMarcador(api, ped);
    if (id === null) {
      const r = await api.gravar('POST', '/bills', ped.titulo);
      id = idDoLocation(r.location);
      if (r.status !== 201 || id === null) throw new Error(`POST /bills respondeu ${r.status} sem o id do título`);
      criado = true;
    }
    await api.registrarCriado(id);
  }
  const corrigir = conferirParcelas(ped.parcelas, await parcelasDoSienge(api, id));
  if (corrigir.some((c) => c.amount !== undefined)) {
    // valores diferentes: um PATCH em massa só, que o Sienge aplica inteiro ou nada (o total não muda)
    await api.gravar('PATCH', `/bills/${id}/installments`, corrigir.map((c) => ({
      installmentId: c.numero,
      ...(c.amount !== undefined ? { amount: c.amount } : {}),
      ...(c.dueDate !== undefined ? { dueDate: c.dueDate } : {}),
    })));
    const resta = conferirParcelas(ped.parcelas, await parcelasDoSienge(api, id));
    if (resta.length) throw new Divergencia(`o Sienge não aceitou corrigir as parcelas ${resta.map((c) => c.numero).join(', ')}`);
  } else {
    for (const c of corrigir) await api.gravar('PATCH', `/bills/${id}/installments/${c.numero}`, { dueDate: c.dueDate });
  }
  for (const p of ped.parcelas) {
    if (!p.forma) continue; // a previsão (PRV) vai sem forma de pagamento
    const g = pagamentoDaParcela(id, p, ped.titulo_id);
    await api.gravar('PATCH', g.caminho, g.corpo);
  }
  return { siengeId: id, criado };
}

// Espera até a próxima tentativa: 1, 2, 4... minutos, no máximo 6 horas.
export function proximaTentativa(tentativas: number, agora: Date): Date {
  const min = Math.min(2 ** Math.max(0, tentativas - 1), 360);
  return new Date(agora.getTime() + min * 60_000);
}
