// node --test --experimental-strip-types servicos/sienge-escrita/fila.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bancoPostgres, dataSaoPaulo, httpSienge, processarUm, TENTATIVAS_4XX, type Banco, type Http, type ItemFila } from './fila.ts';
import { ErroSienge, type PedidoTitulo } from './envio.ts';

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

test('com o id do Sienge já na fila, a trava deixa gravar no título criado pela fila (caminho de teste)', async () => {
  const { b, fim, reg } = banco({ titulo_id: T, sienge_id: 9100, tentativas: 0 });
  const s = sienge();
  const r = await processarUm(b, s.h, cfg);
  assert.equal(r.passo, 'enviado');
  assert.deepEqual(reg, []);
  assert.deepEqual(s.chamadas, ['GET /bills/9100/installments', 'GET /bills/9100', 'PATCH /bills/9100/installments/1/payment-information/pix']);
  assert.equal(fim[0].situacao, 'enviado');
});

test('POST respondido sem 201 vira erro e não registra id', async () => {
  const { b, fim, reg } = banco({ titulo_id: T, sienge_id: null, tentativas: 0 });
  const s = sienge();
  s.h.enviar = async (m, c) => { s.chamadas.push(`${m} ${c}`); return { status: 200, location: '/bills/9100' }; };
  const r = await processarUm(b, s.h, cfg);
  assert.equal(r.passo, 'erro');
  assert.deepEqual(reg, []);
  assert.equal(fim[0].situacao, 'erro');
});

test('4xx do Sienge: tenta de novo e, na terceira recusa seguida, vai para manual', async () => {
  for (const [antes, esperado] of [[0, 'erro'], [TENTATIVAS_4XX - 2, 'erro'], [TENTATIVAS_4XX - 1, 'manual']] as const) {
    const { b, fim } = banco({ titulo_id: T, sienge_id: null, tentativas: antes });
    const s = sienge();
    s.h.enviar = async () => { throw new ErroSienge(400, 'Sienge POST /bills respondeu 400: campo inválido'); };
    const r = await processarUm(b, s.h, cfg);
    assert.equal(r.passo, esperado);
    assert.equal(fim[0].situacao, esperado);
    if (esperado === 'manual') assert.match(String(fim[0].erro), /recusado pelo Sienge em 3 tentativas/);
  }
  // 429 e 5xx nunca vão para manual sozinhos
  for (const st of [429, 500]) {
    const { b, fim } = banco({ titulo_id: T, sienge_id: null, tentativas: 10 });
    const s = sienge();
    s.h.enviar = async () => { throw new ErroSienge(st, 'x'); };
    await processarUm(b, s.h, cfg);
    assert.equal(fim[0].situacao, 'erro');
  }
});

test('Retry-After do Sienge empurra a próxima tentativa (S-044)', async () => {
  const { b, fim } = banco({ titulo_id: T, sienge_id: null, tentativas: 0 });
  const s = sienge();
  s.h.enviar = async () => { throw new ErroSienge(429, 'limite', 3600); };
  await processarUm(b, s.h, cfg);
  assert.equal((fim[0].proxima as Date).getTime() - cfg.agora().getTime(), 3600_000);
  // pedido menor que a espera normal não encurta a espera
  const c = banco({ titulo_id: T, sienge_id: null, tentativas: 4 });
  const s2 = sienge();
  s2.h.enviar = async () => { throw new ErroSienge(429, 'limite', 1); };
  await processarUm(c.b, s2.h, cfg);
  assert.equal((c.fim[0].proxima as Date).getTime() - cfg.agora().getTime(), 16 * 60_000);
});

test('banco: todo passo roda numa transação como erp_sistema', async () => {
  const log: string[][] = [];
  let atual: string[] = [];
  const tx = (partes: TemplateStringsArray) => {
    atual.push(partes.join('?').replace(/\s+/g, ' ').trim());
    if (/sienge_enfileirar/.test(partes.join(''))) return Promise.resolve([{ n: 2 }]);
    if (/returning titulo_id/.test(partes.join(''))) return Promise.resolve([{ titulo_id: T, sienge_id: null, tentativas: 0 }]);
    if (/select sienge_id from/.test(partes.join(''))) return Promise.resolve([{ sienge_id: 5 }]);
    if (/sienge_pedido/.test(partes.join(''))) return Promise.resolve([{ p: pedido() }]);
    return Promise.resolve([]);
  };
  const sql = { begin: async (f: (t: unknown) => Promise<unknown>) => { atual = []; log.push(atual); return await f(tx); } };
  const bp = bancoPostgres(sql);
  assert.equal(await bp.enfileirar(), 2);
  assert.deepEqual(await bp.pegar(), { titulo_id: T, sienge_id: null, tentativas: 0 });
  await bp.pedido(T);
  await bp.registrar(T, 9);
  assert.deepEqual(await bp.idsNoSienge(), [5]);
  await bp.terminar(T, { situacao: 'erro', erro: 'x', tentativas: 1, proxima: new Date() });
  assert.equal(log.length, 6);
  for (const passo of log) assert.equal(passo[0], 'set local role erp_sistema');
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
    if (url.endsWith('/limite')) return new Response('', { status: 429, headers: { 'retry-after': '90' } });
    return new Response('{"x":1}', { status: url.endsWith('/ruim') ? 400 : 200 });
  }) as typeof fetch;
  const h = httpSienge('https://x/v1', 'Basic y', falsoFetch);
  assert.deepEqual(await h.ler('/bom'), { x: 1 });
  await assert.rejects(h.ler('/ruim'), (e: unknown) => e instanceof ErroSienge && e.status === 400 && e.retryAfter === null);
  await assert.rejects(h.ler('/limite'), (e: unknown) => e instanceof ErroSienge && e.status === 429 && e.retryAfter === 90);
  assert.equal((await h.enviar('POST', '/bills', {})).location, '/bills/7');
});
