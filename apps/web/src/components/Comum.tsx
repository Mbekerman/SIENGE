// Peças comuns das telas, no desenho da linha F do protótipo aprovado (tpl.js: ic, dTiles, fCab, fAbas, fGrupo, gavB, kvB, ch).
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { NavLink } from 'react-router-dom';
import { P, type NomeIcone } from '../lib/icones';
import { AMBIENTE } from '../lib/config';

export const BASE = import.meta.env.BASE_URL;

/** Ícone de linha (do BKM Terrenos, components/Moldura.tsx › Ic). */
export function Ic({ n, s = 20 }: { n: NomeIcone; s?: number }) {
  return (
    <svg className="ic" viewBox="0 0 24 24" width={s} height={s} aria-hidden="true">
      <path fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" d={P[n]} />
    </svg>
  );
}

export function Logo() {
  const amb = AMBIENTE && AMBIENTE !== 'producao' ? (AMBIENTE === 'dev' ? 'Desenvolvimento' : AMBIENTE) : '';
  return <span className="logo"><img src={`${BASE}marca/bkm-logo.svg`} alt="BKM" />{amb && <span className="selo">{amb}</span>}</span>;
}

/** Fecha no clique fora e no Esc (do BKM Terrenos, Moldura.tsx › useFora). */
export function useFora<T extends HTMLElement>(aberto: boolean, fechar: () => void) {
  const ref = useRef<T>(null);
  useEffect(() => {
    if (!aberto) return;
    const clique = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) fechar(); };
    const tecla = (e: KeyboardEvent) => { if (e.key === 'Escape') fechar(); };
    document.addEventListener('mousedown', clique);
    document.addEventListener('keydown', tecla);
    return () => { document.removeEventListener('mousedown', clique); document.removeEventListener('keydown', tecla); };
  }, [aberto, fechar]);
  return ref;
}

/** Cores dos chips tonais (tpl.js › CH). */
const CH = { ok: ['#c4eed0', '#0d3d1c'], at: ['#ffdf99', '#5c4300'], cr: ['#ffdad6', '#8c1d18'], az: ['#d3e3fd', '#041e49'], ro: ['#e8def8', '#3b2066'], ci: ['#e9eef6', '#444746'] } as const;
export type CorChip = keyof typeof CH;
export function Chip({ t, c }: { t: string; c: CorChip }) {
  return <span className="e-chip" style={{ background: CH[c][0], color: CH[c][1] }}>{t}</span>;
}

/** Abas da página de pedidos (tpl.js › fAbas). */
export function Abas() {
  const abas: [string, string][] = [['/titulos', 'Títulos'], ['/previsoes', 'Previsões'], ['/contratos', 'Contas recorrentes']];
  return <nav className="f-abas">{abas.map(([to, r]) => <NavLink key={to} to={to} className={({ isActive }) => (isActive ? 'on' : '')}>{r}</NavLink>)}</nav>;
}

export function Cab({ t, children }: { t: string; children?: ReactNode }) {
  return <div className="f-cab"><h1>{t}</h1><span className="esp" />{children}</div>;
}

/** Contadores que filtram (tpl.js › dTiles): o clique no ligado volta para "todos". */
export function Tiles<K extends string>({ itens, on, mudar }: { itens: { k: K; r: string; n: number; alerta?: boolean }[]; on: K | null; mudar: (k: K | null) => void }) {
  const cores = ['var(--azul-bkm)', 'var(--roxo)', 'var(--terracota)', 'var(--verde)'];
  return (
    <div className="tiles">
      {itens.map((t, i) => (
        <button key={t.k} className={`tile ${t.k === on ? 'on' : ''}`} style={{ ['--fx' as string]: cores[i % 4] }} onClick={() => mudar(t.k === on ? null : t.k)} aria-pressed={t.k === on}>
          <span className="tl">{t.r}</span>
          <span className="tn num" style={t.alerta && t.n > 0 ? { color: 'var(--cr)' } : undefined}>{t.n}</span>
        </button>
      ))}
    </div>
  );
}

export interface Linha {
  id: string;
  titulo: ReactNode;
  /** células do computador depois do nome; `r` alinha à direita (número) e `x` some com a gaveta aberta */
  cels: { c: ReactNode; r?: boolean; x?: boolean }[];
  /** celular: valor à direita da 1ª linha e a 2ª linha */
  valor: ReactNode;
  sub: ReactNode;
  cor?: string;
}

