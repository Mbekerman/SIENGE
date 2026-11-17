// node --test --experimental-strip-types servicos/sienge-escrita/fila.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dataSaoPaulo, httpSienge, processarUm, type Banco, type Http, type ItemFila } from './fila.ts';
import type { PedidoTitulo } from './envio.ts';

const T = '00000000-0000-0000-0000-0000000000aa';
const pedido = (debtorId = 11, creditorId = 823): PedidoTitulo => ({
  titulo_id: T, empresa: debtorId,
  titulo: { debtorId, creditorId, documentNumber: '9001', issueDate: '2026-11-17', notes: `ERP ${T} · teste` },
  parcelas: [{ numero: 1, vencimento: '2026-12-01', valor: 1, forma: 'pix', pix_tipo: 'email', pix_chave: 'a@b.com' }],
});

function banco(item: ItemFila | null, ped: PedidoTitulo | Error = pedido()) {
  const fim: Record<string, unknown>[] = [];
  const reg: number[] = [];
  const ids: number[] = [];
  const b: Banco = {
    enfileirar: async () => 1,
    pegar: async () => item,
    pedido: async () => { if (ped instanceof Error) throw ped; return ped; },
    registrar: async (_t, s) => { reg.push(s); ids.push(s); },
    idsNoSienge: async () => [...ids, ...(item?.sienge_id ? [item.sienge_id] : [])],
    terminar: async (_t, r) => { fim.push(r); },
  };
  return { b, fim, reg };
}

function sienge(opc: { amount?: number; debtorDoTitulo?: number } = {}) {
  const chamadas: string[] = [];
  const h: Http = {
    ler: async (c) => {
      chamadas.push(`GET ${c.split('?')[0]}`);
      if (c.startsWith('/bills?')) return { results: [] };
      if (/\/installments$/.test(c)) return { results: [{ installmentNumber: 1, dueDate: '2026-12-01', amount: opc.amount ?? 1 }] };
      if (/^\/bills\/\d+$/.test(c)) return { id: 9100, debtorId: opc.debtorDoTitulo ?? 11 };
      throw new Error('?');
    },
    enviar: async (m, c) => { chamadas.push(`${m} ${c}`); return m === 'POST' ? { status: 201, location: '/bills/9100' } : { status: 204 }; },
  };
  return { h, chamadas };
}

const cfg = { ambiente: 'dev', credoresTeste: [823], agora: () => new Date('2026-11-17T12:00:00Z') };

test('fila vazia: só enfileira', async () => {
  const { b } = banco(null);
  assert.deepEqual(await processarUm(b, sienge().h, cfg), { passo: 'nada a fazer', enfileirados: 1 });
});

test('envio completo em teste, passando pela trava', async () => {
  const { b, fim, reg } = banco({ titulo_id: T, sienge_id: null, tentativas: 0 });
  const s = sienge();
  const r = await processarUm(b, s.h, cfg);
  assert.equal(r.passo, 'enviado');
  assert.deepEqual(reg, [9100]);
  assert.deepEqual(s.chamadas, [
    'GET /bills', 'POST /bills', 'GET /bills/9100/installments',
    'GET /bills/9100', 'PATCH /bills/9100/installments/1/payment-information/pix', // a trava lê a empresa antes
  ]);
  assert.deepEqual(fim, [{ situacao: 'enviado', passo: 'pagamento', erro: null, tentativas: 1, proxima: cfg.agora() }]);
});

test('a trava recusa empresa real e credor real em teste: nada sai, fica em erro', async () => {
  for (const ped of [pedido(2, 823), pedido(11, 27)]) {
    const { b, fim } = banco({ titulo_id: T, sienge_id: null, tentativas: 2 }, ped);
    const s = sienge();
    const r = await processarUm(b, s.h, cfg);
    assert.equal(r.passo, 'erro');
    assert.match((r as { erro: string }).erro, /trava/);
    assert.equal(s.chamadas.some((c) => !c.startsWith('GET')), false);
    assert.equal(fim[0].tentativas, 3);
    assert.equal((fim[0].proxima as Date).getTime() - cfg.agora().getTime(), 4 * 60_000);
  }
});

test('a trava recusa gravar em título que não foi criado pela fila', async () => {
  const { b } = banco({ titulo_id: T, sienge_id: 9100, tentativas: 0 });
  const s = sienge({ debtorDoTitulo: 2 }); // id da fila apontando para título de outra empresa
  const r = await processarUm(b, s.h, cfg);
  assert.equal(r.passo, 'erro');
  assert.equal(s.chamadas.some((c) => c.startsWith('PATCH')), false);
});

test('divergência vai para manual; pedido recusado pelo banco vai para erro', async () => {
  const d = banco({ titulo_id: T, sienge_id: 9100, tentativas: 0 });
  assert.equal((await processarUm(d.b, sienge({ amount: 2 }).h, cfg)).passo, 'manual');
  assert.equal(d.fim[0].situacao, 'manual');
  const e = banco({ titulo_id: T, sienge_id: null, tentativas: 0 }, new Error('Falta o de-para da natureza'));
  const r = await processarUm(e.b, sienge().h, cfg);
  assert.deepEqual([r.passo, (r as { erro: string }).erro], ['erro', 'Falta o de-para da natureza']);
});

test('data de hoje em São Paulo', () => {
  assert.equal(dataSaoPaulo(new Date('2026-11-18T02:00:00Z')), '2026-11-17');
});

test('http: erro fora de 2xx e Location lido', async () => {
  const falsoFetch = (async (url: string, init: RequestInit) => {
    if (init.method === 'POST') return new Response('', { status: 201, headers: { location: '/bills/7' } });
    return new Response('{"x":1}', { status: url.endsWith('/ruim') ? 400 : 200 });
  }) as typeof fetch;
  const h = httpSienge('https://x/v1', 'Basic y', falsoFetch);
  assert.deepEqual(await h.ler('/bom'), { x: 1 });
  await assert.rejects(h.ler('/ruim'), /400/);
  assert.equal((await h.enviar('POST', '/bills', {})).location, '/bills/7');
});
