// Os arquivos de um título lidos juntos (pedido do Moises, 23/nov/2026): a nota, o boleto e os anexos de um mesmo
// título viram uma leitura só. Puro (sem React nem rede) para rodar no teste do node: apps/web/testes/conjunto.test.ts.
import type { Leitura, ResultadoLeitor } from './tipos';

type Boleto = NonNullable<Leitura['boletos']>[number];
type ParcelaLida = NonNullable<Leitura['parcelas']>[number];

const centavos = (v: number) => Math.round(v * 100);
const igual = (a?: number, b?: number) => a != null && b != null && Math.abs(centavos(a) - centavos(b)) <= 1;
const brl = (v: number) => `R$ ${v.toFixed(2).replace('.', ',').replace(/\B(?=(\d{3})+(?!\d))/g, '.')}`;

/** O documento fiscal manda no conjunto; boleto e "outro" só completam. */
const PESO: Record<string, number> = { nfe: 3, nfse: 3, fatura: 3, iptu: 3, itbi: 3, darf: 3, darm: 3, dare: 3, recibo: 2, outro: 1, boleto: 1 };

/** A soma das retenções lidas (0 sem nenhuma). */
export function somaRetencoes(l: Leitura): number {
  return Object.values(l.retencoes ?? {}).reduce<number>((a, v) => a + (v && v > 0 ? v : 0), 0);
}

/** O líquido: o que a nota mostra, senão o bruto menos as retenções lidas (nulo sem retenção nem líquido). */
export function liquidoDe(l: Leitura): number | undefined {
  if (l.valor_liquido && l.valor_liquido > 0) return l.valor_liquido;
  const r = somaRetencoes(l);
  return l.valor && r > 0 ? Math.round((l.valor - r) * 100) / 100 : undefined;
}

/** O que se cobra: a soma das parcelas lidas, se todas têm valor, senão a dos boletos válidos, se todos têm. */
export function cobradoDe(l: Leitura): number | undefined {
  const ps = l.parcelas ?? [], bs = (l.boletos ?? []).filter(b => b.valida);
  const soma = (xs: (number | undefined)[]) => Math.round(xs.reduce<number>((a, v) => a + (v ?? 0), 0) * 100) / 100;
  if (ps.length && ps.every(p => p.valor && p.valor > 0)) return soma(ps.map(p => p.valor));
  if (bs.length && bs.every(b => b.valor && b.valor > 0)) return soma(bs.map(b => b.valor));
  return undefined;
}

/** Bruto, retenções, líquido e o que se cobra: os avisos quando não fecham e se há sinal de retenção não lida
 *  (cobra-se menos que o bruto e nada explica a diferença). */
export function conferirValores(l: Leitura): { avisos: string[]; retencaoSuspeita: boolean } {
  const avisos: string[] = [];
  const bruto = l.valor, ret = somaRetencoes(l), liq = liquidoDe(l), cob = cobradoDe(l);
  if (bruto && l.valor_liquido && l.valor_liquido > bruto + 0.009) avisos.push(`O líquido lido (${brl(l.valor_liquido)}) é maior que o bruto (${brl(bruto)}): confira os dois`);
  else if (bruto && l.valor_liquido && ret > 0 && !igual(bruto - ret, l.valor_liquido))
    avisos.push(`Bruto (${brl(bruto)}) menos as retenções lidas (${brl(ret)}) não dá o líquido lido (${brl(l.valor_liquido)}): confira as retenções`);
  let retencaoSuspeita = false;
  if (bruto && cob != null && !igual(cob, bruto) && !igual(cob, liq)) {
    if (cob < bruto && liq == null) {
      retencaoSuspeita = true;
      avisos.push(`As parcelas somam ${brl(cob)}, ${brl(bruto - cob)} abaixo do valor da nota (${brl(bruto)}): pode haver retenção que a leitura não achou`);
    } else avisos.push(`As parcelas somam ${brl(cob)}, mas a nota é de ${brl(bruto)}${liq != null ? ` (líquido ${brl(liq)})` : ''}: confira`);
  }
  return { avisos, retencaoSuspeita };
}

/** Para cada parcela lida, o boleto que é dela: primeiro pelo valor (até 1 centavo), no empate o de vencimento mais
 *  perto; o que sobra, pelo vencimento mais perto; sem vencimento nem valor, pela ordem. Cada boleto vai a uma
 *  parcela só. Sem parcelas lidas, os boletos são as parcelas. */
