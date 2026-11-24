// DANFSe v2.0 (Documento Auxiliar da NFS-e) no leiaute da NT 008/2026 v1.02 do Sistema
// Nacional da NFS-e, gerado a partir do XML da NFS-e. Desde 03/08/2026 o Ambiente de Dados
// Nacional não entrega mais o PDF: quem guarda o XML gera o DANFSe.
//
// Duas partes: `dadosDanfse` lê o XML e monta o que vai em cada campo (testável sem PDF);
// `desenhaDanfse` põe isso na folha A4 com o jsPDF, nas posições da tabela 2.4.5 da NT.
// Medidas em centímetros, fontes em pontos.

import type { jsPDF } from 'jspdf';
import qrcode from 'qrcode-generator';
import { lerXml, no, tx, type No } from './xml.ts';
import { cep, cnpjCpf, data, dataHora, decimal, fone, junta, pct, reais, ufDoIbge } from './formato.ts';
import { LOGO_NFSE } from './logo-nfse.ts';
import { cabe, latin1, quebra } from './texto.ts';

export type Celula = {
  x: number;
  w: number;
  rotulo: string;
  valor: string;
  /** rótulo 7 pt em caixa alta (identificação e valores em destaque) */
  forte?: boolean;
  /** fundo cinza 5% */
  cinza?: boolean;
  /** título do bloco (7 pt, negrito, caixa alta, fundo cinza) */
  titulo?: boolean;
};
export type Linha = { h: number; celulas: Celula[] };
export type Bloco = { linhas: Linha[] } | { aviso: string };

export type DadosDanfse = {
  chave: string;
  urlConsulta: string;
  municipio: string;
  ambienteGerador: string;
  tipoAmbiente: string;
  homologacao: boolean;
  identificacao: Linha[];
  /** prestador, tomador, destinatário e intermediário */
  pessoas: Bloco[];
  servico: Linha;
  descricaoCodigo: string;
  descricaoServico: string;
  /** tributação municipal, federal, IBS/CBS e valor total */
  valores: Bloco[];
  informacoes: string;
  totaisTributos: string;
};

export type OpcoesNota = {
  /** nome do município pelo código IBGE de 7 dígitos */
  municipio?: (cMun: string) => string;
};

// Colunas da NT (cm)
const C1 = 0.3, C2 = 5.41, C3 = 10.51, C4 = 15.62, W = 5.09, W2 = 10.19, LARG = 20.4;
const H = 0.645;

const TP_EMIT: Record<string, string> = { '1': 'Prestador', '2': 'Tomador', '3': 'Intermediário' };
const C_STAT: Record<string, string> = {
  '100': 'NFS-e Gerada',
  '101': 'NFS-e de Substituição Gerada',
  '102': 'NFS-e de Decisão Judicial',
  '103': 'NFS-e Avulsa',
  '107': 'NFS-e MEI',
};
const FIN: Record<string, string> = { '0': 'NFS-e regular' };
const OP_SN: Record<string, string> = { '1': 'Não Optante', '2': 'Optante - Microempreendedor Individual (MEI)', '3': 'Optante - Microempresa ou Empresa de Pequeno Porte (ME/EPP)' };
const REG_SN: Record<string, string> = {
  '1': 'Regime de apuração dos tributos federais e municipal pelo Simples Nacional',
  '2': 'Regime de apuração dos tributos federais pelo SN e o ISSQN pela NFS-e conforme respectiva legislação municipal do tributo',
  '3': 'Regime de apuração dos tributos federais e municipal pela NFS-e conforme respectivas legislações federal e municipal de cada tributo',
};
const TRIB_ISS: Record<string, string> = { '1': 'Operação Tributável', '2': 'Imunidade', '3': 'Exportação de Serviço', '4': 'Não Incidência' };
const REG_ESP: Record<string, string> = {
  '0': 'Nenhum', '1': 'Ato Cooperado (Cooperativa)', '2': 'Estimativa', '3': 'Microempresa Municipal',
  '4': 'Notário ou Registrador', '5': 'Profissional Autônomo', '6': 'Sociedade de Profissionais', '9': 'Outros',
};
const IMUN: Record<string, string> = {
  '0': 'Imunidade (tipo não informado na nota de origem)',
  '1': 'Patrimônio, renda ou serviços, uns dos outros (CF88, Art 150, VI, a)',
  '2': 'Templos de qualquer culto (CF88, Art 150, VI, b)',
  '3': 'Patrimônio, renda ou serviços dos partidos políticos, inclusive suas fundações, das entidades sindicais dos trabalhadores, das instituições de educação e de assistência social, sem fins lucrativos, atendidos os requisitos da lei (CF88, Art 150, VI, c)',
  '4': 'Livros, jornais, periódicos e o papel destinado a sua impressão (CF88, Art 150, VI, d)',
  '5': 'Fonogramas e videofonogramas musicais produzidos no Brasil contendo obras musicais ou literomusicais de autores brasileiros e/ou obras em geral interpretadas por artistas brasileiros bem como os suportes materiais ou arquivos digitais que os contenham, salvo na etapa de replicação industrial de mídias ópticas de leitura a laser (CF88, Art 150, VI, e)',
};
const SUSP: Record<string, string> = { '1': 'Exigibilidade Suspensa por Decisão Judicial', '2': 'Exigibilidade Suspensa por Processo Administrativo' };
const TP_BM: Record<string, string> = { '1': 'Isenção', '2': 'Redução da BC em ppBM %', '3': 'Redução da BC em R$', '4': 'Alíquota Diferenciada' };
const RET_ISS: Record<string, string> = { '1': 'Não Retido', '2': 'Retido pelo Tomador', '3': 'Retido pelo Intermediário' };
const RET_PC: Record<string, string> = {
  '0': 'PIS/COFINS/CSLL Não Retidos', '1': 'PIS/COFINS Retidos', '2': 'PIS/COFINS Não Retidos',
  '3': 'PIS/COFINS/CSLL Retidos', '4': 'PIS/COFINS Retidos, CSLL Não Retido', '5': 'PIS Retido, COFINS/CSLL Não Retido',
  '6': 'COFINS Retido, PIS/CSLL Não Retido', '7': 'PIS Não Retido, COFINS/CSLL Retidos',
  '8': 'PIS/COFINS Não Retidos, CSLL Retido', '9': 'COFINS Não Retido, PIS/CSLL Retidos',
};
const AMB_GER: Record<string, string> = { '1': 'Prefeitura', '2': 'Sistema Nacional da NFS-e' };
const TP_AMB: Record<string, string> = { '1': 'Produção', '2': 'Homologação' };

