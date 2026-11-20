import { test } from 'node:test';
import assert from 'node:assert/strict';
import { conferir, recebedorAsaas, LIMITE, type Deps, type Recebedor } from './logica.ts';

const COD = '00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF';
const R: Recebedor = { cpf_cnpj: '77777777000177', nome: 'FORNECEDOR EXEMPLO', banco: 'Banco Exemplo', chave: null, valor: 150 };
type D = Deps & { gravados: unknown[]; asaasChamado: number; tentativas: string[] };
function deps(m: Partial<Deps> = {}): D {
  const o = { gravados: [] as unknown[], asaasChamado: 0, tentativas: [] as string[] } as D;
  Object.assign(o, {
    origens: ['https://front.example.com'],
    login: async (a: string) => (a === 'Bearer bom' ? 'u1' : null),
    tentativa: async (l: string) => { o.tentativas.push(l); return l === 'u1' ? o.tentativas.length : null; }, valido: async () => true, guardado: async () => null,
    asaas: async () => { o.asaasChamado++; return { ok: true as const, r: R }; },
    gravar: async (...a: unknown[]) => { o.gravados.push(a); },
  }, m);
  return o;
}
const pedido = (corpo: unknown, auth = 'Bearer bom', origin = 'https://front.example.com') =>
  new Request('https://x/functions/v1/pix-conferir', { method: 'POST', headers: { authorization: auth, origin }, body: JSON.stringify(corpo) });

test('sem login ou login forjado: 401 e nada vai ao Asaas', async () => {
  const d = deps();
  assert.equal((await conferir(pedido({ codigo: COD }, ''), d)).status, 401);
  assert.equal((await conferir(pedido({ codigo: COD }, 'Bearer forjado'), d)).status, 401);
  assert.equal(d.asaasChamado, 0);
});
test('confere no Asaas, grava como sistema com o login conferido e devolve o recebedor', async () => {
  const d = deps();
  const r = await conferir(pedido({ codigo: ` ${COD}\n` }), d);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), R);
  assert.deepEqual(d.gravados, [[COD, R, 'u1']]);
  assert.equal(r.headers.get('access-control-allow-origin'), 'https://front.example.com');
});
test('origem fora da lista não ganha CORS', async () => {
  const r = await conferir(pedido({ codigo: COD }, 'Bearer bom', 'https://outro.example.com'), deps());
  assert.equal(r.headers.get('access-control-allow-origin'), null);
});
test('código inválido não vai ao Asaas', async () => {
  const d = deps({ valido: async () => false });
  assert.equal((await conferir(pedido({ codigo: COD }), d)).status, 400);
  assert.equal((await conferir(pedido({ codigo: 'abc' }), d)).status, 400);
  assert.equal(d.asaasChamado, 0);
});
test('conferência guardada responde sem chamar o Asaas; acima do limite, 429', async () => {
  const d = deps({ guardado: async () => R });
  assert.equal((await conferir(pedido({ codigo: COD }), d)).status, 200);
  assert.equal(d.asaasChamado, 0);
  const e = deps({ tentativa: async () => LIMITE + 1 });
  assert.equal((await conferir(pedido({ codigo: COD }), e)).status, 429);
  assert.equal(e.asaasChamado, 0);
  assert.equal((await conferir(pedido({ codigo: COD }), deps({ tentativa: async () => LIMITE }))).status, 200);
});
test('login que não é usuário ativo do ERP: 403, sem conferência guardada nem Asaas', async () => {
  const d = deps({ login: async () => 'fora', guardado: async () => R });
  const r = await conferir(pedido({ codigo: COD }), d);
  assert.equal(r.status, 403);
  assert.equal(d.asaasChamado, 0);
  assert.deepEqual(d.tentativas, ['fora']);
});
test('todo pedido conta no limite, também os recusados pelo Asaas e os inválidos', async () => {
  const d = deps({ asaas: async () => { d.asaasChamado++; return { ok: false as const, erro: 'QR Code inválido' }; } });
  for (let i = 0; i < LIMITE; i++) assert.equal((await conferir(pedido({ codigo: COD }), d)).status, 422);
  assert.equal((await conferir(pedido({ codigo: 'abc' }), d)).status, 429);
  assert.equal(d.asaasChamado, LIMITE);
  assert.equal(d.tentativas.length, LIMITE + 1);
});
test('erro do Asaas volta como 422 e não grava', async () => {
  const d = deps({ asaas: async () => ({ ok: false as const, erro: 'QR Code inválido' }) });
  const r = await conferir(pedido({ codigo: COD }), d);
  assert.equal(r.status, 422);
  assert.equal(d.gravados.length, 0);
});
test('o recebedor do Asaas: documento só com dígitos e *, nome fantasia na falta do nome', () => {
  assert.deepEqual(recebedorAsaas({ pixKey: 'k', receiver: { cpfCnpj: '77.777.777/0001-77', name: ' X ', ispbName: 'B' } }),
                   { cpf_cnpj: '77777777000177', nome: 'X', banco: 'B', chave: 'k', valor: null });
  assert.equal(recebedorAsaas({ value: 150.004, receiver: {} }).valor, 150);
  assert.equal(recebedorAsaas({ value: 0, receiver: {} }).valor, null);
  assert.equal(recebedorAsaas({ receiver: { cpfCnpj: '***.456.789-**', tradingName: 'Y' } }).cpf_cnpj, '***456789**');
  assert.equal(recebedorAsaas({ receiver: { cpfCnpj: 'lixo' } }).cpf_cnpj, null);
});
test('sem ORIGENS, só os endereços do front no Cloud Run', async () => {
  const d = deps({ origens: [] });
  const ok = await conferir(pedido({ codigo: COD }, 'Bearer bom', 'https://erp-web-dev-123.southamerica-east1.run.app'), d);
  assert.equal(ok.headers.get('access-control-allow-origin'), 'https://erp-web-dev-123.southamerica-east1.run.app');
  const nao = await conferir(pedido({ codigo: COD }, 'Bearer bom', 'https://erp-web-dev.example.com'), d);
  assert.equal(nao.headers.get('access-control-allow-origin'), null);
});
