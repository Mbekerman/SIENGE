// Formatos usados no DANFE e no DANFSe. Tudo devolve '' quando não há dado; quem
// desenha decide o traço ("-") do campo vazio.

const num = (v: string) => (v === '' || v == null ? NaN : Number(v));

/** 1234.5 -> "1.234,50" (casas fixas). */
export function decimal(v: string | number, casas = 2): string {
  const n = typeof v === 'number' ? v : num(v);
  if (!Number.isFinite(n)) return '';
  const [i, d] = Math.abs(n).toFixed(casas).split('.');
  const mil = i.replace(/\B(?=(\d{3})+(?!\d))/g, '.');
  return (n < 0 ? '-' : '') + mil + (d ? ',' + d : '');
}

/** Quantidade ou valor unitário: até `max` casas, ao menos `min`. */
export function decimalVar(v: string, min = 2, max = 4): string {
  const n = num(v);
  if (!Number.isFinite(n)) return '';
  let casas = max;
  while (casas > min && Number(n.toFixed(casas - 1)) === Number(n.toFixed(casas))) casas--;
  return decimal(n, casas);
}

export const reais = (v: string | number) => {
  const d = decimal(v);
  return d ? 'R$ ' + d : '';
};
export const pct = (v: string) => {
  const d = decimal(v);
  return d ? d + '%' : '';
};

/** "2026-11-19T15:53:08-03:00" -> "19/11/2026 15:53:08" (hora do próprio XML, sem fuso). */
export function dataHora(v: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}:\d{2}:\d{2}))?/.exec(v || '');
  if (!m) return '';
  return `${m[3]}/${m[2]}/${m[1]}` + (m[4] ? ' ' + m[4] : '');
}
export const data = (v: string) => dataHora(v).slice(0, 10);
export const hora = (v: string) => dataHora(v).slice(11);

export function cnpjCpf(v: string): string {
  const d = (v || '').replace(/\D/g, '');
  if (d.length === 14) return d.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, '$1.$2.$3/$4-$5');
  if (d.length === 11) return d.replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, '$1.$2.$3-$4');
  return v || '';
}

export function cep(v: string): string {
  const d = (v || '').replace(/\D/g, '');
  return d.length === 8 ? d.replace(/^(\d{2})(\d{3})(\d{3})$/, '$1.$2-$3') : v || '';
}

export function fone(v: string): string {
  const d = (v || '').replace(/\D/g, '');
  if (d.length === 10) return d.replace(/^(\d{2})(\d{4})(\d{4})$/, '($1) $2-$3');
  if (d.length === 11) return d.replace(/^(\d{2})(\d{5})(\d{4})$/, '($1) $2-$3');
  return v || '';
}

/** Chave de 44 dígitos em 11 grupos de 4. */
export const chaveGrupos = (c: string) => (c || '').replace(/(\d{4})(?=\d)/g, '$1 ');

/** UF pelos dois primeiros dígitos do código IBGE do município. */
const UF_IBGE: Record<string, string> = {
  '11': 'RO', '12': 'AC', '13': 'AM', '14': 'RR', '15': 'PA', '16': 'AP', '17': 'TO',
  '21': 'MA', '22': 'PI', '23': 'CE', '24': 'RN', '25': 'PB', '26': 'PE', '27': 'AL', '28': 'SE', '29': 'BA',
  '31': 'MG', '32': 'ES', '33': 'RJ', '35': 'SP', '41': 'PR', '42': 'SC', '43': 'RS',
  '50': 'MS', '51': 'MT', '52': 'GO', '53': 'DF',
};
export const ufDoIbge = (cMun: string) => UF_IBGE[(cMun || '').slice(0, 2)] ?? '';

/** Junta as partes não vazias. */
export const junta = (sep: string, ...p: (string | undefined)[]) => p.filter((x) => x && x.trim()).join(sep);
