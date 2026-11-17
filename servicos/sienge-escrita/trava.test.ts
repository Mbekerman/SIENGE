// node --test --experimental-strip-types servicos/sienge-escrita/trava.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { conferirGravacao, empresaDoCorpo, gravarComTrava, registroDoCaminho } from './trava.ts';

const CREDOR_TESTE = 900;
const titulo = (debtorId: unknown, creditorId: unknown = CREDOR_TESTE) => ({ debtorId, creditorId, totalInvoiceAmount: 1 });
const ctxTeste = { credoresTeste: new Set([CREDOR_TESTE]), criadosPeloTeste: new Set(['bills:8547']) };
const novo = (corpo: unknown, empresa?: number) => ({ metodo: 'POST', caminho: '/bills', corpo, empresa });
const pix = (id: number, empresa?: number) => ({ metodo: 'PATCH', caminho: `/bills/${id}/installments/1/payment-information/pix`, corpo: { keyPix: 'x' }, empresa });

test('leitura passa em qualquer ambiente', () => {
  assert.deepEqual(conferirGravacao({ metodo: 'get', caminho: '/bills/1' }, undefined), { ok: true, empresa: null });
  assert.deepEqual(conferirGravacao({ metodo: 'GET', caminho: '/creditors/27/pix-informations' }, 'producao'), { ok: true, empresa: null });
});

test('título novo em teste: só empresa 11 e credor de teste', () => {
  assert.deepEqual(conferirGravacao(novo(titulo(11)), 'dev', ctxTeste), { ok: true, empresa: 11 });
  for (const e of [1, 2, 5]) assert.equal(conferirGravacao(novo(titulo(e)), 'dev', ctxTeste).ok, false);
  assert.equal(conferirGravacao(novo(titulo(11, 27)), 'dev', ctxTeste).ok, false); // credor real
  assert.equal(conferirGravacao(novo(titulo(11, null)), 'dev', ctxTeste).ok, false);
  assert.equal(conferirGravacao(novo(titulo(11)), 'dev').ok, false); // sem lista de credores de teste
});

test('ambiente diferente da palavra exata conta como teste', () => {
  for (const amb of [undefined, '', 'Producao', 'produção', ' producao']) {
    assert.equal(conferirGravacao(novo(titulo(2)), amb, ctxTeste).ok, false);
  }
});

test('produção recusa empresa de teste e a Muchmore, aceita as outras', () => {
  assert.equal(conferirGravacao(novo(titulo(11, 27)), 'producao').ok, false);
  assert.equal(conferirGravacao(novo(titulo(1, 27)), 'producao').ok, false);
  assert.deepEqual(conferirGravacao(novo(titulo(2, 27)), 'producao'), { ok: true, empresa: 2 });
});

test('sem empresa conhecida recusa, também em produção', () => {
  assert.equal(conferirGravacao(novo({ creditorId: CREDOR_TESTE }), 'dev', ctxTeste).ok, false);
  assert.equal(conferirGravacao(novo({ creditorId: 27 }), 'producao').ok, false);
});

test('corpo e empresa informada divergentes recusa, nos dois sentidos', () => {
  assert.equal(conferirGravacao(novo(titulo(2), 11), 'dev', ctxTeste).ok, false);
  assert.equal(conferirGravacao(novo(titulo(11), 2), 'dev', ctxTeste).ok, false);
});

test('corpo com empresa ilegível ou divergente recusa', () => {
  assert.equal(empresaDoCorpo({ debtorId: 11, companyId: 2 }), 'conflito');
  assert.equal(empresaDoCorpo([{ companyId: 11 }, { companyId: 2 }]), 'conflito');
  assert.equal(empresaDoCorpo({ debtorId: 'onze' }), 'conflito');
  assert.equal(empresaDoCorpo({ debtorId: '11' }), 11);
  assert.equal(conferirGravacao(novo(titulo(null)), 'dev', ctxTeste).ok, false);
});

test('S-120: registro existente vale a empresa lida nele, não a declarada', () => {
  // id digitado errado (8457 no lugar de 8547) é de outra empresa: recusa mesmo com empresa 11 declarada
  assert.equal(conferirGravacao(pix(8457, 11), 'dev', { ...ctxTeste, empresaDoRegistro: 2 }).ok, false);
  // sem leitura da empresa do registro: recusa
  assert.equal(conferirGravacao(pix(8547, 11), 'dev', ctxTeste).ok, false);
  assert.equal(conferirGravacao(pix(8547), 'producao').ok, false);
  // registro da 11 criado pelo teste: passa
  assert.deepEqual(conferirGravacao(pix(8547), 'dev', { ...ctxTeste, empresaDoRegistro: 11 }), { ok: true, empresa: 11 });
  // registro da 11 que o teste não criou: recusa
  assert.equal(conferirGravacao(pix(8548), 'dev', { ...ctxTeste, empresaDoRegistro: 11 }).ok, false);
  // em produção, a do registro decide
  assert.deepEqual(conferirGravacao(pix(8417), 'producao', { empresaDoRegistro: 2 }), { ok: true, empresa: 2 });
  assert.equal(conferirGravacao(pix(8547), 'producao', { empresaDoRegistro: 11 }).ok, false);
  assert.equal(conferirGravacao(pix(8417, 3), 'producao', { empresaDoRegistro: 2 }).ok, false);
  // DELETE e anexo também passam pela empresa do registro
  assert.equal(conferirGravacao({ metodo: 'DELETE', caminho: '/bills/8417', empresa: 11 }, 'dev', { ...ctxTeste, empresaDoRegistro: 2 }).ok, false);
  assert.equal(conferirGravacao({ metodo: 'POST', caminho: '/bills/8547/attachments?description=x' }, 'dev', { ...ctxTeste, empresaDoRegistro: 11 }).ok, true);
});

