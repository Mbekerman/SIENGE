// DANFE (Documento Auxiliar da NF-e) em A4 retrato, folhas soltas, no leiaute do MOC 7.0,
// Anexo II (Manual de Especificações Técnicas do DANFE e Código de Barras), versão laser.
// A SEFAZ não entrega PDF: o DANFE sempre se gera do XML autorizado (nfeProc).
//
// `dadosDanfe` lê o XML e monta os campos (testável sem PDF); `desenhaDanfe` põe na folha
// com o jsPDF, nas posições da tabela 3.8.1, em quantas folhas os itens pedirem.
// Medidas em centímetros, fontes em pontos (Times, como manda o item 3.3).

import type { jsPDF } from 'jspdf';
import { lerXml, no, nos, tx, type No } from './xml.ts';
import { cep, chaveGrupos, cnpjCpf, data, dataHora, decimal, decimalVar, fone, hora, junta } from './formato.ts';
import { code128c } from './code128.ts';
import { cabe, latin1, quebra } from './texto.ts';
import { marcaDagua, type Marca } from './danfse.ts';

export type ItemDanfe = {
  codigo: string;
  descricao: string;
  /** informações adicionais do produto (infAdProd), impressas logo abaixo da descrição */
  adicional: string;
  ncm: string;
  cst: string;
  cfop: string;
  unidade: string;
  quantidade: string;
  valorUnitario: string;
  desconto: string;
  valorTotal: string;
  bcIcms: string;
  bcIcmsSt: string;
  valorIcms: string;
  valorIcmsSt: string;
  valorIpi: string;
  aliqIcms: string;
  aliqIpi: string;
};

export type DadosDanfe = {
  chave: string;
  numero: string; // 000.000.000
  serie: string;
  tipo: string; // 0 entrada, 1 saída
  homologacao: boolean;
  emitente: { nome: string; linhas: string[]; ie: string; ieSt: string; cnpj: string; im: string };
  naturezaOperacao: string;
  protocolo: string;
  destinatario: {
    nome: string; documento: string; emissao: string; endereco: string; bairro: string; cep: string;
    entradaSaida: string; municipio: string; fone: string; uf: string; ie: string; horaSaida: string;
  };
  fatura: string;
  impostos: Record<'bcIcms' | 'icms' | 'bcIcmsSt' | 'icmsSt' | 'produtos' | 'frete' | 'seguro' | 'desconto' | 'outras' | 'ipi' | 'total', string>;
  transporte: {
    nome: string; frete: string; antt: string; placa: string; ufPlaca: string; documento: string;
    endereco: string; municipio: string; uf: string; ie: string;
    quantidade: string; especie: string; marca: string; numeracao: string; pesoBruto: string; pesoLiquido: string;
  };
  itens: ItemDanfe[];
  issqn: { im: string; servicos: string; bc: string; valor: string };
  informacoes: string;
  destinatarioCanhoto: string;
};

const MOD_FRETE: Record<string, string> = {
  '0': '0-Remetente (CIF)', '1': '1-Destinatário (FOB)', '2': '2-Terceiros',
  '3': '3-Próprio Remetente', '4': '4-Próprio Destinatário', '9': '9-Sem Transporte',
};

const v2 = (v: string) => decimal(v);

function somaVolumes(vols: No[], campo: string, casas: number): string {
  const vs = vols.map((v) => tx(v, campo)).filter((x) => x !== '');
  return vs.length ? decimal(vs.reduce((a, b) => a + Number(b), 0), casas) : '';
}
const unico = (vols: No[], campo: string) => {
  const s = [...new Set(vols.map((v) => tx(v, campo)).filter(Boolean))];
  return s.length === 1 ? s[0] : s.length > 1 ? 'Diversos' : '';
};

