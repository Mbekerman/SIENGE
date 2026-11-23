// Testes da parte pura da busca de notas. Só XML sintético e CNPJs fictícios (o repositório é público).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { createHash, createSign, createVerify, generateKeyPairSync } from 'node:crypto';
import {
  lerLoteAdn, lerDocAdn, pedidoDist, lerRespostaDist, lerDocZip, eventoCiencia, pedidoEventos, lerRespostaEventos,
  esperaSefaz, horaBrasilia,
} from './notas.ts';

const EMPRESA = '33333333000133';
const FORNECEDOR = '55555555000155';
const gz = (s: string) => gzipSync(Buffer.from(s, 'utf8')).toString('base64');

// NF-e: cUF(2) AAMM(4) CNPJ(14) mod(2) série(3) nNF(9) tpEmis(1) cNF(8) DV(1)
const chaveNfe = (doc = FORNECEDOR, serie = 1, num = 1234) =>
  `35` + `2611` + doc + `55` + String(serie).padStart(3, '0') + String(num).padStart(9, '0') + `1` + `12345678` + `9`;
// NFS-e: cMun(7) amb(1) tpInsc(1) doc(14) nNFSe(13) AAMM(4) cNum(9) DV(1)
const chaveNfse = (doc = FORNECEDOR, num = 77) =>
  `3550308` + `1` + `2` + doc + String(num).padStart(13, '0') + `2611` + `123456789` + `0`;

const nfseXml = (o: { tomador?: string; emit?: string; chave?: string; vServ?: string } = {}) =>
  `<?xml version="1.0" encoding="UTF-8"?><NFSe xmlns="http://www.sped.fazenda.gov.br/nfse" versao="1.00">`
  + `<infNFSe Id="NFS${o.chave ?? chaveNfse()}"><cLocIncid>3550308</cLocIncid><nNFSe>77</nNFSe><dhProc>2026-11-10T10:00:00-03:00</dhProc>`
  + `<emit><CNPJ>${o.emit ?? FORNECEDOR}</CNPJ><xNome>Fornecedor Teste &amp; Cia</xNome></emit>`
  + `<DPS versao="1.00"><infDPS Id="DPS1"><dhEmi>2026-11-09T09:00:00-03:00</dhEmi><dCompet>2026-11-01</dCompet>`
  + `<prest><CNPJ>${o.emit ?? FORNECEDOR}</CNPJ></prest><toma><CNPJ>${o.tomador ?? EMPRESA}</CNPJ><xNome>Empresa</xNome></toma>`
  + `<valores><vServPrest><vServ>${o.vServ ?? '1500.50'}</vServ></vServPrest></valores></infDPS></DPS></infNFSe></NFSe>`;

test('ADN: lote com maiúsculas, NSU inválido fica fora, maior NSU', () => {
  const l = lerLoteAdn({ StatusProcessamento: 'DOCUMENTOS_LOCALIZADOS', LoteDFe: [
    { NSU: 10, TipoDocumento: 'NFSE', ArquivoXml: 'x' }, { NSU: 'abc' }, { nsu: 12, tipoDocumento: 'EVENTO', arquivoXml: 'y' }] });
  assert.equal(l.status, 'DOCUMENTOS_LOCALIZADOS');
  assert.deepEqual(l.docs.map((d) => d.nsu), [10, 12]);
  assert.equal(l.maiorNsu, 12);
  assert.deepEqual(lerLoteAdn(null), { status: '', docs: [], maiorNsu: null });
});

test('ADN: NFS-e recebida vira nota completa', () => {
  const d = lerDocAdn({ nsu: 10, tipo: 'NFSE', xmlGzipB64: gz(nfseXml()) }, EMPRESA);
  assert.equal(d.tipo, 'nota');
  if (d.tipo !== 'nota') return;
  assert.equal(d.completo, true);
  assert.deepEqual(d.nota, {
    tipo: 'nfse', chave: chaveNfse(), nsu: 10, tomador: EMPRESA, emitente_documento: FORNECEDOR,
    emitente_nome: 'Fornecedor Teste & Cia', numero: '77', serie: '', emissao: '2026-11-09', competencia: '2026-11-01',
    valor: 1500.5, municipio: '3550308',
  });
  // o que o banco confere: emitente e número batem com a chave
  assert.equal(d.nota.chave.slice(9, 23), d.nota.emitente_documento);
  assert.equal(d.nota.chave.slice(23, 36).replace(/^0+/, ''), d.nota.numero);
});

