// Leitura exata do XML da nota, sem IA. Formatos: NF-e (modelo 55, 4.00), NFS-e Nacional (ADN), NFS-e de São Paulo
// (nota paulistana) e NFS-e ABRASF (a maioria das prefeituras). Um XML fora desses volta nulo e vai para a IA como
// texto. O analisador é pequeno e não resolve entidades externas nem DTD (não há XXE: a DOCTYPE é recusada).
import { type Leitura, type Parcela, data, limpar, numero, soDigitos } from './leitura.ts';

export interface No { nome: string; attrs: Record<string, string>; filhos: No[]; texto: string }

const ENT: Record<string, string> = { lt: '<', gt: '>', amp: '&', quot: '"', apos: "'" };
function desescapar(s: string) {
  return s.replace(/&(#x[0-9a-fA-F]+|#\d+|lt|gt|amp|quot|apos);/g, (_, e: string) =>
    e[0] === '#' ? String.fromCodePoint(e[1] === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)) : ENT[e]);
}
const local = (n: string) => n.slice(n.indexOf(':') + 1);

export function analisar(xml: string): No {
  if (/<!DOCTYPE/i.test(xml)) throw new Error('XML com DOCTYPE não é aceito');
  const raiz: No = { nome: '#', attrs: {}, filhos: [], texto: '' };
  const pilha: No[] = [raiz];
  const re = /<!\[CDATA\[([\s\S]*?)\]\]>|<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<\/([^\s>]+)\s*>|<([^\s/>]+)((?:\s+[^\s=]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(\/?)>|([^<]+)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml))) {
    const topo = pilha[pilha.length - 1];
    if (m[1] !== undefined) topo.texto += m[1];
    else if (m[2] !== undefined) {
      if (local(m[2]) !== topo.nome || pilha.length === 1) throw new Error('XML malformado');
      pilha.pop();
    } else if (m[3] !== undefined) {
      const attrs: Record<string, string> = {};
      for (const a of m[4].matchAll(/([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) attrs[local(a[1])] = desescapar(a[2] ?? a[3] ?? '');
      const no: No = { nome: local(m[3]), attrs, filhos: [], texto: '' };
      topo.filhos.push(no);
      if (!m[5]) pilha.push(no);
    } else if (m[6] !== undefined) topo.texto += desescapar(m[6]);
  }
  if (pilha.length !== 1) throw new Error('XML malformado');
  return raiz;
}

// Busca em profundidade pelo caminho de nomes (sem prefixo). "a/b" = b filho de algum a.
export function achar(no: No | undefined, caminho: string): No | undefined {
  return todos(no, caminho)[0];
}
export function todos(no: No | undefined, caminho: string): No[] {
  if (!no) return [];
  const [primeiro, ...resto] = caminho.split('/');
  const acc: No[] = [];
  const visitar = (n: No) => { for (const f of n.filhos) { if (f.nome === primeiro) acc.push(f); visitar(f); } };
  visitar(no);
  if (!resto.length) return acc;
  const sub = resto.join('/');
  return acc.flatMap((a) => filhosPorCaminho(a, sub));
}
function filhosPorCaminho(no: No, caminho: string): No[] {
  let atual = [no];
  for (const p of caminho.split('/')) atual = atual.flatMap((n) => n.filhos.filter((f) => f.nome === p));
  return atual;
}
const txt = (no: No | undefined, caminho?: string) => {
  const n = caminho ? achar(no, caminho) : no;
  const t = n?.texto.trim();
  return t ? t : undefined;
};
const doc = (no: No | undefined) => soDigitos(txt(no, 'CNPJ') ?? txt(no, 'CPF') ?? txt(no, 'Cnpj') ?? txt(no, 'Cpf') ?? '') || undefined;

export function lerXml(xml: string): Leitura | null {
  const raiz = analisar(xml);
  const r = achar(raiz, 'infNFe') ? nfe(raiz)
    : achar(raiz, 'infNFSe') ? nfseNacional(raiz)
    : achar(raiz, 'NumeroNFe') && achar(raiz, 'CPFCNPJPrestador') ? nfsePaulistana(raiz)
    : achar(raiz, 'InfNfse') ? nfseAbrasf(raiz)
    : null;
  return r ? limpar(r) : null;
}

function nfe(raiz: No): Leitura {
  const inf = achar(raiz, 'infNFe')!;
  const ide = achar(inf, 'ide');
  const mod = txt(ide, 'mod');
  const chave = soDigitos(txt(raiz, 'chNFe') ?? inf.attrs.Id ?? '') || undefined;
  const tot = achar(inf, 'ICMSTot');
  const ret = achar(inf, 'retTrib');
  const parcelas: Parcela[] = todos(inf, 'cobr/dup').map((d) => ({ numero: txt(d, 'nDup'), vencimento: data(txt(d, 'dVenc')), valor: numero(txt(d, 'vDup')) }));
  const avisos: string[] = [];
  if (mod && mod !== '55') avisos.push(`Modelo ${mod} (não é NF-e de modelo 55)`);
  if (!achar(raiz, 'protNFe')) avisos.push('XML sem o protocolo de autorização da SEFAZ');
  const cstat = txt(raiz, 'protNFe/infProt/cStat');
  if (cstat && cstat !== '100' && cstat !== '150') avisos.push(`Situação na SEFAZ: ${cstat} ${txt(raiz, 'protNFe/infProt/xMotivo') ?? ''}`.trim());
  return {
    origem: 'xml', formato: `NF-e ${inf.attrs.versao ?? ''}`.trim(), tipo: 'nfe',
    emitente: { documento: doc(achar(inf, 'emit')), nome: txt(inf, 'emit/xNome') },
    tomador: { documento: doc(achar(inf, 'dest')), nome: txt(inf, 'dest/xNome') },
    numero: txt(ide, 'nNF'), serie: txt(ide, 'serie'), chave_acesso: chave,
    emissao: data(txt(ide, 'dhEmi') ?? txt(ide, 'dEmi')),
    valor: numero(txt(tot, 'vNF')),
    retencoes: { pis: numero(txt(ret, 'vRetPIS')), cofins: numero(txt(ret, 'vRetCOFINS')), csll: numero(txt(ret, 'vRetCSLL')),
                 irrf: numero(txt(ret, 'vIRRF')), inss: numero(txt(ret, 'vRetPrev')) },
    descricao: txt(ide, 'natOp'),
    parcelas,
    avisos,
  };
}

// NFS-e do padrão nacional (Ambiente de Dados Nacional). Sem amostra real ainda: campos pelo leiaute da Receita.
function nfseNacional(raiz: No): Leitura {
  const inf = achar(raiz, 'infNFSe')!;
  const dps = achar(inf, 'infDPS');
  const vals = achar(dps, 'valores');
  const fed = achar(vals, 'tribFed');
  const issRetido = ['2', '3'].includes(txt(vals, 'tpRetISSQN') ?? '');
  // tpRetPisCofins: só o código 1 (retido) conta; o leiaute tem outros códigos, que ficam como não retidos até haver amostra.
  const pcRetido = txt(fed, 'tpRetPisCofins') === '1';
  return {
    origem: 'xml', formato: 'NFS-e Nacional', tipo: 'nfse',
    emitente: { documento: doc(achar(inf, 'emit')) ?? doc(achar(dps, 'prest')), nome: txt(inf, 'emit/xNome') },
    tomador: { documento: doc(achar(dps, 'toma')), nome: txt(dps, 'toma/xNome') },
    numero: txt(inf, 'nNFSe'), serie: txt(dps, 'serie'),
    chave_acesso: soDigitos(inf.attrs.Id ?? '') || undefined,
    emissao: data(txt(dps, 'dhEmi') ?? txt(inf, 'dhProc')),
    competencia: data(txt(dps, 'dCompet'))?.slice(0, 7),
    valor: numero(txt(dps, 'vServPrest/vServ')),
    valor_liquido: numero(txt(inf, 'valores/vLiq')),
    retencoes: {
      iss: issRetido ? numero(txt(inf, 'valores/vISSQN')) : undefined,
      irrf: numero(txt(fed, 'vRetIRRF')), inss: numero(txt(fed, 'vRetCP')), csll: numero(txt(fed, 'vRetCSLL')),
      pis: pcRetido ? numero(txt(fed, 'vPis')) : undefined, cofins: pcRetido ? numero(txt(fed, 'vCofins')) : undefined,
    },
    descricao: txt(dps, 'xDescServ'),
    avisos: ['Formato lido pelo leiaute nacional, ainda sem amostra real: confira os valores'],
  };
}

// Nota paulistana (NFS-e da Prefeitura de São Paulo).
function nfsePaulistana(raiz: No): Leitura {
  const n = achar(raiz, 'NumeroNFe')!;
  const nota = todos(raiz, 'NFe').find((x) => filhosPorCaminho(x, 'ChaveNFe/NumeroNFe').length) ?? raiz;
  const v = (t: string) => numero(txt(nota, t));
  const issRetido = (txt(nota, 'ISSRetido') ?? '').toLowerCase() === 'true';
  return {
    origem: 'xml', formato: 'NFS-e de São Paulo', tipo: 'nfse',
    emitente: { documento: doc(achar(nota, 'CPFCNPJPrestador')), nome: txt(nota, 'RazaoSocialPrestador') },
    tomador: { documento: doc(achar(nota, 'CPFCNPJTomador')), nome: txt(nota, 'RazaoSocialTomador') },
    numero: n.texto.trim(),
    chave_acesso: txt(nota, 'CodigoVerificacao'),
    emissao: data(txt(nota, 'DataEmissaoNFe')),
    valor: v('ValorServicos'),
    retencoes: { iss: issRetido ? v('ValorISS') : undefined, irrf: v('ValorIR'), inss: v('ValorINSS'), pis: v('ValorPIS'),
                 cofins: v('ValorCOFINS'), csll: v('ValorCSLL') },
    descricao: txt(nota, 'Discriminacao'),
  };
}

// NFS-e no padrão ABRASF (versões 1 e 2).
function nfseAbrasf(raiz: No): Leitura {
  const inf = achar(raiz, 'InfNfse')!;
  const serv = achar(inf, 'Servico') ?? achar(raiz, 'Servico');
  const vals = achar(serv, 'Valores');
  const v = (t: string) => numero(txt(vals, t));
  const issRetido = txt(vals, 'IssRetido') === '1' || txt(serv, 'IssRetido') === '1';
  const prest = achar(inf, 'PrestadorServico') ?? achar(raiz, 'Prestador');
  const toma = achar(inf, 'TomadorServico') ?? achar(raiz, 'Tomador') ?? achar(raiz, 'TomadorServico');
  return {
    origem: 'xml', formato: 'NFS-e ABRASF', tipo: 'nfse',
    emitente: { documento: doc(achar(prest, 'CpfCnpj')) ?? doc(prest), nome: txt(prest, 'RazaoSocial') },
    tomador: { documento: doc(achar(toma, 'CpfCnpj')) ?? doc(toma), nome: txt(toma, 'RazaoSocial') },
    numero: txt(inf, 'Numero'),
    chave_acesso: txt(inf, 'CodigoVerificacao'),
    emissao: data(txt(inf, 'DataEmissao')),
    competencia: data(txt(inf, 'Competencia') ?? txt(raiz, 'Competencia'))?.slice(0, 7),
    valor: v('ValorServicos'),
    valor_liquido: numero(txt(inf, 'ValorLiquidoNfse')) ?? v('ValorLiquidoNfse'),
    retencoes: { iss: issRetido ? (v('ValorIssRetido') ?? v('ValorIss') ?? numero(txt(inf, 'ValorIss'))) : undefined,
                 irrf: v('ValorIr'), inss: v('ValorInss'), pis: v('ValorPis'), cofins: v('ValorCofins'), csll: v('ValorCsll') },
    descricao: txt(serv, 'Discriminacao'),
  };
}
