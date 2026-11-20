// erp-leitor: serviço do Cloud Run (projeto bkm-erp) que recebe o arquivo da nota, guarda no bucket próprio, registra o
// anexo e a leitura no banco com o login da pessoa e devolve o que casa com a nota. Só a chave publicável do Supabase
// fica aqui: o que a pessoa pode fazer é o que o JWT dela pode no esquema api.
//
// POST /anexos         corpo = os bytes do arquivo; cabeçalho X-Nome-Arquivo (codificado como URI) e Authorization
// GET  /anexos/<id>    entrega o arquivo para baixar, se a pessoa vê o anexo
// GET  /saude          200
//
// Variáveis: SUPABASE_URL, SUPABASE_KEY (publicável), BUCKET, ORIGENS (endereços do front, separados por vírgula),
// ANTHROPIC_FEDERATION_RULE_ID, ANTHROPIC_ORGANIZATION_ID, ANTHROPIC_SERVICE_ACCOUNT_ID, ANTHROPIC_WORKSPACE_ID,
// ASAAS_URL e ASAAS_CHAVE (esta pelo Secret Manager; sem ela, o boleto fica só com a conferência dos dígitos).
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LIMITE, type Mime } from './arquivo.ts';
import { clienteFederado, lerComIa } from './ia.ts';
import { type Banco, type Bucket, type Deps, Recusa, baixar, subir } from './fluxo.ts';
import { Limite } from './limite.ts';

const env = (k: string) => { const v = process.env[k]; if (!v) throw new Error(`Falta a variável ${k}`); return v; };
const SUPABASE_URL = env('SUPABASE_URL').replace(/\/$/, '');
const SUPABASE_KEY = env('SUPABASE_KEY');
const BUCKET = env('BUCKET');
const ORIGENS = new Set(env('ORIGENS').split(',').map((s) => s.trim()).filter(Boolean));
if (!/^sb_publishable_/.test(SUPABASE_KEY)) throw new Error('SUPABASE_KEY precisa ser a chave publicável');

const log = (msg: string, extra: Record<string, unknown> = {}) => console.log(JSON.stringify({ severity: 'INFO', msg, ...extra }));

const banco: Banco = {
  async rpc(jwt, fn, args) {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: SUPABASE_KEY, authorization: `Bearer ${jwt}`, 'content-type': 'application/json',
                 'content-profile': 'api', 'accept-profile': 'api' },
      body: JSON.stringify(args), signal: AbortSignal.timeout(30_000),
    });
    const corpo = await r.text();
    if (r.status === 401 || r.status === 403) throw new Recusa(401, 'Entre de novo');
    if (!r.ok) {
      // a mensagem do banco é a regra de negócio recusando (ex.: "Só quem tem cadastro ativo"); o resto fica no log
      let m = 'Erro no banco';
      try { const j = JSON.parse(corpo); if (j?.code === 'P0001' && typeof j.message === 'string') m = j.message; } catch { /* */ }
      log('rpc recusada', { fn, status: r.status });
      throw new Recusa(r.status === 400 ? 422 : 502, m);
    }
    return corpo ? JSON.parse(corpo) : null;
  },
};

// Token da conta de serviço para o bucket, pelo servidor de metadados (sem chave guardada).
let tokenGcs: { v: string; ate: number } | null = null;
async function gcs(): Promise<string> {
  if (tokenGcs && tokenGcs.ate > Date.now() + 60_000) return tokenGcs.v;
  const r = await fetch('http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token',
    { headers: { 'Metadata-Flavor': 'Google' }, signal: AbortSignal.timeout(5_000) });
  if (!r.ok) throw new Error(`metadados: ${r.status}`);
  const j = await r.json() as { access_token: string; expires_in: number };
  tokenGcs = { v: j.access_token, ate: Date.now() + j.expires_in * 1000 };
  return tokenGcs.v;
}
const bucket: Bucket = {
  async gravar(nome: string, mime: Mime, dados: Buffer) {
    // ifGenerationMatch=0: só grava se o objeto não existe (o mesmo id nunca recebe outro arquivo)
    const u = `https://storage.googleapis.com/upload/storage/v1/b/${encodeURIComponent(BUCKET)}/o?uploadType=media`
      + `&name=${encodeURIComponent(nome)}&ifGenerationMatch=0`;
    const r = await fetch(u, { method: 'POST', headers: { authorization: `Bearer ${await gcs()}`, 'content-type': mime },
      body: dados, signal: AbortSignal.timeout(60_000) });
    if (!r.ok) { log('bucket recusou gravar', { status: r.status }); throw new Recusa(502, 'Não consegui guardar o arquivo'); }
  },
  async ler(nome: string) {
    const u = `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(BUCKET)}/o/${encodeURIComponent(nome)}?alt=media`;
    const r = await fetch(u, { headers: { authorization: `Bearer ${await gcs()}` }, signal: AbortSignal.timeout(60_000) });
    if (r.status === 404) return null;
    if (!r.ok) throw new Recusa(502, 'Não consegui ler o arquivo guardado');
    return Buffer.from(await r.arrayBuffer());
  },
};