test('ADN: nota emitida pela empresa, de outro tomador, sem valor ou sem chave não entra', () => {
  const m = (xml: string) => { const d = lerDocAdn({ nsu: 1, tipo: 'NFSE', xmlGzipB64: gz(xml) }, EMPRESA); return d.tipo === 'outro' ? d.motivo : d.tipo; };
  assert.equal(m(nfseXml({ emit: EMPRESA, tomador: FORNECEDOR })), 'emitida pela empresa');
  assert.equal(m(nfseXml({ tomador: '44444444000144' })), 'a empresa não é a tomadora');
  assert.equal(m(nfseXml({ vServ: 'abc' })), 'NFS-e sem valor');
  assert.equal(m(nfseXml({ chave: '123' })), 'NFS-e sem chave de 50 dígitos');
  assert.equal(lerDocAdn({ nsu: 1, tipo: 'NFSE', xmlGzipB64: null }, EMPRESA).tipo, 'outro');
});

test('ADN: evento de cancelamento', () => {
  const xml = `<evento xmlns="http://www.sped.fazenda.gov.br/nfse"><infEvento Id="EVT1"><pedRegEvento><infPedReg Id="PRE1">`
    + `<chNFSe>${chaveNfse()}</chNFSe><e101101><xDesc>Cancelamento de NFS-e</xDesc></e101101></infPedReg></pedRegEvento></infEvento></evento>`;
  const d = lerDocAdn({ nsu: 11, tipo: 'EVENTO', xmlGzipB64: gz(xml) }, EMPRESA);
  assert.equal(d.tipo, 'evento');
  if (d.tipo === 'evento') assert.deepEqual(d.evento, { chave: chaveNfse(), codigo: '101101', cancelamento: true, nsu: 11 });
  const outro = lerDocAdn({ nsu: 12, tipo: 'EVENTO', xmlGzipB64: gz(xml.replace(/e101101/g, 'e105104')) }, EMPRESA);
  if (outro.tipo === 'evento') assert.equal(outro.evento.cancelamento, false); else assert.fail('devia ser evento');
});

test('SEFAZ: pedido da distribuição', () => {
  const p = pedidoDist(EMPRESA, '35', 123);
  assert.match(p, /<ultNSU>000000000000123<\/ultNSU>/);
  assert.match(p, new RegExp(`<CNPJ>${EMPRESA}</CNPJ>`));
  assert.match(p, /<cUFAutor>35<\/cUFAutor>/);
  assert.throws(() => pedidoDist('123', '35', 0));
  assert.throws(() => pedidoDist(EMPRESA, '35', -1));
  assert.throws(() => pedidoDist(EMPRESA, 'SP', 0));
});

const resNFe = (chave = chaveNfe()) => `<resNFe xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.01"><chNFe>${chave}</chNFe>`
  + `<CNPJ>${FORNECEDOR}</CNPJ><xNome>Fornecedor Teste</xNome><IE>1</IE><dhEmi>2026-11-08T08:00:00-03:00</dhEmi><tpNF>1</tpNF>`
  + `<vNF>2350.00</vNF><digVal>x</digVal><dhRecbto>2026-11-08T08:01:00-03:00</dhRecbto><nProt>1</nProt><cSitNFe>1</cSitNFe></resNFe>`;
const procNFe = (dest = EMPRESA) => `<nfeProc xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00"><NFe><infNFe Id="NFe${chaveNfe()}" versao="4.00">`
  + `<ide><cUF>35</cUF><serie>1</serie><nNF>1234</nNF><dhEmi>2026-11-08T08:00:00-03:00</dhEmi><cMunFG>3550308</cMunFG></ide>`
  + `<emit><CNPJ>${FORNECEDOR}</CNPJ><xNome>Fornecedor Teste</xNome></emit><dest><CNPJ>${dest}</CNPJ><xNome>Empresa</xNome></dest>`
  + `<total><ICMSTot><vNF>2350.00</vNF></ICMSTot></total></infNFe></NFe><protNFe><infProt><cStat>100</cStat></infProt></protNFe></nfeProc>`;