const desc = (m: Record<string, string>, v: string) => (v ? m[v] ?? v : '');
const n = (v: string) => (v === '' ? 0 : Number(v) || 0);
const tem = (...v: string[]) => v.some((x) => x !== '');
const soma = (...v: string[]) => (tem(...v) ? reais(v.reduce((a, b) => a + n(b), 0)) : '');

/** "030301" -> "03.03.01" */
export const codTribNac = (c: string) => (/^\d{6}$/.test(c) ? c.replace(/^(\d{2})(\d{2})(\d{2})$/, '$1.$2.$3') : c);
/** "118066100" -> "1.1806.61.00" */
export const codNbs = (c: string) => (/^\d{9}$/.test(c) ? c.replace(/^(\d)(\d{4})(\d{2})(\d{2})$/, '$1.$2.$3.$4') : c);

const cel = (x: number, w: number, rotulo: string, valor: string, extra: Partial<Celula> = {}): Celula => ({ x, w, rotulo, valor, ...extra });
const tit = (t: string): Celula => ({ x: C1, w: W, rotulo: t, valor: '', titulo: true });
const linha = (...celulas: Celula[]): Linha => ({ h: H, celulas });

function documento(el: No | undefined): string {
  return cnpjCpf(tx(el, 'CNPJ')) || cnpjCpf(tx(el, 'CPF')) || tx(el, 'NIF') || desc({ '1': 'Dispensado do NIF', '2': 'Não exigência do NIF' }, tx(el, 'cNaoNIF'));
}

/** Endereço do prestador, tomador, destinatário ou intermediário: o `end` da DPS ou o `enderNac` do emitente. */
function endereco(el: No | undefined, municipio: (c: string) => string) {
  const end = no(el, 'end') ?? no(el, 'enderNac');
  const nac = no(end, 'endNac') ?? (tx(end, 'cMun') ? end : undefined);
  const ext = no(end, 'endExt');
  const cMun = tx(nac, 'cMun');
  const uf = tx(nac, 'UF') || ufDoIbge(cMun);
  const munUf = nac ? junta(' / ', municipio(cMun) || cMun, uf) : ext ? junta(' / ', tx(ext, 'xCidade'), tx(ext, 'xEstProvReg')) : '';
  const codCep = nac ? junta(' / ', cMun, cep(tx(nac, 'CEP'))) : ext ? junta(' / ', tx(ext, 'cPais'), tx(ext, 'cEndPost')) : '';
  const rua = junta(', ', tx(end, 'xLgr'), tx(end, 'nro'), tx(end, 'xCpl'), tx(end, 'xBairro'));
  return { munUf, codCep, rua };
}

