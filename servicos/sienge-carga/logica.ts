// Regras do programa de carga do Sienge que não dependem de rede nem de banco (testadas em logica.test.ts).
// O programa só LÊ o Sienge: a única chamada de rede é um GET (ver index.ts).

export type Carga = {
  id: number;
  recurso: string;
  parametros: Record<string, string>;
  situacao: string;
  pedido_assincrono: string | null;
  pedacos: number | null;
  pedacos_lidos: number;
  iniciada_em: string | null;
};

export type Cota = { restante_dia: number | null; lido_em: string } | null;

export type Acao =
  | { tipo: 'pedir' }
  | { tipo: 'andamento' }
  | { tipo: 'baixar'; pedaco: number }
  | { tipo: 'concluir' }
  | { tipo: 'esperar_cota'; ate: Date };

// A cota diária de massa vira à meia-noite UTC (medido em 15 e 16/nov/2026). Esperamos 5 minutos a mais.
export function proximaVirada(agora: Date): Date {
  const d = new Date(Date.UTC(agora.getUTCFullYear(), agora.getUTCMonth(), agora.getUTCDate() + 1, 0, 5, 0));
  return d;
}

// A cota lida conta só se foi lida hoje (dia UTC); depois da virada, volta cheia.
export function restanteHoje(cota: Cota, agora: Date): number | null {
  if (!cota || cota.restante_dia === null) return null;
  const lido = new Date(cota.lido_em);
  const mesmoDia = lido.getUTCFullYear() === agora.getUTCFullYear() && lido.getUTCMonth() === agora.getUTCMonth()
    && lido.getUTCDate() === agora.getUTCDate();
  return mesmoDia ? cota.restante_dia : null;
}

// Próximo passo de uma carga de massa assíncrona. `reserva` = consultas de massa deixadas para o CRM.
export function proximaAcaoMassa(c: Carga, cota: Cota, agora: Date, reserva: number): Acao {
  const restante = restanteHoje(cota, agora);
  if (restante !== null && restante <= reserva) return { tipo: 'esperar_cota', ate: proximaVirada(agora) };
  if (!c.pedido_assincrono) return { tipo: 'pedir' };
  if (c.pedacos === null) return { tipo: 'andamento' };
  if (c.pedacos_lidos < c.pedacos) return { tipo: 'baixar', pedaco: c.pedacos_lidos + 1 };
  return { tipo: 'concluir' };
}

// Retry-After em segundos (o Sienge manda número); sem cabeçalho, 60 s.
export function esperaDoSienge(retryAfter: string | null): number {
  const n = Number(retryAfter);
  return Number.isFinite(n) && n > 0 ? Math.ceil(n) : 60;
}

const PROIBIDOS = /^(senha|password|authorization|token|user|usuario)$/i;

// Monta a consulta (caminho + parâmetros) sem nenhuma credencial. É o que se grava na camada bruta.
export function montarConsulta(caminho: string, parametros: Record<string, string>): string {
  if (!caminho.startsWith('/')) throw new Error('caminho deve começar com /');
  const chaves = Object.keys(parametros).sort();
  for (const k of chaves) if (PROIBIDOS.test(k)) throw new Error(`parâmetro proibido: ${k}`);
  const q = chaves.map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(parametros[k])}`).join('&');
  return q ? `${caminho}?${q}` : caminho;
}

// Cabeçalhos que vale guardar (cota e rastreio); nunca os de autenticação.
export function cabecalhosParaGuardar(h: Headers): Record<string, string> {
  const out: Record<string, string> = {};
  h.forEach((v, k) => {
    const n = k.toLowerCase();
    if (n.includes('ratelimit') || n === 'retry-after' || n === 'date' || n === 'content-type' || n.startsWith('x-sienge')) out[n] = v;
  });
  return out;
}
