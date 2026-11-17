// node --test --experimental-strip-types servicos/sienge-carga/logica.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cabecalhosParaGuardar, esperaDoSienge, marcaAusentes, montarConsulta, proximaAcaoMassa, proximaVirada, restanteHoje } from './logica.ts';

const base = { id: 1, recurso: 'bulk:outcome', parametros: {}, situacao: 'pendente', pedido_assincrono: null,
  pedacos: null, pedacos_lidos: 0, iniciada_em: null };
const agora = new Date('2026-11-17T12:00:00Z');

test('pede a consulta quando não há pedido', () => {
  assert.deepEqual(proximaAcaoMassa(base, null, agora, 6), { tipo: 'pedir' });
});
test('acompanha o andamento até saber os pedaços', () => {
  assert.deepEqual(proximaAcaoMassa({ ...base, pedido_assincrono: 'abc' }, null, agora, 6), { tipo: 'andamento' });
});
test('baixa o próximo pedaço e conclui no fim', () => {
  const c = { ...base, pedido_assincrono: 'abc', pedacos: 4, pedacos_lidos: 2 };
  assert.deepEqual(proximaAcaoMassa(c, null, agora, 6), { tipo: 'baixar', pedaco: 3 });
  assert.deepEqual(proximaAcaoMassa({ ...c, pedacos_lidos: 4 }, null, agora, 6), { tipo: 'concluir' });
});
test('deixa a reserva da cota de massa para o CRM e espera a virada', () => {
  const cota = { restante_dia: 6, lido_em: '2026-11-17T10:00:00Z' };
  const a = proximaAcaoMassa(base, cota, agora, 6);
  assert.equal(a.tipo, 'esperar_cota');
  assert.equal((a as { ate: Date }).ate.toISOString(), '2026-11-18T00:05:00.000Z');
});
test('cota lida ontem não vale hoje', () => {
  assert.equal(restanteHoje({ restante_dia: 0, lido_em: '2026-11-16T23:59:00Z' }, agora), null);
  assert.equal(restanteHoje({ restante_dia: 9, lido_em: '2026-11-17T00:10:00Z' }, agora), 9);
});
test('virada é meia-noite UTC + 5 min, também no fim do mês', () => {
  assert.equal(proximaVirada(new Date('2026-11-30T23:00:00Z')).toISOString(), '2026-12-01T00:05:00.000Z');
});
test('Retry-After', () => {
  assert.equal(esperaDoSienge('10415'), 10415);
  assert.equal(esperaDoSienge(null), 60);
  assert.equal(esperaDoSienge('lixo'), 60);
});
test('consulta nunca leva credencial', () => {
  assert.equal(montarConsulta('/outcome', { startDate: '2000-01-01', _async: 'true' }), '/outcome?_async=true&startDate=2000-01-01');
  assert.throws(() => montarConsulta('/outcome', { senha: 'x' }));
  assert.throws(() => montarConsulta('/outcome', { Authorization: 'x' }));
});
test('cabeçalhos guardados não incluem autenticação', () => {
  const h = new Headers({ 'X-Ratelimit-Remaining-Day': '13', Authorization: 'Basic x', 'Set-Cookie': 'a=b', 'Retry-After': '36' });
  assert.deepEqual(cabecalhosParaGuardar(h), { 'x-ratelimit-remaining-day': '13', 'retry-after': '36' });
});
test('só carga por emissão, sem filtro e com janela marca ausentes', () => {
  const j = { selectionType: 'I', startDate: '2000-01-01', endDate: '2026-12-31', withAuthorizations: 'true' };
  assert.equal(marcaAusentes(j), true);
  assert.equal(marcaAusentes({ ...j, selectionType: 'D' }), false);
  assert.equal(marcaAusentes({ ...j, companyId: '5' }), false);
  assert.equal(marcaAusentes({ selectionType: 'I', startDate: '2000-01-01' }), false);
});
