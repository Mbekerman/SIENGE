// node --test --experimental-strip-types servicos/sienge-escrita/envio.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  acharPeloMarcador, barrasDaLinha, ErroSienge, chavePix, conferirParcelas, Divergencia, enviarTitulo, erroPermanente, idDoLocation,
  pagamentoDaParcela, proximaTentativa, segundosRetryAfter, type Api, type Parcela, type PedidoTitulo,
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
  // CNPJ alfanumérico: o Sienge não aceita letras; vira divergência (fila manual), não erro que se repete
  assert.throws(() => chavePix('cpf_cnpj', '12ABC34501DE35'), (e) => e instanceof Divergencia);
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

test('pagamento da parcela: TED pela forma 6, com a conta e o titular com máscara', () => {
  const conta = { banco: '341', agencia: '1234', conta: '56789', conta_digito: '0', conta_tipo: 'corrente' as const,
                  titular_documento: '77777777000177', titular_nome: 'Fornecedor Exemplo' };
  const ted = pagamentoDaParcela(10, { numero: 1, vencimento: '2026-12-01', valor: 1, forma: 'ted', ted: conta }, 'u1');
  assert.equal(ted.caminho, '/bills/10/installments/1/payment-information/bank-transfer');
  assert.deepEqual(ted.corpo, {
    paymentTypeId: 6, notes: 'ERP u1 parcela 1', beneficiaryBankCode: '341', beneficiaryBankBranchNumber: '1234',
    beneficiaryAccountNumber: '56789', beneficiaryAccountDigit: '0', beneficiaryAccountType: 'C',
    beneficiaryName: 'Fornecedor Exemplo', beneficiaryCNPJNumber: '77.777.777/0001-77',
  });
  const pou = pagamentoDaParcela(10, { numero: 2, vencimento: '2026-12-01', valor: 1, forma: 'ted',
    ted: { ...conta, agencia_digito: 'X', conta_tipo: 'poupanca', titular_documento: '12345678909', titular_nome: null } }, 'u1');
  assert.equal(pou.corpo.beneficiaryAccountType, 'P');
  assert.equal(pou.corpo.beneficiaryBankBranchDigit, 'X');
  assert.equal(pou.corpo.beneficiaryCPFNumber, '123.456.789-09');
  assert.equal('beneficiaryName' in pou.corpo, false);
  assert.equal('beneficiaryCNPJNumber' in pou.corpo, false);
  assert.throws(() => pagamentoDaParcela(10, { numero: 3, vencimento: '', valor: 1, forma: 'ted' }, 'u1'), /TED/);
  assert.throws(() => pagamentoDaParcela(10, { numero: 3, vencimento: '', valor: 1, forma: 'ted', ted: { ...conta, banco: '34' } }, 'u1'), /TED/);
  assert.throws(() => pagamentoDaParcela(10, { numero: 3, vencimento: '', valor: 1, forma: 'ted', ted: { ...conta, titular_documento: '12ABC34501DE35' } }, 'u1'),
    (e) => e instanceof Divergencia);
});

const p = (numero: number, vencimento: string, valor: number): Parcela => ({ numero, vencimento, valor, forma: 'pix', pix_tipo: 'email', pix_chave: 'a@b.com' });

test('conferir parcelas: vencimento e valor corrigem, quantidade ou total diferente para', () => {
  const nossas = [p(1, '2026-12-01', 100), p(2, '2027-01-01', 200)];
  assert.deepEqual(conferirParcelas(nossas, [
    { installmentNumber: 1, dueDate: '2026-12-01', amount: 100 }, { installmentNumber: 2, dueDate: '2026-12-01', amount: 200.001 },
  ]), [{ numero: 2, dueDate: '2027-01-01' }]);
  assert.throws(() => conferirParcelas(nossas, [{ installmentNumber: 1, dueDate: '2026-12-01', amount: 300 }]), Divergencia);
  // mesmo total, valores diferentes (o Sienge dividiu igual): corrige o valor
  assert.deepEqual(conferirParcelas(nossas, [
    { installmentNumber: 1, dueDate: '2026-12-01', amount: 150 }, { installmentNumber: 2, dueDate: '2026-12-01', amount: 150 },
  ]), [{ numero: 1, amount: 100 }, { numero: 2, amount: 200, dueDate: '2027-01-01' }]);
  // total diferente: para
  assert.throws(() => conferirParcelas(nossas, [
    { installmentNumber: 1, dueDate: '2026-12-01', amount: 150 }, { installmentNumber: 2, dueDate: '2027-01-01', amount: 151 },
  ]), /total das parcelas/);
  // só a quantidade difere: as nossas batem, mas o Sienge tem uma a mais
  assert.throws(() => conferirParcelas(nossas, [
    { installmentNumber: 1, dueDate: '2026-12-01', amount: 100 }, { installmentNumber: 2, dueDate: '2027-01-01', amount: 200 },
    { installmentNumber: 3, dueDate: '2027-02-01', amount: 0 },
  ]), /3 parcelas/);
});

