// Trava de toda gravação no Sienge (pedido do Moises, 17/nov/2026; S-120 e S-121 aprovadas por ele no mesmo dia).
//
// O usuário de API do Sienge não tem trava por empresa: a mesma credencial grava em todas,
// inclusive na Muchmore (docs/tecnico/04-integracao-sienge.md, "Área de testes"). Por isso a trava
// mora no nosso código. Todo POST, PUT, PATCH ou DELETE ao Sienge passa antes por gravarComTrava();
// se ela recusar, a chamada não sai.
//
// Regras:
// 1. Ambiente: só a palavra exata "producao" é produção. Qualquer outro valor, inclusive ausente, é teste.
// 2. Credor (rotas /creditors): o credor vale para todas as empresas, então não tem empresa para conferir.
//    - PIX e conta bancária de credor nunca se gravam pela API, em ambiente nenhum (regra de 6/nov/2026).
//    - Em teste, nenhuma gravação em credor. O credor de teste é criado à mão, pela tela.
//    - Em produção, só a inclusão de credor novo (POST /creditors); o resto do cadastro é pela tela.
// 3. Registro que já existe (rota com id: parcela, PIX ou boleto da parcela, anexo, autorizar, DELETE...):
//    a empresa vem do próprio registro, lida no Sienge antes da gravação (lerEmpresa), nunca só do que
//    quem chama declara. Se quem chama também informar a empresa e ela divergir, recusa. Recurso sem
//    leitura conhecida recusa (hoje só /bills tem). Em teste, o registro também tem de estar na lista
//    dos criados pelo próprio teste (criadosPeloTeste), para um id digitado errado não alcançar
//    um registro de outra empresa nem um registro antigo da 11.
// 4. Registro novo (POST na coleção, sem id): a empresa vem do corpo (debtorId ou companyId).
//    Em teste, o credor do corpo (creditorId) tem de ser um credor de teste.
// 5. Empresa: em teste, só as empresas de teste (hoje a 11). Em produção, nunca as de teste nem as
//    fora do ERP (Muchmore, 1). Sem empresa conhecida, ou com empresas divergentes, recusa.
//
// conferirGravacao() é pura (testada em trava.test.ts); gravarComTrava() lê a empresa do registro com a
// função que recebe, chama conferirGravacao() e, se passar, envia ela mesma o pedido conferido.

export const EMPRESAS_TESTE = [11] as const;
export const EMPRESAS_FORA = [1] as const; // Muchmore: não entra no ERP (Moises, 15/11/2026)

export type Ambiente = string | undefined;

export type Pedido = {
  metodo: string;
  caminho: string; // sem a base, ex.: /bills/8547/installments/1/payment-information/pix
  corpo?: unknown;
  empresa?: number | null; // a que quem chama declara; nunca basta sozinha num registro existente
};

export type Contexto = {
  empresaDoRegistro?: number | null; // lida no Sienge para o registro do caminho
  criadosPeloTeste?: ReadonlySet<string>; // chaves "recurso:id", ex.: "bills:8547"
  credoresTeste?: ReadonlySet<number>;
};

export type Decisao = { ok: true; empresa: number | null } | { ok: false; motivo: string };

const LEITURA = new Set(['GET', 'HEAD', 'OPTIONS']);

export function ehProducao(ambiente: Ambiente): boolean {
  return ambiente === 'producao';
}

function inteiro(v: unknown): number | null {
  if (typeof v === 'number' && Number.isInteger(v)) return v;
  if (typeof v === 'string' && /^\d+$/.test(v.trim())) return Number(v.trim());
  return null;
}

function semConsulta(caminho: string): string {
  return caminho.split('?')[0].replace(/\/+$/, '');
}

// Recurso e id do registro do caminho (/bills/8547/... → bills, 8547). Sem id → registro novo.
export function registroDoCaminho(caminho: string): { recurso: string; id: string } | null {
  const partes = semConsulta(caminho).split('/').filter(Boolean);
  if (partes.length < 2) return null;
  return { recurso: partes[0], id: partes[1] };
}

// Empresa do corpo: debtorId (títulos a pagar) ou companyId (o resto). Divergente ou ilegível → 'conflito'.
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

function credoresDoCorpo(corpo: unknown): (number | null)[] {
  const itens = Array.isArray(corpo) ? corpo : [corpo];
  const out: (number | null)[] = [];
  for (const it of itens) {
    if (it && typeof it === 'object' && 'creditorId' in (it as object)) out.push(inteiro((it as Record<string, unknown>).creditorId));
  }
  return out;
}

function conferirEmpresa(empresa: number, ambiente: Ambiente): Decisao {
  const teste = (EMPRESAS_TESTE as readonly number[]).includes(empresa);
  if (ehProducao(ambiente)) {
    if (teste) return { ok: false, motivo: `empresa ${empresa} é de teste; produção não grava nela` };
    if ((EMPRESAS_FORA as readonly number[]).includes(empresa)) return { ok: false, motivo: `empresa ${empresa} está fora do ERP` };
    return { ok: true, empresa };
  }
  if (!teste) return { ok: false, motivo: `fora de produção só se grava nas empresas de teste (${EMPRESAS_TESTE.join(', ')}); pedida a ${empresa}` };
  return { ok: true, empresa };
}

