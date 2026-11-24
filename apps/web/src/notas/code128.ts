// Código de barras CODE-128C da chave de acesso do DANFE (MOC 7.0, Anexo II, item 4 e
// Anexo III.01). Só dígitos, em pares; devolve as larguras de barra e espaço em módulos,
// começando por barra.

// Combinações 00 a 105 (105 = START C), na ordem do Anexo III.01 (B S B S B S).
const PADROES = '212222 222122 222221 121223 121322 131222 122213 122312 132212 221213 221312 231212 112232 122132 122231 113222 123122 123221 223211 221132 221231 213212 223112 312131 311222 321122 321221 312212 322112 322211 212123 212321 232121 111323 131123 131321 112313 132113 132311 211313 231113 231311 112133 112331 132131 113123 113321 133121 313121 211331 231131 213113 213311 213131 311123 311321 331121 312113 312311 332111 314111 221411 431111 111224 111422 121124 121421 141122 141221 112214 112412 122114 122411 142112 142211 241211 221114 413111 241112 134111 111242 121142 121241 114212 124112 124211 411212 421112 421211 212141 214121 412121 111143 111341 131141 114113 114311 411113 411311 113141 114131 311141 411131 211412 211214 211232'.split(' ');
const STOP = '2331112';

/** Larguras (em módulos) alternando barra e espaço, do START ao STOP, sem a zona de silêncio. */
export function code128c(digitos: string): number[] {
  if (!/^(\d\d)+$/.test(digitos)) throw new Error('CODE-128C pede quantidade par de dígitos');
  const valores = [105];
  for (let i = 0; i < digitos.length; i += 2) valores.push(Number(digitos.slice(i, i + 2)));
  const soma = valores.reduce((a, v, i) => a + v * (i === 0 ? 1 : i), 0);
  valores.push(soma % 103);
  const larguras: number[] = [];
  for (const v of valores) for (const c of PADROES[v]) larguras.push(Number(c));
  for (const c of STOP) larguras.push(Number(c));
  return larguras;
}

/** Dígito verificador do CODE-128C (para conferência em teste). */
export function verificador128c(digitos: string): number {
  let s = 105;
  for (let i = 0; i < digitos.length; i += 2) s += Number(digitos.slice(i, i + 2)) * (i / 2 + 1);
  return s % 103;
}
