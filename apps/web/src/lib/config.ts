/**
 * Configuração do ambiente, lida das metas da página (copiado do BKM Terrenos, apps/web/src/lib/config.ts).
 * Publicado, o servidor web põe ali os valores do ambiente; no `npm run dev` as metas chegam sem trocar
 * ("{% env ... %}") e valem as variáveis VITE_* do .env.local. Endereço e chave publicável nunca vão para o repositório.
 */
function meta(nome: string): string | undefined {
  const v = document.querySelector<HTMLMetaElement>(`meta[name="${nome}"]`)?.content?.trim();
  return v && !v.startsWith('{%') ? v : undefined;
}

export const SUPABASE_URL = meta('supabase-url') ?? (import.meta.env.VITE_SUPABASE_URL as string | undefined);
export const SUPABASE_KEY = meta('supabase-key') ?? (import.meta.env.VITE_SUPABASE_KEY as string | undefined);
/** 'dev' no ambiente de desenvolvimento; vazio em produção. */
export const AMBIENTE = meta('bkm-ambiente') ?? (import.meta.env.VITE_AMBIENTE as string | undefined) ?? '';
/** Domínio do Google Workspace que entra no sistema. */
export const DOMINIO = 'bkm.com.br';
