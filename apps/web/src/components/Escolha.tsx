// Seleção com busca (Moises, 26/11/2026: núcleo, centro de custo e natureza "possam ter search além da seleção").
// Clicar abre a lista inteira; digitar filtra por todas as palavras, sem acento nem maiúscula; setas e Enter escolhem,
// Esc fecha; sair sem escolher volta ao que estava.
import { useMemo, useRef, useState } from 'react';

import { type OpcaoEscolha, filtrar } from '../lib/busca';
export type { OpcaoEscolha };

export function Escolha({ valor, opcoes, mudar, vazio, rotulo, disabled, erro, className = '' }: {
  valor: string; opcoes: OpcaoEscolha[]; mudar: (id: string) => void; vazio: string; rotulo: string;
  disabled?: boolean; erro?: boolean; className?: string;
}) {
  const [ab, setAb] = useState(false);
  const [txt, setTxt] = useState('');
  const [ativo, setAtivo] = useState(0);
  const lista = useRef<HTMLDivElement>(null);
  const atual = opcoes.find(o => o.id === valor);
  const vis = useMemo(() => filtrar(opcoes, txt), [opcoes, txt]);
  const abrir = () => { if (disabled) return; setTxt(''); setAtivo(Math.max(0, opcoes.findIndex(o => o.id === valor))); setAb(true); };
  const escolher = (o: OpcaoEscolha) => { mudar(o.id); setAb(false); setTxt(''); };
  const mover = (d: number) => {
    const n = Math.min(Math.max(ativo + d, 0), vis.length - 1);
    setAtivo(n);
    lista.current?.children[n]?.scrollIntoView({ block: 'nearest' });
  };
  return (
    <div className={`lt-busca lt-esc ${className}`}>
      <input className={`lt-in ${erro ? 'err' : ''}`} role="combobox" aria-expanded={ab} aria-label={rotulo} disabled={disabled}
        placeholder={ab && atual ? atual.nome : vazio} title={atual?.nome}
        value={ab ? txt : atual?.nome ?? ''}
        onFocus={abrir} onMouseDown={() => { if (!ab) abrir(); }}
        onChange={e => { setTxt(e.target.value); setAtivo(0); setAb(true); }}
        onBlur={() => setTimeout(() => { setAb(false); setTxt(''); }, 150)}
        onKeyDown={e => {
          if (e.key === 'ArrowDown') { e.preventDefault(); if (!ab) abrir(); else mover(1); }
          else if (e.key === 'ArrowUp') { e.preventDefault(); mover(-1); }
          else if (e.key === 'Enter' && ab) { e.preventDefault(); if (vis[ativo]) escolher(vis[ativo]); }
          else if (e.key === 'Escape' && ab) { e.preventDefault(); e.stopPropagation(); setAb(false); setTxt(''); }
        }} />
      <span className="lt-esc-seta" aria-hidden>▾</span>
      {ab && (
        <div className="lt-op" role="listbox" ref={lista}>
          {!vis.length ? <div className="sec peq lt-o">Nada com “{txt}”.</div>
            : vis.map((o, i) => (
              <button key={o.id} type="button" role="option" aria-selected={o.id === valor} tabIndex={-1}
                className={`lt-o ${i === ativo ? 'on' : ''} ${o.id === valor ? 'sel' : ''}`}
                onMouseDown={e => e.preventDefault()} onMouseEnter={() => setAtivo(i)} onClick={() => escolher(o)}>
                <span>{o.nome}</span>{o.sub && <span className="sec peq">{o.sub}</span>}
              </button>
            ))}
        </div>
      )}
    </div>
  );
}
