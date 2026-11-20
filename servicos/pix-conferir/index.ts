// pix-conferir (Edge Function do Supabase, Deno): ver logica.ts. Instalar com verify_jwt ligado (só quem tem login
// chama); a função confere o login de novo no /auth/v1/user e grava como erp_sistema, que só aceita usuário ativo do
// ERP. A chave do Asaas fica no Vault (asaas_chave), a mesma conta sem saldo do leitor; ORIGENS (variável da função, opcional)
// lista os endereços do front, separados por vírgula. SUPABASE_DB_URL, SUPABASE_URL e SUPABASE_ANON_KEY vêm do Supabase.
import postgres from 'npm:postgres@3.4.4';
import { conferir, recebedorAsaas, type Deps } from './logica.ts';

const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { max: 1, prepare: false });
const URL_SB = Deno.env.get('SUPABASE_URL')!;
const CHAVE_SB = Deno.env.get('SUPABASE_ANON_KEY')!;
const ASAAS_URL = 'https://api.asaas.com';

let chave: { v: string | null; ate: number } | null = null;
async function chaveAsaas(): Promise<string | null> {
  if (chave && chave.ate > Date.now()) return chave.v;
  const [k] = await sql`select decrypted_secret as v from vault.decrypted_secrets where name = 'asaas_chave'`;
  chave = { v: k?.v ?? null, ate: Date.now() + 5 * 60_000 };
  return chave.v;
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
  recentes: (login) => comoSistema(async (tx) => (await tx`select erp.pix_conferencias_recentes(${login}) as n`)[0].n ?? 0),
  valido: (c) => comoSistema(async (tx) => (await tx`select erp.pix_copia_cola_valido(${c}) as ok`)[0].ok === true),
  guardado: (c) => comoSistema(async (tx) => {
    const [r] = await tx`select cpf_cnpj, nome, banco, chave from erp.pix_conferencias
                          where codigo = ${c} and conferido_em > clock_timestamp() - interval '1 day'`;
    return r ? { cpf_cnpj: r.cpf_cnpj, nome: r.nome, banco: r.banco, chave: r.chave } : null;
  }),
  async asaas(c) {
    const k = await chaveAsaas();
    if (!k) return { ok: false, erro: 'Conferência pelo Asaas desligada (sem a chave)' };
    const r = await fetch(`${ASAAS_URL}/v3/pix/qrCodes/decode`, {
      method: 'POST', headers: { access_token: k, 'content-type': 'application/json', 'user-agent': 'erp-pix-conferir' },
      body: JSON.stringify({ payload: c }), signal: AbortSignal.timeout(15_000),
    });
    // deno-lint-ignore no-explicit-any
    const j = (await r.json().catch(() => ({}))) as any;
    if (!r.ok) return { ok: false, erro: String(j?.errors?.[0]?.description ?? `Asaas ${r.status}`).slice(0, 300) };
    return { ok: true, r: recebedorAsaas(j) };
  },
  gravar: (c, r, login) => comoSistema(async (tx) => {
    await tx`select erp.registrar_pix_conferencia(${c}, ${r.cpf_cnpj}, ${r.nome}, ${r.banco}, ${r.chave}, ${login})`;
  }),
};

Deno.serve((req) => conferir(req, deps));
