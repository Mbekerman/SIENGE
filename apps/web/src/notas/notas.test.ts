// Testes do leitor de XML, do código de barras e dos geradores do DANFE e do DANFSe.
// Roda com: npm test (node --test). Os XMLs daqui são inventados (CNPJ de exemplo, nomes
// fictícios); nenhuma nota real entra no repositório.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { jsPDF } from 'jspdf';
import { lerXml, no, tx } from './xml.ts';
import { code128c, verificador128c } from './code128.ts';
import { cnpjCpf, decimal, decimalVar, dataHora, chaveGrupos, ufDoIbge } from './formato.ts';
import { latin1 } from './texto.ts';
import { codNbs, codTribNac, dadosDanfse, desenhaDanfse, type Bloco } from './danfse.ts';
import { dadosDanfe, desenhaDanfe } from './danfe.ts';

// ------------------------------------------------------------------ XML

test('xml: namespace, atributos, entidades e CDATA', () => {
  const r = lerXml(`<?xml version="1.0"?><!-- c --><ns:a xmlns:ns="u" Id='X1'><ns:b>R&amp;D &lt;1&gt; &#233;&#xE9;</ns:b><c><![CDATA[<cru>]]></c><d/></ns:a>`);
  assert.equal(r.nome, 'a');
  assert.equal(r.atr.Id, 'X1');
  assert.equal(tx(r, 'b'), 'R&D <1> éé');
  assert.equal(tx(r, 'c'), '<cru>');
  assert.ok(no(r, 'd'));
  assert.equal(tx(r, 'nada/mais'), '');
});

test('xml: recusa XML malformado e não resolve entidade desconhecida', () => {
  assert.throws(() => lerXml('<a><b></a>'));
  assert.throws(() => lerXml('<a>'));
  assert.throws(() => lerXml(''));
  assert.equal(tx(lerXml('<a>&xxe;</a>'), ''), '&xxe;');
});

// ------------------------------------------------------------------ código de barras

test('code128c: START C, verificador e STOP', () => {
  const l = code128c('1234');
  // START C (211232) + 2 símbolos + verificador, 6 larguras cada, + STOP (7 larguras)
  assert.equal(l.length, 6 * 4 + 7);
  assert.deepEqual(l.slice(0, 6), [2, 1, 1, 2, 3, 2]);
  assert.deepEqual(l.slice(-7), [2, 3, 3, 1, 1, 1, 2]);
  // 105 + 12*1 + 34*2 = 185; 185 mod 103 = 82
  assert.equal(verificador128c('1234'), 82);
  assert.equal(l.reduce((a, b) => a + b, 0), 11 * 4 + 13);
  assert.throws(() => code128c('123'));
});

test('code128c: chave de 44 dígitos', () => {
  const l = code128c('3'.repeat(44));
  assert.equal(l.reduce((a, b) => a + b, 0), 11 * (22 + 2) + 13);
});

// ------------------------------------------------------------------ formatos

test('formatos', () => {
  assert.equal(decimal('1234567.5'), '1.234.567,50');
  assert.equal(decimal('-3'), '-3,00');
  assert.equal(decimal(''), '');
  assert.equal(decimalVar('2.5000'), '2,50');
  assert.equal(decimalVar('0.12345', 2, 4), '0,1235');
  assert.equal(cnpjCpf('11222333000181'), '11.222.333/0001-81');
  assert.equal(cnpjCpf('12345678909'), '123.456.789-09');
  assert.equal(dataHora('2026-11-19T15:53:08-03:00'), '19/11/2026 15:53:08');
  assert.equal(chaveGrupos('12345678'), '1234 5678');
  assert.equal(ufDoIbge('3550308'), 'SP');
  assert.equal(codTribNac('030301'), '03.03.01');
  assert.equal(codNbs('118066100'), '1.1806.61.00');
  assert.equal(latin1('a≤bā'), 'a?ba');
});

// ------------------------------------------------------------------ DANFSe

type NfseOp = { toma?: boolean; interm?: boolean; indDest?: string; tribISSQN?: string; tpRetPisCofins?: string; dCompet?: string; tpAmb?: string; ibs?: boolean };