const resEvento = (codigo: string) => `<resEvento xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.01"><cOrgao>35</cOrgao>`
  + `<CNPJ>${FORNECEDOR}</CNPJ><chNFe>${chaveNfe()}</chNFe><dhEvento>2026-11-09T08:00:00-03:00</dhEvento><tpEvento>${codigo}</tpEvento>`
  + `<nSeqEvento>1</nSeqEvento><xEvento>Cancelamento</xEvento></resEvento>`;

test('SEFAZ: resposta com resumo, nota completa e evento', () => {
  const resp = `<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body><nfeDistDFeInteresseResponse>`
    + `<nfeDistDFeInteresseResult><retDistDFeInt xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.01"><tpAmb>1</tpAmb>`
    + `<cStat>138</cStat><xMotivo>Documento(s) localizado(s)</xMotivo><dhResp>x</dhResp><ultNSU>000000000000012</ultNSU>`
    + `<maxNSU>000000000000020</maxNSU><loteDistDFeInt>`
    + `<docZip NSU="000000000000010" schema="resNFe_v1.01.xsd">${gz(resNFe())}</docZip>`
    + `<docZip NSU="000000000000011" schema="procNFe_v4.00.xsd">${gz(procNFe())}</docZip>`
    + `<docZip NSU="000000000000012" schema="resEvento_1.01.xsd">${gz(resEvento('110111'))}</docZip>`
    + `</loteDistDFeInt></retDistDFeInt></nfeDistDFeInteresseResult></nfeDistDFeInteresseResponse></soap:Body></soap:Envelope>`;
  const r = lerRespostaDist(resp);
  assert.equal(r.cStat, '138');
  assert.equal(r.ultNsu, 12);
  assert.equal(r.maxNsu, 20);
  assert.deepEqual(r.docs.map((d) => d.nsu), [10, 11, 12]);
  const [a, b, c] = r.docs.map((d) => lerDocZip(d, EMPRESA));
  assert.equal(a.tipo, 'nota');
  if (a.tipo === 'nota') {
    assert.equal(a.completo, false);
    assert.deepEqual(a.nota, { tipo: 'nfe', chave: chaveNfe(), nsu: 10, tomador: EMPRESA, emitente_documento: FORNECEDOR,
      emitente_nome: 'Fornecedor Teste', numero: '1234', serie: '1', emissao: '2026-11-08', competencia: null, valor: 2350, municipio: null });
  }
  assert.equal(b.tipo, 'nota');
  if (b.tipo === 'nota' && a.tipo === 'nota') {
    assert.equal(b.completo, true);
    assert.equal(b.nota.municipio, '3550308');
    // o resumo e a nota completa dão os mesmos dados (o banco troca o XML do resumo pelo completo)
    for (const k of ['chave', 'emitente_documento', 'numero', 'serie', 'emissao', 'valor'] as const) assert.equal(b.nota[k], a.nota[k]);
  }
  assert.equal(c.tipo, 'evento');
  if (c.tipo === 'evento') assert.deepEqual(c.evento, { chave: chaveNfe(), codigo: '110111', cancelamento: true, nsu: 12 });
});

test('SEFAZ: nota completa de outro destinatário e schema desconhecido ficam de fora', () => {
  const d = lerDocZip({ nsu: 1, schema: 'procNFe_v4.00.xsd', xml: procNFe('44444444000144') }, EMPRESA);
  assert.deepEqual(d, { tipo: 'outro', nsu: 1, motivo: 'a empresa não é a destinatária' });
  assert.equal(lerDocZip({ nsu: 2, schema: 'xyz', xml: '<a/>' }, EMPRESA).tipo, 'outro');
  const ciencia = lerDocZip({ nsu: 3, schema: 'resEvento_1.01.xsd', xml: resEvento('210210') }, EMPRESA);
  if (ciencia.tipo === 'evento') assert.equal(ciencia.evento.cancelamento, false); else assert.fail('devia ser evento');
});

test('SEFAZ: resposta sem retDistDFeInt ou sem cStat é erro; XML com DOCTYPE é recusado', () => {
  assert.throws(() => lerRespostaDist('<a/>'));
  assert.throws(() => lerRespostaDist('<retDistDFeInt></retDistDFeInt>'));
  assert.throws(() => lerRespostaDist('<!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><retDistDFeInt/>'));
});

