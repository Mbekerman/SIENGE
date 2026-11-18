// Recebedor do aviso do Sienge (Edge Function do Supabase, Deno), cadastrado no Sienge por POST /hooks com
// o evento PAYMENT_INSTALLMENT_REMOVED e o token guardado no Vault do banco (sienge_aviso_token). Instalar
// com verify_jwt desligado: o Sienge não manda o JWT do Supabase; quem autentica é o token (logica.ts).
// SUPABASE_DB_URL vem do Supabase.
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

Deno.serve(async (req) => {
  if (req.method !== 'POST' || !temBearer(req)) return new Response('não autorizado', { status: 401 });
  let token: string | null;
  try {
    token = await tokenGuardado();
  } catch {
    return new Response('erro ao ler o token', { status: 500 });
  }
  return await receber(req, token, registrar);
});