function pessoa(titulo: string, el: No | undefined, municipio: (c: string) => string, comIm = true): Linha[] {
  const e = endereco(el, municipio);
  return [
    linha(tit(titulo), cel(C2, W, 'CNPJ / CPF / NIF', documento(el)), ...(comIm ? [cel(C3, W, 'Indicador Municipal (Inscrição)', tx(el, 'IM'))] : []), cel(C4, W, 'Telefone', fone(tx(el, 'fone')))),
    linha(cel(C1, W2, 'Nome / Nome Empresarial', tx(el, 'xNome')), cel(C3, W, 'Município / Sigla UF', e.munUf), cel(C4, W, 'Código IBGE / CEP', e.codCep)),
    linha(cel(C1, W2, 'Endereço', e.rua), cel(C3, W2, 'E-mail', tx(el, 'email'))),
  ];
}

export function dadosDanfse(xml: string, op: OpcoesNota = {}): DadosDanfse {
  const municipio = op.municipio ?? (() => '');
  const raiz = lerXml(xml);
  const inf = raiz.nome === 'infNFSe' ? raiz : no(raiz, 'infNFSe');
  if (!inf) throw new Error('XML não é de NFS-e (falta infNFSe)');
  const dps = no(inf, 'DPS/infDPS');
  const emit = no(inf, 'emit');
  const prest = no(dps, 'prest');
  const toma = no(dps, 'toma');
  const interm = no(dps, 'interm');
  const ibsDps = no(dps, 'IBSCBS');
  const ibs = no(inf, 'IBSCBS');
  const vInf = no(inf, 'valores');
  const vDps = no(dps, 'valores');
  const tribMun = no(vDps, 'trib/tribMun');
  const tribFed = no(vDps, 'trib/tribFed');
  const pc = no(tribFed, 'piscofins');
  const serv = no(dps, 'serv');

  const chave = (inf.atr.Id ?? '').replace(/^NFS/, '');
  const cTribNac = tx(serv, 'cServ/cTribNac');
  const ufEmi = tx(emit, 'enderNac/UF') || ufDoIbge(tx(dps, 'cLocEmi'));
  const municipioCab = cTribNac.startsWith('99') ? '' : junta(' / ', tx(inf, 'xLocEmi'), ufEmi);
  const tpAmb = tx(dps, 'tpAmb');

  const identificacao: Linha[] = [
    { h: 0.79, celulas: [cel(C1, 15.3, 'CHAVE DE ACESSO DA NFS-E', chave, { forte: true })] },
    { h: 0.69, celulas: [cel(C1, W, 'NÚMERO DA NFS-E', tx(inf, 'nNFSe'), { forte: true }), cel(C2, W, 'COMPETÊNCIA DA NFS-E', data(tx(dps, 'dCompet')), { forte: true }), cel(C3, W, 'DATA E HORA DA EMISSÃO DA NFS-E', dataHora(tx(inf, 'dhProc')), { forte: true })] },
    { h: 0.69, celulas: [cel(C1, W, 'NÚMERO DA DPS', tx(dps, 'nDPS'), { forte: true }), cel(C2, W, 'SÉRIE DA DPS', tx(dps, 'serie'), { forte: true }), cel(C3, W, 'DATA E HORA DA EMISSÃO DA DPS', dataHora(tx(dps, 'dhEmi')), { forte: true })] },
    { h: 0.69, celulas: [cel(C1, W, 'EMITENTE DA NFS-E', desc(TP_EMIT, tx(dps, 'tpEmit')), { forte: true, cinza: true }), cel(C2, W, 'SITUAÇÃO DA NFS-E', desc(C_STAT, tx(inf, 'cStat')), { forte: true }), cel(C3, W, 'FINALIDADE', desc(FIN, tx(ibsDps, 'finNFSe')), { forte: true })] },
  ];

  // Prestador: os dados da DPS; nome e endereço, quando a DPS não traz, vêm do emitente que é o próprio prestador.
  const docPrest = tx(prest, 'CNPJ') || tx(prest, 'CPF');
  const prestEmit = docPrest && docPrest === (tx(emit, 'CNPJ') || tx(emit, 'CPF'));
  const prestador: No = {
    nome: 'prest', atr: {}, texto: '',
    filhos: [
      ...(prest?.filhos ?? []),
      ...(prestEmit && !no(prest, 'xNome') && no(emit, 'xNome') ? [no(emit, 'xNome')!] : []),
      ...(prestEmit && !no(prest, 'end') && no(emit, 'enderNac') ? [no(emit, 'enderNac')!] : []),
      ...(prestEmit && !no(prest, 'fone') && no(emit, 'fone') ? [no(emit, 'fone')!] : []),
      ...(prestEmit && !no(prest, 'email') && no(emit, 'email') ? [no(emit, 'email')!] : []),
    ],
  };
  const linhasPrest = pessoa('PRESTADOR / FORNECEDOR', prestador, municipio);
  linhasPrest.push(linha(cel(C1, W, 'Simples Nacional na Data de Competência', desc(OP_SN, tx(prest, 'regTrib/opSimpNac'))), cel(C2, W2 + W, 'Regime de Apuração Tributária pelo SN', desc(REG_SN, tx(prest, 'regTrib/regApTribSN')))));

  const dest = no(ibsDps, 'dest');
  const pessoas: Bloco[] = [
    { linhas: linhasPrest },
    toma ? { linhas: pessoa('TOMADOR / ADQUIRENTE', toma, municipio) } : { aviso: 'TOMADOR/ADQUIRENTE DA OPERAÇÃO NÃO IDENTIFICADO NA NFS-e' },
    dest
      ? { linhas: pessoa('DESTINATÁRIO DA OPERAÇÃO', dest, municipio, false) }
      : { aviso: tx(ibsDps, 'indDest') === '0' && toma ? 'O DESTINATÁRIO É O PRÓPRIO TOMADOR/ADQUIRENTE DA OPERAÇÃO' : 'DESTINATÁRIO DA OPERAÇÃO NÃO IDENTIFICADO NA NFS-e' },
    interm ? { linhas: pessoa('INTERMEDIÁRIO DA OPERAÇÃO', interm, municipio) } : { aviso: 'INTERMEDIÁRIO DA OPERAÇÃO NÃO IDENTIFICADO NA NFS-e' },
  ];

  const cLocPrest = tx(serv, 'locPrest/cLocPrestacao');
  const localPrest = cLocPrest
    ? junta(' / ', tx(inf, 'xLocPrestacao') || municipio(cLocPrest), ufDoIbge(cLocPrest), 'BR')
    : junta(' / ', tx(inf, 'xLocPrestacao'), tx(serv, 'locPrest/cPaisPrestacao'));
  const servico = linha(
    tit('SERVIÇO PRESTADO'),
    cel(C2, W, 'Código de Tributação Nacional / Municipal', junta(' / ', codTribNac(cTribNac), tx(serv, 'cServ/cTribMun'))),
    cel(C3, W, 'Código da NBS', codNbs(tx(serv, 'cServ/cNBS'))),
    cel(C4, W, 'Local da Prestação / Sigla UF / País', localPrest),
  );

  // Tributação municipal
  const valores: Bloco[] = [];
  const tribISSQN = tx(tribMun, 'tribISSQN');
  if (!tribMun || tribISSQN === '4') {
    valores.push({ aviso: 'TRIBUTAÇÃO MUNICIPAL (ISSQN) - OPERAÇÃO NÃO SUJEITA AO ISSQN' });
  } else {
    const cLocIncid = tx(inf, 'cLocIncid');
    const incid = cLocIncid ? junta(' / ', tx(inf, 'xLocIncid') || municipio(cLocIncid), ufDoIbge(cLocIncid), 'BR') : tx(tribMun, 'cPaisResult');
    const l: Linha[] = [linha(tit('TRIBUTAÇÃO MUNICIPAL (ISSQN)'), cel(C2, W, 'Tipo de Tributação do ISSQN', desc(TRIB_ISS, tribISSQN)), cel(C3, W2, 'Município / Sigla UF / País de Incidência do ISSQN', incid))];
    const reg = [desc(REG_ESP, tx(prest, 'regTrib/regEspTrib')), desc(IMUN, tx(tribMun, 'tpImunidade')), desc(SUSP, tx(tribMun, 'exigSusp/tpSusp')), tx(tribMun, 'exigSusp/nProcesso')];
    if (tem(...reg)) l.push(linha(cel(C1, W, 'Regime Especial de Tributação do ISSQN', reg[0]), cel(C2, W, 'Tipo de Imunidade do ISSQN', reg[1]), cel(C3, W, 'Suspensão da Exigibilidade do ISSQN', reg[2]), cel(C4, W, 'Número Processo Suspensão', reg[3])));
    const tpBM = tx(vInf, 'tpBM') || tx(tribMun, 'BM/tpBM');
    const calcBM = tx(vInf, 'vCalcBM') || tx(tribMun, 'BM/vRedBCBM');
    const dedRed = tx(vDps, 'vDedRed/vDR') ? reais(tx(vDps, 'vDedRed/vDR')) : soma(tx(vInf, 'vCalcDR'), tx(ibs, 'valores/vCalcReeRepRes'));
    const descInc = reais(tx(vDps, 'vDescCondIncond/vDescIncond'));
    if (tem(tpBM, calcBM, dedRed, descInc)) l.push(linha(cel(C1, W, 'Benefício Municipal', desc(TP_BM, tpBM)), cel(C2, W, 'Cálculo do BM', reais(calcBM)), cel(C3, W, 'Total Deduções/Reduções', dedRed), cel(C4, W, 'Desconto Incondicionado', descInc)));
    l.push(linha(cel(C1, W, 'BC ISSQN', reais(tx(vInf, 'vBC'))), cel(C2, W, 'Alíquota Aplicada', pct(tx(vInf, 'pAliqAplic'))), cel(C3, W, 'Retenção do ISSQN', desc(RET_ISS, tx(tribMun, 'tpRetISSQN'))), cel(C4, W, 'ISSQN Apurado', reais(tx(vInf, 'vISSQN')))));
    valores.push({ linhas: l });
  }

  // Tributação federal (exceto CBS). A linha do PIS/COFINS só até a competência de 2026 (nota 6).
  const tpRetPC = tx(pc, 'tpRetPisCofins');
  const vPis = tx(pc, 'vPis'), vCofins = tx(pc, 'vCofins'), vCsll = tx(tribFed, 'vRetCSLL');
  const contribRet = tpRetPC === '1' ? soma(vCsll, vPis, vCofins) : reais(vCsll);
  const lf: Linha[] = [linha(tit('TRIBUTAÇÃO FEDERAL (EXCETO CBS)'), cel(C2, W, 'IRRF', reais(tx(tribFed, 'vRetIRRF'))), cel(C3, W, 'Contribuição Previdenciária - Retida', reais(tx(tribFed, 'vRetCP'))), cel(C4, W, 'Contribuições Sociais - Retidas', contribRet))];
  if (tx(dps, 'dCompet') <= '2026-12-31') {
    lf.push(linha(
      cel(C1, W, 'PIS - Débito Apuração Própria', tpRetPC === '1' ? (pc ? reais(0) : '') : reais(vPis)),
      cel(C2, W, 'COFINS - Débito Apuração Própria', tpRetPC === '1' ? (pc ? reais(0) : '') : reais(vCofins)),
      cel(C3, W2, 'Descrição Contrib. Sociais - Retidas', desc(RET_PC, tpRetPC)),
    ));
  }
  valores.push({ linhas: lf });

  // IBS / CBS
  const g = no(ibsDps, 'valores/trib/gIBSCBS');
  const vi = no(ibs, 'valores');
  const tot = no(ibs, 'totCIBS');
  const cLocInc = tx(ibs, 'cLocalidadeIncid');
  const exclusoes = ibs ? soma(tx(vDps, 'vDescCondIncond/vDescIncond'), tx(vi, 'vCalcReeRepRes'), tx(vInf, 'vISSQN'), tx(pc, 'vPis'), tx(pc, 'vCofins')) : '';
  const p3 = (...v: string[]) => (tem(...v) ? v.map((x) => (x === '' ? '-' : decimal(x) + '%')).join(' / ') : '');
  valores.push({
    linhas: [
      linha(tit('TRIBUTAÇÃO IBS / CBS'), cel(C2, W, 'CST / cClassTrib', junta(' / ', tx(g, 'CST'), tx(g, 'cClassTrib'))), cel(C3, W2, 'Indicador de Operação / Código IBGE Incidência / Município Incidência / Sigla UF', junta(' / ', tx(ibsDps, 'cIndOp'), cLocInc, tx(ibs, 'xLocalidadeIncid'), ufDoIbge(cLocInc)))),
      linha(cel(C1, W, 'Exclusões e Reduções da Base de Cálculo', exclusoes), cel(C2, W, 'Base de Cálculo Após Exclusões e Reduções', reais(tx(vi, 'vBC'))), cel(C3, W, 'Red. Alíquota IBS / Red. Alíquota CBS', p3(tx(vi, 'uf/pRedAliqUF'), tx(vi, 'mun/pRedAliqMun'), tx(vi, 'fed/pRedAliqCBS'))), cel(C4, W, 'Alíquota - IBS UF / IBS Mun', p3(tx(vi, 'uf/pIBSUF'), tx(vi, 'mun/pIBSMun')))),
      linha(cel(C1, W, 'Alíq. Efetiva Municipal - IBS', pct(tx(vi, 'mun/pAliqEfetMun'))), cel(C2, W, 'Valor Apurado Municipal - IBS', reais(tx(tot, 'gIBS/gIBSMunTot/vIBSMun'))), cel(C3, W, 'Alíq. Efetiva Estadual - IBS', pct(tx(vi, 'uf/pAliqEfetUF'))), cel(C4, W, 'Valor Apurado Estadual - IBS', reais(tx(tot, 'gIBS/gIBSUFTot/vIBSUF')))),
      linha(cel(C1, W, 'Valor Total Apurado - IBS', reais(tx(tot, 'gIBS/vIBSTot'))), cel(C2, W, 'Alíquota - CBS', pct(tx(vi, 'fed/pCBS'))), cel(C3, W, 'Alíquota Efetiva - CBS', pct(tx(vi, 'fed/pAliqEfetCBS'))), cel(C4, W, 'Valor Total Apurado - CBS', reais(tx(tot, 'gCBS/vCBS')))),
    ],
  });

  // Valor total
  valores.push({
    linhas: [
      { h: 0.69, celulas: [tit('VALOR TOTAL DA NFS-E'), cel(C2, W, 'VALOR DA OPERAÇÃO / SERVIÇO', reais(tx(vDps, 'vServPrest/vServ')), { forte: true }), cel(C3, W, 'Desconto Incondicionado', reais(tx(vDps, 'vDescCondIncond/vDescIncond'))), cel(C4, W, 'Desconto Condicionado', reais(tx(vDps, 'vDescCondIncond/vDescCond')))] },
      { h: 0.69, celulas: [cel(C1, W, 'Total das Retenções (ISSQN / Federais)', reais(tx(vInf, 'vTotalRet'))), cel(C2, W, 'VALOR LÍQUIDO DA NFS-e', reais(tx(vInf, 'vLiq')), { forte: true }), cel(C3, W, 'Total do IBS/CBS', soma(tx(tot, 'gIBS/vIBSTot'), tx(tot, 'gCBS/vCBS'))), cel(C4, W, 'VALOR LÍQUIDO DA NFS-e + IBS/CBS', reais(tx(tot, 'vTotNF')), { forte: true, cinza: true })] },
    ],
  });

  // Informações complementares, na ordem da NT, separadas por " | "
  const ic = no(serv, 'infoCompl');
  const evt = no(serv, 'atvEvento');
  const obra = no(serv, 'obra');
  const infos = [
    ['Inf. Cont.', tx(ic, 'xInfComp')],
    ['NFS-e Subst.', tx(dps, 'subst/chSubstda')],
    ['Doc. Ref.', tx(ic, 'docRef')],
    ['Cod. Obra', tx(obra, 'cObra')],
    ['Insc. Imob.', tx(obra, 'inscImobFisc') || tx(ibsDps, 'imovel/inscImobFisc')],
    ['Cod. Evt.', tx(evt, 'idAtvEvt')],
    ['Doc. Tec.', tx(ic, 'idDocTec')],
    ['Núm. Ped.', tx(ic, 'xPed')],
    ['Item Ped.', (no(ic, 'gItemPed')?.filhos ?? []).map((f) => f.texto.trim()).filter(Boolean).join(', ')],
    ['Inf. A. T. Mun.', tx(inf, 'xOutInf')],
  ].filter(([, v]) => v).map(([r, v]) => `${r}: ${v}`).join(' | ');

  const tt = no(vDps, 'trib/totTrib');
  let totais: string;
  if (no(tt, 'vTotTrib')) totais = `Federais: ${reais(tx(tt, 'vTotTrib/vTotTribFed')) || '-'}; Estaduais: ${reais(tx(tt, 'vTotTrib/vTotTribEst')) || '-'}; Municipais: ${reais(tx(tt, 'vTotTrib/vTotTribMun')) || '-'}`;
  else if (no(tt, 'pTotTrib')) totais = `Federais: ${pct(tx(tt, 'pTotTrib/pTotTribFed')) || '-'}; Estaduais: ${pct(tx(tt, 'pTotTrib/pTotTribEst')) || '-'}; Municipais: ${pct(tx(tt, 'pTotTrib/pTotTribMun')) || '-'}`;
  else if (tx(tt, 'pTotTribSN')) totais = `Federais: -; Estaduais: -; Municipais: - (Simples Nacional: ${pct(tx(tt, 'pTotTribSN'))})`;
  else totais = 'Federais: -; Estaduais: -; Municipais: -';

  return {
    chave,
    urlConsulta: 'https://www.nfse.gov.br/ConsultaPublica/?tpc=1&chave=' + chave,
    municipio: municipioCab,
    ambienteGerador: desc(AMB_GER, tx(inf, 'ambGer')),
    tipoAmbiente: desc(TP_AMB, tpAmb),
    homologacao: tpAmb === '2',
    identificacao,
    pessoas,
    servico,
    descricaoCodigo: tx(inf, 'xTribMun') || tx(inf, 'xTribNac'),
    descricaoServico: tx(serv, 'cServ/xDescServ'),
    valores,
    informacoes: infos,
    totaisTributos: 'Totais Aproximados dos Tributos cfe. Lei nº 12.741/2012: ' + totais,
  };
}

