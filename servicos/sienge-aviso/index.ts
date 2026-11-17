// Recebedor do aviso do Sienge (Edge Function do Supabase, Deno), cadastrado no Sienge por POST /hooks com
// o evento PAYMENT_INSTALLMENT_REMOVED e o token guardado no Vault do banco (sienge_aviso_token). Instalar
// com verify_jwt desligado: o Sienge não manda o JWT do Supabase; quem autentica é o token (logica.ts).
// SUPABASE_DB_URL vem do Supabase.
import postgres from 'npm:postgres@3.4.4';
import { receber } from './logica.ts';

const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { max: 1, prepare: false });

Deno.serve(async (req) => {
  let token: string | null = null;
  try {
    const [k] = await sql`select decrypted_secret as v from vault.decrypted_secrets where name = 'sienge_aviso_token'`;
    token = k?.v ?? null;
  } catch {
    return new Response('erro ao ler o token', { status: 500 });
  }
  return await receber(req, token, (a) => sql.begin(async (tx: any) => {
    await tx`set local role erp_sistema`;
    const [r] = await tx`select erp.sienge_registrar_aviso(${a.eventoId}::uuid, ${a.evento}::text, ${a.hook}::text,
                                                            ${JSON.stringify(a.corpo)}::jsonb) as novo`;
    return r.novo as boolean;
  }));
});
