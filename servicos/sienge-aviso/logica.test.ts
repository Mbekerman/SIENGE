// node --test --experimental-strip-types servicos/sienge-aviso/logica.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CORPO_MAX, iguais, receber, registrarNoBanco, temBearer, type Aviso } from './logica.ts';

const TOKEN = 'k'.repeat(40);
const ID = '0f8fad5b-d9cb-469f-a165-70867728950e';
const pedido = (o: { metodo?: string; aut?: string | null; id?: string; evento?: string; corpo?: string } = {}) => {
  const h: Record<string, string> = { 'x-sienge-id': o.id ?? ID, 'x-sienge-event': o.evento ?? 'PAYMENT_INSTALLMENT_REMOVED', 'x-sienge-hook-id': 'h1' };
  if (o.aut !== null) h.authorization = o.aut ?? `Bearer ${TOKEN}`;
  return new Request('https://x/aviso', { method: o.metodo ?? 'POST', headers: h,
    body: (o.metodo ?? 'POST') === 'POST' ? (o.corpo ?? '{"billId":7301,"installmentId":1}') : undefined });
};
const gravador = (resposta: boolean | Error = true) => {
  const gravados: Aviso[] = [];
  return { gravados, f: async (a: Aviso) => { gravados.push(a); if (resposta instanceof Error) throw resposta; return resposta; } };
};

test('aviso certo é registrado e responde 200', async () => {
  const g = gravador();
  const r = await receber(pedido(), TOKEN, g.f);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { ok: true, novo: true });
  assert.deepEqual(g.gravados, [{ eventoId: ID, evento: 'PAYMENT_INSTALLMENT_REMOVED', hook: 'h1', corpo: { billId: 7301, installmentId: 1 } }]);
});

test('aviso repetido responde 200 sem ser novo', async () => {
  const r = await receber(pedido(), TOKEN, gravador(false).f);
  assert.deepEqual([r.status, await r.json()], [200, { ok: true, novo: false }]);
});

test('sem token certo, nada é gravado', async () => {
  for (const aut of [null, '', `Bearer ${TOKEN}x`, `Bearer ${TOKEN.slice(1)}`, TOKEN, `bearer ${TOKEN}`, `Basic ${TOKEN}`]) {
    const g = gravador();
    const r = await receber(pedido({ aut }), TOKEN, g.f);
    assert.equal(r.status, 401, String(aut));
    assert.equal(g.gravados.length, 0);
  }
});

test('sem token guardado (ou curto), recusa tudo, mesmo com cabeçalho vazio', async () => {
  for (const t of [null, undefined, '', 'curto']) {
    const g = gravador();
    const r = await receber(pedido({ aut: 'Bearer ' }), t, g.f);
    assert.equal(r.status, 503);
    assert.equal(g.gravados.length, 0);
  }
});

test('só POST', async () => {
  const g = gravador();
  assert.equal((await receber(pedido({ metodo: 'GET' }), TOKEN, g.f)).status, 405);
  assert.equal(g.gravados.length, 0);
});

test('id, evento e corpo inválidos são recusados sem gravar', async () => {
  const casos: [Parameters<typeof pedido>[0], number][] = [
    [{ id: 'abc' }, 400], [{ id: `${ID}x` }, 400], [{ evento: 'payment' }, 400], [{ evento: 'A;B' }, 400],
    [{ corpo: 'não json' }, 400], [{ corpo: '[1]' }, 400], [{ corpo: 'null' }, 400], [{ corpo: '7' }, 400],
    [{ corpo: JSON.stringify({ x: 'a'.repeat(CORPO_MAX) }) }, 413],
  ];
  for (const [o, st] of casos) {
    const g = gravador();
    assert.equal((await receber(pedido(o), TOKEN, g.f)).status, st, JSON.stringify(o).slice(0, 80));
    assert.equal(g.gravados.length, 0);
  }
});

test('evento que não usamos responde 200 sem gravar', async () => {
  const g = gravador();
  const r = await receber(pedido({ evento: 'PAYMENT_INSTALLMENT_CREATED' }), TOKEN, g.f);
  assert.equal(r.status, 200);
  assert.equal(g.gravados.length, 0);
});

test('id em maiúsculas vira minúsculas; hook ausente vira nulo', async () => {
  const g = gravador();
  const req = new Request('https://x', { method: 'POST', body: '{}',
    headers: { authorization: `Bearer ${TOKEN}`, 'x-sienge-id': ID.toUpperCase(), 'x-sienge-event': 'PAYMENT_INSTALLMENT_REMOVED' } });
  assert.equal((await receber(req, TOKEN, g.f)).status, 200);
  assert.deepEqual([g.gravados[0].eventoId, g.gravados[0].hook], [ID, null]);
});

test('erro do banco responde 500 sem o detalhe', async () => {
  const r = await receber(pedido(), TOKEN, gravador(new Error('senha do banco xyz')).f);
  assert.equal(r.status, 500);
  assert.doesNotMatch(await r.text(), /xyz/);
});

test('comparação do token', () => {
  assert.ok(iguais('abc', 'abc'));
  assert.ok(!iguais('abc', 'abd'));
  assert.ok(!iguais('abc', 'ab'));
  assert.ok(!iguais('ab', 'abc'));
  assert.ok(!iguais('', 'a'));
  assert.ok(!iguais('\u00e9', 'e\u0301'));
  assert.ok(!iguais('a', 'a\u0000'));
});

test('triagem antes do banco: só Bearer com 32 caracteres ou mais', () => {
  const com = (aut?: string) => new Request('https://x', { method: 'POST', headers: aut === undefined ? {} : { authorization: aut } });
  assert.ok(temBearer(com(`Bearer ${'a'.repeat(32)}`)));
  for (const aut of [undefined, '', 'Bearer ', `Bearer ${'a'.repeat(31)}`, `bearer ${'a'.repeat(40)}`, `Basic ${'a'.repeat(40)}`, `Bearer ${'a'.repeat(20)} ${'b'.repeat(20)}`])
    assert.ok(!temBearer(com(aut)), String(aut));
});

test('registro no banco: como erp_sistema e o corpo por tx.json, nunca como texto', async () => {
  const passos: { q: string; v: unknown[] }[] = [];
  const tx = Object.assign((partes: TemplateStringsArray, ...v: unknown[]) => {
    passos.push({ q: partes.join('?').replace(/\s+/g, ' ').trim(), v });
    return Promise.resolve([{ novo: true }]);
  }, { json: (j: unknown) => ({ comoJson: j }) });
  const sql = { begin: async (f: (t: unknown) => Promise<unknown>) => await f(tx) };
  const corpo = { billId: 7301, installmentId: 1 };
  assert.equal(await registrarNoBanco(sql)({ eventoId: ID, evento: 'PAYMENT_INSTALLMENT_REMOVED', hook: 'h1', corpo }), true);
  assert.equal(passos[0].q, 'set local role erp_sistema');
  assert.ok(passos[1].q.includes('erp.sienge_registrar_aviso'));
  assert.deepEqual(passos[1].v, [ID, 'PAYMENT_INSTALLMENT_REMOVED', 'h1', { comoJson: corpo }]);
});