// ---------------------------------------------------------------- desenho

export type Marca = 'CANCELADA' | 'SUBSTITUÍDA';
const PT = 2.54 / 72; // 1 ponto em cm
const LH7 = 0.3; // altura da linha de texto de 7 pt
const RODAPE = 29.4; // fim da borda da página
const CINZA = 242; // 5% de cinza

function celula(doc: jsPDF, y: number, h: number, c: Celula) {
  if (c.titulo || c.cinza) {
    doc.setFillColor(CINZA, CINZA, CINZA);
    doc.rect(c.x, y, c.w, h, 'F');
  }
  doc.setTextColor(0, 0, 0);
  const pad = 0.08;
  const largura = c.w - 2 * pad;
  if (c.titulo) {
    doc.setFont('helvetica', 'bold').setFontSize(7);
    doc.text(cabe(doc, latin1(c.rotulo), largura), c.x + pad, y + h / 2 + 0.09);
    return;
  }
  doc.setFont('helvetica', 'bold').setFontSize(c.forte ? 7 : 6);
  doc.text(cabe(doc, latin1(c.rotulo), largura), c.x + pad, y + 0.24);
  doc.setFont('helvetica', 'normal').setFontSize(7);
  doc.text(cabe(doc, latin1(c.valor || '-'), largura), c.x + pad, y + 0.52);
}