export function dadosDanfe(xml: string): DadosDanfe {
  const raiz = lerXml(xml);
  const nfe = raiz.nome === 'NFe' ? raiz : no(raiz, 'NFe');
  const inf = no(nfe, 'infNFe');
  if (!inf) throw new Error('XML não é de NF-e completa (falta infNFe)');
  const ide = no(inf, 'ide');
  const emit = no(inf, 'emit');
  const ee = no(emit, 'enderEmit');
  const dest = no(inf, 'dest');
  const ed = no(dest, 'enderDest');
  const tot = no(inf, 'total/ICMSTot');
  const iss = no(inf, 'total/ISSQNtot');
  const transp = no(inf, 'transp');
  const ta = no(transp, 'transporta');
  const veic = no(transp, 'veicTransp');
  const vols = nos(transp, 'vol');
  const prot = no(raiz, 'protNFe/infProt');

  const chave = (inf.atr.Id ?? '').replace(/^NFe/, '');
  const nNF = tx(ide, 'nNF').padStart(9, '0');

  const itens: ItemDanfe[] = nos(inf, 'det').map((d) => {
    const p = no(d, 'prod');
    const icms = no(d, 'imposto/ICMS')?.filhos[0];
    const ipi = no(d, 'imposto/IPI/IPITrib');
    const cst = tx(icms, 'orig') + (tx(icms, 'CST') || tx(icms, 'CSOSN'));
    return {
      codigo: tx(p, 'cProd'),
      descricao: tx(p, 'xProd'),
      adicional: tx(d, 'infAdProd'),
      ncm: tx(p, 'NCM'),
      cst,
      cfop: tx(p, 'CFOP'),
      unidade: tx(p, 'uCom'),
      quantidade: decimalVar(tx(p, 'qCom'), 2, 4),
      valorUnitario: decimalVar(tx(p, 'vUnCom'), 2, 10),
      desconto: v2(tx(p, 'vDesc')),
      valorTotal: v2(tx(p, 'vProd')),
      bcIcms: v2(tx(icms, 'vBC')),
      bcIcmsSt: v2(tx(icms, 'vBCST')),
      valorIcms: v2(tx(icms, 'vICMS')),
      valorIcmsSt: v2(tx(icms, 'vICMSST')),
      valorIpi: v2(tx(ipi, 'vIPI')),
      aliqIcms: v2(tx(icms, 'pICMS')),
      aliqIpi: v2(tx(ipi, 'pIPI')),
    };
  });

  const dups = nos(no(inf, 'cobr'), 'dup').map((d) => `${tx(d, 'nDup')} ${data(tx(d, 'dVenc'))} R$ ${v2(tx(d, 'vDup'))}`.trim());
  const fat = no(inf, 'cobr/fat');
  const fatura = dups.length
    ? dups.join('   ')
    : fat
      ? junta('  ', tx(fat, 'nFat') && 'Fatura ' + tx(fat, 'nFat'), tx(fat, 'vLiq') && 'Valor líquido R$ ' + v2(tx(fat, 'vLiq')))
      : '';

  const adic = no(inf, 'infAdic');
  const obs = nos(adic, 'obsCont').map((o) => `${o.atr.xCampo ?? ''}: ${tx(o, 'xTexto')}`);
  const informacoes = junta(
    '\n',
    tx(adic, 'infCpl') && 'Inf. contribuinte: ' + tx(adic, 'infCpl'),
    tx(adic, 'infAdFisco') && 'Inf. fisco: ' + tx(adic, 'infAdFisco'),
    obs.join('; '),
    tx(no(inf, 'compra'), 'xPed') && 'Pedido: ' + tx(no(inf, 'compra'), 'xPed'),
  );

  const endEmit = junta(', ', tx(ee, 'xLgr'), tx(ee, 'nro'), tx(ee, 'xCpl'));
  const nomeDest = tx(dest, 'xNome');

  return {
    chave,
    numero: nNF.replace(/^(\d{3})(\d{3})(\d{3})$/, '$1.$2.$3'),
    serie: tx(ide, 'serie').padStart(3, '0'),
    tipo: tx(ide, 'tpNF'),
    homologacao: tx(ide, 'tpAmb') === '2',
    emitente: {
      nome: tx(emit, 'xNome'),
      linhas: [
        endEmit,
        junta(' - ', tx(ee, 'xBairro'), cep(tx(ee, 'CEP'))),
        junta(' - ', tx(ee, 'xMun'), tx(ee, 'UF')),
        tx(ee, 'fone') ? 'Fone: ' + fone(tx(ee, 'fone')) : '',
      ].filter(Boolean),
      ie: tx(emit, 'IE'),
      ieSt: tx(emit, 'IEST'),
      cnpj: cnpjCpf(tx(emit, 'CNPJ') || tx(emit, 'CPF')),
      im: tx(emit, 'IM'),
    },
    naturezaOperacao: tx(ide, 'natOp'),
    protocolo: prot ? junta(' - ', tx(prot, 'nProt'), dataHora(tx(prot, 'dhRecbto'))) : '',
    destinatario: {
      nome: nomeDest,
      documento: cnpjCpf(tx(dest, 'CNPJ') || tx(dest, 'CPF')) || tx(dest, 'idEstrangeiro'),
      emissao: data(tx(ide, 'dhEmi')),
      endereco: junta(', ', tx(ed, 'xLgr'), tx(ed, 'nro'), tx(ed, 'xCpl')),
      bairro: tx(ed, 'xBairro'),
      cep: cep(tx(ed, 'CEP')),
      entradaSaida: data(tx(ide, 'dhSaiEnt')),
      municipio: tx(ed, 'xMun'),
      fone: fone(tx(ed, 'fone')),
      uf: tx(ed, 'UF'),
      ie: tx(dest, 'IE'),
      horaSaida: hora(tx(ide, 'dhSaiEnt')),
    },
    fatura,
    impostos: {
      bcIcms: v2(tx(tot, 'vBC')), icms: v2(tx(tot, 'vICMS')), bcIcmsSt: v2(tx(tot, 'vBCST')), icmsSt: v2(tx(tot, 'vST')),
      produtos: v2(tx(tot, 'vProd')), frete: v2(tx(tot, 'vFrete')), seguro: v2(tx(tot, 'vSeg')), desconto: v2(tx(tot, 'vDesc')),
      outras: v2(tx(tot, 'vOutro')), ipi: v2(tx(tot, 'vIPI')), total: v2(tx(tot, 'vNF')),
    },
    transporte: {
      nome: tx(ta, 'xNome'),
      frete: MOD_FRETE[tx(transp, 'modFrete')] ?? tx(transp, 'modFrete'),
      antt: tx(veic, 'RNTC'),
      placa: tx(veic, 'placa'),
      ufPlaca: tx(veic, 'UF'),
      documento: cnpjCpf(tx(ta, 'CNPJ') || tx(ta, 'CPF')),
      endereco: tx(ta, 'xEnder'),
      municipio: tx(ta, 'xMun'),
      uf: tx(ta, 'UF'),
      ie: tx(ta, 'IE'),
      quantidade: somaVolumes(vols, 'qVol', 0),
      especie: unico(vols, 'esp'),
      marca: unico(vols, 'marca'),
      numeracao: unico(vols, 'nVol'),
      pesoBruto: somaVolumes(vols, 'pesoB', 3),
      pesoLiquido: somaVolumes(vols, 'pesoL', 3),
    },
    itens,
    issqn: { im: tx(emit, 'IM'), servicos: v2(tx(iss, 'vServ')), bc: v2(tx(iss, 'vBC')), valor: v2(tx(iss, 'vISS')) },
    informacoes,
    destinatarioCanhoto: junta(' - ', nomeDest, junta(', ', tx(ed, 'xLgr'), tx(ed, 'nro'), tx(ed, 'xBairro'), junta('-', tx(ed, 'xMun'), tx(ed, 'UF')))),
  };
}

