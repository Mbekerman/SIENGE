// O que sai do texto do PDF sem IA, conferido pelos dígitos verificadores: a chave de acesso (NF-e de 44 dígitos e
// NFS-e nacional de 50, as duas em módulo 11), as linhas digitáveis (FEBRABAN), os CPFs e CNPJs e o PIX copia e cola
// (CRC16). Só o que confere entra: um dígito lido errado é pior que nenhum (pedido do Moises, 25/11/2026: ler em
// cerca de 1 s quando o documento traz o código; foi aqui que o Haiku errou no teste de 23/11).
import { conferirLinha } from './boleto.ts';
import { cnpjValido, copiaColaValido, cpfValido } from './ia.ts';
import type { Boleto } from './leitura.ts';

export interface Extraido {
  chaves: string[];              // 44 (NF-e, CT-e...) ou 50 (NFS-e nacional), sem repetição
  boletos: Boleto[];             // só as linhas válidas
  documentos: string[];          // CPFs e CNPJs válidos, na ordem em que aparecem
  pix: string[];                 // copia e cola válidos
}

// Texto que vale ler: pelo menos 100 letras ou dígitos (abaixo disso é foto ou escaneado, e vai ao PDF).
export const temTexto = (t: string | null | undefined): t is string => !!t && (t.match(/[0-9A-Za-zÀ-ÿ]/g)?.length ?? 0) >= 100;

// Módulo 11 com pesos 2 a 9 da direita para a esquerda (resto 0 ou 1 dá 0), o mesmo da chave da NF-e e da NFS-e
// nacional (conferido nas 850 chaves de NFS-e recebidas em 25/11/2026).
export function dvChave(d: string): boolean {
  if (!/^\d+$/.test(d) || (d.length !== 44 && d.length !== 50)) return false;
  let soma = 0;
  for (let i = d.length - 2, peso = 2; i >= 0; i--, peso = peso === 9 ? 2 : peso + 1) soma += Number(d[i]) * peso;
  const r = soma % 11;
  return (r < 2 ? 0 : 11 - r) === Number(d[d.length - 1]);
}

const unicos = <T>(xs: T[], chave: (x: T) => string = String) => {
  const vistos = new Set<string>();
  return xs.filter((x) => { const k = chave(x); if (vistos.has(k)) return false; vistos.add(k); return true; });
};

// 200 mil caracteres cobrem as 5 páginas lidas com folga e limitam o custo das buscas num texto feito para atrasar
// (revisão de segurança do #141).
export const LIMITE_TEXTO = 200_000;

export function extrair(texto: string, referencia = new Date()): Extraido {
  const t = texto.slice(0, LIMITE_TEXTO).normalize('NFKC');

  // Só os desenhos conhecidos, cada um cercado por não dígitos: a chave inteira (44 ou 50) ou em 11 grupos de 4 (a
  // DANFE), e a linha digitável inteira ou nos campos impressos. Nada de procurar pedaços dentro de números maiores,
  // porque no texto do PDF números vizinhos ficam separados por um espaço só.
  const achar = (re: RegExp) => [...t.matchAll(re)].map((m) => m[0].replace(/\D/g, ''));
  const chaves = unicos([...achar(/(?<!\d)(?:\d{50}|\d{44})(?!\d)/g), ...achar(/(?<!\d ?)\d{4}(?: \d{4}){10}(?! ?\d)/g)]
    .filter(dvChave).filter((d) => d.length === 50 || !/^8/.test(d)));
  const linhas = [
    ...achar(/(?<!\d)(?:\d{47}|8\d{47})(?!\d)/g),
    ...achar(/(?<![\d.])\d{5}\.?\d{5} +\d{5}\.?\d{6} +\d{5}\.?\d{6} +\d +\d{14}(?!\d)/g),     // cobrança
    ...achar(/(?<![\d-])8\d{10}[- ]?\d +\d{11}[- ]?\d +\d{11}[- ]?\d +\d{11}[- ]?\d(?!\d)/g),  // arrecadação
  ];
  const boletos = unicos(linhas.map((d) => conferirLinha(d, referencia)).filter((b): b is Boleto => !!b && b.valida), (b) => b.linha);

  const documentos = unicos([
    ...[...t.matchAll(/(?<![0-9A-Z])[0-9A-Z]{2}\.[0-9A-Z]{3}\.[0-9A-Z]{3}\/[0-9A-Z]{4}-\d{2}(?!\d)/g)]
      .map((m) => m[0].replace(/[^0-9A-Z]/g, '')).filter(cnpjValido),
    ...[...t.matchAll(/(?<!\d)\d{3}\.\d{3}\.\d{3}-\d{2}(?!\d)/g)].map((m) => m[0].replace(/\D/g, '')).filter(cpfValido),
    ...[...t.matchAll(/(?<!\d)\d{14}(?!\d)/g)].map((m) => m[0]).filter(cnpjValido),
  ]);

  // O copia e cola pode quebrar de linha no PDF: tenta como está e com as quebras tiradas.
  const pix = unicos([t, t.replace(/\r?\n/g, '')].flatMap((s) => [...s.matchAll(/000201[ -~]{20,500}?6304[0-9A-F]{4}/g)].map((m) => m[0]))
    .filter(copiaColaValido));

  return { chaves, boletos, documentos, pix };
}
