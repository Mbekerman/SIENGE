// Página das linhas PRV a apagar à mão no Sienge (Moises, 18/11/2026: no lugar da planilha do Google;
// quem abre: qualquer login Google da BKM). Sem biblioteca de fora: o login é o fluxo PKCE do Supabase
// Auth feito aqui, e a lista vem da função pagina.prv_apagar (que recusa quem não é Google da BKM).
//
// As funções puras ficam exportadas para o teste (prv.test.mjs); iniciar() só roda no navegador.

export const SITUACAO = { cancelada: 'Cancelada', encerrada: 'Encerrada', consumida: 'Consumida pela nota', aberta: 'Aberta' };
const CHAVE_SESSAO = 'bkm-prv-sessao';
const CHAVE_PKCE = 'bkm-prv-pkce';
const URL_SUPABASE = /^https:\/\/[a-z0-9]{20}\.supabase\.co$/;

export function lerConfig(c) {
  if (!c || typeof c.url !== 'string' || !URL_SUPABASE.test(c.url)) throw new Error('Página sem configuração do banco');
  if (typeof c.chave !== 'string' || !/^sb_publishable_[A-Za-z0-9_-]+$/.test(c.chave)) throw new Error('Página sem a chave publicável');
  return { url: c.url, chave: c.chave };
}

const b64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

export function novoVerificador(aleatorio = (n) => crypto.getRandomValues(new Uint8Array(n))) {
  return b64url(aleatorio(48));
}

export async function desafio(verificador) {
  return b64url(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verificador))));
}

// Endereço de entrada pelo Google. A volta é sempre para a própria página (sem consulta nem âncora).
export function urlEntrar(cfg, volta, codigoDesafio) {
  const q = new URLSearchParams({ provider: 'google', redirect_to: volta, code_challenge: codigoDesafio, code_challenge_method: 's256' });
  return `${cfg.url}/auth/v1/authorize?${q}`;
}

export function enderecoDaPagina(href) {
  const u = new URL(href);
  return `${u.origin}${u.pathname}`;
}

// Só lê o conteúdo do token para mostrar o e-mail; quem decide o acesso é o banco.
export function conteudoDoToken(token) {
  try {
    const p = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(decodeURIComponent(escape(atob(p + '='.repeat((4 - p.length % 4) % 4)))));
  } catch { return null; }
}

export function sessaoDaResposta(r, agora = Date.now()) {
  if (!r || typeof r.access_token !== 'string' || typeof r.refresh_token !== 'string') throw new Error('O login não devolveu a sessão');
  const dura = Number(r.expires_in) > 0 ? Number(r.expires_in) : 3600;
  return { acesso: r.access_token, renovar: r.refresh_token, vence: agora + dura * 1000 };
}

export function precisaRenovar(s, agora = Date.now()) {
  return !s || s.vence - agora < 60_000;
}

const moeda = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' });
const diaHora = new Intl.DateTimeFormat('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' });

export function dataBr(iso) {
  if (!iso) return '';
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  return m ? `${m[3]}/${m[2]}/${m[1]}` : '';
}

export function linhaDaPagina(l) {
  return {
    empresa: l.empresa_sienge ?? '',
    titulo: String(l.titulo_sienge),
    documento: l.documento,
    valor: l.valor === null || l.valor === undefined ? '' : moeda.format(Number(l.valor)),
    prevista: dataBr(l.data_prevista),
    desde: l.na_lista_desde ? diaHora.format(new Date(l.na_lista_desde)) : '',
    conferido: l.conferido_em ? diaHora.format(new Date(l.conferido_em)) : 'Ainda não',
    situacao: SITUACAO[l.situacao_previsao] ?? l.situacao_previsao,
  };
}

export function mensagemDeErro(status, corpo) {
  if (status === 401 || status === 403 || corpo?.code === '42501') return 'Entre com a conta Google da BKM (@bkm.com.br).';
  return 'Não foi possível ler a lista agora. Tente de novo em instantes.';
}

// ---------- tempo real ----------
// O Broadcast do Realtime do Supabase (supabase/dev/pagina_prv_realtime.sql) avisa "mudou" no canal
// privado prv-apagar; a página relê a lista. O protocolo (Phoenix) é feito aqui, sem biblioteca de fora.
// Sem o Realtime, a releitura a cada RELER_MS continua valendo.
export const CANAL = 'realtime:prv-apagar';
export const RELER_MS = 60_000;
export const BATIDA_MS = 25_000;
export const ESPERAS_MS = [1_000, 2_000, 5_000, 10_000, 30_000];

export function urlRealtime(cfg) {
  return `${cfg.url.replace(/^https:/, 'wss:')}/realtime/v1/websocket?${new URLSearchParams({ apikey: cfg.chave, vsn: '1.0.0' })}`;
}

