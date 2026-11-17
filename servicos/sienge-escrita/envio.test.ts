// node --test --experimental-strip-types servicos/sienge-escrita/envio.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  acharPeloMarcador, barrasDaLinha, ErroSienge, chavePix, conferirParcelas, Divergencia, enviarTitulo, idDoLocation,
  pagamentoDaParcela, proximaTentativa, type Api, type Parcela, type PedidoTitulo,
} from './envio.ts';

const LINHA = '34191090080000000212134567890008799990000000100'; // boleto de teste (o mesmo do erp.sql)

test('id do título pelo Location', () => {
  assert.equal(idDoLocation('https://api.sienge.com.br/x/public/api/v1/bills/8547'), 8547);
  assert.equal(idDoLocation('/bills/12/'), 12);
  assert.equal(idDoLocation('/bills/abc'), null);
  assert.equal(idDoLocation(null), null);
});

test('linha digitável vira código de barras e recusa dígito errado', () => {
  const b = barrasDaLinha(LINHA);
  assert.equal(b.length, 44);
  assert.equal(b.slice(0, 4), '3419');
  assert.equal(b.slice(5, 19), LINHA.slice(33, 47));
  assert.throws(() => barrasDaLinha(LINHA.slice(0, 46)));
  const campoErrado = LINHA.slice(0, 9) + String((Number(LINHA[9]) + 1) % 10) + LINHA.slice(10);
  assert.throws(() => barrasDaLinha(campoErrado), /campo/);
  const geralErrado = LINHA.slice(0, 32) + String((Number(LINHA[32]) + 1) % 10) + LINHA.slice(33);
  assert.throws(() => barrasDaLinha(geralErrado), /geral/);
});

test('chave PIX com a máscara do Sienge', () => {
  assert.deepEqual(chavePix('cpf_cnpj', '29732041000154'), { keyPixType: 'C', keyPix: '29.732.041/0001-54' });
  assert.deepEqual(chavePix('cpf_cnpj', '12345678901'), { keyPixType: 'C', keyPix: '123.456.789-01' });
  assert.deepEqual(chavePix('email', 'a@b.com'), { keyPixType: 'E', keyPix: 'a@b.com' });
  assert.equal(chavePix('aleatoria', 'x').keyPixType, 'A');
  assert.throws(() => chavePix('cpf_cnpj', '123'));
  assert.throws(() => chavePix(undefined, 'x'));
});

test('pagamento da parcela: PIX sem dados do credor e boleto com as duas linhas', () => {
  const pix = pagamentoDaParcela(10, { numero: 1, vencimento: '2026-12-01', valor: 1, forma: 'pix', pix_tipo: 'email', pix_chave: 'a@b.com' }, 'u1');
  assert.equal(pix.caminho, '/bills/10/installments/1/payment-information/pix');
  assert.deepEqual(pix.corpo, { paymentTypeId: 14, notes: 'ERP u1 parcela 1', isUsingCreditorData: 'N', keyPixType: 'E', keyPix: 'a@b.com' });
  const bol = pagamentoDaParcela(10, { numero: 2, vencimento: '2026-12-01', valor: 1, forma: 'boleto', boleto_linha: LINHA, boleto_tipo: 2 }, 'u1');
  assert.equal(bol.caminho, '/bills/10/installments/2/payment-information/boleto-bancario');
  assert.equal(bol.corpo.paymentTypeId, 2);
  assert.equal(bol.corpo.boletoBancarioManualBarCodeNumber, LINHA);
  assert.equal(String(bol.corpo.boletoBancarioBarCodeNumber).length, 44);
  assert.throws(() => pagamentoDaParcela(10, { numero: 3, vencimento: '', valor: 1, forma: 'pix' }, 'u1'), /chave/);
  assert.throws(() => pagamentoDaParcela(10, { numero: 3, vencimento: '', valor: 1, forma: 'boleto', boleto_linha: LINHA }, 'u1'), /boleto/);
});

const p = (numero: number, vencimento: string, valor: number): Parcela => ({ numero, vencimento, valor, forma: 'pix', pix_tipo: 'email', pix_chave: 'a@b.com' });

test('conferir parcelas: vencimento corrige, valor ou quantidade diferente para', () => {
  const nossas = [p(1, '2026-12-01', 100), p(2, '2027-01-01', 200)];
  assert.deepEqual(conferirParcelas(nossas, [
    { installmentNumber: 1, dueDate: '2026-12-01', amount: 100 }, { installmentNumber: 2, dueDate: '2026-12-01', amount: 200.001 },
  ]), [{ numero: 2, dueDate: '2027-01-01' }]);
  assert.throws(() => conferirParcelas(nossas, [{ installmentNumber: 1, dueDate: '2026-12-01', amount: 300 }]), Divergencia);
  assert.throws(() => conferirParcelas(nossas, [
    { installmentNumber: 1, dueDate: '2026-12-01', amount: 150 }, { installmentNumber: 2, dueDate: '2027-01-01', amount: 150 },
  ]), Divergencia);
});

const pedido = (parcelas: Parcela[]): PedidoTitulo => ({
  titulo_id: 'u1', empresa: 11,
  titulo: { debtorId: 11, creditorId: 823, documentNumber: '9001', issueDate: '2026-11-17', notes: 'ERP u1 · teste' },
  parcelas,
});