function conferirCredor(p: Pedido, metodo: string, ambiente: Ambiente): Decisao {
  const partes = semConsulta(p.caminho).split('/').filter(Boolean);
  if (partes.some((x) => x === 'pix-informations' || x === 'bank-informations')) {
    return { ok: false, motivo: 'PIX e conta bancária de credor não se gravam pela API' };
  }
  if (!ehProducao(ambiente)) return { ok: false, motivo: 'em teste não se grava em credor (o credor de teste é criado pela tela)' };
  if (metodo === 'POST' && partes.length === 1) return { ok: true, empresa: null };
  return { ok: false, motivo: `${metodo} ${p.caminho}: só a inclusão de credor novo é feita pela API` };
}

export function conferirGravacao(p: Pedido, ambiente: Ambiente, ctx: Contexto = {}): Decisao {
  const metodo = p.metodo.toUpperCase();
  if (LEITURA.has(metodo)) return { ok: true, empresa: null };

  const reg = registroDoCaminho(p.caminho);
  const recurso = reg?.recurso ?? semConsulta(p.caminho).split('/').filter(Boolean)[0];
  if (recurso === 'creditors') return conferirCredor(p, metodo, ambiente);

  const doCorpo = empresaDoCorpo(p.corpo);
  if (doCorpo === 'conflito') return { ok: false, motivo: 'empresa ilegível ou divergente no corpo' };
  const informada = p.empresa ?? null;
  if (doCorpo !== null && informada !== null && doCorpo !== informada) {
    return { ok: false, motivo: `empresa do corpo (${doCorpo}) diferente da informada (${informada})` };
  }

  let empresa: number | null;
  if (reg) {
    // registro que já existe: vale a empresa lida nele
    const doRegistro = ctx.empresaDoRegistro ?? null;
    if (doRegistro === null) return { ok: false, motivo: `${metodo} ${p.caminho}: empresa do registro não lida no Sienge` };
    const declarada = doCorpo ?? informada;
    if (declarada !== null && declarada !== doRegistro) {
      return { ok: false, motivo: `empresa declarada (${declarada}) diferente da do registro (${doRegistro})` };
    }
    if (!ehProducao(ambiente) && !(ctx.criadosPeloTeste?.has(`${reg.recurso}:${reg.id}`) ?? false)) {
      return { ok: false, motivo: `${reg.recurso} ${reg.id} não foi criado pelo teste` };
    }
    empresa = doRegistro;
  } else {
    empresa = doCorpo ?? informada;
    if (empresa === null) return { ok: false, motivo: `${metodo} ${p.caminho} sem empresa conhecida` };
    if (!ehProducao(ambiente)) {
      const credores = credoresDoCorpo(p.corpo);
      if (recurso === 'bills' && credores.length === 0) return { ok: false, motivo: 'título novo sem creditorId' };
      for (const c of credores) {
        if (c === null || !(ctx.credoresTeste?.has(c) ?? false)) return { ok: false, motivo: `credor ${c ?? '?'} não é credor de teste` };
      }
    }
  }
  return conferirEmpresa(empresa, ambiente);
}

// Leitura da empresa de um registro existente, por recurso. Recurso fora da lista → sem leitura → recusa.
export const LEITURA_EMPRESA: Record<string, { caminho: (id: string) => string; campo: string }> = {
  bills: { caminho: (id) => `/bills/${encodeURIComponent(id)}`, campo: 'debtorId' },
};

export type LerJson = (caminho: string) => Promise<unknown>;

// Quem grava é a própria trava, a partir do pedido conferido (S-123): o adaptador não passa uma
// chamada pronta, que poderia apontar para outro id; passa só a função que envia método, caminho e corpo.
export type Enviar<T> = (metodo: string, caminho: string, corpo: unknown) => Promise<T>;

export async function gravarComTrava<T>(
  p: Pedido,
  ambiente: Ambiente,
  ler: LerJson,
  enviar: Enviar<T>,
  ctx: Omit<Contexto, 'empresaDoRegistro'> = {},
): Promise<T> {
  let empresaDoRegistro: number | null = null;
  const reg = registroDoCaminho(p.caminho);
  if (!LEITURA.has(p.metodo.toUpperCase()) && reg && reg.recurso !== 'creditors') {
    const l = LEITURA_EMPRESA[reg.recurso];
    if (l) {
      const r = await ler(l.caminho(reg.id));
      empresaDoRegistro = r && typeof r === 'object' ? inteiro((r as Record<string, unknown>)[l.campo]) : null;
    }
  }
  const d = conferirGravacao(p, ambiente, { ...ctx, empresaDoRegistro });
  if (!d.ok) throw new Error(`trava do Sienge: ${d.motivo}`);
  return await enviar(p.metodo.toUpperCase(), p.caminho, p.corpo);
}
