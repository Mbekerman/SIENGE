// As rotas do leitor, separadas do servidor para os testes. O login é conferido no Supabase ANTES de ler o corpo:
// o serviço é público (o navegador chama direto), então sem login válido nada é lido nem guardado, e o limite por
// pessoa usa o id que o Supabase devolveu, não o que o JWT diz.
import type { IncomingMessage, ServerResponse } from 'node:http';
import { LIMITE } from './arquivo.ts';
import { type Deps, Recusa, baixar, subir } from './fluxo.ts';
import type { Limite } from './limite.ts';

export interface Opcoes {
  deps: Deps;
  limite: Limite;
  origens: Set<string>;
  quem: (jwt: string) => Promise<string | null>;   // id da pessoa, ou null se o login não vale
}

export function tratador(o: Opcoes) {
  function cors(req: IncomingMessage, res: ServerResponse) {
    const origem = req.headers.origin;
    if (origem && o.origens.has(origem)) {
      res.setHeader('access-control-allow-origin', origem);
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

  return async (req: IncomingMessage, res: ServerResponse) => {
    cors(req, res);
    try {
      const url = new URL(req.url ?? '/', 'http://x');
      if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
      if (req.method === 'GET' && url.pathname === '/saude') return json(res, 200, { ok: true });
      const post = req.method === 'POST' && url.pathname === '/anexos';
      const m = /^\/anexos\/([^/]+)$/.exec(url.pathname);
      if (!post && !(req.method === 'GET' && m)) throw new Recusa(404, 'Não encontrado');
      const jwt = /^Bearer (\S+)$/.exec(req.headers.authorization ?? '')?.[1];
      if (!jwt || jwt.length > 8192) throw new Recusa(401, 'Entre de novo');
      const id = await o.quem(jwt);
      if (!id) throw new Recusa(401, 'Entre de novo');

      if (post) {
        if (!o.limite.passa(id)) throw new Recusa(429, 'Muitos arquivos em pouco tempo; espere alguns minutos');
        const tam = Number(req.headers['content-length'] ?? 0);
        if (tam > LIMITE) throw new Recusa(413, 'O arquivo passa de 20 MB');
        const dados = await lerCorpo(req);
        let nome = 'arquivo';
        try { nome = decodeURIComponent(String(req.headers['x-nome-arquivo'] ?? 'arquivo')); } catch { /* fica arquivo */ }
        return json(res, 200, await subir(o.deps, jwt, nome, dados));
      }
      const a = await baixar(o.deps, jwt, m![1]);
      res.writeHead(200, {
        'content-type': 'application/octet-stream',
        'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(a.nome)}`,
        'x-content-type-options': 'nosniff', 'content-security-policy': "sandbox; default-src 'none'",
        'cache-control': 'private, no-store', 'content-length': String(a.dados.length),
      });
      res.end(a.dados);
    } catch (e) {
      if (e instanceof Recusa) {
        // recusado antes de ler o corpo: responde e fecha a conexão, sem receber o resto
        if (!req.readableEnded) { res.setHeader('connection', 'close'); res.on('finish', () => req.destroy()); }
        if (!res.headersSent) json(res, e.status, { erro: e.message });
        return;
      }
      o.deps.log('erro', { erro: String(e) });
      if (!res.headersSent) json(res, 500, { erro: 'Erro no leitor' });
    }
  };
}
