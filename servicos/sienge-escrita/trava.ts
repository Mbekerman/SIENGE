// Trava de empresa para toda gravação no Sienge (pedido do Moises, 17/nov/2026).
//
// O usuário de API do Sienge não tem trava por empresa: a mesma credencial grava em todas,
// inclusive na Muchmore (ver docs/tecnico/04-integracao-sienge.md, "Área de testes"). Por isso
// a trava mora no nosso código. Todo POST, PUT, PATCH ou DELETE ao Sienge passa antes por
// conferirGravacao(); se ela recusar, a chamada não sai.
//
// Regra:
// - Fora de produção (desenvolvimento, teste, qualquer valor diferente de "producao", inclusive
//   ambiente não informado), só se grava nas empresas de teste: hoje só a 11, "BKM TESTES - NAO USAR".
// - Em produção, nunca se grava numa empresa de teste nem numa empresa fora do ERP (Muchmore, 1).
// - A empresa vem do corpo (debtorId ou companyId) ou é informada por quem chama, quando a rota
//   não a traz no corpo (PATCH de parcela, anexo...). Sem empresa conhecida, recusa.
//
// Funções puras, sem rede nem banco (testadas em trava.test.ts).

export const EMPRESAS_TESTE = [11] as const;
export const EMPRESAS_FORA = [1] as const; // Muchmore: não entra no ERP (Moises, 15/11/2026)

export type Ambiente = 'producao' | string | undefined;

export type Pedido = {
  metodo: string;
  caminho: string;
  corpo?: unknown;
  empresa?: number | null; // obrigatória quando o corpo não traz debtorId nem companyId
};

export type Decisao = { ok: true; empresa: number | null } | { ok: false; motivo: string };

const LEITURA = new Set(['GET', 'HEAD', 'OPTIONS']);

function inteiro(v: unknown): number | null {
  if (typeof v === 'number' && Number.isInteger(v)) return v;
  if (typeof v === 'string' && /^\d+$/.test(v.trim())) return Number(v.trim());
  return null;
}

// Empresa do corpo: debtorId (títulos a pagar) ou companyId (o resto). Se o corpo trouxer as
// duas e elas divergirem, ou se o corpo for uma lista com empresas diferentes, devolve 'conflito'.
export function empresaDoCorpo(corpo: unknown): number | null | 'conflito' {
  const itens = Array.isArray(corpo) ? corpo : [corpo];
  let achada: number | null = null;
  for (const it of itens) {
    if (!it || typeof it !== 'object') continue;
    const o = it as Record<string, unknown>;
    for (const campo of ['debtorId', 'companyId']) {
      if (!(campo in o)) continue;
      const e = inteiro(o[campo]);
      if (e === null) return 'conflito';
      if (achada !== null && achada !== e) return 'conflito';
      achada = e;
    }
  }
  return achada;
}

export function conferirGravacao(p: Pedido, ambiente: Ambiente): Decisao {
  const metodo = p.metodo.toUpperCase();
  if (LEITURA.has(metodo)) return { ok: true, empresa: null };

  const doCorpo = empresaDoCorpo(p.corpo);
  if (doCorpo === 'conflito') return { ok: false, motivo: 'empresa ilegível ou divergente no corpo' };
  const informada = p.empresa ?? null;
  if (doCorpo !== null && informada !== null && doCorpo !== informada) {
    return { ok: false, motivo: `empresa do corpo (${doCorpo}) diferente da informada (${informada})` };
  }
  const empresa = doCorpo ?? informada;
  if (empresa === null) return { ok: false, motivo: `${metodo} ${p.caminho} sem empresa conhecida` };

  const teste = (EMPRESAS_TESTE as readonly number[]).includes(empresa);
  if (ambiente === 'producao') {
    if (teste) return { ok: false, motivo: `empresa ${empresa} é de teste; produção não grava nela` };
    if ((EMPRESAS_FORA as readonly number[]).includes(empresa)) {
      return { ok: false, motivo: `empresa ${empresa} está fora do ERP` };
    }
    return { ok: true, empresa };
  }
  if (!teste) {
    return { ok: false, motivo: `fora de produção só se grava nas empresas de teste (${EMPRESAS_TESTE.join(', ')}); pedida a ${empresa}` };
  }
  return { ok: true, empresa };
}
