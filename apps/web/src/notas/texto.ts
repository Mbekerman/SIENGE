// Texto para as fontes padrão do PDF (Helvetica e Times), que só conhecem o WinAnsi
// (Latin-1 mais alguns sinais do Windows-1252). O que não cabe vira o caractere sem acento
// ou "?", para o PDF nunca sair com lixo.

import type { jsPDF } from 'jspdf';

const CP1252 = '€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ';

export function latin1(s: string): string {
  let r = '';
  for (const ch of (s ?? '').replace(/\r\n?/g, '\n')) {
    const c = ch.codePointAt(0)!;
    if (ch === '\n') r += ch;
    else if (c < 32 || (c >= 0x7f && c < 0xa0)) r += ' ';
    else if (c <= 0xff || CP1252.includes(ch)) r += ch;
    else {
      const base = ch.normalize('NFD').replace(/[̀-ͯ]/g, '');
      r += base && [...base].every((b) => b.codePointAt(0)! <= 0xff) ? base : '?';
    }
  }
  return r;
}

/** Corta o texto (uma linha) para caber na largura, com reticências. */
export function cabe(doc: jsPDF, s: string, largura: number): string {
  const t = s.replace(/\s*\n\s*/g, ' ');
  if (doc.getTextWidth(t) <= largura) return t;
  let lo = 0, hi = t.length;
  while (lo < hi) {
    const m = Math.ceil((lo + hi) / 2);
    if (doc.getTextWidth(t.slice(0, m) + '...') <= largura) lo = m;
    else hi = m - 1;
  }
  return t.slice(0, lo).trimEnd() + '...';
}

/** Quebra em linhas que cabem na largura, respeitando as quebras do próprio texto. */
export function quebra(doc: jsPDF, s: string, largura: number): string[] {
  const out: string[] = [];
  for (const p of s.split('\n')) {
    const l = doc.splitTextToSize(p, largura) as string[];
    out.push(...(l.length ? l : ['']));
  }
  return out;
}