function nfse(o: NfseOp = {}) {
  const ibsInf = o.ibs === false ? '' : `<IBSCBS><cLocalidadeIncid>3549904</cLocalidadeIncid><xLocalidadeIncid>Cidade B</xLocalidadeIncid><valores><vBC>980.00</vBC><vCalcReeRepRes>0.00</vCalcReeRepRes><uf><pIBSUF>0.10</pIBSUF><pAliqEfetUF>0.10</pAliqEfetUF></uf><mun><pIBSMun>0.00</pIBSMun><pAliqEfetMun>0.00</pAliqEfetMun></mun><fed><pCBS>0.90</pCBS><pAliqEfetCBS>0.90</pAliqEfetCBS></fed></valores><totCIBS><vTotNF>1000.00</vTotNF><gIBS><vIBSTot>0.98</vIBSTot><gIBSUFTot><vIBSUF>0.98</vIBSUF></gIBSUFTot><gIBSMunTot><vIBSMun>0.00</vIBSMun></gIBSMunTot></gIBS><gCBS><vCBS>8.82</vCBS></gCBS></totCIBS></IBSCBS>`;
  const ibsDps = o.ibs === false ? '' : `<IBSCBS><finNFSe>0</finNFSe><indFinal>0</indFinal><cIndOp>100401</cIndOp><indDest>${o.indDest ?? '0'}</indDest><valores><trib><gIBSCBS><CST>000</CST><cClassTrib>000001</cClassTrib></gIBSCBS></trib></valores></IBSCBS>`;
  return `<?xml version="1.0" encoding="utf-8"?><NFSe versao="1.01" xmlns="http://www.sped.fazenda.gov.br/nfse"><infNFSe Id="NFS35041072211222333000181000000000000000000000000001"><xLocEmi>Cidade A</xLocEmi><xLocPrestacao>Cidade A</xLocPrestacao><nNFSe>39</nNFSe><cLocIncid>3504107</cLocIncid><xLocIncid>Cidade A</xLocIncid><xTribNac>Descrição nacional</xTribNac><xTribMun>Descrição municipal</xTribMun><ambGer>2</ambGer><cStat>100</cStat><dhProc>2026-11-19T15:53:08-03:00</dhProc><xOutInf>Info da prefeitura</xOutInf>
<emit><CNPJ>11222333000181</CNPJ><IM>70003</IM><xNome>PRESTADORA EXEMPLO LTDA</xNome><enderNac><xLgr>RUA UM</xLgr><nro>10</nro><xBairro>CENTRO</xBairro><cMun>3504107</cMun><UF>SP</UF><CEP>12900000</CEP></enderNac><fone>11900000000</fone><email>a@exemplo.com</email></emit>
<valores><vBC>1000.00</vBC><pAliqAplic>2.00</pAliqAplic><vISSQN>20.00</vISSQN><vTotalRet>15.00</vTotalRet><vLiq>985.00</vLiq></valores>${ibsInf}
<DPS versao="1.01"><infDPS Id="DPS1"><tpAmb>${o.tpAmb ?? '1'}</tpAmb><dhEmi>2026-11-19T15:52:08-03:00</dhEmi><serie>800</serie><nDPS>8038</nDPS><dCompet>${o.dCompet ?? '2026-11-19'}</dCompet><tpEmit>1</tpEmit><cLocEmi>3504107</cLocEmi>
<prest><CNPJ>11222333000181</CNPJ><IM>70003</IM><regTrib><opSimpNac>1</opSimpNac><regEspTrib>0</regEspTrib></regTrib></prest>
${o.toma === false ? '' : `<toma><CNPJ>11444777000161</CNPJ><xNome>TOMADORA EXEMPLO SA</xNome><end><endNac><cMun>3549904</cMun><CEP>12200000</CEP></endNac><xLgr>AV DOIS</xLgr><nro>50</nro><xBairro>JARDIM</xBairro></end><email>t@exemplo.com</email></toma>`}
${o.interm ? `<interm><CPF>12345678909</CPF><xNome>INTERMEDIARIO EXEMPLO</xNome></interm>` : ''}
<serv><locPrest><cLocPrestacao>3504107</cLocPrestacao></locPrest><cServ><cTribNac>030301</cTribNac><cTribMun>001</cTribMun><xDescServ>Serviço de exemplo
segunda linha</xDescServ><cNBS>118066100</cNBS></cServ><obra><cObra>OB-1</cObra></obra><infoCompl><xInfComp>Contrato 7</xInfComp><xPed>PED-9</xPed></infoCompl></serv>
<valores><vServPrest><vServ>1000.00</vServ></vServPrest><trib><tribMun><tribISSQN>${o.tribISSQN ?? '1'}</tribISSQN><tpRetISSQN>2</tpRetISSQN></tribMun><tribFed><piscofins><CST>01</CST><vPis>6.50</vPis><vCofins>30.00</vCofins><tpRetPisCofins>${o.tpRetPisCofins ?? '0'}</tpRetPisCofins></piscofins><vRetIRRF>15.00</vRetIRRF><vRetCSLL>10.00</vRetCSLL></tribFed><totTrib><vTotTrib><vTotTribFed>40.00</vTotTribFed><vTotTribEst>0.00</vTotTribEst><vTotTribMun>20.00</vTotTribMun></vTotTrib></totTrib></trib></valores>${ibsDps}</infDPS></DPS></infNFSe></NFSe>`;
}

