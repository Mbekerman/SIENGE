// Testes da rodada por empresa, com banco e rede de mentira. Só dados fictícios.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { rodadaAdn, rodadaSefaz, rodadaCiencia, type Banco, type Leitura, type Rede } from './ciclo.ts';
import { lerPem } from './job.ts';

const EMP = { id: '00000000-0000-0000-0000-000000000001', cnpj: '33333333000133', uf: '35' };
const gz = (s: string) => gzipSync(Buffer.from(s)).toString('base64');
const chaveNfse = (n: number) => '3550308' + '1' + '2' + '55555555000155' + String(n).padStart(13, '0') + '2611' + '123456789' + '0';
const chaveNfe = (n: number) => '352611' + '55555555000155' + '55' + '001' + String(n).padStart(9, '0') + '1' + '12345678' + '9';
const nfse = (n: number, tomador = EMP.cnpj) => gz(`<NFSe><infNFSe Id="NFS${chaveNfse(n)}"><nNFSe>${n}</nNFSe><emit><CNPJ>55555555000155</CNPJ></emit>`
  + `<DPS><infDPS><dhEmi>2026-11-09T09:00:00-03:00</dhEmi><toma><CNPJ>${tomador}</CNPJ></toma><vServ>10.00</vServ></infDPS></DPS></infNFSe></NFSe>`);

function bancoFalso(leituras: Partial<Record<'adn' | 'sefaz', Leitura>> = {}) {
  const g = { notas: [] as string[], eventos: [] as string[], leituras: [] as unknown[][], ciencias: [] as string[], pendentes: [] as string[] };
  const b: Banco = {
    leitura: async (_e, o) => leituras[o] ?? { ultimoNsu: 0, lida: false, bloqueadoAte: null },
    gravarNota: async (_e, n) => { if (n.numero === '666') throw new Error('Emitente ou número não batem'); g.notas.push(n.chave); },
    gravarEvento: async (_e, ev) => { g.eventos.push(ev.codigo); },
    gravarLeitura: async (...a) => { g.leituras.push(a.slice(1)); },
    semCiencia: async (_e, lim) => g.pendentes.filter((k) => !g.ciencias.includes(k)).slice(0, lim),
    gravarCiencia: async (k) => { g.ciencias.push(k); },
  };
  return { b, g };
}
const ritmo = (agora = new Date('2026-11-23T12:00:00Z')) => ({ lotesAdn: 5, lotesSefaz: 5, lotesCiencia: 3, pausa: async () => {}, agora: () => agora });

test('ADN: começa do 0, segue pelo maior NSU, para no 404 e um erro de gravação não para o lote', async () => {
  const { b, g } = bancoFalso();
  const pedidos: number[] = [];
  const rede: Rede = {
    adn: async (nsu) => {
      pedidos.push(nsu);
      if (nsu === 0) return { status: 200, corpo: { StatusProcessamento: 'OK', LoteDFe: [
        { NSU: 1, TipoDocumento: 'NFSE', ArquivoXml: nfse(1) }, { NSU: 2, TipoDocumento: 'NFSE', ArquivoXml: nfse(666) },
        { NSU: 3, TipoDocumento: 'NFSE', ArquivoXml: nfse(3, '44444444000144') }] } };
      return { status: 404, corpo: { StatusProcessamento: 'NENHUM_DOCUMENTO_LOCALIZADO' } };
    },
    soap: async () => { throw new Error('não usa'); },
  };
  const r = await rodadaAdn(b, rede, EMP, ritmo());
  assert.deepEqual(pedidos, [0, 4]);
  assert.deepEqual(g.notas, [chaveNfse(1)]);
  assert.equal(r.falhas, 1);
  assert.equal(r.fora, 1);
  assert.equal(r.parou, 'fim');
  assert.equal(g.leituras[0][1], 3);
  assert.match(String(g.leituras[0][4]), /NSU 2: Emitente ou número não batem/);
  assert.deepEqual(g.leituras[1], ['adn', 3, null, null, null]);
});

test('ADN: já lido continua do último + 1; HTTP de erro registra e para', async () => {
  const { b, g } = bancoFalso({ adn: { ultimoNsu: 40, lida: true, bloqueadoAte: null } });
  const pedidos: number[] = [];
  const rede: Rede = { adn: async (nsu) => { pedidos.push(nsu); return { status: 503, corpo: {} }; }, soap: async () => ({ status: 500, corpo: '' }) };
  const r = await rodadaAdn(b, rede, EMP, ritmo());
  assert.deepEqual(pedidos, [41]);
  assert.equal(r.parou, 'HTTP 503');
  assert.deepEqual(g.leituras[0].slice(0, 3), ['adn', 40, null]);
  assert.match(String(g.leituras[0][4]), /HTTP 503/);
});

