// node --test --experimental-strip-types apps/web/testes/busca.test.ts
import test from 'node:test';
import assert from 'node:assert/strict';
import { filtrar } from '../src/lib/busca.ts';

test('busca da lista: todas as palavras, sem acento nem maiúscula, em qualquer ordem', () => {
  const ops = [{ id: '1', nome: 'Comerciais › Marketing › Agência' }, { id: '2', nome: 'Comerciais › Custos de repasse' }, { id: '3', nome: 'Pessoal › Salários' }];
  assert.deepEqual(filtrar(ops, '').map(o => o.id), ['1', '2', '3']);
  assert.deepEqual(filtrar(ops, 'agencia').map(o => o.id), ['1']);
  assert.deepEqual(filtrar(ops, 'MARK agên').map(o => o.id), ['1']);
  assert.deepEqual(filtrar(ops, 'comerciais').map(o => o.id), ['1', '2']);
  assert.deepEqual(filtrar(ops, 'salario xyz').map(o => o.id), []);
});