export function msgEntrar(token, ref) {
  return JSON.stringify({ topic: CANAL, event: 'phx_join', ref, join_ref: ref,
    payload: { config: { broadcast: { self: false, ack: false }, presence: { key: '' }, private: true }, access_token: token } });
}
export const msgBatida = (ref) => JSON.stringify({ topic: 'phoenix', event: 'heartbeat', payload: {}, ref });
export const msgToken = (token, ref) => JSON.stringify({ topic: CANAL, event: 'access_token', payload: { access_token: token }, ref });

// O que chega: 'mudou' (relê a lista), 'entrou' (canal aceito: relê, pode ter perdido algo), 'recusado'
// ou nada de interesse.
export function lerMensagem(texto, refEntrada) {
  let m;
  try { m = JSON.parse(texto); } catch { return null; }
  if (!m || m.topic !== CANAL) return null;
  if (m.event === 'broadcast' && m.payload?.event === 'mudou') return 'mudou';
  if (m.event === 'phx_reply' && m.ref === refEntrada) return m.payload?.status === 'ok' ? 'entrou' : 'recusado';
  if (m.event === 'phx_error' || m.event === 'phx_close' || m.event === 'system' && m.payload?.status === 'error') return 'recusado';
  return null;
}

// O motivo que o Realtime dá ao recusar o canal, para mostrar na tela (sem dado nenhum da lista).
export function motivoDaRecusa(texto) {
  try {
    const p = JSON.parse(texto)?.payload ?? {};
    const m = p.response?.reason ?? p.message ?? p.reason ?? '';
    return typeof m === 'string' ? m.slice(0, 200) : '';
  } catch { return ''; }
}

export const esperaDaVez = (n) => ESPERAS_MS[Math.min(n, ESPERAS_MS.length - 1)];

// Liga o canal e se religa sozinho. token() devolve o token atual (ou null: fora do login, não liga).
// Devolve trocarToken(), para mandar o token renovado sem religar, e parar().
// aoEstado(ligada, motivo): avisa a tela se a atualização automática está ligada e, desligada, por quê.
export function ouvir(cfg, token, aoMudar, Ws = globalThis.WebSocket, aoEstado = () => {}) {
  let ws = null, batida = null, falhas = 0, ref = 0, enviado = null, entrada = null, parado = false, volta = null;
  const proximo = () => String(++ref);
  const religar = () => { if (!parado) volta = setTimeout(abrir, esperaDaVez(falhas++)); };
  async function abrir() {
    if (parado) return;
    const t = await token().catch(() => null);
    if (!t) return religar();
    try { ws = new Ws(urlRealtime(cfg)); } catch { return religar(); }
    ws.onopen = () => {
      enviado = t;
      entrada = proximo();
      ws.send(msgEntrar(t, entrada));
      batida = setInterval(() => { if (ws.readyState === 1) ws.send(msgBatida(proximo())); }, BATIDA_MS);
    };
    ws.onmessage = (e) => {
      const o = lerMensagem(e.data, entrada);
      if (o === 'entrou') { falhas = 0; aoEstado(true); aoMudar(); }
      else if (o === 'mudou') aoMudar();
      else if (o === 'recusado') { aoEstado(false, motivoDaRecusa(e.data)); ws.close(); }
    };
    ws.onclose = () => { clearInterval(batida); ws = null; aoEstado(false); religar(); };
  }
  abrir();
  return {
    trocarToken: async () => {
      const t = await token().catch(() => null);
      if (t && t !== enviado && ws?.readyState === 1) { enviado = t; ws.send(msgToken(t, proximo())); }
    },
    parar: () => { parado = true; clearTimeout(volta); clearInterval(batida); ws?.close(); },
  };
}

// ---------- navegador ----------

async function pedirJson(url, init) {
  const r = await fetch(url, { ...init, signal: AbortSignal.timeout(30_000) });
  const t = await r.text();
  let corpo = null;
  try { corpo = t ? JSON.parse(t) : null; } catch { /* corpo não é JSON */ }
  return { ok: r.ok, status: r.status, corpo };
}

function guardar(chave, v) { try { v === null ? localStorage.removeItem(chave) : localStorage.setItem(chave, JSON.stringify(v)); } catch { /* sem armazenamento */ } }
function ler(chave) { try { return JSON.parse(localStorage.getItem(chave) ?? 'null'); } catch { return null; } }

