// Credores do Sienge no cadastro de pessoas do ERP (Moises, 24/nov/2026: "a nota ainda não está buscando o fornecedor
// pelo CNPJ no banco de dados do Sienge"; decisão de 08/11: importar todos os credores, nenhuma conta nem PIX entra
// aprovado). O banco decide o que entra (erp.sienge_importar_credores); aqui fica o que fala com o Sienge (GET /creditors,
// creditor-v1.yaml, só leitura) e quem pode pedir. Dois jeitos de chamar:
//   - carga (pg_cron, com a chave do Vault no cabeçalho x-credores-chave): lê todas as páginas de 200 e importa. Em
//     24/11/2026 eram 825 credores, 5 chamadas. Resposta só {ok} (o pg_net guarda as respostas, S-143).
//   - busca (a tela Lançar, com o login): {documento} = CPF ou CNPJ do emitente que o ERP não achou; pergunta ao Sienge só
//     por ele e importa o que vier. Responde sempre {ok: true}, achando ou não (revisão do #139: a resposta não pode dizer
//     se o documento é credor no Sienge); a tela busca de novo no ERP, pelo RLS, e só vê a pessoa se puder.
// Do credor só seguem para o banco código, nome, nome fantasia, CPF/CNPJ e ativo: endereço, telefones, contatos e conta
// do Sienge ficam fora (o banco também não os grava).

export interface Credor { id: unknown; name: unknown; tradeName: unknown; cnpj: unknown; cpf: unknown; active: unknown }
export interface Importado { novos: number; ligados: number; ja_ligados: number; avisos: unknown[] }
export interface Deps {
  login(auth: string): Promise<string | null>;
  tentativa(login: string): Promise<number | null>;          // erp.conferencia_tentativa (o mesmo limite da conferência)
  chaveCarga(): Promise<string | null>;                      // Vault: sienge_credores_chave
  ritmo(rotina: string, segundos: number): Promise<boolean>; // sienge.ritmo
  sienge(caminho: string): Promise<unknown>;                  // GET; erro fora de 2xx (404 = nada achado)
  importar(lista: Credor[]): Promise<Importado>;             // erp.sienge_importar_credores, como erp_sistema
  esperar(ms: number): Promise<void>;
  log(o: unknown): void;
  origens: string[];
}
export const LIMITE = 60;          // pedidos por pessoa a cada 10 minutos, somados aos de conferência
export const PAGINA = 200;         // máximo do Sienge
export const MAX_PAGINAS = 50;     // 10 mil credores; acima disso algo mudou e a carga para
export const RITMO_CARGA = 3000;   // segundos entre duas cargas (a agenda é diária)
export const RITMO_BUSCA = 1;      // segundos entre duas buscas de qualquer pessoa: teto global, a cota do Sienge é dividida com o CRM

const FRONT = /^https:\/\/erp-web-[a-z0-9-]+(\.[a-z0-9-]+)*\.run\.app$/;
export function cors(origem: string | null, origens: string[]): Record<string, string> {
  return origem && (origens.length ? origens.includes(origem) : FRONT.test(origem))
    ? { 'access-control-allow-origin': origem, 'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
        'access-control-allow-methods': 'POST, OPTIONS', vary: 'origin' }
    : {};
}

/** Só os campos que o banco usa. */
// deno-lint-ignore no-explicit-any
export function enxugar(r: any): Credor {
  return { id: r?.id, name: r?.name, tradeName: r?.tradeName, cnpj: r?.cnpj, cpf: r?.cpf, active: r?.active };
}

/** CPF (11 dígitos) ou CNPJ (14, com letras desde 2026) do jeito que o Sienge pede: sem máscara. Nulo se não é nenhum. */
export function documento(x: unknown): { tipo: 'cpf' | 'cnpj'; valor: string } | null {
  if (typeof x !== 'string' || x.length > 40) return null;
  const v = x.toUpperCase().replace(/[^0-9A-Z]/g, '');
  if (/^[0-9]{11}$/.test(v)) return { tipo: 'cpf', valor: v };
  if (/^[0-9A-Z]{12}[0-9]{2}$/.test(v)) return { tipo: 'cnpj', valor: v };
  return null;
}