// ---------------------------------------------------------------- desenho

const X0 = 0.25, LARG = 20.57, X1 = X0 + LARG;
const PT = 2.54 / 72;
const FIM = 29.45;
const LH6 = 0.25; // linha de texto de 6 pt

type Col = { r: string; w: number; k: keyof ItemDanfe; dir?: boolean; centro?: boolean };
const COLS: Col[] = [
  { r: 'CÓDIGO', w: 1.4, k: 'codigo' },
  { r: 'DESCRIÇÃO DOS PRODUTOS/SERVIÇOS', w: 4.62, k: 'descricao' },
  { r: 'NCM/SH', w: 1.05, k: 'ncm', centro: true },
  { r: 'CST', w: 0.65, k: 'cst', centro: true },
  { r: 'CFOP', w: 0.75, k: 'cfop', centro: true },
  { r: 'UNID.', w: 0.7, k: 'unidade', centro: true },
  { r: 'QUANT.', w: 1.25, k: 'quantidade', dir: true },
  { r: 'VALOR UNIT.', w: 1.4, k: 'valorUnitario', dir: true },
  { r: 'DESC.', w: 1.05, k: 'desconto', dir: true },
  { r: 'VALOR TOTAL', w: 1.4, k: 'valorTotal', dir: true },
  { r: 'B.CÁLC. ICMS', w: 1.2, k: 'bcIcms', dir: true },
  { r: 'B.CÁLC. ICMS ST', w: 1.05, k: 'bcIcmsSt', dir: true },
  { r: 'VALOR ICMS', w: 1.05, k: 'valorIcms', dir: true },
  { r: 'VALOR ICMS ST', w: 0.9, k: 'valorIcmsSt', dir: true },
  { r: 'VALOR IPI', w: 0.9, k: 'valorIpi', dir: true },
  { r: 'ALÍQ. ICMS', w: 0.6, k: 'aliqIcms', dir: true },
  { r: 'ALÍQ. IPI', w: 0.6, k: 'aliqIpi', dir: true },
];

