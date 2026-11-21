// node --test --experimental-strip-types servicos/teste-adn/logica.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { lerLote, lerNota, resumir } from './logica.ts';

const BKM = '11111111000191';
const xml = (prest: string, toma: string, comp = '2026-09-15', mun = '3550308') =>
  `<NFSe xmlns="http://www.sped.fazenda.gov.br/nfse"><infNFSe><cLocIncid>${mun}</cLocIncid><DPS><infDPS><dCompet>${comp}</dCompet>` +
  `<prest><CNPJ>${prest}</CNPJ></prest><toma><CNPJ>${toma}</CNPJ><xNome>BKM</xNome></toma>` +
  `<valores><vServPrest><vServ>1500.00</vServ></vServPrest></valores></infDPS></DPS></infNFSe></NFSe>`;

test('lê o lote do ADN e acha o maior NSU', () => {
  const l = lerLote({ StatusProcessamento: 'DOCUMENTOS_LOCALIZADOS', LoteDFe: [
    { NSU: 7, ChaveAcesso: 'a', TipoDocumento: 'NFSE', ArquivoXml: 'x' }, { NSU: 9, ChaveAcesso: 'b', TipoDocumento: 'EVENTO', ArquivoXml: null }] });
  assert.equal(l.status, 'DOCUMENTOS_LOCALIZADOS');
  assert.equal(l.docs.length, 2);
  assert.equal(l.maiorNsu, 9);
});

test('lote vazio não quebra', () => {
  const l = lerLote({ StatusProcessamento: 'NENHUM_DOCUMENTO_LOCALIZADO' });
  assert.deepEqual([l.docs.length, l.maiorNsu], [0, null]);
});

test('separa prestador de tomador (o CNPJ do tomador não é confundido com o do prestador)', () => {
  const n = lerNota(xml('22222222000191', BKM));
  assert.deepEqual(n, { prestador: '22222222000191', tomador: BKM, competencia: '2026-09-15', municipio: '3550308', valor: 1500 });
});

test('resume só as recebidas por mês e por município', () => {
  const r = resumir([lerNota(xml('2', BKM)), lerNota(xml('3', BKM, '2026-10-01', '3524402')), lerNota(xml(BKM, '4')), null], BKM);
  assert.deepEqual(r.recebidas, { '2026-09': 1, '2026-10': 1 });
  assert.deepEqual(r.porMunicipio, { '3550308': 1, '3524402': 1 });
  assert.deepEqual([r.emitidas, r.outras, r.semXml], [1, 0, 1]);
});
