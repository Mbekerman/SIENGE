// Previsão mês a mês da conta recorrente (Moises, 23/11/2026): um valor por mês no lugar do valor igual. O banco
// confere (migration 20261123000200_erp_conta_calendario.sql): no contrato, a soma bate com o valor; no consumo, os meses
// de cada ano não passam do teto; depois de aprovada, mês que já passou não muda. Aqui ficam as contas da tela, em
// centavos inteiros, e o quadro dos meses.
import { Alerta, Ic } from '../components/Comum';
import { lerReais, mes as nomeMes, reais } from '../lib/format';

/** Meses (AAAA-MM-01) → valor digitado. */
export type Meses = Record<string, string>;

const mesDe = (d: string) => `${d.slice(0, 7)}-01`;
const somaMes = (m: string, n: number) => {
  const [y, mm] = m.split('-').map(Number);
  const t = y * 12 + (mm - 1) + n;
  return `${Math.floor(t / 12)}-${String((t % 12) + 1).padStart(2, '0')}-01`;
};
export const centavos = (s: string | undefined) => Math.round((lerReais(s ?? '') ?? 0) * 100);
const txt = (c: number) => reais(c / 100);

/** Os meses do calendário: da vigência; sem fim, 12 meses a partir do maior entre o início e o mês de hoje. */
export function mesesDaVigencia(inicio: string, fim: string, hoje: string): string[] {
  if (!inicio) return [];
  if (fim && fim >= inicio) {
    const l: string[] = [];
    for (let m = mesDe(inicio); m <= mesDe(fim) && l.length < 600; m = somaMes(m, 1)) l.push(m);
    return l;
  }
  const de = mesDe(inicio) > mesDe(hoje) ? mesDe(inicio) : mesDe(hoje);
  return Array.from({ length: 12 }, (_, i) => somaMes(de, i));
}

/** Divide c centavos em n meses iguais; o centavo que sobra vai para os primeiros. */
export function igual(c: number, n: number): number[] {
  if (n <= 0) return [];
  const b = Math.floor(c / n), r = c - b * n;
  return Array.from({ length: n }, (_, i) => b + (i < r ? 1 : 0));
}

/** O calendário completo para os meses da vigência: o que já foi digitado e, no que falta, o valor igual. */
export function completar(atual: Meses | null, lista: string[], igualPorMes: (i: number) => number): Meses {
  const n: Meses = {};
  lista.forEach((m, i) => { n[m] = atual && atual[m] != null ? atual[m] : txt(igualPorMes(i)); });
  return n;
}

/** Ajusta o calendário para somar alvo: a diferença vai para os meses que ainda mudam, na proporção do valor de cada um
 *  (todos zero: igual), e o centavo que sobra no último. Nulo = não dá (a diferença tira mais do que eles têm). */
export function ajustarCalendario(m: Meses, alvo: number, travaAntes: string | null): Meses | null {
  const chaves = Object.keys(m).sort();
  const abertos = chaves.filter(k => !travaAntes || k >= travaAntes);
  if (!abertos.length) return null;
  const soma = chaves.reduce((a, k) => a + centavos(m[k]), 0);
  const dif = alvo - soma;
  const base = abertos.reduce((a, k) => a + centavos(m[k]), 0);
  if (base + dif < 0) return null;
  const novo = { ...m };
  let usado = 0;
  abertos.forEach((k, i) => {
    const v = centavos(m[k]);
    const parte = i === abertos.length - 1 ? dif - usado
      : base > 0 ? Math.round((dif * v) / base) : Math.round(dif / abertos.length);
    usado += parte;
    novo[k] = txt(v + parte);
  });
  if (abertos.some(k => centavos(novo[k]) < 0)) return null;
  return novo;
}

export function Calendario({ meses, mudar, travaAntes, tipo, valorContrato, teto, ajustarContrato }: {
  meses: Meses; mudar: (m: Meses) => void; travaAntes: string | null; tipo: 'contrato' | 'assinatura' | 'consumo';
  valorContrato: number; teto: number; ajustarContrato: (c: number) => void;
}) {
  const chaves = Object.keys(meses).sort();
  const soma = chaves.reduce((a, k) => a + centavos(meses[k]), 0);
  const anos = [...new Set(chaves.map(k => k.slice(0, 4)))];
  const porAno = (a: string) => chaves.filter(k => k.startsWith(a)).reduce((s, k) => s + centavos(meses[k]), 0);
  const difere = tipo === 'contrato' && soma !== valorContrato;
  const ajustado = difere ? ajustarCalendario(meses, valorContrato, travaAntes) : null;
  return (
    <>
      <p className="sec lt-intro">
        {tipo === 'contrato' ? 'Digite quanto se espera pagar em cada mês. A soma dos meses tem de dar o valor do contrato.'
          : 'Digite quanto se espera pagar em cada mês. Depois do último mês, a previsão segue com o valor dele.'}
        {travaAntes && ' Os meses que já passaram não mudam.'}
      </p>
      {anos.map(a => (
        <section key={a} className="lt-sec">
          <h3>{a}<span className="sec peq" style={{ marginLeft: 8 }}>{txt(porAno(a))}</span></h3>
          {tipo === 'consumo' && teto > 0 && porAno(a) > teto && <Alerta c="cr" t={`Os meses de ${a} passam do teto no ano (${txt(teto)}).`} />}
          <div className="cal-grade">
            {chaves.filter(k => k.startsWith(a)).map(k => {
              const trava = Boolean(travaAntes && k < travaAntes);
              return (
                <label key={k} className="cal-mes">
                  <span className="sec peq">{nomeMes(k)}</span>
                  <input className="lt-in num" inputMode="decimal" value={meses[k]} disabled={trava}
                    title={trava ? 'Mês que já passou não muda' : undefined}
                    onChange={e => mudar({ ...meses, [k]: e.target.value })}
                    onBlur={() => mudar({ ...meses, [k]: txt(centavos(meses[k])) })}
                    onFocus={e => e.currentTarget.select()} />
                </label>
              );
            })}
          </div>
        </section>
      ))}
      <div className="cal-total">
        <span>Soma dos meses</span><b className="num">{txt(soma)}</b>
        {tipo === 'contrato' && <><span>Valor do contrato</span><b className="num">{txt(valorContrato)}</b></>}
      </div>
      {difere && (
        <div className="cal-pergunta" role="group" aria-label="A soma não bate">
          <Alerta c="at" t={`A soma dos meses (${txt(soma)}) não bate com o valor do contrato (${txt(valorContrato)}). Qual ajustar?`} />
          <div className="lt-lin">
            <button className="btn sm" onClick={() => ajustarContrato(soma)}><Ic n="edit" s={18} />Ajustar o contrato para {txt(soma)}</button>
            <button className="btn sm" disabled={!ajustado} onClick={() => ajustado && mudar(ajustado)}
              title={ajustado ? 'A diferença vai para os meses que ainda mudam, na proporção de cada um' : 'Os meses que ainda mudam não cobrem a diferença'}>
              <Ic n="edit" s={18} />Ajustar o calendário para {txt(valorContrato)}</button>
          </div>
        </div>
      )}
    </>
  );
}