function campo(doc: jsPDF, x: number, y: number, w: number, h: number, rotulo: string, valor: string, o: { negrito?: boolean; dir?: boolean; tam?: number } = {}) {
  doc.setLineWidth(0.5 * PT);
  doc.rect(x, y, w, h);
  doc.setFont('times', 'normal').setFontSize(6);
  doc.text(cabe(doc, latin1(rotulo), w - 0.1), x + 0.05, y + 0.22);
  if (!valor) return;
  let tam = o.tam ?? 10;
  doc.setFont('times', o.negrito ? 'bold' : 'normal').setFontSize(tam);
  const t = latin1(valor);
  while (tam > 7 && doc.getTextWidth(t) > w - 0.1) doc.setFontSize(--tam);
  const s = cabe(doc, t, w - 0.1);
  if (o.dir) doc.text(s, x + w - 0.05, y + h - 0.14, { align: 'right' });
  else doc.text(s, x + 0.05, y + h - 0.14);
}

function titulo(doc: jsPDF, y: number, t: string) {
  doc.setFont('times', 'bold').setFontSize(5);
  doc.text(latin1(t), X0, y + 0.32);
}

function barras(doc: jsPDF, digitos: string, x: number, y: number, w: number, h: number) {
  const larg = code128c(digitos);
  const total = larg.reduce((a, b) => a + b, 0) + 20; // 10 módulos de silêncio de cada lado
  const m = Math.max(0.02, w / total);
  let cx = x + (w - (total - 20) * m) / 2;
  doc.setFillColor(0, 0, 0);
  larg.forEach((l, i) => {
    if (i % 2 === 0) doc.rect(cx, y, l * m, h, 'F');
    cx += l * m;
  });
}

/** Cabeçalho da folha (quadro do emitente, DANFE, código de barras, chave, natureza, IE). Devolve o y do fim. */
function cabecalho(doc: jsPDF, d: DadosDanfe, y0: number, folha: number, folhas: number): number {
  doc.setLineWidth(0.5 * PT);
  // Emitente
  doc.rect(X0, y0, 10.0, 3.92);
  doc.setFont('times', 'normal').setFontSize(6);
  doc.text('IDENTIFICAÇÃO DO EMITENTE', X0 + 0.05, y0 + 0.22);
  doc.setFont('times', 'bold').setFontSize(12);
  const nome = quebra(doc, latin1(d.emitente.nome), 9.4).slice(0, 2);
  let y = y0 + 0.95;
  nome.forEach((t) => { doc.text(t, X0 + 5.0, y, { align: 'center' }); y += 0.48; });
  doc.setFont('times', 'bold').setFontSize(8);
  y += 0.1;
  for (const l of d.emitente.linhas) {
    doc.text(cabe(doc, latin1(l), 9.6), X0 + 5.0, y, { align: 'center' });
    y += 0.36;
  }
  // Quadro DANFE
  const xd = 10.25, wd = 2.54, cx = xd + wd / 2;
  doc.rect(xd, y0, wd, 3.92);
  doc.setFont('times', 'bold').setFontSize(12);
  doc.text('DANFE', cx, y0 + 0.5, { align: 'center' });
  doc.setFont('times', 'normal').setFontSize(8);
  ['DOCUMENTO', 'AUXILIAR DA', 'NOTA FISCAL', 'ELETRÔNICA'].forEach((t, i) => doc.text(latin1(t), cx, y0 + 0.82 + i * 0.27, { align: 'center' }));
  doc.text('0 - ENTRADA', xd + 0.15, y0 + 1.95);
  doc.text('1 - SAÍDA', xd + 0.15, y0 + 2.27);
  doc.rect(xd + 1.95, y0 + 1.75, 0.45, 0.55);
  doc.setFont('times', 'bold').setFontSize(10);
  doc.text(d.tipo || '', xd + 2.175, y0 + 2.17, { align: 'center' });
  doc.text('Nº ' + d.numero, cx, y0 + 2.8, { align: 'center' });
  doc.text('SÉRIE ' + d.serie, cx, y0 + 3.18, { align: 'center' });
  doc.text(`FOLHA ${folha}/${folhas}`, cx, y0 + 3.56, { align: 'center' });
  // Código de barras, chave e consulta
  const xb = 12.79, wb = X1 - xb;
  doc.setLineWidth(0.5 * PT);
  doc.rect(xb, y0, wb, 1.48);
  if (/^\d{44}$/.test(d.chave)) barras(doc, d.chave, xb + 0.1, y0 + 0.24, wb - 0.2, 1.0);
  campo(doc, xb, y0 + 1.48, wb, 0.85, 'CHAVE DE ACESSO', chaveGrupos(d.chave), { negrito: true, tam: 10 });
  doc.rect(xb, y0 + 2.44, wb, 1.48);
  doc.setFont('times', 'normal').setFontSize(8);
  ['Consulta de autenticidade no portal nacional da NF-e', 'www.nfe.fazenda.gov.br/portal ou no site da Sefaz Autorizadora'].forEach((t, i) =>
    doc.text(t, xb + wb / 2, y0 + 3.05 + i * 0.36, { align: 'center' }),
  );
  // Natureza e protocolo; inscrições e CNPJ
  y = y0 + 3.92;
  campo(doc, X0, y, xb - X0, 0.85, 'NATUREZA DA OPERAÇÃO', d.naturezaOperacao);
  campo(doc, xb, y, wb, 0.85, 'PROTOCOLO DE AUTORIZAÇÃO DE USO', d.protocolo, { negrito: true });
  y += 0.85;
  campo(doc, X0, y, 6.86, 0.85, 'INSCRIÇÃO ESTADUAL', d.emitente.ie);
  campo(doc, 7.11, y, 6.86, 0.85, 'INSCRIÇÃO ESTADUAL DO SUBST. TRIBUT.', d.emitente.ieSt);
  campo(doc, 13.97, y, X1 - 13.97, 0.85, 'CNPJ', d.emitente.cnpj);
  return y + 0.85;
}