// Sienge de mentira: guarda os títulos e as parcelas e registra cada chamada.
function falso(opc: { existentes?: Record<string, unknown>[]; parcelasDoSienge?: { installmentNumber: number; dueDate: string; amount: number }[] } = {}) {
  const chamadas: string[] = [];
  const registrados: number[] = [];
  const api: Api = {
    ler: async (c) => {
      chamadas.push(`GET ${c}`);
      if (c.startsWith('/bills?')) return { results: opc.existentes ?? [] };
      if (/\/installments$/.test(c)) return { results: opc.parcelasDoSienge ?? [] };
      throw new Error(`leitura inesperada ${c}`);
    },
    gravar: async (m, c) => {
      chamadas.push(`${m} ${c}`);
      return m === 'POST' ? { status: 201, location: '/bills/9100' } : { status: 204 };
    },
    registrarCriado: async (id) => { registrados.push(id); },
    hoje: () => '2026-11-18',
  };
  return { api, chamadas, registrados };
}

test('enviar: cria, registra, corrige vencimento e grava o pagamento', async () => {
  const f = falso({ parcelasDoSienge: [{ installmentNumber: 1, dueDate: '2026-11-30', amount: 100 }] });
  const r = await enviarTitulo(f.api, pedido([p(1, '2026-12-01', 100)]), null);
  assert.deepEqual(r, { siengeId: 9100, criado: true });
  assert.deepEqual(f.registrados, [9100]);
  assert.equal(f.chamadas[0].startsWith('GET /bills?'), true);
  assert.match(f.chamadas[0], /endDate=2026-11-18/);
  assert.deepEqual(f.chamadas.slice(1), [
    'POST /bills', 'GET /bills/9100/installments', 'PATCH /bills/9100/installments/1',
    'PATCH /bills/9100/installments/1/payment-information/pix',
  ]);
});

test('enviar: acha pelo marcador e não cria de novo', async () => {
  const f = falso({
    existentes: [{ id: 9200, notes: 'ERP u1 · teste' }, { id: 9201, notes: 'ERP u12 · outro' }, { id: 9202, notes: 'outro ERP u1' }],
    parcelasDoSienge: [{ installmentNumber: 1, dueDate: '2026-12-01', amount: 100 }],
  });
  const r = await enviarTitulo(f.api, pedido([p(1, '2026-12-01', 100)]), null);
  assert.deepEqual(r, { siengeId: 9200, criado: false });
  assert.deepEqual(f.registrados, [9200]);
  assert.equal(f.chamadas.some((c) => c.startsWith('POST')), false);
});

test('enviar: mesmo credor e número sem o marcador é divergência e não cria', async () => {
  const f = falso({ existentes: [{ id: 9400, notes: 'lançado à mão' }] });
  await assert.rejects(enviarTitulo(f.api, pedido([p(1, '2026-12-01', 100)]), null), /9400/);
  assert.equal(f.chamadas.some((c) => c.startsWith('POST')), false);
});

test('enviar: com o id já na fila, não procura nem cria', async () => {
  const f = falso({ parcelasDoSienge: [{ installmentNumber: 1, dueDate: '2026-12-01', amount: 100 }] });
  const r = await enviarTitulo(f.api, pedido([p(1, '2026-12-01', 100)]), 9300);
  assert.deepEqual(r, { siengeId: 9300, criado: false });
  assert.deepEqual(f.registrados, []);
  assert.deepEqual(f.chamadas, ['GET /bills/9300/installments', 'PATCH /bills/9300/installments/1/payment-information/pix']);
});

test('enviar: divergência para antes do pagamento', async () => {
  const f = falso({ parcelasDoSienge: [{ installmentNumber: 1, dueDate: '2026-12-01', amount: 99 }] });
  await assert.rejects(enviarTitulo(f.api, pedido([p(1, '2026-12-01', 100)]), 9300), Divergencia);
  assert.equal(f.chamadas.some((c) => c.startsWith('PATCH')), false);
});

test('enviar: dois títulos com o marcador é divergência; pedido sem marcador é recusado', async () => {
  const f = falso({ existentes: [{ id: 1, notes: 'ERP u1 a' }, { id: 2, notes: 'ERP u1 b' }] });
  await assert.rejects(acharPeloMarcador(f.api, pedido([])), Divergencia);
  const sem = pedido([]);
  sem.titulo.notes = 'sem marcador';
  await assert.rejects(enviarTitulo(falso().api, sem, null), /marcador/);
});

test('pesquisa sem resultado (404 do Sienge) é lista vazia; outro erro sobe', async () => {
  const f = falso();
  f.api.ler = async () => { throw new ErroSienge(404, 'Resource not found'); };
  assert.equal(await acharPeloMarcador(f.api, pedido([])), null);
  f.api.ler = async () => { throw new ErroSienge(500, 'erro'); };
  await assert.rejects(acharPeloMarcador(f.api, pedido([])), /erro/);
});

test('enviar: POST sem 201 ou sem Location não registra nada', async () => {
  const f = falso();
  f.api.gravar = async () => ({ status: 200, location: null });
  await assert.rejects(enviarTitulo(f.api, pedido([p(1, '2026-12-01', 100)]), null), /POST/);
  assert.deepEqual(f.registrados, []);
});

test('próxima tentativa: 1, 2, 4 minutos... até 6 horas', () => {
  const t0 = new Date('2026-11-17T12:00:00Z');
  const min = (n: number) => (proximaTentativa(n, t0).getTime() - t0.getTime()) / 60_000;
  assert.deepEqual([0, 1, 2, 3, 4].map(min), [1, 1, 2, 4, 8]);
  assert.equal(min(20), 360);
});
