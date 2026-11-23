// Busca das notas recebidas (Moises, 23/nov/2026): a parte pura, sem rede.
// NFS-e: Ambiente de Dados Nacional (ADN), GET /DFe/{NSU}?cnpjConsulta=...&lote=true (lotes de até 50, XML em gzip+base64).
// NF-e: SEFAZ, NFeDistribuicaoDFe (distNSU, até 50 por chamada, docZip em gzip+base64) e a ciência da operação
// (evento 210210, assinado com o certificado da empresa) para baixar o XML completo.
// O que sai daqui é o que o banco grava (erp.registrar_nota_recebida, erp.registrar_evento_nota_recebida).
import { gunzipSync } from 'node:zlib';
import { analisar, achar, documento, soDigitos, txt, type No } from './xml.ts';

// O que erp.registrar_nota_recebida recebe em p_nota.
export type NotaBanco = {
  tipo: 'nfe' | 'nfse'; chave: string; nsu: number; tomador: string; emitente_documento: string; emitente_nome: string | null;
  numero: string; serie: string; emissao: string; competencia: string | null; valor: number; municipio: string | null;
};
export type EventoBanco = { chave: string; codigo: string; cancelamento: boolean; nsu: number };
export type Documento =
  | { tipo: 'nota'; nota: NotaBanco; xml: string; completo: boolean }
  | { tipo: 'evento'; evento: EventoBanco; xml: string }
  | { tipo: 'outro'; nsu: number; motivo: string };

// Eventos que cancelam a nota: NF-e 110111 (cancelamento) e 110112 (por substituição); NFS-e 101101 (cancelamento) e
// 105102 (por substituição).
const CANCELAM = new Set(['110111', '110112', '101101', '105102']);

const data = (s: string | undefined) => (s && /^\d{4}-\d{2}-\d{2}/.test(s) ? s.slice(0, 10) : undefined);
const valor = (s: string | undefined) => (s !== undefined && /^\d+(\.\d+)?$/.test(s) ? Number(s) : undefined);
const semZeros = (s: string) => s.replace(/^0+/, '');
export const gunzipB64 = (b64: string) => gunzipSync(Buffer.from(b64, 'base64')).toString('utf8');

function falta(o: Record<string, unknown>): string | undefined {
  for (const [k, v] of Object.entries(o)) if (v === undefined || v === '' || (typeof v === 'number' && !Number.isFinite(v))) return k;
  return undefined;
}

// ------------------------------------------------------------------------------------------------
// NFS-e (ADN)
// ------------------------------------------------------------------------------------------------
export type DocAdn = { nsu: number; tipo: string | null; xmlGzipB64: string | null };
export type LoteAdn = { status: string; docs: DocAdn[]; maiorNsu: number | null };

// O ADN usa nomes com maiúscula (LoteDFe, NSU, TipoDocumento, ArquivoXml, StatusProcessamento); aceita minúscula também.
export function lerLoteAdn(corpo: unknown): LoteAdn {
  const o = (corpo ?? {}) as Record<string, unknown>;
  const pega = (x: Record<string, unknown>, ...ks: string[]) => { for (const k of ks) if (x[k] !== undefined) return x[k]; return undefined; };
  const lista = (pega(o, 'LoteDFe', 'loteDFe') ?? []) as Record<string, unknown>[];
  const docs = (Array.isArray(lista) ? lista : []).map((d) => ({
    nsu: Number(pega(d, 'NSU', 'nsu')),
    tipo: (pega(d, 'TipoDocumento', 'tipoDocumento') as string) ?? null,
    xmlGzipB64: (pega(d, 'ArquivoXml', 'arquivoXml') as string) ?? null,
  })).filter((d) => Number.isSafeInteger(d.nsu) && d.nsu >= 0);
  const maiorNsu = docs.length ? Math.max(...docs.map((d) => d.nsu)) : null;
  return { status: String(pega(o, 'StatusProcessamento', 'statusProcessamento') ?? ''), docs, maiorNsu };
}

