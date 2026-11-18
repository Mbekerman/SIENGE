import { test } from 'node:test';
import assert from 'node:assert/strict';
import { lerConfig, novoVerificador, desafio, urlEntrar, enderecoDaPagina, conteudoDoToken, sessaoDaResposta,
  precisaRenovar, dataBr, linhaDaPagina, mensagemDeErro, urlRealtime, msgEntrar, msgBatida, msgToken, lerMensagem, esperaDaVez,
  ouvir, CANAL, ESPERAS_MS } from './prv.js';

const CFG = { url: 'https://abcdefghijklmnopqrst.supabase.co', chave: 'sb_publishable_AbC-12_x' };

test('config: só endereço do Supabase e chave publicável', () => {
  assert.deepEqual(lerConfig(CFG), CFG);
  assert.throws(() => lerConfig(null), /configuração/);
  assert.throws(() => lerConfig({ ...CFG, url: 'https://abcdefghijklmnopqrst.supabase.co.mal.com' }), /configuração/);
  assert.throws(() => lerConfig({ ...CFG, url: 'http://abcdefghijklmnopqrst.supabase.co' }), /configuração/);
  assert.throws(() => lerConfig({ ...CFG, chave: 'eyJhbGciOi.service_role' }), /chave/);
  assert.throws(() => lerConfig({ ...CFG, chave: 'sb_secret_xyz' }), /chave/);
});

