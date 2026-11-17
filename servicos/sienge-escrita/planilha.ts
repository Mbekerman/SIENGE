// Planilha do Google, só leitura para o financeiro, com as linhas PRV a apagar à mão no Sienge
// (decisão do Moises, 14/11/2026; conta de serviço do Google, 17/11/2026). O programa reescreve a
// aba inteira a partir de erp.v_sienge_prv_apagar: quem apaga no Sienge não mexe na planilha, e a linha
// some sozinha quando a conferência vê o 404 (erp.sienge_marcar_apagado).
//
// A conta de serviço só tem acesso a esta planilha (compartilhada com ela como Editor); não tem papel no
// projeto do Google Cloud. A chave fica no segredo GOOGLE_PLANILHA_CHAVE (JSON inteiro) e nunca é gravada
// nem devolvida. Sem dependência: JWT RS256 assinado com WebCrypto (Deno e Node 22).

export type LinhaApagar = {
  previsao_id: string; sienge_id: number; empresa_sienge: string | null; data_prevista: string | null;
  valor: number | string | null; situacao_previsao: string; apagar_desde: string;
};

export type ChaveServico = { client_email: string; private_key: string; token_uri?: string };

export const ESCOPO = 'https://www.googleapis.com/auth/spreadsheets';
const TOKEN_URI = 'https://oauth2.googleapis.com/token';
const SHEETS = 'https://sheets.googleapis.com/v4/spreadsheets';
export const ABA = 'PRV a apagar';
export const CABECALHO = ['Empresa (Sienge)', 'Título no Sienge', 'Documento', 'Valor', 'Data prevista', 'Na lista desde', 'Situação da previsão'];

const SITUACAO: Record<string, string> = { cancelada: 'Cancelada', encerrada: 'Encerrada', consumida: 'Consumida pela nota', aberta: 'Aberta' };

export function lerChave(json: string | undefined): ChaveServico {
  if (!json) throw new Error('falta o segredo GOOGLE_PLANILHA_CHAVE');
  let c: Partial<ChaveServico>;
  try { c = JSON.parse(json); } catch { throw new Error('GOOGLE_PLANILHA_CHAVE não é um JSON'); }
  if (typeof c.client_email !== 'string' || typeof c.private_key !== 'string' || !c.private_key.includes('PRIVATE KEY')) {
    throw new Error('GOOGLE_PLANILHA_CHAVE sem client_email ou private_key');
  }
  // só o Google emite o token: nunca mandar a assinatura para outro endereço que venha no arquivo
  if (c.token_uri !== undefined && c.token_uri !== TOKEN_URI) throw new Error('GOOGLE_PLANILHA_CHAVE com token_uri inesperado');
  return { client_email: c.client_email, private_key: c.private_key };
}

// O id da planilha (aceita o link inteiro).
export function idPlanilha(v: string | undefined): string {
  const m = (v ?? '').match(/\/spreadsheets\/d\/([A-Za-z0-9_-]{20,})/) ?? (v ?? '').match(/^([A-Za-z0-9_-]{20,})$/);
  if (!m) throw new Error('PLANILHA_PRV_ID ausente ou inválido');
  return m[1];
}

export function linhasDaPlanilha(linhas: LinhaApagar[]): (string | number)[][] {
  const ordenadas = [...linhas].sort((a, b) => a.apagar_desde.localeCompare(b.apagar_desde) || a.sienge_id - b.sienge_id);
  return [CABECALHO, ...ordenadas.map((l) => [
    l.empresa_sienge ?? '',
    l.sienge_id,
    'PRV-' + l.previsao_id.replace(/-/g, '').slice(0, 12).toUpperCase(),
    l.valor === null ? '' : Number(l.valor),
    l.data_prevista ?? '',
    dataHoraSaoPaulo(new Date(l.apagar_desde)),
    SITUACAO[l.situacao_previsao] ?? l.situacao_previsao,
  ])];
}

function dataHoraSaoPaulo(d: Date): string {
  return new Intl.DateTimeFormat('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' }).format(d);
}

const b64url = (b: Uint8Array | string) =>
  btoa(typeof b === 'string' ? unescape(encodeURIComponent(b)) : String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

export async function jwtServico(c: ChaveServico, agora: Date): Promise<string> {
  const iat = Math.floor(agora.getTime() / 1000);
  const corpo = `${b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))}.${b64url(JSON.stringify({
    iss: c.client_email, scope: ESCOPO, aud: TOKEN_URI, iat, exp: iat + 3600,
  }))}`;
  const pem = c.private_key.replace(/-----[A-Z ]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), (x) => x.charCodeAt(0));
  const k = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', k, new TextEncoder().encode(corpo)));
  return `${corpo}.${b64url(sig)}`;
}

async function pedir(buscar: typeof fetch, url: string, init: RequestInit, o_que: string): Promise<unknown> {
  const r = await buscar(url, { ...init, signal: AbortSignal.timeout(30_000) });
  const t = await r.text();
  // a resposta de erro do Google não traz segredo; o corpo do pedido (com o token) nunca entra na mensagem
  if (!r.ok) throw new Error(`Google ${o_que} respondeu ${r.status}: ${t.slice(0, 200)}`);
  return t ? JSON.parse(t) : null;
}

export async function tokenGoogle(c: ChaveServico, agora: Date, buscar: typeof fetch = fetch): Promise<string> {
  const r = await pedir(buscar, TOKEN_URI, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: await jwtServico(c, agora) }),
  }, 'token') as { access_token?: string };
  if (!r?.access_token) throw new Error('Google token sem access_token');
  return r.access_token;
}

// Reescreve a aba: grava a lista nova por cima e só depois limpa o que sobrou embaixo (se a segunda
// chamada falhar, fica linha velha a mais, nunca a planilha vazia).
export async function escreverPlanilha(id: string, token: string, valores: (string | number)[][], buscar: typeof fetch = fetch): Promise<void> {
  const h = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  await pedir(buscar, `${SHEETS}/${id}/values/${encodeURIComponent(`'${ABA}'!A1`)}?valueInputOption=RAW`,
    { method: 'PUT', headers: h, body: JSON.stringify({ range: `'${ABA}'!A1`, majorDimension: 'ROWS', values: valores }) }, 'gravar');
  const resto = encodeURIComponent(`'${ABA}'!A${valores.length + 1}:G`);
  await pedir(buscar, `${SHEETS}/${id}/values/${resto}:clear`, { method: 'POST', headers: h, body: '{}' }, 'limpar');
}

export async function atualizarPlanilha(ler: () => Promise<LinhaApagar[]>, chave: ChaveServico, id: string, agora: Date,
                                        buscar: typeof fetch = fetch): Promise<{ linhas: number }> {
  const linhas = await ler();
  await escreverPlanilha(id, await tokenGoogle(chave, agora, buscar), linhasDaPlanilha(linhas), buscar);
  return { linhas: linhas.length };
}