// Um documento do ADN: a NFS-e (leiaute nacional) ou um evento dela. p_cnpj = a empresa consultada (tomador).
export function lerDocAdn(d: DocAdn, cnpj: string): Documento {
  if (!d.xmlGzipB64) return { tipo: 'outro', nsu: d.nsu, motivo: 'sem XML' };
  const xml = gunzipB64(d.xmlGzipB64);
  const raiz = analisar(xml);
  const ev = achar(raiz, 'infPedReg') ?? achar(raiz, 'infEvento');
  if (/evento/i.test(d.tipo ?? '') || (!achar(raiz, 'infNFSe') && ev)) {
    const chave = soDigitos(txt(ev, 'chNFSe'));
    const det = ev?.filhos.find((f) => /^e\d{6}$/.test(f.nome));
    if (chave.length !== 50 || !det) return { tipo: 'outro', nsu: d.nsu, motivo: 'evento sem chave ou sem tipo' };
    const codigo = det.nome.slice(1);
    return { tipo: 'evento', evento: { chave, codigo, cancelamento: CANCELAM.has(codigo), nsu: d.nsu }, xml };
  }
  const nota = nfse(raiz, d.nsu);
  if (typeof nota === 'string') return { tipo: 'outro', nsu: d.nsu, motivo: nota };
  if (nota.tomador !== cnpj) return { tipo: 'outro', nsu: d.nsu, motivo: nota.emitente_documento === cnpj ? 'emitida pela empresa' : 'a empresa não é a tomadora' };
  return { tipo: 'nota', nota, xml, completo: true };
}

function nfse(raiz: No, nsu: number): NotaBanco | string {
  const inf = achar(raiz, 'infNFSe');
  if (!inf) return 'não é NFS-e nacional';
  const dps = achar(inf, 'infDPS');
  const chave = soDigitos(inf.attrs.Id);
  const n = {
    tipo: 'nfse' as const, chave, nsu,
    tomador: documento(achar(dps, 'toma')) ?? '',
    emitente_documento: documento(achar(inf, 'emit')) ?? documento(achar(dps, 'prest')) ?? '',
    emitente_nome: txt(inf, 'emit/xNome') ?? null,
    numero: semZeros(soDigitos(txt(inf, 'nNFSe'))),
    serie: '',
    emissao: data(txt(dps, 'dhEmi')) ?? data(txt(inf, 'dhProc')) ?? '',
    competencia: data(txt(dps, 'dCompet')) ?? null,
    valor: valor(txt(dps, 'vServ')) ?? NaN,
    municipio: txt(inf, 'cLocIncid') ?? txt(inf, 'cLocEmi') ?? null,
  };
  if (chave.length !== 50) return 'NFS-e sem chave de 50 dígitos';
  const f = falta({ tomador: n.tomador, emitente: n.emitente_documento, numero: n.numero, emissao: n.emissao, valor: n.valor });
  return f ? `NFS-e sem ${f}` : n;
}

// ------------------------------------------------------------------------------------------------
// NF-e (SEFAZ)
// ------------------------------------------------------------------------------------------------
const NS_NFE = 'http://www.portalfiscal.inf.br/nfe';
export const URL_DIST = 'https://www1.nfe.fazenda.gov.br/NFeDistribuicaoDFe/NFeDistribuicaoDFe.asmx';
export const URL_EVENTO = 'https://www.nfe.fazenda.gov.br/NFeRecepcaoEvento4/NFeRecepcaoEvento4.asmx';
export const ACAO_DIST = 'http://www.portalfiscal.inf.br/nfe/wsdl/NFeDistribuicaoDFe/nfeDistDFeInteresse';
export const ACAO_EVENTO = 'http://www.portalfiscal.inf.br/nfe/wsdl/NFeRecepcaoEvento4/nfeRecepcaoEvento';

