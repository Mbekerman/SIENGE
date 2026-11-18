import { useCallback } from 'react';
import { useLocation, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { normal } from './format';

/** Estado da página no endereço (como o BKM Terrenos): o item aberto no caminho, o contador em ?f= e a busca em ?q=. */
export function usePagina<F extends string>(base: string) {
  const { id } = useParams();
  const [q, setQ] = useSearchParams();
  const loc = useLocation();
  const nav = useNavigate();
  const filtro = (q.get('f') as F | null) ?? null;
  const busca = normal(q.get('q'));
  const abrir = useCallback((i: string) => nav(`${base}/${i}${loc.search}`), [nav, base, loc.search]);
  const fechar = useCallback(() => nav(`${base}${loc.search}`), [nav, base, loc.search]);
  const mudarFiltro = (f: F | null) => { const n = new URLSearchParams(q); if (f) n.set('f', f); else n.delete('f'); setQ(n, { replace: true }); };
  return { id, filtro, busca, abrir, fechar, mudarFiltro };
}

/** Confere a busca em vários textos da linha, sem acento. */
export const acha = (busca: string, ...t: (string | number | null | undefined)[]) =>
  !busca || t.some(x => normal(x == null ? '' : String(x)).includes(busca));