test('S-121: rotas de credor', () => {
  for (const amb of ['dev', 'producao']) {
    assert.equal(conferirGravacao({ metodo: 'POST', caminho: '/creditors/27/pix-informations', corpo: {} }, amb).ok, false);
    assert.equal(conferirGravacao({ metodo: 'PATCH', caminho: '/creditors/27/pix-informations/1', empresa: 11 }, amb).ok, false);
    assert.equal(conferirGravacao({ metodo: 'PATCH', caminho: '/creditors/27/bank-informations/1' }, amb).ok, false);
    assert.equal(conferirGravacao({ metodo: 'POST', caminho: '/creditors/27/bank-informations' }, amb).ok, false);
  }
  // em teste, nenhuma gravação em credor, nem com empresa 11 informada
  for (const c of ['/creditors', '/creditors/27', '/creditors/27/activate', '/creditors/27/deactivate']) {
    assert.equal(conferirGravacao({ metodo: 'PUT', caminho: c, empresa: 11 }, 'dev', ctxTeste).ok, false);
  }
  assert.equal(conferirGravacao({ metodo: 'POST', caminho: '/creditors', corpo: { name: 'x' } }, 'dev', ctxTeste).ok, false);
  // em produção, só a inclusão de credor novo
  assert.deepEqual(conferirGravacao({ metodo: 'POST', caminho: '/creditors', corpo: { name: 'x' } }, 'producao'), { ok: true, empresa: null });
  assert.equal(conferirGravacao({ metodo: 'PATCH', caminho: '/creditors/27' }, 'producao').ok, false);
  assert.equal(conferirGravacao({ metodo: 'PUT', caminho: '/creditors/27/deactivate' }, 'producao').ok, false);
  assert.equal(conferirGravacao({ metodo: 'PUT', caminho: '/creditors', corpo: { name: 'x' } }, 'producao').ok, false);
  assert.equal(conferirGravacao({ metodo: 'POST', caminho: '/creditors/27' }, 'producao').ok, false);
  // a conta bancária cai na regra própria (nunca pela API), não só na de "só inclusão"
  const conta = conferirGravacao({ metodo: 'POST', caminho: '/creditors/27/bank-informations' }, 'producao');
  assert.equal(conta.ok, false);
  assert.match((conta as { motivo: string }).motivo, /PIX e conta bancária/);
});

test('método desconhecido conta como gravação', () => {
  assert.equal(conferirGravacao({ metodo: 'MERGE', caminho: '/bills', corpo: titulo(2) }, 'dev', ctxTeste).ok, false);
});

test('registroDoCaminho', () => {
  assert.equal(registroDoCaminho('/bills'), null);
  assert.equal(registroDoCaminho('/bills/'), null);
  assert.deepEqual(registroDoCaminho('/bills/8547/attachments?x=1'), { recurso: 'bills', id: '8547' });
});

test('gravarComTrava lê a empresa do título antes e só grava se passar', async () => {
  const lidos: string[] = [];
  const ler = async (c: string) => { lidos.push(c); return c === '/bills/8547' ? { debtorId: 11 } : { debtorId: 2 }; };
  let gravou = 0;
  const gravar = async () => { gravou++; return 'ok'; };
  assert.equal(await gravarComTrava(pix(8547, 11), 'dev', ler, gravar, ctxTeste), 'ok');
  await assert.rejects(gravarComTrava(pix(8457, 11), 'dev', ler, gravar, ctxTeste), /registro \(2\)/);
  // recurso sem leitura conhecida: recusa sem gravar
  await assert.rejects(gravarComTrava({ metodo: 'PATCH', caminho: '/supply-contracts/measurements/2', empresa: 11 }, 'dev', ler, gravar, ctxTeste), /não lida/);
  // leitura não é feita para registro novo nem para credor
  await assert.rejects(gravarComTrava({ metodo: 'PATCH', caminho: '/creditors/27/pix-informations/1' }, 'dev', ler, gravar), /PIX/);
  assert.deepEqual(lidos, ['/bills/8547', '/bills/8457']);
  assert.equal(gravou, 1);
});
