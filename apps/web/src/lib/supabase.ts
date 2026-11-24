import { createClient } from '@supabase/supabase-js';
import { SUPABASE_KEY as key, SUPABASE_URL as url } from './config';

export const configurado = Boolean(url && key);

/* O front só fala com o esquema `api` (funções finas, que rodam com o login e o RLS de quem chama;
   migration 20261118000500_api_telas.sql). O `erp` fica fora da API. No Supabase, `api` precisa estar em
   Settings › API › Exposed schemas. */
export const supabase = createClient(url ?? 'http://localhost', key ?? 'sem-chave', {
  db: { schema: 'api' },
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: 'pkce' },
});

/** Converte erro do banco em mensagem legível (do BKM Terrenos, lib/supabase.ts). */
export function mensagemErro(e: unknown): string {
  if (!e) return 'Erro desconhecido';
  if (typeof e === 'object' && e && 'message' in e) {
    const m = String((e as { message: string }).message);
    if (m.includes('Failed to fetch')) return 'Sem conexão com o servidor. Verifique a internet e tente de novo.';
    if (m.includes('row-level security')) return 'Você não tem permissão para esta ação.';
    // trava de duplicidade (migration 20261124001000): mesmo fornecedor, tipo e número do documento
    if (m.includes('documentos_fiscais_unico'))
      return 'Este fornecedor já tem um documento desse tipo com esse número (zeros à esquerda e pontuação não contam). Confira se não é o mesmo documento lançado de novo; se o primeiro estava errado, cancele-o antes.';
    return m;
  }
  return String(e);
}

/** Chama uma função do esquema api e devolve os dados, ou lança o erro. */
export async function rpc<T>(nome: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(nome, args ?? {});
  if (error) throw error;
  return data as T;
}