const mun = (c: string) => ({ '3504107': 'Cidade A', '3549904': 'Cidade B' })[c] ?? '';
const celula = (bs: Bloco[], rotulo: string) => {
  for (const b of bs) if ('linhas' in b) for (const l of b.linhas) for (const c of l.celulas) if (c.rotulo === rotulo) return c.valor;
  return undefined;
};
const avisos = (bs: Bloco[]) => bs.filter((b): b is { aviso: string } => 'aviso' in b).map((b) => b.aviso);

test('danfse: identificação, cabeçalho e QR', () => {
  const d = dadosDanfse(nfse(), { municipio: mun });
  assert.equal(d.chave, '35041072211222333000181000000000000000000000000001');
  assert.equal(d.chave.length, 50);
  assert.equal(d.urlConsulta, 'https://www.nfse.gov.br/ConsultaPublica/?tpc=1&chave=' + d.chave);
  assert.equal(d.municipio, 'Cidade A / SP');
  assert.equal(d.ambienteGerador, 'Sistema Nacional da NFS-e');
  assert.equal(d.tipoAmbiente, 'Produção');
  assert.equal(d.homologacao, false);
  const id = d.identificacao.flatMap((l) => l.celulas);
  const v = (r: string) => id.find((c) => c.rotulo === r)?.valor;
  assert.equal(v('COMPETÊNCIA DA NFS-E'), '19/11/2026');
  assert.equal(v('EMITENTE DA NFS-E'), 'Prestador');
  assert.equal(v('SITUAÇÃO DA NFS-E'), 'NFS-e Gerada');
  assert.equal(v('FINALIDADE'), 'NFS-e regular');
  assert.ok(id.find((c) => c.rotulo === 'EMITENTE DA NFS-E')?.cinza);
});

test('danfse: prestador completa nome e endereço pelo emitente; tomador com município pela tabela', () => {
  const d = dadosDanfse(nfse(), { municipio: mun });
  const [prest, toma] = d.pessoas;
  assert.ok('linhas' in prest && 'linhas' in toma);
  assert.equal(celula([prest], 'Nome / Nome Empresarial'), 'PRESTADORA EXEMPLO LTDA');
  assert.equal(celula([prest], 'Endereço'), 'RUA UM, 10, CENTRO');
  assert.equal(celula([prest], 'CNPJ / CPF / NIF'), '11.222.333/0001-81');
  assert.equal(celula([prest], 'Simples Nacional na Data de Competência'), 'Não Optante');
  assert.equal(celula([toma], 'Município / Sigla UF'), 'Cidade B / SP');
  assert.equal(celula([toma], 'Código IBGE / CEP'), '3549904 / 12.200-000');
  assert.equal(celula([toma], 'Endereço'), 'AV DOIS, 50, JARDIM');
});

test('danfse: blocos substituídos (notas 2, 3 e 4 da NT)', () => {
  const sem = dadosDanfse(nfse({ toma: false, indDest: '1', tribISSQN: '4' }), { municipio: mun });
  assert.deepEqual(avisos(sem.pessoas), [
    'TOMADOR/ADQUIRENTE DA OPERAÇÃO NÃO IDENTIFICADO NA NFS-e',
    'DESTINATÁRIO DA OPERAÇÃO NÃO IDENTIFICADO NA NFS-e',
    'INTERMEDIÁRIO DA OPERAÇÃO NÃO IDENTIFICADO NA NFS-e',
  ]);
  assert.deepEqual(avisos(sem.valores), ['TRIBUTAÇÃO MUNICIPAL (ISSQN) - OPERAÇÃO NÃO SUJEITA AO ISSQN']);
  const proprio = dadosDanfse(nfse({ indDest: '0', interm: true }), { municipio: mun });
  assert.deepEqual(avisos(proprio.pessoas), ['O DESTINATÁRIO É O PRÓPRIO TOMADOR/ADQUIRENTE DA OPERAÇÃO']);
  assert.equal(celula(proprio.pessoas, 'Nome / Nome Empresarial') !== undefined, true);
});

