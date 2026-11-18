// Moldura do ERP: barra de cima, menu lateral (barra de baixo no celular) e a área da página.
// Desenho do protótipo aprovado (tpl.js › moldura); comportamento do BKM Terrenos (components/Moldura.tsx).
import { useCallback, useState, type ReactNode } from 'react';
import { NavLink, useLocation, useSearchParams } from 'react-router-dom';
import { useSessao } from '../lib/sessao';
import { BASE, Ic, Logo, useFora } from './Comum';

const PAPEL: Record<string, string> = { diretor: 'Diretor', gestor: 'Gestor', analista: 'Analista', leitura: 'Leitura' };

export function Moldura({ children }: { children: ReactNode }) {
  const { eu, sessao, sair } = useSessao();
  const [q, setQ] = useSearchParams();
  const loc = useLocation();
  const [perfil, setPerfil] = useState(false);
  const fechar = useCallback(() => setPerfil(false), []);
  const ref = useFora<HTMLDivElement>(perfil, fechar);
  const busca = q.get('q') ?? '';
  const comGaveta = /^\/(titulos|previsoes|contratos)\/[^/]+/.test(loc.pathname);
  const foto = sessao?.user.user_metadata?.avatar_url as string | undefined;
  const pedidos = ['/titulos', '/previsoes', '/contratos'].some(p => loc.pathname.startsWith(p));

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
        <nav className="rail">
          <span className="fabr-vaga" />
          <NavLink to={`/titulos${loc.search}`} className={`ri ${pedidos ? 'on' : ''}`}>
            <span className="pil"><img src={`${BASE}marca/icone-documento.svg`} alt="" /></span>Pedidos
          </NavLink>
        </nav>
        <main className={`main ${comGaveta ? 'com-gav' : ''}`}>{children}</main>
      </div>
    </div>
  );
}
