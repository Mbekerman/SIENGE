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
const CHAVE = meta('supabase-key') ?? (import.meta.env.VITE_SUPABASE_KEY as string | undefined);

/** Só a chave publicável vai ao navegador: `sb_publishable_…` ou o JWT antigo com role anon. Qualquer outra
 *  (a service_role por engano no servidor, por exemplo) é recusada e a tela mostra o erro, sem chamar o banco.
 *  Mesma regra da página das PRV (pagina/prv.js). */
export function chavePublicavel(k: string | undefined): boolean {
  if (!k) return false;
  if (/^sb_publishable_[A-Za-z0-9_-]+$/.test(k)) return true;
  const partes = k.split('.');
  if (partes.length !== 3) return false;
  try {
    const corpo = JSON.parse(atob(partes[1].replace(/-/g, '+').replace(/_/g, '/')));
    return corpo?.role === 'anon';
  } catch { return false; }
}
export const CHAVE_RECUSADA = Boolean(CHAVE) && !chavePublicavel(CHAVE);
export const SUPABASE_KEY = CHAVE_RECUSADA ? undefined : CHAVE;
/** 'dev' no ambiente de desenvolvimento; vazio em produção. */
export const AMBIENTE = meta('bkm-ambiente') ?? (import.meta.env.VITE_AMBIENTE as string | undefined) ?? '';
/** Domínio do Google Workspace que entra no sistema. */
export const DOMINIO = 'bkm.com.br';
/** Endereço do leitor de notas (serviço erp-leitor no Cloud Run): recebe o arquivo, guarda e lê. Sem ele, a tela
 *  lança só à mão. Só https (ou http://localhost no desenvolvimento). */
const LEITOR = (meta('erp-leitor-url') ?? (import.meta.env.VITE_LEITOR_URL as string | undefined))?.replace(/\/$/, '');
export const LEITOR_URL = LEITOR && /^(https:\/\/[a-z0-9.-]+|http:\/\/localhost(:\d+)?)$/.test(LEITOR) ? LEITOR : undefined;
