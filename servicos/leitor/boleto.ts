// Conferência da linha digitável pelos dígitos verificadores (regras da FEBRABAN), sem rede.
// Cobrança: 47 dígitos (ou o código de barras de 44 começando por banco). Arrecadação (concessionária, tributo):
// 48 dígitos começando por 8 (ou o código de barras de 44 começando por 8).
import type { Boleto } from './leitura.ts';

function mod10(n: string): number {
  let soma = 0, peso = 2;
  for (let i = n.length - 1; i >= 0; i--) {
    let p = Number(n[i]) * peso;
    if (p > 9) p = Math.floor(p / 10) + (p % 10);
    soma += p; peso = peso === 2 ? 1 : 2;
  }
  return (10 - (soma % 10)) % 10;
}

function somaMod11(n: string): number {
  let soma = 0, peso = 2;
  for (let i = n.length - 1; i >= 0; i--) { soma += Number(n[i]) * peso; peso = peso === 9 ? 2 : peso + 1; }
  return soma % 11;
}
// DV geral do código de barras da cobrança: 0, 10 e 11 viram 1.
function dvCobranca(n: string): number { const d = 11 - somaMod11(n); return d === 0 || d >= 10 ? 1 : d; }
// DV da arrecadação em módulo 11: resto 0 ou 1 vira 0.
function dvArrecadacao11(n: string): number { const r = somaMod11(n); return r === 0 || r === 1 ? 0 : 11 - r; }

const DIA = 86_400_000;
// Fator de vencimento: até 21/2/2025 contava de 7/10/1997; o fator 1000 recomeçou em 22/2/2025. Fica a data mais
// perto da referência (hoje, ou a emissão da nota).
function vencimentoPorFator(fator: number, referencia: Date): string | undefined {
  if (!fator) return undefined;
  const antiga = Date.UTC(1997, 9, 7) + fator * DIA;
  const nova = fator >= 1000 ? Date.UTC(2025, 1, 22) + (fator - 1000) * DIA : NaN;
  const ref = referencia.getTime();
  const t = Number.isNaN(nova) || Math.abs(antiga - ref) < Math.abs(nova - ref) ? antiga : nova;
  return new Date(t).toISOString().slice(0, 10);
}

const valor = (s: string) => { const v = Number(s) / 100; return v > 0 ? v : undefined; };

export function conferirLinha(entrada: string, referencia = new Date()): Boleto | null {
  const d = entrada.replace(/\D/g, '');
  if (d.length === 47) return cobrancaLinha(d, referencia);
  if (d.length === 48 && d[0] === '8') return arrecadacaoLinha(d);
  if (d.length === 44) return d[0] === '8' ? arrecadacaoBarras(d, d) : cobrancaBarras(d, d, referencia);
  return null;
}

function cobrancaLinha(l: string, ref: Date): Boleto {
  const camposOk = mod10(l.slice(0, 9)) === Number(l[9]) && mod10(l.slice(10, 20)) === Number(l[20])
                && mod10(l.slice(21, 31)) === Number(l[31]);
  const barras = l.slice(0, 4) + l[32] + l.slice(33, 47) + l.slice(4, 9) + l.slice(10, 20) + l.slice(21, 31);
  const b = cobrancaBarras(barras, l, ref);
  return { ...b, valida: camposOk && b.valida };
}
function cobrancaBarras(c: string, linha: string, ref: Date): Boleto {
  const valida = dvCobranca(c.slice(0, 4) + c.slice(5)) === Number(c[4]);
  return { linha, valida, banco: c.slice(0, 3), vencimento: vencimentoPorFator(Number(c.slice(5, 9)), ref), valor: valor(c.slice(9, 19)) };
}

function arrecadacaoLinha(l: string): Boleto {
  const blocos = [0, 12, 24, 36].map((i) => l.slice(i, i + 12));
  const usa10 = l[2] === '6' || l[2] === '7';
  const camposOk = blocos.every((b) => (usa10 ? mod10(b.slice(0, 11)) : dvArrecadacao11(b.slice(0, 11))) === Number(b[11]));
  const b = arrecadacaoBarras(blocos.map((x) => x.slice(0, 11)).join(''), l);
  return { ...b, valida: camposOk && b.valida };
}
function arrecadacaoBarras(c: string, linha: string): Boleto {
  const id = c[2];
  const resto = c.slice(0, 3) + c.slice(4);
  const dv = id === '6' || id === '7' ? mod10(resto) : id === '8' || id === '9' ? dvArrecadacao11(resto) : -1;
  // 6 e 8: valor efetivo em reais; 7 e 9: valor de referência (não é dinheiro), fica sem valor.
  return { linha, valida: dv === Number(c[3]), valor: id === '6' || id === '8' ? valor(c.slice(4, 15)) : undefined };
}