function cabecalhoItens(doc: jsPDF, y: number): number {
  let x = X0;
  const h = 0.5;
  doc.setFont('times', 'bold').setFontSize(5);
  for (const c of COLS) {
    doc.rect(x, y, c.w, h);
    const l = quebra(doc, latin1(c.r), c.w - 0.06).slice(0, 2);
    l.forEach((t, i) => doc.text(t, x + c.w / 2, y + 0.2 + i * 0.18, { align: 'center' }));
    x += c.w;
  }
  return y + h;
}

type Bloco = { item: ItemDanfe; linhas: string[]; h: number };

function preparaItens(doc: jsPDF, itens: ItemDanfe[]): Bloco[] {
  doc.setFont('times', 'normal').setFontSize(6);
  const wd = COLS[1].w - 0.08;
  return itens.map((item) => {
    const linhas = [...quebra(doc, latin1(item.descricao), wd), ...(item.adicional ? quebra(doc, latin1(item.adicional), wd) : [])];
    return { item, linhas, h: linhas.length * LH6 + 0.1 };
  });
}

function desenhaItem(doc: jsPDF, b: Bloco, y: number, linhas: string[]) {
  let x = X0;
  doc.setFont('times', 'normal').setFontSize(6);
  for (const c of COLS) {
    if (c.k === 'descricao') {
      linhas.forEach((t, i) => doc.text(t, x + 0.04, y + 0.22 + i * LH6));
    } else {
      const v = cabe(doc, latin1(b.item[c.k]), c.w - 0.06);
      if (c.dir) doc.text(v, x + c.w - 0.04, y + 0.22, { align: 'right' });
      else if (c.centro) doc.text(v, x + c.w / 2, y + 0.22, { align: 'center' });
      else doc.text(v, x + 0.04, y + 0.22);
    }
    x += c.w;
  }
}

function colunas(doc: jsPDF, y: number, h: number) {
  doc.setLineWidth(0.5 * PT);
  doc.rect(X0, y, LARG, h);
  let x = X0;
  for (const c of COLS.slice(0, -1)) {
    x += c.w;
    doc.line(x, y, x, y + h);
  }
}

