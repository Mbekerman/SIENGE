// node --test --experimental-strip-types servicos/sienge-escrita/planilha.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ABA, atualizarPlanilha, CABECALHO, ESCOPO, idPlanilha, jwtServico, lerChave, linhasDaPlanilha, type LinhaApagar } from './planilha.ts';

async function chaveTeste() {
  const par = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
  const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', par.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der)).replace(/.{64}/g, '$&\n')}\n-----END PRIVATE KEY-----\n`;
  return { publica: par.publicKey, json: JSON.stringify({ type: 'service_account', client_email: 'erp@x.iam.gserviceaccount.com', private_key: pem, token_uri: 'https://oauth2.googleapis.com/token' }) };
}
const de64 = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4)), (c) => c.charCodeAt(0));

const L = (o: Partial<LinhaApagar>): LinhaApagar => ({
  previsao_id: '6b000000-0000-0000-0000-0000000000c1', sienge_id: 8592, empresa_sienge: '11', data_prevista: '2026-12-10',
  valor: '40.00', situacao_previsao: 'encerrada', apagar_desde: '2026-11-17T22:00:00+00:00', ...o,
});

test('chave: recusa ausente, inválida e token_uri que não é do Google', () => {
  assert.throws(() => lerChave(undefined), /falta o segredo/);
  assert.throws(() => lerChave('x'), /não é um JSON/);
  assert.throws(() => lerChave('{"client_email":"a"}'), /sem client_email ou private_key/);
  assert.throws(() => lerChave(JSON.stringify({ client_email: 'a', private_key: '-----BEGIN PRIVATE KEY-----', token_uri: 'https://mal.example/token' })), /token_uri/);
});

test('id da planilha: pelo link ou pelo id', () => {
  const id = '1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-ab';
  assert.equal(idPlanilha(`https://docs.google.com/spreadsheets/d/${id}/edit#gid=0`), id);
  assert.equal(idPlanilha(id), id);
  assert.throws(() => idPlanilha('curto'), /PLANILHA_PRV_ID/);
  assert.throws(() => idPlanilha(undefined), /PLANILHA_PRV_ID/);
});

test('JWT da conta de serviço: RS256 válido, escopo só de planilhas, 1 hora', async () => {
  const k = await chaveTeste();
  const jwt = await jwtServico(lerChave(k.json), new Date('2026-11-17T12:00:00Z'));
  const [h, c, s] = jwt.split('.');
  assert.deepEqual(JSON.parse(new TextDecoder().decode(de64(h))), { alg: 'RS256', typ: 'JWT' });
  const corpo = JSON.parse(new TextDecoder().decode(de64(c)));
  assert.equal(corpo.scope, ESCOPO);
  assert.equal(corpo.aud, 'https://oauth2.googleapis.com/token');
  assert.equal(corpo.exp - corpo.iat, 3600);
  assert.ok(await crypto.subtle.verify('RSASSA-PKCS1-v1_5', k.publica, de64(s), new TextEncoder().encode(`${h}.${c}`)));
});

test('linhas: cabeçalho, documento PRV, valor em número, ordem por quando entrou na lista', () => {
  const v = linhasDaPlanilha([L({ sienge_id: 9000, apagar_desde: '2026-11-18T12:00:00+00:00', situacao_previsao: 'cancelada' }), L({})]);
  assert.deepEqual(v[0], CABECALHO);
  assert.deepEqual(v[1], ['11', 8592, 'PRV-6B0000000000', 40, '2026-12-10', '17/11/2026, 19:00', 'Encerrada']);
  assert.equal(v[2][1], 9000);
  assert.equal(v[2][6], 'Cancelada');
  assert.deepEqual(linhasDaPlanilha([]), [CABECALHO]);
});

test('atualizar: token pelo Google, limpa a aba e grava tudo; erro do Google para sem gravar', async () => {
  const k = await chaveTeste();
  const chamadas: { url: string; metodo: string; corpo: string; auth: string | null }[] = [];
  const falso = (async (url: string, init: RequestInit) => {
    const auth = new Headers(init.headers).get('authorization');
    chamadas.push({ url, metodo: init.method ?? 'GET', corpo: String(init.body ?? ''), auth });
    if (url.startsWith('https://oauth2.googleapis.com/token')) return new Response('{"access_token":"tk"}', { status: 200 });
    return new Response('{}', { status: 200 });
  }) as typeof fetch;
  const id = '1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-ab';
  const r = await atualizarPlanilha(async () => [L({})], lerChave(k.json), id, new Date(), falso);
  assert.deepEqual(r, { linhas: 1 });
  assert.deepEqual(chamadas.map((c) => c.metodo), ['POST', 'PUT', 'POST']);
  assert.match(chamadas[0].corpo, /grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=/);
  assert.ok(chamadas[1].url.endsWith('?valueInputOption=RAW'));
  assert.equal(chamadas[2].url, `https://sheets.googleapis.com/v4/spreadsheets/${id}/values/${encodeURIComponent(`'${ABA}'!A3:G`)}:clear`);
  assert.deepEqual(chamadas.slice(1).map((c) => c.auth), ['Bearer tk', 'Bearer tk']);
  assert.equal(JSON.parse(chamadas[1].corpo).values.length, 2);

  const recusa = (async (url: string) => url.includes('oauth2')
    ? new Response('{"access_token":"tk"}', { status: 200 })
    : new Response('{"error":{"message":"The caller does not have permission"}}', { status: 403 })) as typeof fetch;
  await assert.rejects(atualizarPlanilha(async () => [], lerChave(k.json), id, new Date(), recusa), /Google gravar respondeu 403/);
});
