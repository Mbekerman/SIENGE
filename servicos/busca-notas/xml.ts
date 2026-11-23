// Analisador de XML pequeno, copiado do leitor (servicos/leitor/xml.ts): sem DTD nem entidades externas (sem XXE).
export interface No { nome: string; attrs: Record<string, string>; filhos: No[]; texto: string }

const ENT: Record<string, string> = { lt: '<', gt: '>', amp: '&', quot: '"', apos: "'" };
function desescapar(s: string) {
  return s.replace(/&(#x[0-9a-fA-F]+|#\d+|lt|gt|amp|quot|apos);/g, (_, e: string) =>
    e[0] === '#' ? String.fromCodePoint(e[1] === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)) : ENT[e]);
}
const local = (n: string) => n.slice(n.indexOf(':') + 1);

export function analisar(xml: string): No {
  if (/<!DOCTYPE/i.test(xml)) throw new Error('XML com DOCTYPE não é aceito');
  const raiz: No = { nome: '#', attrs: {}, filhos: [], texto: '' };
  const pilha: No[] = [raiz];
  const re = /<!\[CDATA\[([\s\S]*?)\]\]>|<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<\/([^\s>]+)\s*>|<([^\s/>]+)((?:\s+[^\s=]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(\/?)>|([^<]+)/y;
  // sticky (/y): cada pedaço começa onde o anterior acabou. Com /g, um "<" ou "<!--" sem fechar fazia a busca
  // recomeçar em cada posição seguinte (tempo quadrático); aqui, o que não casa é XML malformado, na hora.
  while (re.lastIndex < xml.length) {
    const m = re.exec(xml);
    if (!m) throw new Error('XML malformado');
    const topo = pilha[pilha.length - 1];
    if (m[1] !== undefined) topo.texto += m[1];
    else if (m[2] !== undefined) {
      if (local(m[2]) !== topo.nome || pilha.length === 1) throw new Error('XML malformado');
      pilha.pop();
    } else if (m[3] !== undefined) {
      const attrs: Record<string, string> = {};
      for (const a of m[4].matchAll(/([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) attrs[local(a[1])] = desescapar(a[2] ?? a[3] ?? '');
      const no: No = { nome: local(m[3]), attrs, filhos: [], texto: '' };
      topo.filhos.push(no);
      if (!m[5]) pilha.push(no);
    } else if (m[6] !== undefined) topo.texto += desescapar(m[6]);
  }
  if (pilha.length !== 1) throw new Error('XML malformado');
  return raiz;
}

// Busca em profundidade pelo caminho de nomes (sem prefixo). "a/b" = b filho de algum a.
export function achar(no: No | undefined, caminho: string): No | undefined {
  return todos(no, caminho)[0];
}
export function todos(no: No | undefined, caminho: string): No[] {
  if (!no) return [];
  const [primeiro, ...resto] = caminho.split('/');
  const acc: No[] = [];
  const visitar = (n: No) => { for (const f of n.filhos) { if (f.nome === primeiro) acc.push(f); visitar(f); } };
  visitar(no);
  if (!resto.length) return acc;
  const sub = resto.join('/');
  return acc.flatMap((a) => filhosPorCaminho(a, sub));
}
function filhosPorCaminho(no: No, caminho: string): No[] {
  let atual = [no];
  for (const p of caminho.split('/')) atual = atual.flatMap((n) => n.filhos.filter((f) => f.nome === p));
  return atual;
}
export const txt = (no: No | undefined, caminho?: string) => {
  const n = caminho ? achar(no, caminho) : no;
  const t = n?.texto.trim();
  return t ? t : undefined;
};
export const soDigitos = (s: string | undefined) => (s ?? '').replace(/\D/g, '');
// CNPJ ou CPF de um nó (filho CNPJ ou CPF).
export const documento = (no: No | undefined) => {
  const f = no?.filhos.find((x) => x.nome === 'CNPJ' || x.nome === 'CPF');
  return f ? soDigitos(f.texto) || undefined : undefined;
};
