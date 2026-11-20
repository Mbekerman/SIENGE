// Quem recebe pelo PIX copia e cola (BR Code): a mesma leitura do banco (erp.pix_copia_cola_recebedor), só para mostrar
// e pedir a justificativa na tela; quem confere é o banco.
function campo(p: string, id: string): string | undefined {
  for (let i = 0; i + 3 < p.length;) {
    const n = Number(p.slice(i + 2, i + 4));
    if (!/^\d{2}$/.test(p.slice(i + 2, i + 4))) return undefined;
    if (p.slice(i, i + 2) === id) return p.slice(i + 4, i + 4 + n);
    i += 4 + n;
  }
  return undefined;
}
export interface Recebedor { chave: string | null; url: string | null; nome: string | null }
export function recebedorPix(codigo: string): Recebedor | null {
  const p = codigo.trim();
  if (!p.startsWith('000201')) return null;
  for (let i = 26; i <= 51; i++) {
    const v = campo(p, String(i));
    if (v && (campo(v, '00') ?? '').toLowerCase() === 'br.gov.bcb.pix') {
      let c = campo(v, '01')?.trim() || null;
      if (c && (c.includes('@') || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(c))) c = c.toLowerCase();
      return { chave: c, url: campo(v, '25')?.trim() || null, nome: campo(p, '59')?.trim() || null };
    }
  }
  return null;
}
