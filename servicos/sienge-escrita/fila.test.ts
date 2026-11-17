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

function banco(item: ItemFila | null, ped: PedidoTitulo | Error = pedido(), conferir: { item_id: string; sienge_id: number } | null = null) {
  const fim: Record<string, unknown>[] = [];
  const reg: number[] = [];
  const ids: number[] = [];
  const apagados: string[] = [];
  const b: Banco = {
    enfileirar: async () => 1,
    pegar: async () => item,
    pedido: async () => { if (ped instanceof Error) throw ped; return ped; },
    registrar: async (_t, s) => { reg.push(s); ids.push(s); },
    idsNoSienge: async () => [...ids, ...(item?.sienge_id ? [item.sienge_id] : [])],
    terminar: async (_t, r) => { fim.push(r); },
    pegarConferencia: async () => conferir,
    marcarApagado: async (id) => { apagados.push(id); },
    pegarCruzamento: async () => null,
    prvNossas: async () => [],
    recriarPrv: async () => { throw new Error('não recria'); },
    terminarCruzamento: async () => { throw new Error('não cruza'); },
    linhasApagar: async () => [],
  };
  return { b, fim, reg, apagados };
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
  const { b, fim, reg } = banco({ item_id: T, sienge_id: null, tentativas: 0 });
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
    const { b, fim } = banco({ item_id: T, sienge_id: null, tentativas: 2 }, ped);
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
  const { b } = banco({ item_id: T, sienge_id: 9100, tentativas: 0 });
  const s = sienge({ debtorDoTitulo: 2 }); // id da fila apontando para título de outra empresa
  const r = await processarUm(b, s.h, cfg);
  assert.equal(r.passo, 'erro');
  assert.equal(s.chamadas.some((c) => c.startsWith('PATCH')), false);
});

test('com o id do Sienge já na fila, a trava deixa gravar no título criado pela fila (caminho de teste)', async () => {
  const { b, fim, reg } = banco({ item_id: T, sienge_id: 9100, tentativas: 0 });
  const s = sienge();
  const r = await processarUm(b, s.h, cfg);
  assert.equal(r.passo, 'enviado');
  assert.deepEqual(reg, []);
  assert.deepEqual(s.chamadas, ['GET /bills/9100/installments', 'GET /bills/9100', 'PATCH /bills/9100/installments/1/payment-information/pix']);
  assert.equal(fim[0].situacao, 'enviado');
});

test('POST respondido sem 201 vira erro e não registra id', async () => {
  const { b, fim, reg } = banco({ item_id: T, sienge_id: null, tentativas: 0 });
  const s = sienge();
  s.h.enviar = async (m, c) => { s.chamadas.push(`${m} ${c}`); return { status: 200, location: '/bills/9100' }; };
  const r = await processarUm(b, s.h, cfg);
  assert.equal(r.passo, 'erro');
  assert.deepEqual(reg, []);
  assert.equal(fim[0].situacao, 'erro');
});

test('4xx do Sienge: tenta de novo e, na terceira recusa seguida, vai para manual', async () => {
  for (const [antes, esperado] of [[0, 'erro'], [TENTATIVAS_4XX - 2, 'erro'], [TENTATIVAS_4XX - 1, 'manual']] as const) {
    const { b, fim } = banco({ item_id: T, sienge_id: null, tentativas: antes });
    const s = sienge();
    s.h.enviar = async () => { throw new ErroSienge(400, 'Sienge POST /bills respondeu 400: campo inválido'); };
    const r = await processarUm(b, s.h, cfg);
    assert.equal(r.passo, esperado);
    assert.equal(fim[0].situacao, esperado);
    if (esperado === 'manual') assert.match(String(fim[0].erro), /recusado pelo Sienge em 3 tentativas/);
  }
  // 429 e 5xx nunca vão para manual sozinhos
  for (const st of [429, 500]) {
    const { b, fim } = banco({ item_id: T, sienge_id: null, tentativas: 10 });
    const s = sienge();
    s.h.enviar = async () => { throw new ErroSienge(st, 'x'); };
    await processarUm(b, s.h, cfg);
    assert.equal(fim[0].situacao, 'erro');
  }
});

