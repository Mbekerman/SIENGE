// Moldura do ERP: barra de cima, menu lateral (barra de baixo no celular) e a área da página.
// Desenho do protótipo aprovado (tpl.js › moldura); comportamento do BKM Terrenos (components/Moldura.tsx).
import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { NavLink, useLocation, useSearchParams } from 'react-router-dom';
import { useSessao } from '../lib/sessao';
import { Ic, Logo, useFora } from './Comum';
import { MODULOS, ondeEstou, type Modulo } from '../lib/modulos';

const PAPEL: Record<string, string> = { diretor: 'Diretor', gestor: 'Gestor', analista: 'Analista', leitura: 'Leitura' };

export function Moldura({ children }: { children: ReactNode }) {
  const { eu, sessao, sair } = useSessao();
  const [q, setQ] = useSearchParams();
  const loc = useLocation();
  const [perfil, setPerfil] = useState(false);
  const fechar = useCallback(() => setPerfil(false), []);
  const ref = useFora<HTMLDivElement>(perfil, fechar);
  const busca = q.get('q') ?? '';
  const comGaveta = /^\/(aprovar|titulos|previsoes|contratos)\/[^/]+/.test(loc.pathname);
  const foto = sessao?.user.user_metadata?.avatar_url as string | undefined;
  const atual = ondeEstou(loc.pathname);

  function buscar(v: string) {
    const n = new URLSearchParams(q);
    if (v) n.set('q', v); else n.delete('q');
    setQ(n, { replace: true });
  }

  return (
    <div className="app">
      <div className="mold">
        <header className="top">
          <span className="menu" aria-hidden="true" />
          <Logo />
          <label className="busca">
            <Ic n="search" />
            <input value={busca} onChange={e => buscar(e.target.value)} placeholder="Buscar fornecedor, nota ou título" aria-label="Buscar" />
            {busca && <button className="icb" title="Limpar" onClick={() => buscar('')}><Ic n="close" s={18} /></button>}
          </label>
          <div className="dir" ref={ref}>
            <button className="av perfil-btn" title={eu?.nome} onClick={() => setPerfil(!perfil)} aria-expanded={perfil}>
              {foto ? <img className="perfil-foto" src={foto} alt="" referrerPolicy="no-referrer" /> : eu?.nome[0]}
            </button>
            {perfil && (
              <div className="perfil-menu" role="menu">
                <div className="perfil-nome">{eu?.nome}</div>
                <div className="sec peq">{sessao?.user.email}</div>
                <div className="sec peq">{[PAPEL[eu?.papel ?? ''], eu?.master ? 'Master' : '', ...(eu?.listas ?? []), eu?.administrador ? 'Administrador' : ''].filter(Boolean).join(' · ')}</div>
                <button className="btn t" role="menuitem" onClick={() => { setPerfil(false); sair(); }}>Sair</button>
              </div>
            )}
          </div>
        </header>
        <Menu atual={atual.m?.k} sub={atual.s?.r} />
        <main className={`main ${comGaveta ? 'com-gav' : ''}`}>{children}</main>
      </div>
    </div>
  );
}

/** Menu lateral com os módulos; o submódulo abre numa coluna ao lado (clique, ou o mouse parado 0,3 s), que fecha ao sair. */
function Menu({ atual, sub }: { atual?: string; sub?: string }) {
  const [aberto, setAberto] = useState<string | null>(null);
  const t = useRef<number>();
  const fechar = useCallback(() => setAberto(null), []);
  const ref = useFora<HTMLDivElement>(aberto != null, fechar);
  const loc = useLocation();
  useEffect(() => setAberto(null), [loc.pathname]);
  useEffect(() => () => window.clearTimeout(t.current), []);
  const m = MODULOS.find(x => x.k === aberto);
  // Submódulo com filhos abre uma segunda coluna ao lado (como no Business Manager da Meta), no clique ou no mouse.
  const [pai, setPai] = useState<string | null>(null);
  useEffect(() => setPai(null), [aberto]);
  const filhos = m?.subs.find(x => x.r === pai)?.filhos;
  function agendar(k: string | null, ms: number) { window.clearTimeout(t.current); t.current = window.setTimeout(() => setAberto(k), ms); }
  function item(x: Modulo) {
    const conteudo = <><span className="pil"><Ic n={x.ic} s={22} /></span>{x.r}</>;
    const cls = `ri ${x.k === atual ? 'on' : ''} ${x.k === aberto ? 'ab' : ''}`;
    if (!x.subs.length) return <span key={x.k} className={`${cls} off`} title="Em breve">{conteudo}</span>;
    return (
      <button key={x.k} className={cls} aria-expanded={x.k === aberto} onClick={() => setAberto(x.k === aberto ? null : x.k)}
        onMouseEnter={() => agendar(x.k, aberto ? 0 : 150)} onMouseLeave={() => window.clearTimeout(t.current)}>{conteudo}</button>
    );
  }
  return (
    <div className="nav-w" ref={ref} onMouseLeave={() => aberto && agendar(null, 400)} onMouseEnter={() => aberto && window.clearTimeout(t.current)}>
      <nav className="rail" aria-label="Módulos">{MODULOS.map(item)}</nav>
      {m && (
        <div className="subm" role="menu" aria-label={m.r}>
          <div className="subm-t">{m.r}</div>
          {m.subs.map(s => !s.to
            ? <span key={s.r} className="subm-i off" role="menuitem" aria-disabled="true" onMouseEnter={() => setPai(null)}>{s.r}<span className="subm-eb">Em breve</span></span>
            : s.filhos
              ? <NavLink key={s.r} to={s.to} role="menuitem" aria-haspopup="menu" aria-expanded={s.r === pai}
                  className={`subm-i subm-pai ${s.r === sub && m.k === atual ? 'at' : ''} ${s.r === pai ? 'ab' : ''}`}
                  onMouseEnter={() => setPai(s.r)} onFocus={() => setPai(s.r)}>{s.r}<Ic n="chev" s={18} /></NavLink>
              : <NavLink key={s.r} to={s.to} role="menuitem" onMouseEnter={() => setPai(null)} className={`subm-i ${s.r === sub && m.k === atual ? 'on' : ''}`}>{s.r}</NavLink>)}
        </div>
      )}
      {m && pai && filhos && (
        <div className="subm subm2" role="menu" aria-label={pai}>
          <div className="subm-t">{pai}</div>
          {filhos.map(f => <NavLink key={f.to} to={f.to} end role="menuitem" className={({ isActive }) => `subm-i ${isActive ? 'on' : ''}`}>{f.r}</NavLink>)}
        </div>
      )}
    </div>
  );
}
