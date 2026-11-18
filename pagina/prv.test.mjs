import { test } from 'node:test';
import assert from 'node:assert/strict';
import { lerConfig, novoVerificador, desafio, urlEntrar, enderecoDaPagina, conteudoDoToken, sessaoDaResposta,
  precisaRenovar, dataBr, linhaDaPagina, mensagemDeErro } from './prv.js';

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
