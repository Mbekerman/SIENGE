// O que se sabe do arquivo pelos próprios bytes (nunca pelo nome nem pelo tipo que o navegador mandou).
import { createHash } from 'node:crypto';

export type Mime = 'application/pdf' | 'application/xml' | 'image/jpeg' | 'image/png';
export const LIMITE = 20 * 1024 * 1024; // o mesmo de erp.anexos

export function tipoPelosBytes(b: Buffer): Mime | null {
  if (b.length >= 5 && b.subarray(0, 5).toString('latin1') === '%PDF-') return 'application/pdf';
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg';
  if (b.length >= 8 && b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  // XML: começa com <, depois de BOM e espaços; e o texto é UTF-8 válido
  let i = b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf ? 3 : 0;
  while (i < b.length && [0x20, 0x09, 0x0a, 0x0d].includes(b[i])) i++;
  if (b[i] === 0x3c && textoUtf8(b) !== null) return 'application/xml';
  return null;
}

export function textoUtf8(b: Buffer): string | null {
  try { return new TextDecoder('utf-8', { fatal: true }).decode(b).replace(/^﻿/, ''); } catch { return null; }
}

export const sha256 = (b: Buffer) => createHash('sha256').update(b).digest('hex');

// Nome que vai para o banco: sem caminho, sem caracteres de controle, até 255.
export function nomeLimpo(nome: string, mime: Mime): string {
  const base = nome.split(/[\\/]/).pop()!.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 255);
  if (base) return base;
  return { 'application/pdf': 'arquivo.pdf', 'application/xml': 'arquivo.xml', 'image/jpeg': 'foto.jpg', 'image/png': 'imagem.png' }[mime];
}

export function pdfCriptografado(b: Buffer): boolean {
  // O dicionário /Encrypt fica no trailer (ou no objeto do xref); basta procurar no fim e no começo do arquivo.
  const fim = b.subarray(Math.max(0, b.length - 4096)).toString('latin1');
  const ini = b.subarray(0, Math.min(b.length, 4096)).toString('latin1');
  return /\/Encrypt\s/.test(fim) || /\/Encrypt\s/.test(ini);
}

// Senhas que as concessionárias usam, tiradas do CNPJ de quem paga (pedido do Moises, 20/11/2026): primeiro os
// começos do CNPJ de cada empresa, do 3 primeiros dígitos ao CNPJ inteiro; depois os finais, dos 3 últimos até
// todos menos o primeiro. Sem repetir; em ordem, porque a primeira que abre encerra.
export function senhasCandidatas(cnpjs: string[]): string[] {
  const ds = [...new Set(cnpjs.map((c) => c.replace(/\D/g, '')).filter((d) => d.length === 14))];
  const s = new Set<string>();
  for (const d of ds) for (let n = 3; n <= 14; n++) s.add(d.slice(0, n));
  for (const d of ds) for (let n = 3; n <= 13; n++) s.add(d.slice(-n));
  return [...s];
}
