// Leitor de XML mínimo para as notas fiscais (NF-e e NFS-e), igual no navegador e no Node.
// Só o que esses XMLs usam: elementos, atributos, texto, CDATA, comentários e entidades.
// Ignora o prefixo de namespace (o nome do elemento é o local). Não executa nada e não
// resolve DTD nem entidades externas: quem chega aqui é XML de terceiro (o emitente).

export type No = { nome: string; atr: Record<string, string>; filhos: No[]; texto: string };

const ENT: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

function decodifica(s: string): string {
  if (s.indexOf('&') < 0) return s;
  return s.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/g, (m, e: string) => {
    if (e[0] === '#') {
      const n = e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(n) && n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : m;
    }
    return ENT[e] ?? m;
  });
}

const local = (n: string) => {
  const i = n.indexOf(':');
  return i < 0 ? n : n.slice(i + 1);
};

/** Lê o XML e devolve o elemento raiz. Lança erro em XML malformado. */
export function lerXml(xml: string): No {
  const raiz: No = { nome: '#doc', atr: {}, filhos: [], texto: '' };
  const pilha: No[] = [raiz];
  let i = 0;
  const L = xml.length;
  while (i < L) {
    const lt = xml.indexOf('<', i);
    if (lt < 0) {
      pilha[pilha.length - 1].texto += decodifica(xml.slice(i));
      break;
    }
    if (lt > i) pilha[pilha.length - 1].texto += decodifica(xml.slice(i, lt));
    if (xml.startsWith('<!--', lt)) {
      const f = xml.indexOf('-->', lt + 4);
      if (f < 0) throw new Error('XML: comentário sem fim');
      i = f + 3;
    } else if (xml.startsWith('<![CDATA[', lt)) {
      const f = xml.indexOf(']]>', lt + 9);
      if (f < 0) throw new Error('XML: CDATA sem fim');
      pilha[pilha.length - 1].texto += xml.slice(lt + 9, f);
      i = f + 3;
    } else if (xml[lt + 1] === '?' || xml[lt + 1] === '!') {
      const f = xml.indexOf('>', lt);
      if (f < 0) throw new Error('XML: declaração sem fim');
      i = f + 1;
    } else if (xml[lt + 1] === '/') {
      const f = xml.indexOf('>', lt);
      if (f < 0) throw new Error('XML: fechamento sem fim');
      const nome = local(xml.slice(lt + 2, f).trim());
      const topo = pilha.pop();
      if (!topo || topo.nome !== nome || pilha.length === 0) throw new Error(`XML: </${nome}> fora de ordem`);
      i = f + 1;
    } else {
      // abertura: lê nome e atributos respeitando aspas
      let j = lt + 1;
      while (j < L && !/[\s/>]/.test(xml[j])) j++;
      const no: No = { nome: local(xml.slice(lt + 1, j)), atr: {}, filhos: [], texto: '' };
      if (!no.nome) throw new Error('XML: elemento sem nome');
      let vazio = false;
      for (;;) {
        while (j < L && /\s/.test(xml[j])) j++;
        if (j >= L) throw new Error('XML: elemento sem fim');
        if (xml[j] === '>') { j++; break; }
        if (xml[j] === '/' && xml[j + 1] === '>') { vazio = true; j += 2; break; }
        const eq = xml.indexOf('=', j);
        if (eq < 0) throw new Error('XML: atributo malformado');
        const an = xml.slice(j, eq).trim();
        let k = eq + 1;
        while (/\s/.test(xml[k])) k++;
        const q = xml[k];
        if (q !== '"' && q !== "'") throw new Error('XML: atributo sem aspas');
        const fq = xml.indexOf(q, k + 1);
        if (fq < 0) throw new Error('XML: atributo sem fim');
        no.atr[local(an)] = decodifica(xml.slice(k + 1, fq));
        j = fq + 1;
      }
      pilha[pilha.length - 1].filhos.push(no);
      if (!vazio) pilha.push(no);
      i = j;
    }
  }
  if (pilha.length !== 1) throw new Error('XML: elementos sem fechamento');
  const r = raiz.filhos[0];
  if (!r) throw new Error('XML vazio');
  return r;
}

/** Primeiro descendente pelo caminho "a/b/c" (filhos diretos em cada passo). */
export function no(el: No | undefined, caminho: string): No | undefined {
  let at = el;
  for (const p of caminho.split('/')) {
    if (!at) return undefined;
    if (!p) continue;
    at = at.filhos.find((f) => f.nome === p);
  }
  return at;
}

/** Todos os filhos com o nome no fim do caminho. */
export function nos(el: No | undefined, caminho: string): No[] {
  const partes = caminho.split('/');
  const ult = partes.pop()!;
  const pai = partes.length ? no(el, partes.join('/')) : el;
  return pai ? pai.filhos.filter((f) => f.nome === ult) : [];
}

/** Texto do elemento no caminho, aparado; '' quando não existe. */
export function tx(el: No | undefined, caminho: string): string {
  return (no(el, caminho)?.texto ?? '').trim();
}

/** Primeiro descendente com esse nome, em qualquer profundidade. */
export function busca(el: No | undefined, nome: string): No | undefined {
  if (!el) return undefined;
  for (const f of el.filhos) {
    if (f.nome === nome) return f;
    const r = busca(f, nome);
    if (r) return r;
  }
  return undefined;
}
