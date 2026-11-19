// Peças comuns das telas, no desenho da linha F do protótipo aprovado (tpl.js: ic, dTiles, fCab, fAbas, fGrupo, gavB, kvB, ch).
import { useEffect, useRef, useState, type KeyboardEvent as TeclaReact, type ReactNode } from 'react';
import { NavLink, useLocation, useParams } from 'react-router-dom';
import { ondeEstou } from '../lib/modulos';
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
  const abas: [string, string][] = [['/contas-a-pagar', 'Visão geral'], ['/titulos', 'Títulos'], ['/previsoes', 'Previsões'], ['/contratos', 'Contas recorrentes']];
  return <nav className="f-abas">{abas.map(([to, r]) => <NavLink key={to} to={to} className={({ isActive }) => (isActive ? 'on' : '')}>{r}</NavLink>)}</nav>;
}

/** Cores de cada estado: faixa e ponto (`c`) e o texto sobre branco (`t`, versão escura, contraste AA). Uma cor por estado. */
export const COR = {
  cinza: { c: '#747775', t: '#5f6368' }, azul: { c: '#0094fe', t: '#0062b8' }, roxo: { c: '#863d8f', t: '#863d8f' },
  verde: { c: '#7d8a3e', t: '#5c6a22' }, terra: { c: '#c67355', t: '#9c4b2e' },
} as const;
export type Cor = (typeof COR)[keyof typeof COR];

/** Linha de cabeçalho compacta: as abas no lugar do título grande (o h1 fica só para leitor de tela) e as ações à direita. */
export function Cab({ t, children }: { t: string; children?: ReactNode }) {
  useEffect(() => { document.title = `${t} · ERP BKM`; }, [t]);
  const { m, s } = ondeEstou(useLocation().pathname);
  return (
    <>
      {m && s && <nav className="f-trilha" aria-label="Onde estou"><span>{m.r}</span><Ic n="chev" s={16} />{s.to ? <NavLink to={s.to} end><b>{s.r}</b></NavLink> : <b>{s.r}</b>}</nav>}
      <div className="f-head"><h1 className="sr-only">{t}</h1><Abas /><span className="esp" />{children}</div>
    </>
  );
}

/** Contadores que filtram (tpl.js › dTiles): o clique no ligado volta para "todos". A cor é a do grupo, nunca a da posição. */
export function Tiles<K extends string>({ itens, on, mudar }: { itens: { k: K; r: string; n: number; cor: Cor; v?: ReactNode; alerta?: boolean }[]; on: K | null; mudar: (k: K | null) => void }) {
  return (
    <div className="tiles">
      {itens.map(t => (
        <button key={t.k} className={`tile ${t.k === on ? 'on' : ''}`} style={{ ['--fx' as string]: t.cor.c }} onClick={() => mudar(t.k === on ? null : t.k)} aria-pressed={t.k === on}>
          <span className="tl">{t.k === on && <Ic n="check" s={18} />}{t.r}</span>
          <span className="tv"><span className="tn num" style={t.alerta && t.n > 0 ? { color: 'var(--cr)' } : undefined}>{t.n}</span>{t.v != null && <span className="tr num">{t.v}</span>}</span>
        </button>
      ))}
    </div>
  );
}

