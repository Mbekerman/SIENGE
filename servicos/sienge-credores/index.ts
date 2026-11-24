// sienge-credores (Edge Function do Supabase, Deno): ver logica.ts. Instalar com verify_jwt DESLIGADO, porque o pg_cron
// chama sem login (com a chave do Vault sienge_credores_chave); a busca da tela exige o login, conferido aqui no
// /auth/v1/user, e o pedido conta em erp.conferencia_tentativa, que só aceita usuário ativo do ERP.
// Segredos (Edge Functions › Secrets): SIENGE_USUARIO e SIENGE_SENHA (os mesmos da sienge-escrita; a função só faz GET).
// ORIGENS (opcional) lista os endereços do front. SUPABASE_DB_URL, SUPABASE_URL e SUPABASE_ANON_KEY vêm do Supabase.
import postgres from 'npm:postgres@3.4.4';
import { atender, type Credor, type Deps, type Importado } from './logica.ts';

const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { max: 1, prepare: false });
const URL_SB = Deno.env.get('SUPABASE_URL')!;
const CHAVE_SB = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUB = Deno.env.get('SIENGE_SUBDOMINIO') ?? 'bkmincorporadora';
const BASE = `https://api.sienge.com.br/${SUB}/public/api/v1`;

function credencial(): string {
  const u = Deno.env.get('SIENGE_USUARIO'), s = Deno.env.get('SIENGE_SENHA');
  if (!u || !s) throw new Error('faltam os segredos SIENGE_USUARIO e SIENGE_SENHA');
  return 'Basic ' + btoa(`${u}:${s}`);
}
// deno-lint-ignore no-explicit-any
const comoSistema = <T>(f: (tx: any) => Promise<T>) => sql.begin(async (tx: any) => { await tx`set local role erp_sistema`; return await f(tx); }) as Promise<T>;

const deps: Deps = {
  origens: (Deno.env.get('ORIGENS') ?? '').split(',').map((s) => s.trim()).filter(Boolean),
  async login(auth) {
    const r = await fetch(`${URL_SB}/auth/v1/user`, { headers: { apikey: CHAVE_SB, authorization: auth }, signal: AbortSignal.timeout(10_000) });
    if (r.status === 401 || r.status === 403) return null;
    if (!r.ok) throw new Error(`auth ${r.status}`);
    const id = ((await r.json()) as { id?: unknown }).id;
    return typeof id === 'string' && id ? id : null;
  },
  tentativa: (login) => comoSistema(async (tx) => (await tx`select erp.conferencia_tentativa(${login}) as n`)[0].n ?? null),
  async chaveCarga() {
    const [k] = await sql`select decrypted_secret as v from vault.decrypted_secrets where name = 'sienge_credores_chave'`;
    return k?.v ?? null;
  },
  ritmo: async (rotina, s) => (await sql`select sienge.ritmo(${rotina}, ${s}) as v`)[0]?.v === true,
  async sienge(caminho) {
    const r = await fetch(BASE + caminho, { headers: { Authorization: credencial(), Accept: 'application/json' }, signal: AbortSignal.timeout(60_000) });
    const texto = await r.text();
    if (r.status < 200 || r.status > 299) throw Object.assign(new Error(`Sienge GET ${caminho.split('?')[0]} respondeu ${r.status}: ${texto.slice(0, 200)}`), { status: r.status });
    return texto ? JSON.parse(texto) : null;
  },
  // JSON sempre por tx.json (JSON.stringify com ::jsonb chega como jsonb do tipo string)
  importar: (lista: Credor[]) => comoSistema(async (tx) => (await tx`select erp.sienge_importar_credores(${tx.json(lista)}::jsonb) as r`)[0].r as Importado),
  esperar: (ms) => new Promise((r) => setTimeout(r, ms)),
  log: (o) => console.log(JSON.stringify(o)),
};

Deno.serve((req) => atender(req, deps));