const ret = (cStat: string, ult: number, max: number, docs = '') => `<retDistDFeInt xmlns="http://www.portalfiscal.inf.br/nfe"><cStat>${cStat}</cStat>`
  + `<xMotivo>m</xMotivo><ultNSU>${String(ult).padStart(15, '0')}</ultNSU><maxNSU>${String(max).padStart(15, '0')}</maxNSU>`
  + (docs ? `<loteDistDFeInt>${docs}</loteDistDFeInt>` : '') + `</retDistDFeInt>`;
const resNFe = (n: number) => `<docZip NSU="${String(n).padStart(15, '0')}" schema="resNFe_v1.01.xsd">${gz(`<resNFe><chNFe>${chaveNfe(n)}</chNFe>`
  + `<CNPJ>55555555000155</CNPJ><dhEmi>2026-11-08T08:00:00-03:00</dhEmi><vNF>5.00</vNF></resNFe>`)}</docZip>`;

test('SEFAZ: lê até o fim da fila e marca a espera de 1 hora', async () => {
  const { b, g } = bancoFalso();
  const pedidos: string[] = [];
  const rede: Rede = {
    adn: async () => ({ status: 404, corpo: {} }),
    soap: async (_u, _a, corpo) => {
      const ult = Number(corpo.match(/<ultNSU>(\d+)<\/ultNSU>/)![1]);
      pedidos.push(String(ult));
      return { status: 200, corpo: ult === 0 ? ret('138', 5, 9, resNFe(5)) : ret('138', 9, 9, resNFe(9)) };
    },
  };
  const r = await rodadaSefaz(b, rede, EMP, ritmo());
  assert.deepEqual(pedidos, ['0', '5']);
  assert.deepEqual(g.notas, [chaveNfe(5), chaveNfe(9)]);
  assert.equal(r.parou, 'fim');
  const ultima = g.leituras.at(-1)!;
  assert.equal(ultima[1], 9);
  assert.equal((ultima[3] as Date).toISOString(), '2026-11-23T13:01:00.000Z');
});

test('SEFAZ: bloqueada não consulta; 656 registra o bloqueio', async () => {
  const agora = new Date('2026-11-23T12:00:00Z');
  const { b } = bancoFalso({ sefaz: { ultimoNsu: 5, lida: true, bloqueadoAte: new Date('2026-11-23T12:30:00Z') } });
  let chamou = false;
  const rede: Rede = { adn: async () => ({ status: 404, corpo: {} }), soap: async () => { chamou = true; return { status: 200, corpo: '' }; } };
  assert.equal((await rodadaSefaz(b, rede, EMP, ritmo(agora))).parou, 'esperando a hora da SEFAZ');
  assert.equal(chamou, false);
  const x = bancoFalso({ sefaz: { ultimoNsu: 5, lida: true, bloqueadoAte: null } });
  const r = await rodadaSefaz(x.b, { ...rede, soap: async () => ({ status: 200, corpo: ret('656', 5, 5) }) }, EMP, ritmo(agora));
  assert.equal(r.parou, 'bloqueio da SEFAZ (656)');
  assert.match(String(x.g.leituras[0][4]), /656/);
  assert.ok(x.g.leituras[0][3] instanceof Date);
});

test('ciência: manda as pendentes em lotes de até 20, grava as aceitas e para quando nenhuma é aceita', async () => {
  const { b, g } = bancoFalso();
  g.pendentes.push(...Array.from({ length: 25 }, (_, i) => chaveNfe(i + 1)));
  const assinador = { certificadoB64: 'AA==', assinar: () => 'c2ln' };
  const lotes: number[] = [];
  const rede: Rede = {
    adn: async () => ({ status: 404, corpo: {} }),
    soap: async (_u, _a, corpo) => {
      const ks = [...corpo.matchAll(/<chNFe>(\d{44})<\/chNFe>/g)].map((m) => m[1]);
      lotes.push(ks.length);
      const recusada = chaveNfe(25);
      return { status: 200, corpo: `<retEnvEvento><cStat>128</cStat>` + ks.map((k) =>
        `<retEvento><infEvento><cStat>${k === recusada ? '596' : '135'}</cStat><chNFe>${k}</chNFe></infEvento></retEvento>`).join('') + `</retEnvEvento>` };
    },
  };
  const r = await rodadaCiencia(b, rede, EMP, ritmo(), assinador, () => 'ZGln');
  assert.deepEqual(lotes, [20, 5, 1]);
  assert.equal(g.ciencias.length, 24);
  assert.ok(!g.ciencias.includes(chaveNfe(25)));
  assert.match(r.parou, /nenhuma aceita/);
});

test('certificado: o pem separa a chave e a cadeia', () => {
  const pem = `-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n-----BEGIN CERTIFICATE-----\nBBBB\n-----END CERTIFICATE-----\n`
    + `-----BEGIN CERTIFICATE-----\nCCCC\n-----END CERTIFICATE-----\n`;
  const { chave, certs } = lerPem(pem);
  assert.match(chave, /AAAA/);
  assert.equal(certs.length, 2);
  assert.throws(() => lerPem(`-----BEGIN CERTIFICATE-----\nBBBB\n-----END CERTIFICATE-----`));
});
