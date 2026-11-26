// Filtro das listas com busca (components/Escolha.tsx): todas as palavras, sem acento nem maiúscula.
export interface OpcaoEscolha { id: string; nome: string; sub?: string }

const sem = (s: string) => s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();

export function filtrar(opcoes: OpcaoEscolha[], txt: string): OpcaoEscolha[] {
  const ps = sem(txt).split(/\s+/).filter(Boolean);
  if (!ps.length) return opcoes;
  return opcoes.filter(o => { const a = sem(`${o.nome} ${o.sub ?? ''}`); return ps.every(p => a.includes(p)); });
}