test('Retry-After do Sienge empurra a próxima tentativa (S-044)', async () => {
  const { b, fim } = banco({ item_id: T, sienge_id: null, tentativas: 0 });
  const s = sienge();
  s.h.enviar = async () => { throw new ErroSienge(429, 'limite', 3600); };
  await processarUm(b, s.h, cfg);
  assert.equal((fim[0].proxima as Date).getTime() - cfg.agora().getTime(), 3600_000);
  // pedido menor que a espera normal não encurta a espera
  const c = banco({ item_id: T, sienge_id: null, tentativas: 4 });
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
    if (/erp\.sienge_pegar\(\)/.test(partes.join(''))) return Promise.resolve([{ item_id: T, sienge_id: null, tentativas: 0 }]);
    if (/erp\.sienge_pegar_conferencia\(\)/.test(partes.join(''))) return Promise.resolve([{ item_id: T, sienge_id: 7 }]);
    if (/erp\.sienge_ids\(\)/.test(partes.join(''))) return Promise.resolve([{ sienge_id: 5 }]);
    if (/erp\.sienge_pedido_item/.test(partes.join(''))) return Promise.resolve([{ p: pedido() }]);
    if (/erp\.sienge_pegar_cruzamento\(\)/.test(partes.join(''))) return Promise.resolve([{ empresa_sienge: 11, desde: '2026-11-01' }]);
    if (/erp\.sienge_prv_nossas/.test(partes.join(''))) return Promise.resolve([{ sienge_id: 7, previsao_id: T, esperada: true }]);
    if (/erp\.sienge_terminar_cruzamento/.test(partes.join(''))) return Promise.resolve([{ n: 3 }]);
    return Promise.resolve([]);
  };
  const sql = { begin: async (f: (t: unknown) => Promise<unknown>) => { atual = []; log.push(atual); return await f(tx); } };
  const bp = bancoPostgres(sql);
  assert.equal(await bp.enfileirar(), 2);
  assert.deepEqual(await bp.pegar(), { item_id: T, sienge_id: null, tentativas: 0 });
  await bp.pedido(T);
  await bp.registrar(T, 9);
  assert.deepEqual(await bp.idsNoSienge(), [5]);
  await bp.terminar(T, { situacao: 'erro', erro: 'x', tentativas: 1, proxima: new Date() });
  assert.deepEqual(await bp.pegarConferencia(), { item_id: T, sienge_id: 7 });
  await bp.marcarApagado(T);
  assert.deepEqual(await bp.pegarCruzamento(), { empresa: 11, desde: '2026-11-01' });
  assert.deepEqual(await bp.prvNossas(11), [{ sienge_id: 7, previsao_id: T, esperada: true }]);
  await bp.recriarPrv(T, 7, 'm');
  assert.equal(await bp.terminarCruzamento(11, [], {}), 3);
  assert.deepEqual(await bp.linhasApagar(), []);
  assert.equal(log.length, 13);
  const sqls = log.map((p) => p[1]);
  for (const f of ['sienge_enfileirar', 'sienge_pegar()', 'sienge_pedido_item', 'sienge_registrar_item', 'sienge_ids()', 'sienge_terminar', 'sienge_pegar_conferencia()', 'sienge_marcar_apagado',
                   'sienge_pegar_cruzamento()', 'sienge_prv_nossas', 'sienge_recriar_prv', 'sienge_terminar_cruzamento', 'v_sienge_prv_apagar'])
    assert.ok(sqls.some((q) => q.includes(`erp.${f}`)), f);
  for (const passo of log) assert.equal(passo[0], 'set local role erp_sistema');
});