test('danfse: serviço, ISSQN e valores', () => {
  const d = dadosDanfse(nfse(), { municipio: mun });
  assert.equal(d.servico.celulas[1].valor, '03.03.01 / 001');
  assert.equal(d.servico.celulas[2].valor, '1.1806.61.00');
  assert.equal(d.servico.celulas[3].valor, 'Cidade A / SP / BR');
  assert.equal(d.descricaoCodigo, 'Descrição municipal');
  assert.equal(d.descricaoServico, 'Serviço de exemplo\nsegunda linha');
  assert.equal(celula(d.valores, 'Retenção do ISSQN'), 'Retido pelo Tomador');
  assert.equal(celula(d.valores, 'ISSQN Apurado'), 'R$ 20,00');
  assert.equal(celula(d.valores, 'IRRF'), 'R$ 15,00');
  assert.equal(celula(d.valores, 'Total do IBS/CBS'), 'R$ 9,80');
  assert.equal(celula(d.valores, 'VALOR LÍQUIDO DA NFS-e + IBS/CBS'), 'R$ 1.000,00');
  // soma de desconto incondicionado, reembolso, ISSQN, PIS e COFINS
  assert.equal(celula(d.valores, 'Exclusões e Reduções da Base de Cálculo'), 'R$ 56,50');
  assert.equal(celula(d.valores, 'Alíquota - IBS UF / IBS Mun'), '0,10% / 0,00%');
});

test('danfse: PIS/COFINS retidos (tpRetPisCofins = 1) somam nas contribuições e zeram o débito próprio', () => {
  const r = dadosDanfse(nfse({ tpRetPisCofins: '1' }));
  assert.equal(celula(r.valores, 'Contribuições Sociais - Retidas'), 'R$ 46,50');
  assert.equal(celula(r.valores, 'PIS - Débito Apuração Própria'), 'R$ 0,00');
  assert.equal(celula(r.valores, 'COFINS - Débito Apuração Própria'), 'R$ 0,00');
  const n = dadosDanfse(nfse({ tpRetPisCofins: '0' }));
  assert.equal(celula(n.valores, 'Contribuições Sociais - Retidas'), 'R$ 10,00');
  assert.equal(celula(n.valores, 'PIS - Débito Apuração Própria'), 'R$ 6,50');
  assert.equal(celula(n.valores, 'Descrição Contrib. Sociais - Retidas'), 'PIS/COFINS/CSLL Não Retidos');
});

test('danfse: linha do PIS/COFINS só até a competência de 2026 (nota 6)', () => {
  assert.notEqual(celula(dadosDanfse(nfse({ dCompet: '2026-12-31' })).valores, 'PIS - Débito Apuração Própria'), undefined);
  assert.equal(celula(dadosDanfse(nfse({ dCompet: '2027-01-01' })).valores, 'PIS - Débito Apuração Própria'), undefined);
  assert.notEqual(celula(dadosDanfse(nfse({ dCompet: '2027-01-01' })).valores, 'IRRF'), undefined);
});

test('danfse: informações complementares na ordem da NT e totais da Lei 12.741', () => {
  const d = dadosDanfse(nfse());
  assert.equal(d.informacoes, 'Inf. Cont.: Contrato 7 | Cod. Obra: OB-1 | Núm. Ped.: PED-9 | Inf. A. T. Mun.: Info da prefeitura');
  assert.equal(d.totaisTributos, 'Totais Aproximados dos Tributos cfe. Lei nº 12.741/2012: Federais: R$ 40,00; Estaduais: R$ 0,00; Municipais: R$ 20,00');
});

test('danfse: nota antiga, sem IBS/CBS, e homologação', () => {
  const d = dadosDanfse(nfse({ ibs: false, tpAmb: '2' }));
  assert.equal(d.homologacao, true);
  assert.equal(celula(d.valores, 'CST / cClassTrib'), '');
  assert.equal(celula(d.valores, 'Exclusões e Reduções da Base de Cálculo'), '');
  assert.deepEqual(avisos(d.pessoas), ['DESTINATÁRIO DA OPERAÇÃO NÃO IDENTIFICADO NA NFS-e', 'INTERMEDIÁRIO DA OPERAÇÃO NÃO IDENTIFICADO NA NFS-e']);
});