/** Desenha o DANFE, a partir da página atual do `doc` (A4 retrato, unidade cm), em quantas folhas precisar. */
export function desenhaDanfe(doc: jsPDF, d: DadosDanfe, marca?: Marca) {
  doc.setDrawColor(0, 0, 0).setTextColor(0, 0, 0);
  const blocos = preparaItens(doc, d.itens);
  doc.setFont('times', 'normal').setFontSize(6);
  const info = d.informacoes ? quebra(doc, latin1(d.informacoes), 12.95 - 0.1) : [];
  const cabemQuadro = Math.floor((3.07 - 0.3) / LH6);
  // sobrando texto, a última linha do quadro avisa que continua
  const cabemInfo = info.length > cabemQuadro ? cabemQuadro - 1 : cabemQuadro;

  // Folha 1: itens entre 17.87 + cabeçalho da tabela e 24.64. Demais folhas: do fim do cabeçalho até o fim da folha.
  const ALT1 = 24.64 - (17.87 + 0.5);
  const yCont = 0.42 + 3.92 + 0.85 + 0.85; // cabeçalho repetido começa em 0.42
  const ALTN = FIM - (yCont + 0.42 + 0.5);
  // Divide os itens pelas folhas; item maior que a folha é cortado entre folhas pela descrição.
  type Pedaco = { b: Bloco; linhas: string[]; h: number };
  const folhasItens: Pedaco[][] = [[]];
  let livre = ALT1;
  for (const b of blocos) {
    let resto = b.linhas;
    while (resto.length) {
      const n = Math.max(1, Math.floor((livre - 0.1) / LH6));
      if (livre < LH6 + 0.1) { folhasItens.push([]); livre = ALTN; continue; }
      const parte = resto.slice(0, n);
      const h = parte.length * LH6 + 0.1;
      folhasItens[folhasItens.length - 1].push({ b, linhas: parte, h });
      livre -= h;
      resto = resto.slice(n);
      if (resto.length) { folhasItens.push([]); livre = ALTN; }
    }
  }
  // Informações complementares que não cabem no quadro da folha 1 continuam depois dos itens.
  let infoResto = info.slice(cabemInfo);
  const folhasInfo: string[][] = folhasItens.map(() => []);
  {
    let f = folhasItens.length - 1;
    let disp = f === 0 ? 0 : livre - 0.5;
    while (infoResto.length) {
      const n = Math.floor(disp / LH6);
      if (n > 0) {
        folhasInfo[f].push(...infoResto.slice(0, n));
        infoResto = infoResto.slice(n);
      }
      if (infoResto.length) { folhasItens.push([]); folhasInfo.push([]); f++; disp = ALTN - 0.5; }
    }
  }
  const total = folhasItens.length;

  for (let f = 0; f < total; f++) {
    if (f > 0) doc.addPage('a4', 'portrait');
    let y: number;
    if (f === 0) {
      canhoto(doc, d);
      y = cabecalho(doc, d, 2.54, 1, total);
      y = corpo(doc, d, y);
    } else {
      y = cabecalho(doc, d, 0.42, f + 1, total);
    }
    titulo(doc, y, 'DADOS DOS PRODUTOS / SERVIÇOS');
    y += 0.42;
    const yTab = y;
    y = cabecalhoItens(doc, y);
    const altTab = f === 0 ? 24.64 - yTab : FIM - yTab;
    for (const p of folhasItens[f]) {
      desenhaItem(doc, p.b, y, p.linhas);
      y += p.h;
      doc.setLineWidth(0.25 * PT).setDrawColor(150, 150, 150);
      doc.line(X0, y, X1, y);
      doc.setDrawColor(0, 0, 0);
    }
    if (folhasInfo[f].length) {
      // continuação das informações complementares, dentro da folha, abaixo dos itens
      const yi = Math.max(y + 0.1, FIM - (folhasInfo[f].length * LH6 + 0.45));
      colunas(doc, yTab + 0.5, yi - (yTab + 0.5));
      doc.rect(X0, yi, LARG, FIM - yi);
      doc.setFont('times', 'normal').setFontSize(6);
      doc.text('INFORMAÇÕES COMPLEMENTARES (CONTINUAÇÃO)', X0 + 0.05, yi + 0.22);
      folhasInfo[f].forEach((t, i) => doc.text(t, X0 + 0.05, yi + 0.47 + i * LH6));
    } else {
      colunas(doc, yTab + 0.5, altTab - 0.5);
    }
    if (f === 0) rodape(doc, d, info.length > cabemInfo ? [...info.slice(0, cabemInfo), 'Continua na folha seguinte...'] : info);
    if (d.homologacao) {
      doc.setFont('times', 'bold').setFontSize(14).setTextColor(255, 0, 0);
      doc.text('SEM VALOR FISCAL', 10.5, f === 0 ? 17.4 : yTab - 0.1, { align: 'center' });
      doc.setTextColor(0, 0, 0);
    }
    if (marca) marcaDagua(doc, marca);
  }
}