test('divergência vai para manual; pedido recusado pelo banco vai para erro', async () => {
  const d = banco({ item_id: T, sienge_id: 9100, tentativas: 0 });
  assert.equal((await processarUm(d.b, sienge({ amount: 2 }).h, cfg)).passo, 'manual');
  assert.equal(d.fim[0].situacao, 'manual');
  const e = banco({ item_id: T, sienge_id: null, tentativas: 0 }, new Error('Falta o de-para da natureza'));
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

test('previsão (PRV): título sem forma de pagamento não faz o PATCH do pagamento', async () => {
  const ped = pedido();
  ped.parcelas = [{ numero: 1, vencimento: '2026-12-01', valor: 1 }];
  ped.titulo.documentNumber = 'PRV-0000000000AA';
  const { b, fim, reg } = banco({ item_id: T, sienge_id: null, tentativas: 0 }, ped);
  const s = sienge();
  const r = await processarUm(b, s.h, cfg);
  assert.equal(r.passo, 'enviado');
  assert.deepEqual(reg, [9100]);
  assert.equal(fim[0].situacao, 'enviado');
  assert.ok(s.chamadas.includes('POST /bills'));
  assert.ok(!s.chamadas.some((c) => c.startsWith('PATCH')), s.chamadas.join(', '));
});

test('fila vazia confere a linha PRV a apagar: 404 marca apagada; outro erro não marca', async () => {
  const sumiu = banco(null, pedido(), { item_id: T, sienge_id: 7001 });
  const h404: Http = { ler: async () => { throw new ErroSienge(404, 'não existe', null); }, enviar: async () => { throw new Error('não grava'); } };
  assert.deepEqual(await processarUm(sumiu.b, h404, cfg), { passo: 'apagado', previsao: T, siengeId: 7001, enfileirados: 1 });
  assert.deepEqual(sumiu.apagados, [T]);

  const existe = banco(null, pedido(), { item_id: T, sienge_id: 7001 });
  const lidos: string[] = [];
  const h200: Http = { ler: async (c) => { lidos.push(c); return { id: 7001 }; }, enviar: async () => { throw new Error('não grava'); } };
  assert.equal((await processarUm(existe.b, h200, cfg)).passo, 'nada a fazer');
  assert.deepEqual(lidos, ['/bills/7001']);
  assert.deepEqual(existe.apagados, []);

  const caiu = banco(null, pedido(), { item_id: T, sienge_id: 7001 });
  const h500: Http = { ler: async () => { throw new ErroSienge(500, 'fora do ar', null); }, enviar: async () => { throw new Error('não grava'); } };
  assert.equal((await processarUm(caiu.b, h500, cfg)).passo, 'nada a fazer');
  assert.deepEqual(caiu.apagados, []);
});

// Cruzamento: fila vazia e nada a conferir
function cruzamento(nossas: { sienge_id: number; previsao_id: string; esperada: boolean }[]) {
  const recriadas: [string, number][] = [];
  const fins: { empresa: number; estranhas: unknown[]; resumo: Record<string, number>; erro?: string | null }[] = [];
  const x = banco(null);
  x.b.pegarCruzamento = async () => ({ empresa: 11, desde: '2026-11-01' });
  x.b.prvNossas = async () => nossas;
  x.b.recriarPrv = async (p, s) => { recriadas.push([p, s]); };
  x.b.terminarCruzamento = async (empresa, estranhas, resumo, erro) => { fins.push({ empresa, estranhas, resumo, erro }); return estranhas.length; };
  return { b: x.b, recriadas, fins };
}
const P1 = '00000000-0000-0000-0000-0000000000b1', P2 = '00000000-0000-0000-0000-0000000000b2', P3 = '00000000-0000-0000-0000-0000000000b3';

test('cruzamento: recria a esperada que sumiu (fora da lista e 404) e aponta as estranhas', async () => {
  const c = cruzamento([
    { sienge_id: 7001, previsao_id: P1, esperada: true },  // na lista: fica
    { sienge_id: 7002, previsao_id: P2, esperada: true },  // fora da lista, 404: recria
    { sienge_id: 7003, previsao_id: P3, esperada: true },  // fora da lista, mas o GET acha: não mexe
    { sienge_id: 7004, previsao_id: P1, esperada: false }, // trocada/apagar: conhecida, não é estranha
    { sienge_id: 7005, previsao_id: P3, esperada: false }, // não esperada e fora da lista: nem consulta
    { sienge_id: 7006, previsao_id: P3, esperada: true },  // fora da lista, GET com 500: não mexe
  ]);
  const lidos: string[] = [];
  const h: Http = {
    ler: async (q) => {
      lidos.push(q);
      if (q.startsWith('/bills?')) return { resultSetMetadata: { total: 4 }, results: [
        { id: 7001, documentNumber: 'PRV-1', notes: `ERP ${P1} · Previsão` },
        { id: 7004, documentNumber: 'PRV-4' },
        { id: 8000, documentNumber: 'X', issueDate: '2026-10-01', totalInvoiceAmount: 5, notes: 'lançada à mão' },
        { id: 8001, documentNumber: 'PRV-9', notes: `ERP ${P2} · Previsão` },
      ] };
      if (q === '/bills/7002') throw new ErroSienge(404, 'não existe', null);
      if (q === '/bills/7003') return { id: 7003 };
      if (q === '/bills/7006') throw new ErroSienge(500, 'fora do ar', null);
      throw new Error(q);
    },
    enviar: async () => { throw new Error('cruzamento não grava no Sienge'); },
  };
  const r = await processarUm(c.b, h, cfg);
  assert.deepEqual(r, { passo: 'cruzado', empresa: 11, lidas: 4, recriadas: 1, estranhas: 2, novas: 2, enfileirados: 1 });
  assert.deepEqual(c.recriadas, [[P2, 7002]]);
  const q = new URLSearchParams(lidos[0].split('?')[1]);
  assert.deepEqual([q.get('startDate'), q.get('endDate'), q.get('debtorId'), q.get('documentsIdentificationId'), q.get('limit'), q.get('offset')],
                   ['2026-11-01', '2026-11-17', '11', 'PRV', '200', '0']);
  assert.deepEqual(lidos.slice(1), ['/bills/7002', '/bills/7003', '/bills/7006']);
  const est = c.fins[0].estranhas as { sienge_id: number; motivo: string; valor: number | null; emissao: string | null }[];
  assert.deepEqual(est.map((e) => e.sienge_id), [8000, 8001]);
  assert.equal(est[0].motivo, 'sem a marca do ERP');
  assert.deepEqual([est[0].valor, est[0].emissao], [5, '2026-10-01']);
  assert.match(est[1].motivo, /duplicada/);
  assert.deepEqual(c.fins[0].resumo, { lidas: 4, recriadas: 1, nao_confirmadas: 2 });
  assert.equal(c.fins[0].erro, undefined);
});

test('cruzamento: lista vazia (404) recria as esperadas que somem; páginas seguem até o total', async () => {
  const c = cruzamento([{ sienge_id: 7002, previsao_id: P2, esperada: true }]);
  const h: Http = { ler: async () => { throw new ErroSienge(404, 'Resource not found', null); }, enviar: async () => { throw new Error('não'); } };
  assert.equal((await processarUm(c.b, h, cfg)).passo, 'cruzado');
  assert.deepEqual(c.recriadas, [[P2, 7002]]);

  const d = cruzamento([]);
  const offsets: string[] = [];
  const pag: Http = {
    ler: async (q) => {
      const o = Number(new URLSearchParams(q.split('?')[1]).get('offset'));
      offsets.push(String(o));
      const n = o === 0 ? 200 : 3;
      return { resultSetMetadata: { total: 203 }, results: Array.from({ length: n }, (_, i) => ({ id: 10000 + o + i })) };
    },
    enviar: async () => { throw new Error('não'); },
  };
  const r = await processarUm(d.b, pag, cfg);
  assert.deepEqual(offsets, ['0', '200']);
  assert.equal((r as { lidas: number }).lidas, 203);

  // sem o total, a página incompleta encerra
  const e = cruzamento([]);
  let chamadas = 0;
  const curta: Http = { ler: async () => { chamadas++; return { results: [{ id: 1 }, { id: 2 }] }; }, enviar: async () => { throw new Error('não'); } };
  assert.equal(((await processarUm(e.b, curta, cfg)) as { lidas: number }).lidas, 2);
  assert.equal(chamadas, 1);
});

test('cruzamento: erro do Sienge na lista fecha a passada com erro, sem recriar nem apontar', async () => {
  const c = cruzamento([{ sienge_id: 7002, previsao_id: P2, esperada: true }]);
  const h: Http = { ler: async () => { throw new ErroSienge(429, 'cota', 60); }, enviar: async () => { throw new Error('não'); } };
  const r = await processarUm(c.b, h, cfg);
  assert.equal(r.passo, 'cruzamento com erro');
  assert.deepEqual(c.recriadas, []);
  assert.deepEqual(c.fins.map((f) => [f.estranhas.length, typeof f.erro]), [[0, 'string']]);
  // 404 na segunda página é erro, não lista vazia
  const d = cruzamento([]);
  const h2: Http = { ler: async (q) => {
    if (q.includes('offset=0')) return { results: Array.from({ length: 200 }, (_, i) => ({ id: i + 1 })) };
    throw new ErroSienge(404, 'x', null);
  }, enviar: async () => { throw new Error('não'); } };
  assert.equal((await processarUm(d.b, h2, cfg)).passo, 'cruzamento com erro');
});

test('cruzamento: sem empresa para cruzar (fora da madrugada ou feito), nada a fazer e nenhuma chamada', async () => {
  const x = banco(null);
  const h: Http = { ler: async () => { throw new Error('não chama'); }, enviar: async () => { throw new Error('não'); } };
  assert.deepEqual(await processarUm(x.b, h, cfg), { passo: 'nada a fazer', enfileirados: 1 });
});
