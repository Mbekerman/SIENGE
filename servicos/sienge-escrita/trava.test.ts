// node --test --experimental-strip-types servicos/sienge-escrita/trava.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { conferirGravacao, empresaDoCorpo } from './trava.ts';

const titulo = (debtorId: unknown) => ({ debtorId, creditorId: 27, totalInvoiceAmount: 1 });

test('leitura passa em qualquer ambiente', () => {
  assert.deepEqual(conferirGravacao({ metodo: 'get', caminho: '/bills/1' }, undefined), { ok: true, empresa: null });
  assert.deepEqual(conferirGravacao({ metodo: 'GET', caminho: '/bills/1' }, 'producao'), { ok: true, empresa: null });
});

test('fora de produção grava só na empresa 11', () => {
  assert.deepEqual(conferirGravacao({ metodo: 'POST', caminho: '/bills', corpo: titulo(11) }, 'dev'), { ok: true, empresa: 11 });
  for (const e of [1, 2, 5]) {
    assert.equal(conferirGravacao({ metodo: 'POST', caminho: '/bills', corpo: titulo(e) }, 'dev').ok, false);
  }
});

test('ambiente não informado conta como teste', () => {
  assert.equal(conferirGravacao({ metodo: 'POST', caminho: '/bills', corpo: titulo(2) }, undefined).ok, false);
  assert.equal(conferirGravacao({ metodo: 'POST', caminho: '/bills', corpo: titulo(2) }, '').ok, false);
  assert.equal(conferirGravacao({ metodo: 'POST', caminho: '/bills', corpo: titulo(2) }, 'Producao').ok, false);
});

test('produção recusa empresa de teste e a Muchmore', () => {
  assert.equal(conferirGravacao({ metodo: 'POST', caminho: '/bills', corpo: titulo(11) }, 'producao').ok, false);
  assert.equal(conferirGravacao({ metodo: 'POST', caminho: '/bills', corpo: titulo(1) }, 'producao').ok, false);
  assert.deepEqual(conferirGravacao({ metodo: 'POST', caminho: '/bills', corpo: titulo(2) }, 'producao'), { ok: true, empresa: 2 });
});

test('sem empresa conhecida recusa; empresa informada vale para rota sem corpo', () => {
  const pix = { metodo: 'PATCH', caminho: '/bills/8547/installments/1/payment-information/pix', corpo: { pixKey: 'x' } };
  assert.equal(conferirGravacao(pix, 'dev').ok, false);
  assert.deepEqual(conferirGravacao({ ...pix, empresa: 11 }, 'dev'), { ok: true, empresa: 11 });
  assert.equal(conferirGravacao({ metodo: 'DELETE', caminho: '/x/1', empresa: 2 }, 'dev').ok, false);
});

test('empresa do corpo diferente da informada recusa', () => {
  assert.equal(conferirGravacao({ metodo: 'POST', caminho: '/bills', corpo: titulo(2), empresa: 11 }, 'dev').ok, false);
});

test('corpo com empresa ilegível ou divergente recusa', () => {
  assert.equal(empresaDoCorpo({ debtorId: 11, companyId: 2 }), 'conflito');
  assert.equal(empresaDoCorpo([{ companyId: 11 }, { companyId: 2 }]), 'conflito');
  assert.equal(empresaDoCorpo({ debtorId: 'onze' }), 'conflito');
  assert.equal(empresaDoCorpo({ debtorId: '11' }), 11);
  assert.equal(conferirGravacao({ metodo: 'POST', caminho: '/bills', corpo: titulo(null) }, 'dev').ok, false);
});