const soap = (corpo: string) =>
  `<?xml version="1.0" encoding="utf-8"?><soap12:Envelope xmlns:soap12="http://www.w3.org/2003/05/soap-envelope"><soap12:Body>${corpo}</soap12:Body></soap12:Envelope>`;

// Pedido da distribuição a partir do último NSU lido (a SEFAZ devolve até 50 documentos depois dele).
export function pedidoDist(cnpj: string, uf: string, ultNsu: number): string {
  if (!/^\d{14}$/.test(cnpj) || !/^\d{2}$/.test(uf) || !Number.isSafeInteger(ultNsu) || ultNsu < 0) throw new Error('pedido inválido');
  return soap(`<nfeDistDFeInteresse xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeDistribuicaoDFe"><nfeDadosMsg>`
    + `<distDFeInt xmlns="${NS_NFE}" versao="1.01"><tpAmb>1</tpAmb><cUFAutor>${uf}</cUFAutor><CNPJ>${cnpj}</CNPJ>`
    + `<distNSU><ultNSU>${String(ultNsu).padStart(15, '0')}</ultNSU></distNSU></distDFeInt></nfeDadosMsg></nfeDistDFeInteresse>`);
}

export type DocZip = { nsu: number; schema: string; xml: string };
export type RespostaDist = { cStat: string; motivo: string; ultNsu: number; maxNsu: number; docs: DocZip[] };

// 137 = nenhum documento; 138 = documentos achados; 656 = consumo indevido (a empresa fica bloqueada por 1 hora).
export function lerRespostaDist(xml: string): RespostaDist {
  const ret = achar(analisar(xml), 'retDistDFeInt');
  if (!ret) throw new Error('resposta da SEFAZ sem retDistDFeInt');
  const num = (s: string | undefined) => (s && /^\d+$/.test(s) ? Number(s) : NaN);
  const docs = (achar(ret, 'loteDistDFeInt')?.filhos ?? []).filter((f) => f.nome === 'docZip').map((f) => ({
    nsu: num(f.attrs.NSU), schema: f.attrs.schema ?? '', xml: gunzipB64(f.texto.trim()),
  }));
  const r = { cStat: txt(ret, 'cStat') ?? '', motivo: txt(ret, 'xMotivo') ?? '', ultNsu: num(txt(ret, 'ultNSU')), maxNsu: num(txt(ret, 'maxNSU')), docs };
  if (!r.cStat) throw new Error('resposta da SEFAZ sem cStat');
  return r;
}