function fio(doc: jsPDF, y: number) {
  doc.setLineWidth(0.5 * PT);
  doc.line(C1, y, C1 + LARG, y);
}

function blocos(doc: jsPDF, y: number, bs: Bloco[]): number {
  for (const b of bs) {
    fio(doc, y);
    if ('aviso' in b) {
      doc.setFillColor(CINZA, CINZA, CINZA);
      doc.rect(C1, y, LARG, 0.36, 'F');
      doc.setFont('helvetica', 'bold').setFontSize(7).setTextColor(0, 0, 0);
      doc.text(latin1(b.aviso), C1 + 0.08, y + 0.25);
      y += 0.36;
    } else {
      for (const l of b.linhas) {
        for (const c of l.celulas) celula(doc, y, l.h, c);
        y += l.h;
      }
    }
  }
  return y;
}

function qr(doc: jsPDF, texto: string, x: number, y: number, lado: number) {
  const q = qrcode(0, 'M');
  q.addData(texto);
  q.make();
  const n = q.getModuleCount();
  const m = lado / n;
  doc.setFillColor(0, 0, 0);
  for (let r = 0; r < n; r++) {
    for (let c = 0; c < n; c++) {
      if (!q.isDark(r, c)) continue;
      // junta módulos escuros seguidos na mesma linha num retângulo só
      let k = c;
      while (k + 1 < n && q.isDark(r, k + 1)) k++;
      doc.rect(x + c * m, y + r * m, (k - c + 1) * m + 0.001, m + 0.001, 'F');
      c = k;
    }
  }
}