function canhoto(doc: jsPDF, d: DadosDanfe) {
  doc.setLineWidth(0.5 * PT);
  doc.rect(X0, 0.42, 16.1, 0.85);
  doc.setFont('times', 'normal').setFontSize(6);
  const t = `RECEBEMOS DE ${d.emitente.nome} OS PRODUTOS E/OU SERVIÇOS CONSTANTES DA NOTA FISCAL ELETRÔNICA INDICADA AO LADO. EMISSÃO: ${d.destinatario.emissao} VALOR TOTAL: R$ ${d.impostos.total} DESTINATÁRIO: ${d.destinatarioCanhoto}`;
  quebra(doc, latin1(t), 15.95).slice(0, 3).forEach((l, i) => doc.text(l, X0 + 0.05, 0.62 + i * 0.22));
  campo(doc, X0, 1.27, 4.1, 0.85, 'DATA DE RECEBIMENTO', '');
  campo(doc, 4.35, 1.27, 12.0, 0.85, 'IDENTIFICAÇÃO E ASSINATURA DO RECEBEDOR', '');
  doc.rect(16.35, 0.42, X1 - 16.35, 1.7);
  doc.setFont('times', 'bold').setFontSize(10);
  doc.text('NF-e', 16.35 + (X1 - 16.35) / 2, 0.85, { align: 'center' });
  doc.text('Nº ' + d.numero, 16.5, 1.38);
  doc.text('SÉRIE ' + d.serie, 16.5, 1.82);
  doc.setLineDashPattern([0.1, 0.1], 0);
  doc.line(X0, 2.33, X1, 2.33);
  doc.setLineDashPattern([], 0);
}