// Um docZip da distribuição: resumo (resNFe), nota completa (procNFe) ou evento (resEvento, procEventoNFe).
export function lerDocZip(d: DocZip, cnpj: string): Documento {
  const raiz = analisar(d.xml);
  if (/^resNFe/.test(d.schema) || achar(raiz, 'resNFe')) {
    const r = achar(raiz, 'resNFe')!;
    const chave = soDigitos(txt(r, 'chNFe'));
    const n = {
      tipo: 'nfe' as const, chave, nsu: d.nsu, tomador: cnpj,      // o resumo vem só para o destinatário consultado
      emitente_documento: documento(r) ?? '', emitente_nome: txt(r, 'xNome') ?? null,
      numero: semZeros(chave.slice(25, 34)), serie: semZeros(chave.slice(22, 25)),
      emissao: data(txt(r, 'dhEmi')) ?? '', competencia: null, valor: valor(txt(r, 'vNF')) ?? NaN, municipio: null,
    };
    if (chave.length !== 44) return { tipo: 'outro', nsu: d.nsu, motivo: 'resumo sem chave' };
    const f = falta({ emitente: n.emitente_documento, numero: n.numero, emissao: n.emissao, valor: n.valor });
    return f ? { tipo: 'outro', nsu: d.nsu, motivo: `resumo sem ${f}` } : { tipo: 'nota', nota: n, xml: d.xml, completo: false };
  }
  if (/^procNFe/.test(d.schema) || achar(raiz, 'infNFe')) {
    const inf = achar(raiz, 'infNFe');
    const chave = soDigitos(inf?.attrs.Id);
    const n = {
      tipo: 'nfe' as const, chave, nsu: d.nsu, tomador: documento(achar(inf, 'dest')) ?? '',
      emitente_documento: documento(achar(inf, 'emit')) ?? '', emitente_nome: txt(inf, 'emit/xNome') ?? null,
      numero: semZeros(soDigitos(txt(inf, 'ide/nNF'))), serie: semZeros(soDigitos(txt(inf, 'ide/serie'))),
      emissao: data(txt(inf, 'ide/dhEmi')) ?? data(txt(inf, 'ide/dEmi')) ?? '', competencia: null,
      valor: valor(txt(inf, 'ICMSTot/vNF')) ?? NaN, municipio: txt(inf, 'ide/cMunFG') ?? null,
    };
    if (chave.length !== 44) return { tipo: 'outro', nsu: d.nsu, motivo: 'NF-e sem chave' };
    if (n.tomador !== cnpj) return { tipo: 'outro', nsu: d.nsu, motivo: 'a empresa não é a destinatária' };
    const f = falta({ emitente: n.emitente_documento, numero: n.numero, emissao: n.emissao, valor: n.valor });
    return f ? { tipo: 'outro', nsu: d.nsu, motivo: `NF-e sem ${f}` } : { tipo: 'nota', nota: n, xml: d.xml, completo: true };
  }
  const ev = achar(raiz, 'resEvento') ?? achar(raiz, 'infEvento');
  if (ev) {
    const chave = soDigitos(txt(ev, 'chNFe'));
    const codigo = soDigitos(txt(ev, 'tpEvento'));
    if (chave.length !== 44 || codigo.length !== 6) return { tipo: 'outro', nsu: d.nsu, motivo: 'evento sem chave ou sem tipo' };
    return { tipo: 'evento', evento: { chave, codigo, cancelamento: CANCELAM.has(codigo), nsu: d.nsu }, xml: d.xml };
  }
  return { tipo: 'outro', nsu: d.nsu, motivo: `schema ${d.schema || 'desconhecido'}` };
}

// ------------------------------------------------------------------------------------------------
// Ciência da operação (evento 210210), assinada (XMLDSig, RSA-SHA1, C14N), como a SEFAZ exige.
// O XML é montado já na forma canônica (sem espaços, atributos na ordem do C14N), então o que se assina é o que se envia.
// ------------------------------------------------------------------------------------------------
export type Assinador = { assinar: (dados: string) => string; certificadoB64: string };   // RSA-SHA1 em base64; DER do certificado

const escapar = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// Data e hora de Brasília (UTC-3, sem horário de verão desde 2019), no formato AAAA-MM-DDThh:mm:ss-03:00.
export function horaBrasilia(agora: Date): string {
  const d = new Date(agora.getTime() - 3 * 3600_000);
  return d.toISOString().slice(0, 19) + '-03:00';
}