/** Desenha o DANFSe na página atual do `doc` (A4 retrato, unidade cm). */
export function desenhaDanfse(doc: jsPDF, d: DadosDanfse, marca?: Marca) {
  doc.setDrawColor(0, 0, 0);
  doc.setTextColor(0, 0, 0);

  // Cabeçalho
  doc.setFillColor(CINZA, CINZA, CINZA);
  doc.rect(C1, 0.3, LARG, 1.16, 'F');
  doc.addImage(LOGO_NFSE, 'JPEG', 0.49, 0.44, 4.0, 4.0 * 122 / 600);
  doc.setFont('helvetica', 'bold').setFontSize(9);
  doc.text('DANFSe v2.0', C2 + W2 / 2, 0.72, { align: 'center' });
  doc.text('Documento Auxiliar da NFS-e', C2 + W2 / 2, 1.06, { align: 'center' });
  if (d.homologacao) {
    doc.setTextColor(255, 0, 0);
    doc.text('NFS-e SEM VALIDADE JURÍDICA', C2 + W2 / 2, 1.38, { align: 'center' });
    doc.setTextColor(0, 0, 0);
  }
  doc.setFont('helvetica', 'normal').setFontSize(8);
  if (d.municipio) doc.text(cabe(doc, latin1('Município: ' + d.municipio), W - 0.1), C4 + 0.05, 0.62);
  doc.setFontSize(6);
  doc.text(cabe(doc, latin1('Ambiente Gerador: ' + (d.ambienteGerador || '-')), W - 0.1), C4 + 0.05, 1.04);
  doc.text(cabe(doc, latin1('Tipo de Ambiente: ' + (d.tipoAmbiente || '-')), W - 0.1), C4 + 0.05, 1.29);

  // Identificação, QR e o texto da consulta
  let y = 1.48;
  fio(doc, y);
  for (const l of d.identificacao) {
    for (const c of l.celulas) celula(doc, y, l.h, c);
    y += l.h;
  }
  qr(doc, d.urlConsulta, 17.48, 1.6, 1.6);
  doc.setFont('helvetica', 'normal').setFontSize(6);
  ['A autenticidade desta NFS-e pode ser verificada', 'pela leitura deste código QR ou pela consulta da', 'chave de acesso no portal nacional da NFS-e'].forEach((t, i) =>
    doc.text(latin1(t), C4 + W / 2, 3.4 + 0.22 * (i + 1), { align: 'center' }),
  );

  y = blocos(doc, y, d.pessoas);

  // Serviço prestado: código, descrição do código e descrição do serviço (cresce para baixo)
  fio(doc, y);
  for (const c of d.servico.celulas) celula(doc, y, d.servico.h, c);
  y += d.servico.h;
  doc.setFont('helvetica', 'normal').setFontSize(7);
  doc.text(cabe(doc, latin1(d.descricaoCodigo || '-'), LARG - 0.16), C1 + 0.08, y + 0.27);
  y += 0.4;

  // Altura do que vem depois da descrição, para dividir o espaço com as informações complementares
  const alturaValores = d.valores.reduce((a, b) => a + ('aviso' in b ? 0.36 : b.linhas.reduce((s, l) => s + l.h, 0)), 0);
  doc.setFont('helvetica', 'normal').setFontSize(7);
  const larguraTexto = LARG - 0.16;
  const descLinhas = quebra(doc, latin1(d.descricaoServico || '-'), larguraTexto);
  const infoLinhas = d.informacoes ? quebra(doc, latin1(d.informacoes), larguraTexto) : [];
  const livre = RODAPE - y - alturaValores - 0.29 /* rótulo da descrição */ - 0.41 /* título inf. compl. */ - 0.1;
  const minInfo = (Math.min(infoLinhas.length, 4) + 1) * LH7; // ao menos 4 linhas das informações e a dos totais
  const maxDesc = Math.max(1, Math.floor((livre - minInfo) / LH7));
  const desc = corta(descLinhas, maxDesc);

  doc.setFont('helvetica', 'bold').setFontSize(6);
  doc.text('Descrição do Serviço', C1 + 0.08, y + 0.2);
  doc.setFont('helvetica', 'normal').setFontSize(7);
  y += 0.29;
  desc.forEach((t, i) => doc.text(t, C1 + 0.08, y + 0.24 + i * LH7));
  y += desc.length * LH7 + 0.1;

  y = blocos(doc, y, d.valores);

  // Informações complementares
  fio(doc, y);
  doc.setFillColor(CINZA, CINZA, CINZA);
  doc.rect(C1, y, LARG, 0.41, 'F');
  doc.setFont('helvetica', 'bold').setFontSize(7);
  doc.text('INFORMAÇÕES COMPLEMENTARES', C1 + 0.08, y + 0.28);
  y += 0.41;
  doc.setFont('helvetica', 'normal').setFontSize(7);
  const cabemInfo = Math.max(0, Math.floor((RODAPE - y - 0.05) / LH7) - 1);
  const info = corta(infoLinhas, cabemInfo);
  info.forEach((t, i) => doc.text(t, C1 + 0.08, y + 0.26 + i * LH7));
  y += info.length * LH7;
  quebra(doc, latin1(d.totaisTributos), larguraTexto).slice(0, 1).forEach((t) => doc.text(t, C1 + 0.08, y + 0.26));

  // Borda da página
  doc.setLineWidth(1 * PT);
  doc.rect(C1, 0.3, LARG, RODAPE - 0.3);

  if (marca) marcaDagua(doc, marca);
}

/** Corta a lista em `max` linhas, com reticências na última quando sobra texto. */
function corta(linhas: string[], max: number): string[] {
  if (linhas.length <= max) return linhas;
  const r = linhas.slice(0, Math.max(0, max));
  if (r.length) r[r.length - 1] = r[r.length - 1].replace(/.{0,3}$/, '...');
  return r;
}

export function marcaDagua(doc: jsPDF, marca: Marca) {
  const g = new (doc as unknown as { GState: new (p: { opacity: number }) => unknown }).GState({ opacity: 0.5 });
  doc.saveGraphicsState();
  doc.setGState(g);
  doc.setTextColor(166, 166, 166);
  doc.setFont('helvetica', 'bold').setFontSize(90);
  // texto a 45°, centrado na folha: o início fica meia largura para baixo e à esquerda do centro
  const t = latin1(marca);
  const meia = doc.getTextWidth(t) / 2 / Math.SQRT2;
  const alt = (90 * PT) / 2 / Math.SQRT2;
  doc.text(t, 10.5 - meia + alt / 2, 14.85 + meia + alt / 2, { angle: 45 });
  doc.restoreGraphicsState();
  doc.setTextColor(0, 0, 0);
}