// PDF com senha: qpdf no próprio contêiner, sem shell, com arquivos temporários apagados ao fim.
function abrirPdf(pdf: Buffer, senha: string): Promise<Buffer | null> {
  return (async () => {
    const dir = await mkdtemp(join(tmpdir(), 'pdf-'));
    try {
      await writeFile(join(dir, 'e.pdf'), pdf);
      const ok = await new Promise<boolean>((res) => execFile('qpdf', [`--password=${senha}`, '--decrypt', join(dir, 'e.pdf'), join(dir, 's.pdf')],
        { timeout: 20_000 }, (err) => res(!err || (err as { code?: number }).code === 3)));   // 3 = aviso, arquivo gerado
      return ok ? await readFile(join(dir, 's.pdf')) : null;
    } catch { return null; } finally { await rm(dir, { recursive: true, force: true }); }
  })();
}

// Asaas: simula o pagamento da conta para saber o valor, o vencimento e o beneficiário que o banco registrou.
const ASAAS_URL = process.env.ASAAS_URL?.replace(/\/$/, '');
const ASAAS_CHAVE = process.env.ASAAS_CHAVE;
const asaas: Deps['asaas'] = ASAAS_URL && ASAAS_CHAVE ? async (linha) => {
  const r = await fetch(`${ASAAS_URL}/v3/bill/simulate`, {
    method: 'POST', headers: { access_token: ASAAS_CHAVE, 'content-type': 'application/json', 'user-agent': 'erp-leitor' },
    body: JSON.stringify(linha.length === 44 ? { barCode: linha } : { identificationField: linha }), signal: AbortSignal.timeout(15_000),
  });
  const j = await r.json().catch(() => ({})) as any;
  if (!r.ok) return { ok: false, erro: j?.errors?.[0]?.description ?? `Asaas ${r.status}` };
  const b = j?.bankSlipInfo ?? {};
  return { ok: true, valor: typeof b.value === 'number' ? b.value : undefined, vencimento: b.dueDate ?? undefined,
           beneficiario: b.beneficiaryName ?? b.companyName ?? undefined,
           beneficiario_documento: typeof b.beneficiaryCpfCnpj === 'string' ? b.beneficiaryCpfCnpj.replace(/\D/g, '') : undefined };
} : null;

const cliente = await clienteFederado();
const deps: Deps = { banco, bucket, ia: (e) => lerComIa(cliente, e), asaas, abrirPdf, log };
const limite = new Limite(30, 10 * 60_000);   // 30 arquivos por pessoa a cada 10 minutos

function cors(req: IncomingMessage, res: ServerResponse) {
  const o = req.headers.origin;
  if (o && ORIGENS.has(o)) {
    res.setHeader('access-control-allow-origin', o);
    res.setHeader('vary', 'origin');
    res.setHeader('access-control-allow-headers', 'authorization, content-type, x-nome-arquivo');
    res.setHeader('access-control-allow-methods', 'GET, POST');
    res.setHeader('access-control-expose-headers', 'content-disposition');
    res.setHeader('access-control-max-age', '600');
  }
}
function json(res: ServerResponse, status: number, corpo: unknown) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
  res.end(JSON.stringify(corpo));
}
function lerCorpo(req: IncomingMessage): Promise<Buffer> {
  return new Promise((ok, falha) => {
    const partes: Buffer[] = []; let n = 0;
    req.on('data', (c: Buffer) => { n += c.length; if (n > LIMITE) { falha(new Recusa(413, 'O arquivo passa de 20 MB')); req.destroy(); } else partes.push(c); });
    req.on('end', () => ok(Buffer.concat(partes)));
    req.on('error', falha);
  });
}
// Quem é, só para o limite por pessoa (o banco confere o JWT de verdade em cada chamada).
function sujeito(jwt: string): string {
  try { return JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString()).sub ?? 'x'; } catch { return 'x'; }
}

createServer(async (req, res) => {
  cors(req, res);
  try {
    const url = new URL(req.url ?? '/', 'http://x');
    if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
    if (req.method === 'GET' && url.pathname === '/saude') return json(res, 200, { ok: true });
    const jwt = /^Bearer (\S+)$/.exec(req.headers.authorization ?? '')?.[1];
    if (!jwt) throw new Recusa(401, 'Entre de novo');

    if (req.method === 'POST' && url.pathname === '/anexos') {
      if (!limite.passa(sujeito(jwt))) throw new Recusa(429, 'Muitos arquivos em pouco tempo; espere alguns minutos');
      const tam = Number(req.headers['content-length'] ?? 0);
      if (tam > LIMITE) throw new Recusa(413, 'O arquivo passa de 20 MB');
      const dados = await lerCorpo(req);
      let nome = 'arquivo';
      try { nome = decodeURIComponent(String(req.headers['x-nome-arquivo'] ?? 'arquivo')); } catch { /* fica arquivo */ }
      return json(res, 200, await subir(deps, jwt, nome, dados));
    }
    const m = /^\/anexos\/([^/]+)$/.exec(url.pathname);
    if (req.method === 'GET' && m) {
      const a = await baixar(deps, jwt, m[1]);
      res.writeHead(200, {
        'content-type': 'application/octet-stream',
        'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(a.nome)}`,
        'x-content-type-options': 'nosniff', 'content-security-policy': "sandbox; default-src 'none'",
        'cache-control': 'private, no-store', 'content-length': String(a.dados.length),
      });
      res.end(a.dados);
      return;
    }
    throw new Recusa(404, 'Não encontrado');
  } catch (e) {
    if (e instanceof Recusa) return json(res, e.status, { erro: e.message });
    log('erro', { erro: String(e) });
    return json(res, 500, { erro: 'Erro no leitor' });
  }
}).listen(Number(process.env.PORT ?? 8080), () => log('erp-leitor no ar'));