test('danfse: recusa XML que não é NFS-e', () => {
  assert.throws(() => dadosDanfse('<nfeProc><NFe/></nfeProc>'), /NFS-e/);
});

test('danfse: gera PDF de uma página, também com descrição longa e marca d’água', () => {
  const longa = nfse().replace('segunda linha', 'x '.repeat(3000));
  for (const xml of [nfse(), longa]) {
    const doc = new jsPDF({ unit: 'cm', format: 'a4' });
    desenhaDanfse(doc, dadosDanfse(xml, { municipio: mun }), 'CANCELADA');
    assert.equal(doc.getNumberOfPages(), 1);
    const pdf = new Uint8Array(doc.output('arraybuffer'));
    assert.equal(new TextDecoder().decode(pdf.slice(0, 5)), '%PDF-');
  }
});

// ------------------------------------------------------------------ DANFE

function item(n: number, xProd = 'PRODUTO DE EXEMPLO ' + n, adicional = '') {
  return `<det nItem="${n}"><prod><cProd>P${n}</cProd><cEAN>SEM GTIN</cEAN><xProd>${xProd}</xProd><NCM>76101000</NCM><CFOP>5101</CFOP><uCom>PC</uCom><qCom>2.5000</qCom><vUnCom>10.0000000000</vUnCom><vProd>25.00</vProd><indTot>1</indTot></prod><imposto><ICMS><ICMS00><orig>0</orig><CST>00</CST><modBC>3</modBC><vBC>25.00</vBC><pICMS>18.00</pICMS><vICMS>4.50</vICMS></ICMS00></ICMS><IPI><cEnq>999</cEnq><IPITrib><CST>50</CST><vBC>25.00</vBC><pIPI>5.00</pIPI><vIPI>1.25</vIPI></IPITrib></IPI></imposto>${adicional ? `<infAdProd>${adicional}</infAdProd>` : ''}</det>`;
}

function nfe(o: { itens?: number; infCpl?: string; tpAmb?: string; dup?: boolean } = {}) {
  const dets = Array.from({ length: o.itens ?? 2 }, (_, i) => item(i + 1, undefined, i === 0 ? 'Lote 7' : '')).join('');
  return `<nfeProc versao="4.00" xmlns="http://www.portalfiscal.inf.br/nfe"><NFe><infNFe Id="NFe35260911222333000181550010000003271000000017" versao="4.00"><ide><cUF>35</cUF><natOp>VENDA DE EXEMPLO</natOp><mod>55</mod><serie>1</serie><nNF>327</nNF><dhEmi>2026-09-11T16:03:53-03:00</dhEmi><dhSaiEnt>2026-09-11T16:03:53-03:00</dhSaiEnt><tpNF>1</tpNF><tpAmb>${o.tpAmb ?? '1'}</tpAmb></ide>
<emit><CNPJ>11222333000181</CNPJ><xNome>EMITENTE EXEMPLO LTDA</xNome><enderEmit><xLgr>RUA UM</xLgr><nro>10</nro><xBairro>CENTRO</xBairro><cMun>3504107</cMun><xMun>CIDADE A</xMun><UF>SP</UF><CEP>15000000</CEP><fone>1730000000</fone></enderEmit><IE>111222333444</IE></emit>
<dest><CNPJ>11444777000161</CNPJ><xNome>DESTINATARIO EXEMPLO SA</xNome><enderDest><xLgr>AV DOIS</xLgr><nro>50</nro><xBairro>JARDIM</xBairro><xMun>CIDADE B</xMun><UF>SP</UF><CEP>12200000</CEP></enderDest><IE>555666777888</IE></dest>
${dets}
<total><ICMSTot><vBC>50.00</vBC><vICMS>9.00</vICMS><vBCST>0.00</vBCST><vST>0.00</vST><vProd>50.00</vProd><vFrete>0.00</vFrete><vSeg>0.00</vSeg><vDesc>0.00</vDesc><vIPI>2.50</vIPI><vOutro>0.00</vOutro><vNF>52.50</vNF></ICMSTot></total>
<transp><modFrete>1</modFrete><transporta><CNPJ>11444777000161</CNPJ><xNome>TRANSPORTES EXEMPLO</xNome></transporta><veicTransp><placa>ABC1D23</placa><UF>SP</UF></veicTransp><vol><qVol>3</qVol><esp>CAIXA</esp><pesoL>10.500</pesoL><pesoB>11.000</pesoB></vol><vol><qVol>2</qVol><esp>CAIXA</esp><pesoL>1.000</pesoL><pesoB>1.200</pesoB></vol></transp>
${o.dup === false ? '' : '<cobr><dup><nDup>001</nDup><dVenc>2026-10-08</dVenc><vDup>52.50</vDup></dup></cobr>'}
<infAdic><infAdFisco>Fisco diz</infAdFisco><infCpl>${o.infCpl ?? 'Pedido 157'}</infCpl><obsCont xCampo="Obra"><xTexto>Torre A</xTexto></obsCont></infAdic></infNFe></NFe>
<protNFe versao="4.00"><infProt><tpAmb>1</tpAmb><chNFe>35260911222333000181550010000003271000000017</chNFe><dhRecbto>2026-09-11T16:10:00-03:00</dhRecbto><nProt>135000000000001</nProt><cStat>100</cStat></infProt></protNFe></nfeProc>`;
}

