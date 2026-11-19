// Formatos brasileiros (diretrizes de design do BKM Terrenos, seção 3): R$ 1.234,56 e datas 06/11/2026.

/** R$ 6.800,00 (como o protótipo do ERP, função R). */
export function reais(v: number | null | undefined): string {
  if (v == null) return '—';
  return 'R$ ' + Number(v).toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/** R$ 6.800 (sem centavos, para totais por mês). */
export function reais0(v: number | null | undefined): string {
  if (v == null) return '—';
  return 'R$ ' + Number(v).toLocaleString('pt-BR', { maximumFractionDigits: 0 });
}

/** 'AAAA-MM-DD' (ou timestamp) → 21/11/2026, sem fuso. */
export function data(s: string | null | undefined): string {
  if (!s) return '—';
  const [y, m, d] = s.slice(0, 10).split('-');
  return `${d}/${m}/${y}`;
}

/** 'AAAA-MM-DD' → 21/11 */
export function dataCurta(s: string | null | undefined): string {
  return s ? data(s).slice(0, 5) : '—';
}

const MES = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
/** competência 'AAAA-MM-01' → nov/2026 */
export function mes(s: string | null | undefined): string {
  if (!s) return '—';
  const [y, m] = s.split('-');
  return `${MES[Number(m) - 1]}/${y}`;
}

/** Data e hora local: 18/11/2026, 15:42 */
export function dataHora(s: string | null | undefined): string {
  if (!s) return '—';
  return new Date(s).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

/** CPF ou CNPJ só com dígitos → com pontuação. */
export function documento(s: string | null | undefined): string {
  if (!s) return '';
  if (s.length === 14) return s.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, '$1.$2.$3/$4-$5');
  if (s.length === 11) return s.replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, '$1.$2.$3-$4');
  return s;
}

/** Hoje em AAAA-MM-DD, no horário local. */
export function hojeISO(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/** Busca sem acento e sem diferença de maiúsculas. */
export function normal(s: string | null | undefined): string {
  return (s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
}

/** "1.234,56", "1234.56" ou "R$ 1.234" → 1234.56; vazio ou inválido → null. */
export function lerReais(s: string): number | null {
  let t = s.replace(/[^\d,.-]/g, '');
  if (!t) return null;
  if (t.includes(',')) t = t.replace(/\./g, '').replace(',', '.');
  else if ((t.match(/\./g) ?? []).length > 1 || /\.\d{3}$/.test(t)) t = t.replace(/\./g, '');
  const n = Number(t);
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : null;
}

/** Divide o valor em n parcelas iguais, o resto dos centavos na última (como erp._criar_titulo). */
export function dividir(total: number, n: number): number[] {
  if (n <= 0) return [];
  const p = Math.trunc((total / n) * 100) / 100;
  return Array.from({ length: n }, (_, i) => (i < n - 1 ? p : Math.round((total - p * (n - 1)) * 100) / 100));
}
