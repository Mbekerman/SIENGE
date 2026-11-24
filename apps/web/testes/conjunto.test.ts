// node --test --experimental-strip-types apps/web/testes/conjunto.test.ts (só dados inventados: o repositório é público)
import test from 'node:test';
import assert from 'node:assert/strict';
import { casarBoletos, cobradoDe, conferirValores, juntarLeituras, liquidoDe } from '../src/lib/conjunto.ts';

const arq = (nome: string, leitura: any, extra: any = {}) => ({ anexo: { id: nome, nome, tipo_mime: 'application/pdf', tamanho: 1 },
  repetido_em: [], leitura, identificacao: null, ...extra });
const bol = (linha: string, valor?: number, vencimento?: string) => ({ linha, valida: true, valor, vencimento });

test('líquido: o lido, senão bruto menos retenções', () => {
  assert.equal(liquidoDe({ origem: 'ia', valor: 1000, valor_liquido: 900 }), 900);
  assert.equal(liquidoDe({ origem: 'ia', valor: 1000, retencoes: { iss: 50, irrf: 15 } }), 935);
  assert.equal(liquidoDe({ origem: 'ia', valor: 1000 }), undefined);
});

test('valores: boleto do líquido fecha; abaixo do bruto sem retenção lida é suspeita', () => {
  const comRet = conferirValores({ origem: 'ia', valor: 1000, retencoes: { iss: 50 }, boletos: [bol('1', 950)] });
  assert.deepEqual(comRet, { avisos: [], retencaoSuspeita: false });
  const semRet = conferirValores({ origem: 'ia', valor: 1000, boletos: [bol('1', 935)] });
  assert.equal(semRet.retencaoSuspeita, true);
  assert.match(semRet.avisos[0], /pode haver retenção/);
  assert.deepEqual(conferirValores({ origem: 'ia', valor: 1000, boletos: [bol('1', 1000)] }), { avisos: [], retencaoSuspeita: false });
  assert.match(conferirValores({ origem: 'ia', valor: 1000, boletos: [bol('1', 1200)] }).avisos[0], /confira/);
  assert.match(conferirValores({ origem: 'ia', valor: 1000, valor_liquido: 900, retencoes: { iss: 50 } }).avisos[0], /não dá o líquido/);
  assert.match(conferirValores({ origem: 'ia', valor: 1000, valor_liquido: 1100 }).avisos[0], /maior que o bruto/);
  assert.equal(cobradoDe({ origem: 'ia', parcelas: [{ valor: 100 }, { valor: 200.5 }] }), 300.5);
  assert.equal(cobradoDe({ origem: 'ia', parcelas: [{ valor: 100 }, {}], boletos: [bol('1', 50)] }), 50);
});

test('casar: pelo valor, depois pelo vencimento, nunca contra o valor', () => {
  const ps = [{ vencimento: '2026-12-10', valor: 300 }, { vencimento: '2027-01-10', valor: 200 }];
  const b200 = bol('a', 200, '2027-01-10'), b300 = bol('b', 300, '2026-12-10');
  assert.deepEqual(casarBoletos(ps, [b200, b300]), [b300, b200]);
  // valores iguais: o vencimento desempata
  const iguais = [{ vencimento: '2026-12-10', valor: 100 }, { vencimento: '2027-01-10', valor: 100 }];
  const j = bol('j', 100, '2027-01-11'), d = bol('d', 100, '2026-12-09');
  assert.deepEqual(casarBoletos(iguais, [j, d]), [d, j]);
  // sem valor na parcela: o vencimento mais perto
  assert.deepEqual(casarBoletos([{ vencimento: '2027-01-10' }, { vencimento: '2026-12-10' }], [b300, b200]), [b200, b300]);
  // boleto de valor que nenhuma parcela tem não entra à força
  assert.deepEqual(casarBoletos(ps, [bol('x', 999, '2026-12-10')]), [undefined, undefined]);
  // sem parcelas, os boletos são as parcelas
  assert.deepEqual(casarBoletos([], [b200, b300]), [b200, b300]);
});

test('conjunto: a nota manda, os boletos dos outros arquivos entram', () => {
  const nota = arq('nota.pdf', { origem: 'ia', tipo: 'nfse', numero: '12', valor: 500, emitente: { documento: '11222333000181', nome: 'Acme' } },
    { identificacao: { empresa: null, fornecedor: null, nota_repetida: [], candidatos: [], pagamento: null } });
  const boleto = arq('boleto.pdf', { origem: 'ia', tipo: 'boleto', valor: 500, emitente: { documento: '99888777000166' }, boletos: [bol('L1', 500)], avisos: ['aviso do boleto'] });
  const j = juntarLeituras([boleto, nota])!;
  assert.equal(j.anexo.nome, 'nota.pdf');
  assert.equal(j.leitura?.numero, '12');
  assert.deepEqual(j.leitura?.boletos?.map(b => b.linha), ['L1']);
  assert.ok(j.identificacao);
  assert.deepEqual(j.leitura?.avisos, ['boleto.pdf: aviso do boleto']);   // o beneficiário do boleto não gera aviso de emitente
  // outra nota no conjunto
  const outra = arq('outra.pdf', { origem: 'ia', tipo: 'nfse', numero: '13', emitente: { documento: '55444333000122', nome: 'Beta' } });
  const avisos = juntarLeituras([nota, outra])!.leitura!.avisos!;
  assert.ok(avisos.some(a => a.startsWith('outra.pdf é de outro emitente')));
  assert.ok(avisos.some(a => a.startsWith('outra.pdf é a nota 13')));
  // a mesma linha em dois arquivos entra uma vez
  assert.equal(juntarLeituras([nota, boleto, boleto])!.leitura!.boletos!.length, 1);
  // um arquivo só volta como está
  assert.equal(juntarLeituras([nota]), nota);
  assert.equal(juntarLeituras([]), null);
});