export async function iniciar(cfgBruta, el) {
  let cfg;
  try { cfg = lerConfig(cfgBruta); } catch (e) { return mostrar(el, 'erro', e.message); }
  const pagina = enderecoDaPagina(location.href);

  const entrar = async () => {
    const v = novoVerificador();
    guardar(CHAVE_PKCE, v);
    location.assign(urlEntrar(cfg, pagina, await desafio(v)));
  };
  const sair = async () => {
    const s = ler(CHAVE_SESSAO);
    guardar(CHAVE_SESSAO, null);
    if (s?.acesso) await pedirJson(`${cfg.url}/auth/v1/logout`, { method: 'POST', headers: { apikey: cfg.chave, Authorization: `Bearer ${s.acesso}` } }).catch(() => {});
    mostrar(el, 'fora');
  };
  el.entrar.onclick = entrar;
  el.sair.onclick = sair;

  // volta do Google: troca o código pela sessão e limpa o endereço
  const q = new URLSearchParams(location.search);
  if (q.has('code') || q.has('error')) {
    history.replaceState(null, '', pagina);
    const v = ler(CHAVE_PKCE);
    guardar(CHAVE_PKCE, null);
    if (q.has('error') || !v) return mostrar(el, 'fora', 'O login não foi concluído. Entre de novo.');
    const r = await pedirJson(`${cfg.url}/auth/v1/token?grant_type=pkce`, {
      method: 'POST', headers: { apikey: cfg.chave, 'Content-Type': 'application/json' },
      body: JSON.stringify({ auth_code: q.get('code'), code_verifier: v }),
    });
    if (!r.ok) return mostrar(el, 'fora', 'O login não foi concluído. Entre de novo.');
    guardar(CHAVE_SESSAO, sessaoDaResposta(r.corpo));
  }

  const sessao = async () => {
    let s = ler(CHAVE_SESSAO);
    if (s && precisaRenovar(s)) {
      const r = await pedirJson(`${cfg.url}/auth/v1/token?grant_type=refresh_token`, {
        method: 'POST', headers: { apikey: cfg.chave, 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: s.renovar }),
      });
      s = r.ok ? sessaoDaResposta(r.corpo) : null;
      guardar(CHAVE_SESSAO, s);
    }
    return s;
  };

  const carregar = async () => {
    const s = await sessao();
    if (!s) return mostrar(el, 'fora');
    el.quem.textContent = conteudoDoToken(s.acesso)?.email ?? '';
    el.atualizar.disabled = true;
    const r = await pedirJson(`${cfg.url}/rest/v1/rpc/prv_apagar`, {
      method: 'POST',
      headers: { apikey: cfg.chave, Authorization: `Bearer ${s.acesso}`, 'Content-Type': 'application/json', 'Content-Profile': 'pagina' },
      body: '{}',
    }).catch(() => ({ ok: false, status: 0, corpo: null }));
    el.atualizar.disabled = false;
    if (!r.ok) return mostrar(el, r.status === 401 || r.status === 403 || r.corpo?.code === '42501' ? 'negado' : 'dentro', mensagemDeErro(r.status, r.corpo));
    tabela(el, (r.corpo ?? []).map(linhaDaPagina));
    el.lido.textContent = `Lista lida às ${new Intl.DateTimeFormat('pt-BR', { timeZone: 'America/Sao_Paulo', timeStyle: 'short' }).format(new Date())}`;
    mostrar(el, 'dentro');
  };
  // vários avisos seguidos viram uma releitura só
  let espera = null;
  const logo = () => { clearTimeout(espera); espera = setTimeout(() => { if (ler(CHAVE_SESSAO)) carregar(); }, 500); };
  el.atualizar.onclick = carregar;
  setInterval(() => { if (document.visibilityState === 'visible' && ler(CHAVE_SESSAO)) carregar(); }, RELER_MS);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && ler(CHAVE_SESSAO)) carregar(); });
  await carregar();
  if (ler(CHAVE_SESSAO) && globalThis.WebSocket) {
    const canal = ouvir(cfg, async () => (await sessao())?.acesso ?? null, logo, globalThis.WebSocket, (ligada, motivo) => {
      if (ligada) el.vivo.textContent = 'Atualização automática ligada';
      else if (motivo) el.vivo.textContent = `Atualização automática desligada (${motivo}); a lista é relida a cada minuto`;
      else if (!el.vivo.textContent.startsWith('Atualização automática desligada (')) el.vivo.textContent = 'Atualização automática religando; a lista é relida a cada minuto';
      if (!ligada) console.warn('Tempo real da página das PRV:', motivo || 'conexão caiu');
    });
    setInterval(canal.trocarToken, 5 * 60_000);
  }
}

function mostrar(el, estado, aviso = '') {
  el.raiz.dataset.estado = estado;
  el.aviso.textContent = aviso;
  el.aviso.hidden = !aviso;
}

const COLUNAS = [['empresa', 'Empresa'], ['titulo', 'Título no Sienge'], ['documento', 'Documento'], ['valor', 'Valor'],
  ['prevista', 'Data prevista'], ['desde', 'Na lista desde'], ['conferido', 'Última conferência'], ['situacao', 'Situação da previsão']];

function tabela(el, linhas) {
  el.total.textContent = linhas.length === 1 ? '1 título para apagar' : `${linhas.length} títulos para apagar`;
  el.vazio.hidden = linhas.length > 0;
  el.tabela.hidden = linhas.length === 0;
  const corpo = el.tabela.tBodies[0];
  corpo.replaceChildren(...linhas.map((l) => {
    const tr = document.createElement('tr');
    for (const [c, rotulo] of COLUNAS) {
      const td = document.createElement('td');
      td.dataset.rotulo = rotulo;
      td.className = c;
      td.textContent = l[c]; // sempre texto, nunca HTML
      tr.append(td);
    }
    return tr;
  }));
}