export function casarBoletos(parcelas: ParcelaLida[], boletos: Boleto[]): (Boleto | undefined)[] {
  if (!parcelas.length) return boletos.slice();
  const livres = boletos.map((_, i) => i);
  const dias = (a?: string, b?: string) => (a && b ? Math.abs(Date.parse(a) - Date.parse(b)) / 86_400_000 : Infinity);
  const venc = (b: Boleto) => (b.conferido_asaas?.ok ? b.conferido_asaas.vencimento : undefined) ?? b.vencimento;
  const valor = (b: Boleto) => (b.conferido_asaas?.ok ? b.conferido_asaas.valor : undefined) ?? b.valor;
  const out: (Boleto | undefined)[] = parcelas.map(() => undefined);
  const tomar = (pi: number, cand: number[]) => {
    if (!cand.length) return;
    const melhor = cand.reduce((m, i) => (dias(venc(boletos[i]), parcelas[pi].vencimento) < dias(venc(boletos[m]), parcelas[pi].vencimento) ? i : m));
    out[pi] = boletos[melhor];
    livres.splice(livres.indexOf(melhor), 1);
  };
  // 1. pelo valor
  parcelas.forEach((p, pi) => { if (p.valor) tomar(pi, livres.filter(i => igual(valor(boletos[i]), p.valor))); });
  // 2. pelo vencimento, quando a parcela e o boleto têm (e o valor não desmente)
  parcelas.forEach((p, pi) => {
    if (out[pi] || !p.vencimento) return;
    tomar(pi, livres.filter(i => venc(boletos[i]) && !(p.valor && valor(boletos[i]) && !igual(valor(boletos[i]), p.valor))));
  });
  // 3. pela ordem, só o que nada desmente
  parcelas.forEach((p, pi) => {
    if (out[pi]) return;
    const i = livres.find(i => !(p.valor && valor(boletos[i]) && !igual(valor(boletos[i]), p.valor)));
    if (i !== undefined) { out[pi] = boletos[i]; livres.splice(livres.indexOf(i), 1); }
  });
  return out;
}

const docDe = (r: ResultadoLeitor) => r.leitura?.emitente?.documento;

/** O conjunto: a base é o documento fiscal (o de mais peso; no empate, o primeiro), com a identificação dele; os boletos
 *  e o PIX de todos os arquivos entram (sem repetir a linha); parcelas, consumo e PIX que a base não tem vêm dos outros;
 *  e os avisos dizem quando um arquivo é de outro emitente ou de outra nota. Um arquivo só volta como está. */
export function juntarLeituras(rs: ResultadoLeitor[]): ResultadoLeitor | null {
  if (!rs.length) return null;
  if (rs.length === 1) return rs[0];
  const lidos = rs.filter(r => r.leitura);
  const base = lidos.reduce<ResultadoLeitor | null>((m, r) => (!m || (PESO[r.leitura!.tipo ?? 'outro'] ?? 1) > (PESO[m.leitura!.tipo ?? 'outro'] ?? 1) ? r : m), null) ?? rs[0];
  const outros = rs.filter(r => r !== base);
  const repetido = [...rs.flatMap(r => r.repetido_em)].filter((x, i, a) => a.findIndex(y => y.documento_id === x.documento_id) === i);
  if (!base.leitura) return { ...base, repetido_em: repetido };
  const l: Leitura = { ...base.leitura, boletos: [...(base.leitura.boletos ?? [])], avisos: [...(base.leitura.avisos ?? [])] };
  for (const r of outros) {
    const o = r.leitura;
    if (!o) { if (r.erro_leitura && !r.pede_senha) l.avisos!.push(`${r.anexo.nome}: ${r.erro_leitura}`); continue; }
    for (const b of o.boletos ?? []) if (!l.boletos!.some(x => x.linha === b.linha)) l.boletos!.push(b);
    if (!l.parcelas?.length && o.parcelas?.length) l.parcelas = o.parcelas;
    if (!l.pix?.copia_e_cola && o.pix?.copia_e_cola) l.pix = o.pix;
    if (!l.consumo && o.consumo) l.consumo = o.consumo;
    if (!l.valor && o.valor && (PESO[o.tipo ?? 'outro'] ?? 1) > 1) l.valor = o.valor;
    const d = o.emitente?.documento, db = l.emitente?.documento;
    // o beneficiário do boleto pode ser o banco ou um intermediário: o aviso é só quando o arquivo traz outro emitente
    if (d && db && d !== db && o.tipo !== 'boleto') l.avisos!.push(`${r.anexo.nome} é de outro emitente (${o.emitente?.nome ?? d}): confira se é deste título`);
    if (o.numero && l.numero && (PESO[o.tipo ?? 'outro'] ?? 1) > 1 && o.tipo === l.tipo && o.numero.replace(/^0+/, '') !== l.numero.replace(/^0+/, ''))
      l.avisos!.push(`${r.anexo.nome} é a nota ${o.numero}, não a ${l.numero}: confira se é deste título`);
    for (const a of o.avisos ?? []) l.avisos!.push(`${r.anexo.nome}: ${a}`);
  }
  return { ...base, leitura: l, repetido_em: repetido, identificacao: base.identificacao ?? outros.find(r => docDe(r) === docDe(base) && r.identificacao)?.identificacao ?? null };
}