test('ritmo da SEFAZ: espera 1 h quando nada veio, no fim da fila ou com 656', () => {
  const agora = new Date('2026-11-23T12:00:00Z');
  const base = { motivo: '', docs: [] };
  const hora = new Date('2026-11-23T13:01:00Z').getTime();
  assert.equal(esperaSefaz({ ...base, cStat: '137', ultNsu: 5, maxNsu: 5 }, agora)?.getTime(), hora);
  assert.equal(esperaSefaz({ ...base, cStat: '656', ultNsu: NaN, maxNsu: NaN }, agora)?.getTime(), hora);
  assert.equal(esperaSefaz({ ...base, cStat: '138', ultNsu: 20, maxNsu: 20 }, agora)?.getTime(), hora);
  assert.equal(esperaSefaz({ ...base, cStat: '138', ultNsu: 12, maxNsu: 20 }, agora), null);
});

test('ciência: hora de Brasília', () => {
  assert.equal(horaBrasilia(new Date('2026-11-23T12:34:56.789Z')), '2026-11-23T09:34:56-03:00');
  assert.equal(horaBrasilia(new Date('2026-11-23T01:00:00Z')), '2026-11-22T22:00:00-03:00');
});

test('ciência: evento 210210 assinado (digest do infEvento e assinatura do SignedInfo conferem)', () => {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const sha1b64 = (s: string) => createHash('sha1').update(s, 'utf8').digest('base64');
  const assinador = { certificadoB64: 'Q0VSVA==', assinar: (s: string) => createSign('RSA-SHA1').update(s, 'utf8').sign(privateKey, 'base64') };
  const chave = chaveNfe();
  const ev = eventoCiencia(EMPRESA, chave, new Date('2026-11-23T12:00:00Z'), sha1b64, assinador);
  assert.match(ev, new RegExp(`<infEvento Id="ID210210${chave}01">`));
  assert.match(ev, /<cOrgao>91<\/cOrgao>/);
  assert.match(ev, /<dhEvento>2026-11-23T09:00:00-03:00<\/dhEvento>/);
  assert.match(ev, /<descEvento>Ciencia da Operacao<\/descEvento>/);
  // forma canônica: o infEvento com o xmlns herdado do evento, antes do Id
  const inf = ev.match(/<infEvento[\s\S]*<\/infEvento>/)![0].replace('<infEvento Id=', '<infEvento xmlns="http://www.portalfiscal.inf.br/nfe" Id=');
  assert.equal(ev.match(/<DigestValue>([^<]+)<\/DigestValue>/)![1], sha1b64(inf));
  const si = ev.match(/<SignedInfo>[\s\S]*<\/SignedInfo>/)![0].replace('<SignedInfo>', '<SignedInfo xmlns="http://www.w3.org/2000/09/xmldsig#">');
  const sv = ev.match(/<SignatureValue>([^<]+)<\/SignatureValue>/)![1];
  assert.ok(createVerify('RSA-SHA1').update(si, 'utf8').verify(publicKey, sv, 'base64'));
  assert.match(ev, /<X509Certificate>Q0VSVA==<\/X509Certificate>/);
  assert.throws(() => eventoCiencia(EMPRESA, '123', new Date(), sha1b64, assinador));
});

test('ciência: lote de 1 a 20 e resposta por chave', () => {
  assert.throws(() => pedidoEventos([], 1));
  assert.throws(() => pedidoEventos(Array(21).fill('<evento/>'), 1));
  assert.match(pedidoEventos(['<evento/>'], 7), /<idLote>7<\/idLote><evento\/>/);
  const k1 = chaveNfe(FORNECEDOR, 1, 1), k2 = chaveNfe(FORNECEDOR, 1, 2), k3 = chaveNfe(FORNECEDOR, 1, 3);
  const ret = (k: string, c: string) => `<retEvento versao="1.00"><infEvento><cStat>${c}</cStat><xMotivo>m${c}</xMotivo><chNFe>${k}</chNFe></infEvento></retEvento>`;
  const r = lerRespostaEventos(`<retEnvEvento xmlns="http://www.portalfiscal.inf.br/nfe"><idLote>7</idLote><cStat>128</cStat>`
    + ret(k1, '135') + ret(k2, '573') + ret(k3, '650') + `</retEnvEvento>`);
  assert.equal(r.lote, '128');
  assert.equal(r.porChave[k1].feito, true);
  assert.equal(r.porChave[k2].feito, true);
  assert.equal(r.porChave[k3].feito, false);
  assert.throws(() => lerRespostaEventos('<a/>'));
});
