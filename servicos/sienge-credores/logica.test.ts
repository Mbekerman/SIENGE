import { test } from 'node:test';
import assert from 'node:assert/strict';
import { atender, carga, documento, enxugar, LIMITE, PAGINA, type Credor, type Deps } from './logica.ts';

type D = Deps & { chamadas: string[]; importados: Credor[][]; esperas: number };
function deps(m: Partial<Deps> = {}, total = 0): D {
  const o = { chamadas: [] as string[], importados: [] as Credor[][], esperas: 0 } as D;
  let n = 0;
  Object.assign(o, {
    origens: ['https://front.example.com'],
    login: async (a: string) => (a === 'Bearer bom' ? 'u1' : null),
    tentativa: async (l: string) => (l === 'u1' ? ++n : null),
    chaveCarga: async () => 'segredo-da-carga',
    ritmo: async () => true,
    sienge: async (c: string) => {
      o.chamadas.push(c);
      const off = Number(/offset=(\d+)/.exec(c)?.[1] ?? 0);
      const q = Math.max(0, Math.min(PAGINA, total - off));
      return { resultSetMetadata: { count: total }, results: Array.from({ length: q }, (_, i) => ({
        id: off + i + 1, name: `Credor ${off + i + 1}`, cnpj: '11.222.333/0001-81', phones: [{ number: '999' }], address: { streetName: 'x' } })) };
    },
    importar: async (l: Credor[]) => { o.importados.push(l); return { novos: l.length, ligados: 0, ja_ligados: 0, avisos: [] }; },
    esperar: async () => { o.esperas++; },
    log: () => {},
  }, m);
  return o;
}
const pedido = (corpo: unknown, h: Record<string, string> = { authorization: 'Bearer bom', origin: 'https://front.example.com' }) =>
  new Request('https://x/functions/v1/sienge-credores', { method: 'POST', headers: h, body: JSON.stringify(corpo) });

test('documento: CPF, CNPJ com máscara e CNPJ alfanumérico; o resto não', () => {
  assert.deepEqual(documento('529.982.247-25'), { tipo: 'cpf', valor: '52998224725' });
  assert.deepEqual(documento('45.997.418/0001-53'), { tipo: 'cnpj', valor: '45997418000153' });
  assert.deepEqual(documento('12.abc.345/01de-35'), { tipo: 'cnpj', valor: '12ABC34501DE35' });
  for (const x of ['123', '', null, 12345678901, '4599741800015&cnpj=1', 'ABCDEFGHIJKLMN']) assert.equal(documento(x), null);
});

test('enxugar: endereço, telefones e contatos do Sienge não seguem para o banco', () => {
  assert.deepEqual(Object.keys(enxugar({ id: 1, name: 'a', phones: [1], contacts: [1], address: {}, cpf: null })).sort(),
    ['active', 'cnpj', 'cpf', 'id', 'name', 'tradeName']);
});

test('carga: lê as páginas até a incompleta, com pausa entre elas, e importa tudo', async () => {
  const d = deps({}, 825);
  const t = await carga(d);
  assert.equal(t.paginas, 5);
  assert.equal(t.credores, 825);
  assert.equal(d.esperas, 4);
  assert.deepEqual(d.chamadas.map((c) => /offset=(\d+)/.exec(c)?.[1]), ['0', '200', '400', '600', '800']);
  assert.equal(d.importados.flat().length, 825);
  assert.equal('phones' in d.importados[0][0], false);
});

test('carga com número exato de páginas pede a página vazia e para', async () => {
  const d = deps({}, 400);
  assert.equal((await carga(d)).paginas, 3);
  assert.equal(d.importados.length, 2);
});

test('carga: chave errada é 401 e não chama o Sienge; certa responde só ok', async () => {
  const d = deps({}, 10);
  assert.equal((await atender(pedido({}, { 'x-credores-chave': 'errada' }), d)).status, 401);
  assert.equal((await atender(pedido({}, { 'x-credores-chave': '' }), d)).status, 401);
  assert.equal(d.chamadas.length, 0);
  const r = await atender(pedido({}, { 'x-credores-chave': 'segredo-da-carga' }), d);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { ok: true });
});

test('carga sem chave no Vault ou fora do ritmo não chama o Sienge', async () => {
  const d1 = deps({ chaveCarga: async () => null }, 10);
  assert.equal((await atender(pedido({}, { 'x-credores-chave': 'segredo-da-carga' }), d1)).status, 401);
  const d2 = deps({ ritmo: async () => false }, 10);
  assert.equal((await atender(pedido({}, { 'x-credores-chave': 'segredo-da-carga' }), d2)).status, 429);
  assert.equal(d1.chamadas.length + d2.chamadas.length, 0);
});

test('busca: sem login, login forjado ou fora do ERP não chama o Sienge', async () => {
  const d = deps({ tentativa: async () => null }, 1);
  assert.equal((await atender(pedido({ documento: '45997418000153' }, {}), d)).status, 401);
  assert.equal((await atender(pedido({ documento: '45997418000153' }, { authorization: 'Bearer forjado' }), d)).status, 401);
  assert.equal((await atender(pedido({ documento: '45997418000153' }), d)).status, 403);
  assert.equal(d.chamadas.length, 0);
});

test('busca: pergunta só pelo documento, importa e devolve só a contagem', async () => {
  const d = deps({}, 1);
  const r = await atender(pedido({ documento: '45.997.418/0001-53' }), d);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { credores: 1 });
  assert.deepEqual(d.chamadas, ['/creditors?cnpj=45997418000153&limit=200']);
  assert.equal(r.headers.get('access-control-allow-origin'), 'https://front.example.com');
});

test('busca: CPF vai no parâmetro cpf; nada achado (404) não importa', async () => {
  const d = deps({ sienge: async (c) => { d.chamadas.push(c); throw Object.assign(new Error('404'), { status: 404 }); } });
  const r = await atender(pedido({ documento: '529.982.247-25' }), d);
  assert.deepEqual(await r.json(), { credores: 0 });
  assert.deepEqual(d.chamadas, ['/creditors?cpf=52998224725&limit=200']);
  assert.equal(d.importados.length, 0);
});

test('busca: documento torto não chama o Sienge; erro do Sienge não vaza detalhe', async () => {
  const d = deps({}, 1);
  assert.equal((await atender(pedido({ documento: '123&cnpj=1' }), d)).status, 400);
  assert.equal(d.chamadas.length, 0);
  const d2 = deps({ sienge: async () => { throw Object.assign(new Error('Sienge respondeu 500: detalhe interno'), { status: 500 }); } });
  const r = await atender(pedido({ documento: '45997418000153' }), d2);
  assert.equal(r.status, 502);
  assert.equal(JSON.stringify(await r.json()).includes('interno'), false);
});

test('busca: acima do limite por pessoa é 429', async () => {
  const d = deps({ tentativa: async () => LIMITE + 1 }, 1);
  assert.equal((await atender(pedido({ documento: '45997418000153' }), d)).status, 429);
  assert.equal(d.chamadas.length, 0);
});