function corpo(doc: jsPDF, d: DadosDanfe, y0: number): number {
  const de = d.destinatario;
  titulo(doc, 8.16, 'DESTINATÁRIO / REMETENTE');
  let y = 8.58;
  campo(doc, X0, y, 12.32, 0.85, 'NOME / RAZÃO SOCIAL', de.nome);
  campo(doc, 12.57, y, 5.33, 0.85, 'CNPJ / CPF', de.documento, { negrito: true });
  campo(doc, 17.9, y, X1 - 17.9, 0.85, 'DATA DA EMISSÃO', de.emissao);
  y += 0.85;
  campo(doc, X0, y, 10.16, 0.85, 'ENDEREÇO', de.endereco);
  campo(doc, 10.41, y, 4.83, 0.85, 'BAIRRO / DISTRITO', de.bairro);
  campo(doc, 15.24, y, 2.66, 0.85, 'CEP', de.cep);
  campo(doc, 17.9, y, X1 - 17.9, 0.85, 'DATA DA SAÍDA/ENTRADA', de.entradaSaida, { negrito: true });
  y += 0.85;
  campo(doc, X0, y, 7.11, 0.85, 'MUNICÍPIO', de.municipio);
  campo(doc, 7.36, y, 4.06, 0.85, 'FONE / FAX', de.fone);
  campo(doc, 11.42, y, 1.15, 0.85, 'UF', de.uf);
  campo(doc, 12.57, y, 5.33, 0.85, 'INSCRIÇÃO ESTADUAL', de.ie);
  campo(doc, 17.9, y, X1 - 17.9, 0.85, 'HORA DA SAÍDA/ENTRADA', de.horaSaida, { negrito: true });

  titulo(doc, 11.09, 'FATURA / DUPLICATAS');
  doc.setLineWidth(0.5 * PT);
  doc.rect(X0, 11.51, LARG, 0.85);
  doc.setFont('times', 'normal').setFontSize(7);
  quebra(doc, latin1(d.fatura || '-'), LARG - 0.1).slice(0, 2).forEach((l, i) => doc.text(l, X0 + 0.05, 11.82 + i * 0.3));

  const im = d.impostos;
  titulo(doc, 12.36, 'CÁLCULO DO IMPOSTO');
  y = 12.78;
  campo(doc, X0, y, 4.06, 0.85, 'BASE DE CÁLCULO DO ICMS', im.bcIcms, { dir: true });
  campo(doc, 4.31, y, 4.06, 0.85, 'VALOR DO ICMS', im.icms, { dir: true });
  campo(doc, 8.37, y, 4.06, 0.85, 'BASE DE CÁLCULO DO ICMS ST', im.bcIcmsSt, { dir: true });
  campo(doc, 12.43, y, 4.06, 0.85, 'VALOR DO ICMS ST', im.icmsSt, { dir: true });
  campo(doc, 16.49, y, X1 - 16.49, 0.85, 'VALOR TOTAL DOS PRODUTOS', im.produtos, { dir: true });
  y += 0.85;
  campo(doc, X0, y, 3.3, 0.85, 'VALOR DO FRETE', im.frete, { dir: true });
  campo(doc, 3.55, y, 3.3, 0.85, 'VALOR DO SEGURO', im.seguro, { dir: true });
  campo(doc, 6.85, y, 3.3, 0.85, 'DESCONTO', im.desconto, { dir: true });
  campo(doc, 10.15, y, 3.3, 0.85, 'OUTRAS DESPESAS ACESSÓRIAS', im.outras, { dir: true });
  campo(doc, 13.45, y, 3.3, 0.85, 'VALOR DO IPI', im.ipi, { dir: true });
  campo(doc, 16.75, y, X1 - 16.75, 0.85, 'VALOR TOTAL DA NOTA', im.total, { dir: true, negrito: true });

  const t = d.transporte;
  titulo(doc, 14.48, 'TRANSPORTADOR / VOLUMES TRANSPORTADOS');
  y = 14.9;
  campo(doc, X0, y, 9.02, 0.85, 'NOME / RAZÃO SOCIAL', t.nome);
  campo(doc, 9.27, y, 2.79, 0.85, 'FRETE POR CONTA', t.frete, { tam: 8 });
  campo(doc, 12.06, y, 1.78, 0.85, 'CÓDIGO ANTT', t.antt);
  campo(doc, 13.84, y, 2.29, 0.85, 'PLACA DO VEÍCULO', t.placa);
  campo(doc, 16.13, y, 0.76, 0.85, 'UF', t.ufPlaca);
  campo(doc, 16.89, y, X1 - 16.89, 0.85, 'CNPJ / CPF', t.documento);
  y += 0.85;
  campo(doc, X0, y, 9.02, 0.85, 'ENDEREÇO', t.endereco);
  campo(doc, 9.27, y, 6.86, 0.85, 'MUNICÍPIO', t.municipio);
  campo(doc, 16.13, y, 0.76, 0.85, 'UF', t.uf);
  campo(doc, 16.89, y, X1 - 16.89, 0.85, 'INSCRIÇÃO ESTADUAL', t.ie);
  y += 0.85;
  campo(doc, X0, y, 2.92, 0.85, 'QUANTIDADE', t.quantidade, { dir: true });
  campo(doc, 3.17, y, 3.05, 0.85, 'ESPÉCIE', t.especie);
  campo(doc, 6.22, y, 3.05, 0.85, 'MARCA', t.marca);
  campo(doc, 9.27, y, 4.83, 0.85, 'NUMERAÇÃO', t.numeracao);
  campo(doc, 14.1, y, 3.43, 0.85, 'PESO BRUTO', t.pesoBruto, { dir: true });
  campo(doc, 17.53, y, X1 - 17.53, 0.85, 'PESO LÍQUIDO', t.pesoLiquido, { dir: true });
  return Math.max(y0, 17.45);
}

function rodape(doc: jsPDF, d: DadosDanfe, info: string[]) {
  titulo(doc, 24.64, 'CÁLCULO DO ISSQN');
  const y = 25.06;
  campo(doc, X0, y, 5.08, 0.85, 'INSCRIÇÃO MUNICIPAL', d.issqn.im);
  campo(doc, 5.33, y, 5.08, 0.85, 'VALOR TOTAL DOS SERVIÇOS', d.issqn.servicos, { dir: true });
  campo(doc, 10.41, y, 5.08, 0.85, 'BASE DE CÁLCULO DO ISSQN', d.issqn.bc, { dir: true });
  campo(doc, 15.49, y, X1 - 15.49, 0.85, 'VALOR DO ISSQN', d.issqn.valor, { dir: true });
  titulo(doc, 25.91, 'DADOS ADICIONAIS');
  doc.setLineWidth(0.5 * PT);
  doc.rect(X0, 26.33, 12.95, 3.07);
  doc.rect(13.2, 26.33, X1 - 13.2, 3.07);
  doc.setFont('times', 'normal').setFontSize(6);
  doc.text('INFORMAÇÕES COMPLEMENTARES', X0 + 0.05, 26.55);
  doc.text('RESERVADO AO FISCO', 13.25, 26.55);
  info.forEach((t, i) => doc.text(t, X0 + 0.05, 26.82 + i * LH6));
}