const pedido = (parcelas: Parcela[]): PedidoTitulo => ({
  titulo_id: 'u1', empresa: 11,
  titulo: { debtorId: 11, creditorId: 823, documentNumber: '9001', issueDate: '2026-11-17', notes: 'ERP u1 · teste' },
  parcelas,
});

// Sienge de mentira: guarda os títulos e as parcelas e registra cada chamada.
function falso(opc: { aceitaValor?: boolean; existentes?: Record<string, unknown>[]; parcelasDoSienge?: { installmentNumber: number; dueDate: string; amount: number }[] } = {}) {
  const chamadas: string[] = [];
  const registrados: number[] = [];
  const api: Api = {
    ler: async (c) => {
      chamadas.push(`GET ${c}`);
      if (c.startsWith('/bills?')) return { results: opc.existentes ?? [] };
      if (/\/installments$/.test(c)) return { results: opc.parcelasDoSienge ?? [] };
      throw new Error(`leitura inesperada ${c}`);
    },
    gravar: async (m, c, corpo) => {
      chamadas.push(`${m} ${c}`);
      // o PATCH em massa muda as parcelas, como o Sienge (menos com aceitaValor: false)
      if (m === 'PATCH' && /\/installments$/.test(c) && opc.aceitaValor !== false && Array.isArray(corpo)) {
        for (const x of corpo as { installmentId: number; amount?: number; dueDate?: string }[]) {
          const q = opc.parcelasDoSienge?.find((y) => y.installmentNumber === x.installmentId);
          if (q && x.amount !== undefined) q.amount = x.amount;
          if (q && x.dueDate !== undefined) q.dueDate = x.dueDate;
        }
      }
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
  for (const resp of [{ status: 200, location: null }, { status: 200, location: '/bills/9100' }, { status: 201, location: null }]) {
    const f = falso();
    f.api.gravar = async () => resp;
    await assert.rejects(enviarTitulo(f.api, pedido([p(1, '2026-12-01', 100)]), null), /POST/);
    assert.deepEqual(f.registrados, []);
  }
});

test('erro permanente: 4xx menos 408 e 429; Retry-After em segundos ou data', () => {
  assert.equal(erroPermanente(new ErroSienge(400, 'x')), true);
  assert.equal(erroPermanente(new ErroSienge(422, 'x')), true);
  assert.equal(erroPermanente(new ErroSienge(408, 'x')), false);
  assert.equal(erroPermanente(new ErroSienge(429, 'x')), false);
  assert.equal(erroPermanente(new ErroSienge(500, 'x')), false);
  assert.equal(erroPermanente(new Error('rede')), false);
  const t0 = new Date('2026-11-17T12:00:00Z');
  assert.equal(segundosRetryAfter('120', t0), 120);
  assert.equal(segundosRetryAfter('Tue, 17 Nov 2026 12:05:00 GMT', t0), 300);
  assert.equal(segundosRetryAfter(null, t0), null);
  assert.equal(segundosRetryAfter('amanhã', t0), null);
});

test('próxima tentativa: 1, 2, 4 minutos... até 6 horas', () => {
  const t0 = new Date('2026-11-17T12:00:00Z');
  const min = (n: number) => (proximaTentativa(n, t0).getTime() - t0.getTime()) / 60_000;
  assert.deepEqual([0, 1, 2, 3, 4].map(min), [1, 1, 2, 4, 8]);
  assert.equal(min(20), 360);
});

test('enviar: parcelas de valores diferentes corrigem num PATCH em massa e conferem de novo', async () => {
  const f = falso({ parcelasDoSienge: [
    { installmentNumber: 1, dueDate: '2026-12-01', amount: 1.5 }, { installmentNumber: 2, dueDate: '2027-01-01', amount: 1.5 }] });
  await enviarTitulo(f.api, pedido([p(1, '2026-12-01', 1), p(2, '2027-01-01', 2)]), 9300);
  assert.deepEqual(f.chamadas, [
    'GET /bills/9300/installments', 'PATCH /bills/9300/installments', 'GET /bills/9300/installments',
    'PATCH /bills/9300/installments/1/payment-information/pix', 'PATCH /bills/9300/installments/2/payment-information/pix',
  ]);
});

test('enviar: o Sienge não corrigiu o valor, para antes do pagamento', async () => {
  const f = falso({ aceitaValor: false, parcelasDoSienge: [
    { installmentNumber: 1, dueDate: '2026-12-01', amount: 1.5 }, { installmentNumber: 2, dueDate: '2027-01-01', amount: 1.5 }] });
  await assert.rejects(enviarTitulo(f.api, pedido([p(1, '2026-12-01', 1), p(2, '2027-01-01', 2)]), 9300), /não aceitou/);
  assert.equal(f.chamadas.some((c) => c.includes('payment-information')), false);
});
