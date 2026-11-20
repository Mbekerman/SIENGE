// Formato da leitura que o leitor grava em erp.anexos.leitura (api.gravar_leitura) e que a tela usa para preencher o
// Lançar título. Tudo opcional: o que o leitor não achou fica de fora, nunca vira zero (regra "não informado").
// Valores em reais com ponto decimal; datas em AAAA-MM-DD; documentos só com os dígitos.

export type TipoDocumento = 'nfe' | 'nfse' | 'fatura' | 'boleto' | 'recibo' | 'outro';

export interface Pessoa { documento?: string; documento_mascara?: string; nome?: string }  // máscara: dígitos e * (ia.ts)

export interface Parcela { numero?: string; vencimento?: string; valor?: number; pix_copia_cola?: string }

export interface Boleto {
  linha: string;                 // só dígitos, 47 (cobrança) ou 48 (arrecadação/concessionária)
  valida: boolean;               // dígitos verificadores conferidos aqui
  valor?: number;                // o que a linha diz (zero na linha vira "não informado")
  vencimento?: string;           // pelo fator de vencimento (só cobrança)
  banco?: string;                // código do banco (só cobrança)
  conferido_asaas?: {            // a consulta ao Asaas, quando houve
    ok: boolean; valor?: number; vencimento?: string; beneficiario?: string; beneficiario_documento?: string; erro?: string;
  };
}

export interface Retencoes { iss?: number; irrf?: number; inss?: number; pis?: number; cofins?: number; csll?: number }

export interface Leitura {
  origem: 'xml' | 'ia';
  modelo?: string;                // o modelo de IA, quando origem = ia
  formato?: string;               // NF-e 4.00, NFS-e Nacional...
  tipo?: TipoDocumento;
  emitente?: Pessoa;
  tomador?: Pessoa;
  numero?: string;
  serie?: string;
  chave_acesso?: string;
  emissao?: string;
  competencia?: string;           // AAAA-MM
  valor?: number;                 // valor bruto do documento
  valor_liquido?: number;
  retencoes?: Retencoes;
  descricao?: string;
  parcelas?: Parcela[];
  boletos?: Boleto[];
  pix?: { chave?: string; copia_e_cola?: string };
  consumo?: { instalacao?: string; referencia?: string; vencimento?: string };
  avisos?: string[];
}

export const soDigitos = (s: unknown) => (typeof s === 'string' ? s.replace(/\D/g, '') : '');

export function numero(s: unknown): number | undefined {
  if (typeof s === 'number') return Number.isFinite(s) ? s : undefined;
  if (typeof s !== 'string' || !s.trim()) return undefined;
  const n = Number(s.trim());
  return Number.isFinite(n) ? n : undefined;
}

export function data(s: unknown): string | undefined {
  if (typeof s !== 'string') return undefined;
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s.trim());
  return m ? `${m[1]}-${m[2]}-${m[3]}` : undefined;
}

// Tira os campos vazios (undefined, '', [], {}) para a leitura gravada ficar limpa.
export function limpar<T>(v: T): T {
  if (Array.isArray(v)) return v.map(limpar).filter((x) => !vazio(x)) as T;
  if (v && typeof v === 'object') {
    const o: Record<string, unknown> = {};
    for (const [k, x] of Object.entries(v)) { const y = limpar(x); if (!vazio(y)) o[k] = y; }
    return o as T;
  }
  return v;
}
function vazio(x: unknown) {
  return x === undefined || x === null || x === '' || (Array.isArray(x) && x.length === 0)
    || (typeof x === 'object' && x !== null && !Array.isArray(x) && Object.keys(x).length === 0);
}