function iguais(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// deno-lint-ignore no-explicit-any
const resultados = (j: any): unknown[] => (Array.isArray(j?.results) ? j.results : []);

/** Lê o Sienge página a página e importa cada uma. Para na primeira página incompleta. */
export async function carga(d: Deps): Promise<{ paginas: number; credores: number; novos: number; ligados: number; ja_ligados: number; avisos: number }> {
  const t = { paginas: 0, credores: 0, novos: 0, ligados: 0, ja_ligados: 0, avisos: 0 };
  for (let p = 0; p < MAX_PAGINAS; p++) {
    if (p > 0) await d.esperar(1000);   // a cota de 200 por minuto é da BKM inteira, dividida com o CRM
    const lista = resultados(await d.sienge(`/creditors?limit=${PAGINA}&offset=${p * PAGINA}`));
    t.paginas++;
    if (lista.length) {
      const r = await d.importar(lista.map(enxugar));
      t.credores += lista.length; t.novos += r.novos; t.ligados += r.ligados; t.ja_ligados += r.ja_ligados; t.avisos += r.avisos.length;
    }
    if (lista.length < PAGINA) return t;
  }
  throw new Error(`mais de ${MAX_PAGINAS * PAGINA} credores no Sienge: a carga parou`);
}

export async function atender(req: Request, d: Deps): Promise<Response> {
  const h = cors(req.headers.get('origin'), d.origens);
  const resp = (status: number, corpo: unknown) => Response.json(corpo, { status, headers: h });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: h });
  if (req.method !== 'POST') return resp(405, { erro: 'Só POST' });

  const chave = req.headers.get('x-credores-chave');
  if (chave !== null) {
    try {
      const k = await d.chaveCarga();
      if (!k || !iguais(chave, k)) return new Response('não autorizado', { status: 401 });
      if (!(await d.ritmo('credores', RITMO_CARGA))) return Response.json({ ok: false }, { status: 429 });
      d.log({ carga: await carga(d) });
      return Response.json({ ok: true });
    } catch (e) {
      d.log({ erro: String((e as Error)?.message ?? e).slice(0, 500) });
      return Response.json({ ok: false }, { status: 500 });
    }
  }

  const auth = req.headers.get('authorization') ?? '';
  if (!/^Bearer \S+$/.test(auth)) return resp(401, { erro: 'Sem login' });
  let login: string | null;
  try { login = await d.login(auth); } catch { return resp(502, { erro: 'Não consegui conferir o login' }); }
  if (!login) return resp(401, { erro: 'Login inválido' });
  let n: number | null;
  try { n = await d.tentativa(login); } catch { return resp(500, { erro: 'Erro na busca' }); }
  if (n === null) return resp(403, { erro: 'Sem acesso ao ERP' });
  if (n > LIMITE) return resp(429, { erro: 'Muitas buscas em pouco tempo; tente daqui a alguns minutos' });
  const txt = await req.text();
  if (txt.length > 256) return resp(413, { erro: 'Pedido grande demais' });
  // deno-lint-ignore no-explicit-any
  let corpo: any;
  try { corpo = JSON.parse(txt); } catch { return resp(400, { erro: 'Corpo inválido' }); }
  const doc = documento(corpo?.documento);
  if (!doc) return resp(400, { erro: 'Informe um CPF ou CNPJ' });
  try { if (!(await d.ritmo('credores-busca', RITMO_BUSCA))) return resp(429, { erro: 'Muitas buscas agora; tente de novo em instantes' }); }
  catch { return resp(500, { erro: 'Erro na busca' }); }
  try {
    let lista: unknown[];
    try { lista = resultados(await d.sienge(`/creditors?${doc.tipo}=${doc.valor}&limit=${PAGINA}`)); }
    catch (e) { if ((e as { status?: number })?.status === 404) lista = []; else throw e; }
    if (lista.length) await d.importar(lista.map(enxugar));
    return resp(200, { ok: true });
  } catch (e) {
    d.log({ erro: String((e as Error)?.message ?? e).slice(0, 500) });
    return resp(502, { erro: 'O Sienge não respondeu; tente de novo' });
  }
}
