// Recebedor do aviso do Sienge (Edge Function do Supabase, Deno), cadastrado no Sienge por POST /hooks com
// o evento PAYMENT_INSTALLMENT_REMOVED e o token guardado no Vault do banco (sienge_aviso_token). Instalar
// com verify_jwt desligado: o Sienge não manda o JWT do Supabase; quem autentica é o token (logica.ts).
// SUPABASE_DB_URL e SUPABASE_URL vêm do Supabase.
// Aviso novo: chama na hora a sienge-escrita só para os avisos ({"tarefa": "avisos"}, com a chave do Vault
// sienge_escrita_chave), sem segurar a resposta ao Sienge; se falhar, a rotina de minuto pega o aviso.
import postgres from 'npm:postgres@3.4.4';
import { receber, registrarNoBanco, temBearer } from './logica.ts';

const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { max: 1, prepare: false });
const registrar = registrarNoBanco(sql);

// O token fica em memória por 5 minutos (S-136): um POST sem cara de aviso nem chega ao banco.
let cache: { token: string | null; ate: number } | null = null;
async function tokenGuardado(): Promise<string | null> {
  if (cache && cache.ate > Date.now()) return cache.token;
  const [k] = await sql`select decrypted_secret as v from vault.decrypted_secrets where name = 'sienge_aviso_token'`;
  cache = { token: k?.v ?? null, ate: Date.now() + 5 * 60_000 };
  return cache.token;
}

async function processarJa(): Promise<void> {
  const [k] = await sql`select decrypted_secret as v from vault.decrypted_secrets where name = 'sienge_escrita_chave'`;
  if (!k?.v) return;
  await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/sienge-escrita`, {
    method: 'POST', headers: { 'x-escrita-chave': k.v, 'content-type': 'application/json' },
    body: '{"tarefa":"avisos"}', signal: AbortSignal.timeout(60_000),
  });
}
const depois = () => {
  const p = processarJa().catch(() => {});
  // deno-lint-ignore no-explicit-any
  const er = (globalThis as any).EdgeRuntime;
  if (er?.waitUntil) er.waitUntil(p);
};

Deno.serve(async (req) => {
  if (req.method !== 'POST' || !temBearer(req)) return new Response('não autorizado', { status: 401 });
  let token: string | null;
  try {
    token = await tokenGuardado();
  } catch {
    return new Response('erro ao ler o token', { status: 500 });
  }
  return await receber(req, token, registrar, depois);
});