test('PKCE: verificador de 64 caracteres e desafio S256 (vetor do RFC 7636)', async () => {
  assert.equal(novoVerificador().length, 64);
  assert.notEqual(novoVerificador(), novoVerificador());
  assert.equal(await desafio('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
});

test('entrar: Google, volta para a própria página e desafio s256', () => {
  const u = new URL(urlEntrar(CFG, 'https://bkm.github.io/SIENGE/', 'DESAFIO'));
  assert.equal(u.origin + u.pathname, `${CFG.url}/auth/v1/authorize`);
  assert.equal(u.searchParams.get('provider'), 'google');
  assert.equal(u.searchParams.get('redirect_to'), 'https://bkm.github.io/SIENGE/');
  assert.equal(u.searchParams.get('code_challenge'), 'DESAFIO');
  assert.equal(u.searchParams.get('code_challenge_method'), 's256');
  assert.equal(enderecoDaPagina('https://bkm.github.io/SIENGE/?code=x&y=1#z'), 'https://bkm.github.io/SIENGE/');
});

test('sessão: exige os dois tokens e renova 1 minuto antes de vencer', () => {
  const s = sessaoDaResposta({ access_token: 'a', refresh_token: 'r', expires_in: 3600 }, 1000);
  assert.deepEqual(s, { acesso: 'a', renovar: 'r', vence: 1000 + 3_600_000 });
  assert.throws(() => sessaoDaResposta({ access_token: 'a' }), /sessão/);
  assert.equal(precisaRenovar(s, 1000), false);
  assert.equal(precisaRenovar(s, 1000 + 3_600_000 - 59_000), true);
  assert.equal(precisaRenovar(null), true);
});

test('token: lê o e-mail com acento; lixo vira nulo', () => {
  const corpo = Buffer.from(JSON.stringify({ email: 'joão@bkm.com.br' })).toString('base64url');
  assert.equal(conteudoDoToken(`x.${corpo}.y`).email, 'joão@bkm.com.br');
  assert.equal(conteudoDoToken('lixo'), null);
});

test('linha: formata em pt-BR e São Paulo; sem valor fica vazio', () => {
  const l = linhaDaPagina({ empresa_sienge: '11', titulo_sienge: 8591, documento: 'PRV-6C0000000000', valor: 1234.5,
    data_prevista: '2026-12-05', na_lista_desde: '2026-11-18T13:05:00Z', conferido_em: null, situacao_previsao: 'consumida' });
  assert.equal(l.titulo, '8591');
  assert.equal(l.valor.replace(/\s/g, ' '), 'R$ 1.234,50');
  assert.equal(l.prevista, '05/12/2026');
  assert.equal(l.desde, '18/11/2026, 10:05');
  assert.equal(l.conferido, 'Ainda não');
  assert.equal(l.situacao, 'Consumida pela nota');
  const v = linhaDaPagina({ empresa_sienge: null, titulo_sienge: 1, documento: 'd', valor: null, data_prevista: null,
    na_lista_desde: null, conferido_em: null, situacao_previsao: 'outra' });
  assert.equal(v.empresa, ''); assert.equal(v.valor, ''); assert.equal(v.prevista, ''); assert.equal(v.situacao, 'outra');
  assert.equal(dataBr('2026-1-5'), '');
});

test('erro: recusa do banco pede a conta da BKM; o resto é genérico', () => {
  assert.match(mensagemDeErro(400, { code: '42501' }), /Google da BKM/);
  assert.match(mensagemDeErro(401, null), /Google da BKM/);
  assert.match(mensagemDeErro(500, { message: 'detalhe interno' }), /Tente de novo/);
  assert.doesNotMatch(mensagemDeErro(500, { message: 'detalhe interno' }), /detalhe/);
});

test('tempo real: endereço wss do Supabase com a chave publicável', () => {
  const u = new URL(urlRealtime(CFG));
  assert.equal(u.protocol, 'wss:');
  assert.equal(u.host, 'abcdefghijklmnopqrst.supabase.co');
  assert.equal(u.pathname, '/realtime/v1/websocket');
  assert.equal(u.searchParams.get('apikey'), CFG.chave);
  assert.equal(u.searchParams.get('vsn'), '1.0.0');
});

test('tempo real: entrada no canal privado com o token, batida e troca de token', () => {
  const e = JSON.parse(msgEntrar('TOK', '1'));
  assert.equal(e.topic, CANAL);
  assert.equal(e.event, 'phx_join');
  assert.equal(e.payload.config.private, true);
  assert.equal(e.payload.access_token, 'TOK');
  assert.deepEqual(JSON.parse(msgBatida('2')), { topic: 'phoenix', event: 'heartbeat', payload: {}, ref: '2' });
  assert.deepEqual(JSON.parse(msgToken('NOVO', '3')).payload, { access_token: 'NOVO' });
});

test('tempo real: só o "mudou" do canal relê; resposta da entrada; o resto se ignora', () => {
  const m = (o) => JSON.stringify(o);
  assert.equal(lerMensagem(m({ topic: CANAL, event: 'broadcast', payload: { event: 'mudou', payload: {} } }), '1'), 'mudou');
  assert.equal(lerMensagem(m({ topic: 'realtime:outro', event: 'broadcast', payload: { event: 'mudou' } }), '1'), null);
  assert.equal(lerMensagem(m({ topic: CANAL, event: 'broadcast', payload: { event: 'outro' } }), '1'), null);
  assert.equal(lerMensagem(m({ topic: CANAL, event: 'phx_reply', ref: '1', payload: { status: 'ok' } }), '1'), 'entrou');
  assert.equal(lerMensagem(m({ topic: CANAL, event: 'phx_reply', ref: '1', payload: { status: 'error' } }), '1'), 'recusado');
  assert.equal(lerMensagem(m({ topic: CANAL, event: 'phx_reply', ref: '5', payload: { status: 'ok' } }), '1'), null);
  assert.equal(lerMensagem(m({ topic: CANAL, event: 'phx_error', payload: {} }), '1'), 'recusado');
  assert.equal(lerMensagem('não é json', '1'), null);
});

test('tempo real: espera para religar cresce até 30 s', () => {
  assert.deepEqual([0, 1, 2, 3, 4, 9].map(esperaDaVez), [1000, 2000, 5000, 10000, 30000, 30000]);
  assert.equal(ESPERAS_MS.at(-1), 30_000);
});

test('tempo real: liga, entra, relê no aviso e manda o token novo', async () => {
  const enviados = [];
  let sock;
  class FakeWs { constructor(url) { this.url = url; this.readyState = 1; sock = this; } send(t) { enviados.push(JSON.parse(t)); } close() {} }
  let tok = 'T1', relidas = 0;
  const { trocarToken: trocar, parar } = ouvir(CFG, async () => tok, () => { relidas++; }, FakeWs);
  await new Promise((r) => setTimeout(r, 0));
  sock.onopen();
  assert.equal(enviados[0].event, 'phx_join');
  sock.onmessage({ data: JSON.stringify({ topic: CANAL, event: 'phx_reply', ref: enviados[0].ref, payload: { status: 'ok' } }) });
  sock.onmessage({ data: JSON.stringify({ topic: CANAL, event: 'broadcast', payload: { event: 'mudou' } }) });
  assert.equal(relidas, 2);
  tok = 'T2';
  await trocar();
  assert.deepEqual([enviados.at(-1).event, enviados.at(-1).payload.access_token], ['access_token', 'T2']);
  await trocar();
  assert.equal(enviados.filter((x) => x.event === 'access_token').length, 1);
  parar();
  sock.onclose();   // fechado depois de parar: não religa
});