/** Grupo com marcador de cor, contagem e total (tpl.js › fGrupo / fG); fecha e abre pelo título. */
export function Grupo({ nome, cor, linhas, total, sel, abrir, fechado = false, cols }: { nome: string; cor: string; linhas: Linha[]; total?: ReactNode; sel?: string; abrir: (id: string) => void; fechado?: boolean; cols?: number[] }) {
  const [ab, setAb] = useState(!fechado);
  if (!linhas.length) return null;
  return (
    <section className="f-g">
      <button className="f-gh" onClick={() => setAb(!ab)} aria-expanded={ab}>
        <span style={{ color: cor, display: 'inline-flex' }}><Ic n={ab ? 'seta' : 'chev'} s={18} /></span>
        <b style={{ color: cor }}>{nome}</b><span className="sec">{linhas.length}</span><span className="esp" /><span className="num sec">{total}</span>
      </button>
      {ab && (
        <>
          <table className={`f-tab ${cols ? 'fx' : ''}`}>{cols && <colgroup>{cols.map((w, i) => <col key={i} style={{ width: `${w}%` }} />)}</colgroup>}<tbody>
            {linhas.map(l => (
              <tr key={l.id} className={sel === l.id ? 'sel' : ''} onClick={() => abrir(l.id)}>
                <td className="f-nome"><span className="f-mk" style={{ background: l.cor ?? cor }} />{l.titulo}</td>
                {l.cels.map((c, i) => <td key={i} className={[c.r ? 'r num' : '', c.x ? 'f-x' : ''].join(' ').trim() || undefined}>{c.c}</td>)}
              </tr>
            ))}
          </tbody></table>
          <div className="f-lst">
            {linhas.map(l => (
              <div key={l.id} className="f-it" onClick={() => abrir(l.id)} role="button" tabIndex={0} onKeyDown={e => { if (e.key === 'Enter') abrir(l.id); }}>
                <span className="f-mk" style={{ background: l.cor ?? cor }} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div className="e-it-l"><span>{l.titulo}</span><span className="num">{l.valor}</span></div>
                  <div className="e-it-l sec peq" style={{ marginTop: 6 }}>{l.sub}</div>
                </div>
              </div>
            ))}
          </div>
        </>
      )}
    </section>
  );
}

/** Gaveta da direita (tpl.js › fGaveta / gavB); Esc fecha. No celular cobre a tela. */
export function Gaveta({ titulo, sub, fechar, children, pe }: { titulo: ReactNode; sub?: ReactNode; fechar: () => void; children: ReactNode; pe?: ReactNode }) {
  const [cheia, setCheia] = useState(false);
  useEffect(() => {
    const tecla = (e: KeyboardEvent) => { if (e.key === 'Escape') fechar(); };
    document.addEventListener('keydown', tecla);
    return () => document.removeEventListener('keydown', tecla);
  }, [fechar]);
  return (
    <aside className={`gav f-gav ${cheia ? 'g-full' : ''}`} aria-label="Detalhe">
      <div className="gav-h">
        <div className="t"><b>{titulo}</b>{sub && <div className="sec peq">{sub}</div>}</div>
        <button className="icb oc-mm" title={cheia ? 'Voltar à gaveta' : 'Abrir na largura toda'} onClick={() => setCheia(!cheia)}><Ic n={cheia ? 'telaSair' : 'tela'} /></button>
        <button className="icb" title="Fechar (Esc)" onClick={fechar}><Ic n="close" /></button>
      </div>
      <div className="gav-b">{children}</div>
      {pe && <div className="gav-f">{pe}</div>}
    </aside>
  );
}

/** Lista chave e valor (tpl.js › kvB); some a linha sem valor. */
export function Kv({ l }: { l: [string, ReactNode][] }) {
  const v = l.filter(([, x]) => x != null && x !== '' && x !== false);
  return <div className="kv">{v.map(([k, x]) => [<div key={k + 'k'} className="k">{k}</div>, <div key={k + 'v'} className="v">{x}</div>])}</div>;
}

/** Seção da gaveta com título pequeno e linhas (tpl.js › dd-h / dd-li). */
export function Secao({ t, children }: { t: string; children: ReactNode }) {
  return <section><div className="dd-h">{t}</div>{children}</section>;
}
export function Li({ a, b, c }: { a: ReactNode; b?: ReactNode; c?: ReactNode }) {
  return <div className="dd-li"><div style={{ flex: 1, minWidth: 0 }}><div>{a}</div>{c && <div className="sec peq">{c}</div>}</div>{b != null && <span className="sec num">{b}</span>}</div>;
}

export function Alerta({ c, t }: { c: 'cr' | 'at'; t: ReactNode }) {
  return <div className={`al ${c}`}><Ic n={c === 'cr' ? 'warn' : 'info'} s={18} /><span>{t}</span></div>;
}

/** Estado de lista vazia, carregando ou erro, sem texto explicativo além do necessário. */
export function Vazio({ t }: { t: string }) {
  return <p className="sec vazio">{t}</p>;
}