test('danfe: campos do quadro de identificação, destinatário e totais', () => {
  const d = dadosDanfe(nfe());
  assert.equal(d.chave, '35260911222333000181550010000003271000000017');
  assert.equal(d.numero, '000.000.327');
  assert.equal(d.serie, '001');
  assert.equal(d.tipo, '1');
  assert.equal(d.protocolo, '135000000000001 - 11/09/2026 16:10:00');
  assert.equal(d.emitente.cnpj, '11.222.333/0001-81');
  assert.deepEqual(d.emitente.linhas, ['RUA UM, 10', 'CENTRO - 15.000-000', 'CIDADE A - SP', 'Fone: (17) 3000-0000']);
  assert.equal(d.destinatario.documento, '11.444.777/0001-61');
  assert.equal(d.destinatario.horaSaida, '16:03:53');
  assert.equal(d.impostos.total, '52,50');
  assert.equal(d.fatura, '001 08/10/2026 R$ 52,50');
  assert.equal(d.transporte.frete, '1-Destinatário (FOB)');
  assert.equal(d.transporte.quantidade, '5');
  assert.equal(d.transporte.especie, 'CAIXA');
  assert.equal(d.transporte.pesoBruto, '12,200');
  assert.equal(d.informacoes, 'Inf. contribuinte: Pedido 157\nInf. fisco: Fisco diz\nObra: Torre A');
});

test('danfe: itens com CST, alíquotas e informação adicional do produto', () => {
  const [i1, i2] = dadosDanfe(nfe()).itens;
  assert.equal(i1.cst, '000');
  assert.equal(i1.quantidade, '2,50');
  assert.equal(i1.valorUnitario, '10,00');
  assert.equal(i1.aliqIcms, '18,00');
  assert.equal(i1.valorIpi, '1,25');
  assert.equal(i1.adicional, 'Lote 7');
  assert.equal(i2.adicional, '');
});

test('danfe: recusa o resumo (resNFe), que não tem os itens', () => {
  assert.throws(() => dadosDanfe('<resNFe><chNFe>1</chNFe></resNFe>'), /NF-e completa/);
});

test('danfe: uma folha; muitos itens abrem folhas novas; informação longa continua', () => {
  const pags = (xml: string) => {
    const doc = new jsPDF({ unit: 'cm', format: 'a4' });
    desenhaDanfe(doc, dadosDanfe(xml));
    return doc.getNumberOfPages();
  };
  assert.equal(pags(nfe()), 1);
  assert.ok(pags(nfe({ itens: 60 })) >= 2);
  assert.ok(pags(nfe({ infCpl: 'palavra '.repeat(2000) })) >= 2);
  assert.equal(pags(nfe({ itens: 1, dup: false, tpAmb: '2' })), 1);
});

test('pdf: tipo pelo XML', async () => {
  const { tipoDoXml } = await import('./pdf.ts');
  assert.equal(tipoDoXml(nfse()), 'nfse');
  assert.equal(tipoDoXml(nfe()), 'nfe');
  assert.equal(tipoDoXml('<resNFe/>'), null);
});