/** Rótulos das colunas, uma vez acima dos grupos, com as mesmas larguras (`x` some com a gaveta, `r` à direita). */
export function Colunas({ cols, rot }: { cols: number[]; rot: { t: string; r?: boolean; x?: boolean }[] }) {
  const gav = !!useParams().id;
  const vis = rot.map((c, i) => ({ ...c, w: cols[i] })).filter(c => !(gav && c.x));
  cols = vis.map(c => c.w); rot = vis;
  return (
    <table className="f-tab fx f-cols" aria-hidden="true"><colgroup>{cols.map((w, i) => <col key={i} style={{ width: `${w}%` }} />)}</colgroup>
      <thead><tr>{rot.map((c, i) => <th key={i} className={[c.r ? 'r' : '', c.x ? 'f-x' : ''].join(' ').trim() || undefined}>{c.t}</th>)}</tr></thead>
    </table>
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

/** Grupo num card: ponto de cor, nome, contagem e total alinhado à coluna Valor; fecha e abre pelo cabeçalho (tpl.js › fGrupo). */
export function Grupo({ nome, cor, linhas, total, sel, abrir, fechado = false, cols }: { nome: string; cor: Cor; linhas: Linha[]; total?: ReactNode; sel?: string; abrir: (id: string) => void; fechado?: boolean; cols?: number[] }) {
  const [ab, setAb] = useState(!fechado);
  // com a gaveta aberta, as colunas `x` saem da tabela (e da largura), para os grupos e o cabeçalho continuarem alinhados
  const gav = !!useParams().id;
  if (!linhas.length) return null;
  if (gav && cols) {
    const fica = [true, ...linhas[0].cels.map(c => !c.x)];
    cols = cols.filter((_, i) => fica[i] ?? true);
    linhas = linhas.map(l => ({ ...l, cels: l.cels.filter(c => !c.x) }));
  }
  const tecla = (id: string) => (e: TeclaReact) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); abrir(id); } };
  return (
    <section className={`f-g ${ab ? 'ab' : ''}`}>
      <button className="f-gh" onClick={() => setAb(!ab)} aria-expanded={ab}>
        <span className="sec" style={{ display: 'inline-flex' }}><Ic n={ab ? 'seta' : 'chev'} s={18} /></span>
        <span className="f-pt" style={{ background: cor.c }} />
        <b style={{ color: cor.t }}>{nome}</b><span className="f-qt">{linhas.length}</span><span className="esp" /><span className="num f-tot">{total}</span>
      </button>
      {ab && (
        <>
          <table className={`f-tab ${cols ? 'fx' : ''}`}>{cols && <colgroup>{cols.map((w, i) => <col key={i} style={{ width: `${w}%` }} />)}</colgroup>}<tbody>
            {linhas.map(l => (
              <tr key={l.id} className={sel === l.id ? 'sel' : ''} onClick={() => abrir(l.id)} tabIndex={0} onKeyDown={tecla(l.id)}>
                <td className="f-nome">{l.titulo}</td>
                {l.cels.map((c, i) => <td key={i} className={[c.r ? 'r num' : '', c.x ? 'f-x' : ''].join(' ').trim() || undefined}>{c.c}</td>)}
              </tr>
            ))}
          </tbody></table>
          <div className="f-lst">
            {linhas.map(l => (
              <div key={l.id} className={`f-it ${sel === l.id ? 'sel' : ''}`} onClick={() => abrir(l.id)} role="button" tabIndex={0} onKeyDown={tecla(l.id)}>
                <div className="e-it-l"><span className="f-it-n">{l.titulo}</span><span className="num f-it-v">{l.valor}</span></div>
                <div className="e-it-l sec f-it-s">{l.sub}</div>
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
        <button className="icb gav-volta" title="Voltar" onClick={fechar}><Ic n="back" /></button>
        <div className="t"><b>{titulo}</b></div>
        {sub && <span className="gav-sub">{sub}</span>}
        <button className="icb oc-mm" title={cheia ? 'Voltar à gaveta' : 'Abrir na largura toda'} onClick={() => setCheia(!cheia)}><Ic n={cheia ? 'telaSair' : 'tela'} /></button>
        <button className="icb gav-x" title="Fechar (Esc)" onClick={fechar}><Ic n="close" /></button>
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

/** Estado de lista vazia ou erro, centrado, com a ação de limpar quando há filtro ou busca. */
export function Vazio({ t, limpar }: { t: string; limpar?: () => void }) {
  return <div className="vazio"><Ic n="doc" s={40} /><p>{t}</p>{limpar && <button className="btn t" onClick={limpar}>Limpar filtro e busca</button>}</div>;
}

/** Carregando: três linhas-esqueleto no lugar do texto. */
export function Carregando() {
  return <div className="esq" aria-label="Carregando" role="status"><span /><span /><span /></div>;
}
