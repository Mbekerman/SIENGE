// A resposta do leitor em duas etapas (?etapas=1, servicos/leitor/rotas.ts): uma linha JSON por etapa. Puro (sem rede
// nem React) para o teste do node: apps/web/testes/conjunto.test.ts.
import type { ResultadoLeitor } from './tipos';

export type Etapa = { previa?: ResultadoLeitor; resultado?: ResultadoLeitor; erro?: string };

/** As linhas da resposta em duas etapas: a prévia vai para `aoPrevia`, o resultado é o que volta, e { erro } vira erro. */
export async function lerEtapas(corpo: ReadableStream<Uint8Array>, aoPrevia: (r: ResultadoLeitor) => void): Promise<ResultadoLeitor> {
  const leitor = corpo.getReader(), dec = new TextDecoder();
  let resto = '';
  const tratar = (l: string): ResultadoLeitor | null => {
    if (!l.trim()) return null;
    const e = JSON.parse(l) as Etapa;
    if (e.erro) throw new Error(e.erro);
    if (e.previa) { aoPrevia(e.previa); return null; }
    return e.resultado ?? null;
  };
  for (;;) {
    const { done, value } = await leitor.read().catch(() => { throw new Error('A conexão com o leitor caiu. Tente de novo.'); });
    resto += dec.decode(value ?? new Uint8Array(), { stream: !done });
    const linhas = resto.split('\n');
    resto = linhas.pop() ?? '';
    for (const l of linhas) { const r = tratar(l); if (r) return r; }
    if (done) { const r = tratar(resto); if (r) return r; throw new Error('O leitor não respondeu a leitura'); }
  }
}
