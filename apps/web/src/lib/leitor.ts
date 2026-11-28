// O leitor de notas (servicos/leitor, Cloud Run): sobe o arquivo com o login da pessoa e baixa o anexo. O serviço
// pergunta ao banco com esse mesmo login, então só entrega o que a pessoa vê.
import { LEITOR_URL } from './config';
import { supabase } from './supabase';
import { lerEtapas } from './etapas';
import type { ResultadoLeitor } from './tipos';

export const leitorLigado = Boolean(LEITOR_URL);
export const TIPOS_ACEITOS = '.pdf,.xml,.jpg,.jpeg,.png,application/pdf,application/xml,text/xml,image/jpeg,image/png';
export const LIMITE = 20 * 1024 * 1024;

async function token(): Promise<string> {
  const { data } = await supabase.auth.getSession();
  if (!data.session) throw new Error('Entre de novo');
  return data.session.access_token;
}

async function erro(r: Response): Promise<Error> {
  const j = await r.json().catch(() => null) as { erro?: string } | null;
  return new Error(j?.erro ?? (r.status === 429 ? 'Muitos arquivos em pouco tempo; espere alguns minutos' : `O leitor respondeu ${r.status}`));
}

/** Acorda o leitor (o Cloud Run desliga sem uso e leva alguns segundos para subir): um GET /saude ao abrir a tela de
 *  lançar, sem login e sem esperar a resposta. */
export function acordarLeitor(): void {
  if (LEITOR_URL) fetch(`${LEITOR_URL}/saude`, { mode: 'no-cors', cache: 'no-store' }).catch(() => {});
}

/** Sobe o arquivo. Com `aoPrevia`, pede a resposta em duas etapas (?etapas=1): no boleto, a prévia com o que o texto
 *  e o banco do boleto dão chega em cerca de 1 s, antes da leitura completa (pedido do Moises, 26/11/2026). */
export async function subirArquivo(f: File, aoPrevia?: (r: ResultadoLeitor) => void): Promise<ResultadoLeitor> {
  if (!LEITOR_URL) throw new Error('O leitor de notas não está ligado neste ambiente');
  if (f.size > LIMITE) throw new Error('O arquivo passa de 20 MB');
  const r = await fetch(`${LEITOR_URL}/anexos${aoPrevia ? '?etapas=1' : ''}`, {
    method: 'POST', body: f,
    headers: { authorization: `Bearer ${await token()}`, 'content-type': 'application/octet-stream', 'x-nome-arquivo': encodeURIComponent(f.name) },
  }).catch(() => { throw new Error('Sem conexão com o leitor. Verifique a internet e tente de novo.'); });
  if (!r.ok) throw await erro(r);
  if (!aoPrevia || !r.body || !(r.headers.get('content-type') ?? '').includes('ndjson')) return r.json();
  return lerEtapas(r.body, aoPrevia);
}

/** Abre o PDF guardado com a senha que a pessoa digitou (quando os CNPJs das empresas não abriram) e lê. A senha não
 *  fica guardada em lugar nenhum. */
export async function abrirComSenha(id: string, senha: string): Promise<ResultadoLeitor> {
  if (!LEITOR_URL) throw new Error('O leitor de notas não está ligado neste ambiente');
  const r = await fetch(`${LEITOR_URL}/anexos/${encodeURIComponent(id)}/senha`, {
    method: 'POST', body: JSON.stringify({ senha }),
    headers: { authorization: `Bearer ${await token()}`, 'content-type': 'application/json' },
  }).catch(() => { throw new Error('Sem conexão com o leitor. Verifique a internet e tente de novo.'); });
  if (!r.ok) throw await erro(r);
  return r.json();
}

/** Baixa o arquivo (o serviço manda como anexo, nunca para abrir na página). */
export async function baixarAnexo(id: string, nome: string): Promise<void> {
  if (!LEITOR_URL) throw new Error('O leitor de notas não está ligado neste ambiente');
  const r = await fetch(`${LEITOR_URL}/anexos/${encodeURIComponent(id)}`, { headers: { authorization: `Bearer ${await token()}` } })
    .catch(() => { throw new Error('Sem conexão com o leitor. Verifique a internet e tente de novo.'); });
  if (!r.ok) throw await erro(r);
  const url = URL.createObjectURL(await r.blob());
  const a = document.createElement('a');
  a.href = url; a.download = nome; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}
