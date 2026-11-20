// Conferência do PIX copia e cola pelo Asaas (Moises, 20/nov/2026; revisão de segurança do #106; a tela e os avisos dizem
// só "conferido", sem a fonte): o código leva o
// recebedor dentro dele, e só o banco do recebedor sabe quem recebe pelo código dinâmico. A função pergunta ao
// Asaas (POST /v3/pix/qrCodes/decode, que só lê: pagar é outra chamada) e grava em erp.pix_conferencias como
// erp_sistema; o banco dispensa a justificativa quando o documento de quem recebe é o do credor. A tela não grava a
// conferência, só pede.
export interface Recebedor { cpf_cnpj: string | null; nome: string | null; banco: string | null; chave: string | null; valor: number | null }
export interface Deps {
  login(auth: string): Promise<string | null>;                 // id do login conferido no Supabase, ou nulo
  // registra o pedido e devolve quantos a pessoa fez nos últimos 10 minutos (este incluso); nulo se não é usuário ativo do ERP
  tentativa(login: string): Promise<number | null>;
  valido(codigo: string): Promise<boolean>;                     // erp.pix_copia_cola_valido
  guardado(codigo: string): Promise<Recebedor | null>;          // conferência de menos de 1 dia
  asaas(codigo: string): Promise<{ ok: true; r: Recebedor } | { ok: false; erro: string }>;
  gravar(codigo: string, r: Recebedor, login: string): Promise<void>;
  origens: string[];
}
export const LIMITE = 60;   // pedidos por pessoa a cada 10 minutos (também os recusados)

// Sem ORIGENS, os endereços do front no Cloud Run (erp-web-*.run.app). CORS aqui não é a trava: a função exige o login
// (Bearer) e não usa cookie.
const FRONT = /^https:\/\/erp-web-[a-z0-9-]+(\.[a-z0-9-]+)*\.run\.app$/;
export function cors(origem: string | null, origens: string[]): Record<string, string> {
  return origem && (origens.length ? origens.includes(origem) : FRONT.test(origem))
    ? { 'access-control-allow-origin': origem, 'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
        'access-control-allow-methods': 'POST, OPTIONS', vary: 'origin' }
    : {};
}

/** O que o Asaas devolve vira o recebedor; o documento fica só com dígitos e * (pode vir mascarado). */
// deno-lint-ignore no-explicit-any
export function recebedorAsaas(j: any): Recebedor {
  const r = j?.receiver ?? {};
  const s = (x: unknown) => (typeof x === 'string' && x.trim() ? x.trim() : null);
  const doc = s(r.cpfCnpj)?.replace(/[^0-9*]/g, '') || null;
  return { cpf_cnpj: doc && /^[0-9*]{11,14}$/.test(doc) ? doc : null, nome: s(r.name) ?? s(r.tradingName),
           banco: s(r.ispbName), chave: s(j?.pixKey),
           valor: typeof j?.value === 'number' && Number.isFinite(j.value) && j.value > 0 ? Math.round(j.value * 100) / 100 : null };
}

export async function conferir(req: Request, d: Deps): Promise<Response> {
  const h = cors(req.headers.get('origin'), d.origens);
  const resp = (status: number, corpo: unknown) => Response.json(corpo, { status, headers: h });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: h });
  if (req.method !== 'POST') return resp(405, { erro: 'Só POST' });
  const auth = req.headers.get('authorization') ?? '';
  if (!/^Bearer \S+$/.test(auth)) return resp(401, { erro: 'Sem login' });
  let login: string | null;
  try { login = await d.login(auth); } catch { return resp(502, { erro: 'Não consegui conferir o login' }); }
  if (!login) return resp(401, { erro: 'Login inválido' });
  // revisão do #106: antes de tudo, o pedido conta e só usuário ativo do ERP segue (nem a conferência guardada volta)
  let n: number | null;
  try { n = await d.tentativa(login); } catch { return resp(500, { erro: 'Erro ao conferir' }); }
  if (n === null) return resp(403, { erro: 'Sem acesso ao ERP' });
  if (n > LIMITE) return resp(429, { erro: 'Muitas conferências em pouco tempo; tente daqui a alguns minutos' });
  const txt = await req.text();
  if (txt.length > 2048) return resp(413, { erro: 'Pedido grande demais' });
  let codigo: unknown;
  try { codigo = JSON.parse(txt)?.codigo; } catch { return resp(400, { erro: 'Corpo inválido' }); }
  if (typeof codigo !== 'string') return resp(400, { erro: 'Falta o código' });
  codigo = codigo.replace(/[\r\n]+/g, '').trim();
  const c = codigo as string;
  if (c.length > 512 || !c.startsWith('000201')) return resp(400, { erro: 'Não é um PIX copia e cola' });
  try {
    if (!(await d.valido(c))) return resp(400, { erro: 'O PIX copia e cola não confere (formato ou CRC)' });
    const g = await d.guardado(c);
    if (g) return resp(200, g);
    const a = await d.asaas(c);
    if (!a.ok) return resp(422, { erro: a.erro });
    await d.gravar(c, a.r, login);
    return resp(200, a.r);
  } catch {
    return resp(500, { erro: 'Erro ao conferir' });   // o detalhe não vai para quem chamou
  }
}