export function eventoCiencia(cnpj: string, chave: string, agora: Date, sha1b64: (s: string) => string, a: Assinador): string {
  if (!/^\d{14}$/.test(cnpj) || !/^\d{44}$/.test(chave)) throw new Error('ciência: CNPJ ou chave inválidos');
  const id = `ID210210${chave}01`;
  const inf = `<infEvento Id="${id}"><cOrgao>91</cOrgao><tpAmb>1</tpAmb><CNPJ>${cnpj}</CNPJ><chNFe>${chave}</chNFe>`
    + `<dhEvento>${horaBrasilia(agora)}</dhEvento><tpEvento>210210</tpEvento><nSeqEvento>1</nSeqEvento><verEvento>1.00</verEvento>`
    + `<detEvento versao="1.00"><descEvento>${escapar('Ciencia da Operacao')}</descEvento></detEvento></infEvento>`;
  // no C14N o infEvento herda o xmlns do evento, e o namespace vem antes dos atributos
  const infCanonico = inf.replace('<infEvento Id=', `<infEvento xmlns="${NS_NFE}" Id=`);
  const ds = 'http://www.w3.org/2000/09/xmldsig#';
  const c14n = 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315';
  const signedInfo = `<SignedInfo><CanonicalizationMethod Algorithm="${c14n}"></CanonicalizationMethod>`
    + `<SignatureMethod Algorithm="${ds}rsa-sha1"></SignatureMethod><Reference URI="#${id}"><Transforms>`
    + `<Transform Algorithm="${ds}enveloped-signature"></Transform><Transform Algorithm="${c14n}"></Transform></Transforms>`
    + `<DigestMethod Algorithm="${ds}sha1"></DigestMethod><DigestValue>${sha1b64(infCanonico)}</DigestValue></Reference></SignedInfo>`;
  const assinatura = a.assinar(signedInfo.replace('<SignedInfo>', `<SignedInfo xmlns="${ds}">`));
  return `<evento xmlns="${NS_NFE}" versao="1.00">${inf}<Signature xmlns="${ds}">${signedInfo}<SignatureValue>${assinatura}</SignatureValue>`
    + `<KeyInfo><X509Data><X509Certificate>${a.certificadoB64}</X509Certificate></X509Data></KeyInfo></Signature></evento>`;
}

// Lote de até 20 eventos.
export function pedidoEventos(eventos: string[], lote: number): string {
  if (!eventos.length || eventos.length > 20) throw new Error('lote de eventos: de 1 a 20');
  return soap(`<nfeDadosMsg xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeRecepcaoEvento4">`
    + `<envEvento xmlns="${NS_NFE}" versao="1.00"><idLote>${lote}</idLote>${eventos.join('')}</envEvento></nfeDadosMsg>`);
}

// Resultado por chave: 135 e 136 = registrado; 573 = já registrado antes (duplicidade). Os dois contam como feito.
export function lerRespostaEventos(xml: string): { lote: string; porChave: Record<string, { cStat: string; motivo: string; feito: boolean }> } {
  const raiz = analisar(xml);
  const ret = achar(raiz, 'retEnvEvento');
  if (!ret) throw new Error('resposta da SEFAZ sem retEnvEvento');
  const porChave: Record<string, { cStat: string; motivo: string; feito: boolean }> = {};
  for (const r of ret.filhos.filter((f) => f.nome === 'retEvento')) {
    const inf = achar(r, 'infEvento');
    const chave = soDigitos(txt(inf, 'chNFe'));
    const cStat = txt(inf, 'cStat') ?? '';
    if (chave) porChave[chave] = { cStat, motivo: txt(inf, 'xMotivo') ?? '', feito: ['135', '136', '573'].includes(cStat) };
  }
  return { lote: txt(ret, 'cStat') ?? '', porChave };
}

// ------------------------------------------------------------------------------------------------
// Ritmo (regras da SEFAZ e prudência com o ADN)
// ------------------------------------------------------------------------------------------------
// Na SEFAZ, quando o último NSU alcança o máximo (ou nada veio), a empresa só volta a consultar depois de 1 hora;
// 656 bloqueia por 1 hora. Devolve até quando a empresa espera, ou null para continuar agora.
export function esperaSefaz(r: RespostaDist, agora: Date): Date | null {
  const hora = new Date(agora.getTime() + 3600_000 + 60_000);   // 1 hora e 1 minuto
  if (r.cStat === '656' || r.cStat === '137') return hora;
  if (r.cStat === '138' && Number.isFinite(r.ultNsu) && Number.isFinite(r.maxNsu) && r.ultNsu >= r.maxNsu) return hora;
  return null;
}
