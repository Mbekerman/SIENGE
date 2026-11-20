// Limite simples por pessoa, em memória (cada instância do Cloud Run conta a sua; com no máximo 2 instâncias, basta).
export class Limite {
  private vezes = new Map<string, number[]>();
  private max: number;
  private janelaMs: number;
  constructor(max: number, janelaMs: number) { this.max = max; this.janelaMs = janelaMs; }
  passa(quem: string, agora = Date.now()): boolean {
    const v = (this.vezes.get(quem) ?? []).filter((t) => agora - t < this.janelaMs);
    if (v.length >= this.max) { this.vezes.set(quem, v); return false; }
    v.push(agora); this.vezes.set(quem, v);
    if (this.vezes.size > 5000) for (const [k, t] of this.vezes) if (!t.some((x) => agora - x < this.janelaMs)) this.vezes.delete(k);
    return true;
  }
}
