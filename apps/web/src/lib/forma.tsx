// A forma de pagamento do título para quem olha e para quem aprova: a TED da parcela em uma linha e os avisos que o
// banco dá (erp.avisos_forma_pagamento, os mesmos que vão para quem aprova), e o botão da AF "Usar a forma do cadastro"
// quando a cobrança veio diferente da forma cadastrada na conta recorrente (Moises, 23/11/2026: "Abre a opção para o
// Aprovador final escolher (AF)"; migration 20261124003000). Quem decide se pode é o banco (api.usar_forma_do_cadastro):
// a tela só mostra o botão para AF, AD e master com o título em aprovação.
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { Alerta, Ic } from '../components/Comum';
import { documento } from './format';
import { useSessao } from './sessao';
import { mensagemErro, rpc } from './supabase';
import type { ParcelaDetalhe, TituloDetalhe } from './tipos';

export type Ted = NonNullable<ParcelaDetalhe['ted']>;

/** A conta da TED em uma linha. */
export const textoTed = (t: Ted) =>
  `TED · banco ${t.banco} · agência ${t.agencia}${t.agencia_digito ? `-${t.agencia_digito}` : ''} · conta ${t.conta_tipo === 'poupanca' ? 'poupança ' : ''}${t.conta}-${t.conta_digito} · titular ${documento(t.titular_documento)}`;

// o texto do banco (erp.avisos_forma_pagamento) que abre a escolha da AF; "vem com cada cobrança" não tem o que trocar
const DIFERENTE = 'Diferente da forma cadastrada na conta recorrente: ';
const trocavel = (a: string) => a.startsWith(DIFERENTE) && !a.includes('vem com cada cobrança');

/** Os avisos da forma de pagamento, juntos (com o número da parcela quando há mais de uma). */
export function AvisosForma({ t, podeEscolher }: { t: TituloDetalhe; podeEscolher?: boolean }) {
  const qc = useQueryClient();
  const { eu } = useSessao();
  const usar = useMutation({
    mutationFn: () => rpc<number>('usar_forma_do_cadastro', { p_titulo: t.id }),
    onSuccess: () => { for (const k of ['titulo', 'titulos', 'aprovacoes', 'rastro']) qc.invalidateQueries({ queryKey: [k] }); },
  });
  const linhas = t.parcelas.flatMap(p => (p.avisos ?? []).map(a => ({ n: p.numero, a })));
  if (!linhas.length) return null;
  const varias = t.parcelas.length > 1;
  const daAF = Boolean(eu && (eu.master || eu.listas.includes('AF') || eu.listas.includes('AD')));
  const botao = podeEscolher && daAF && t.etapa === 'aprovacao' && linhas.some(l => trocavel(l.a));
  // o mesmo aviso em todas as parcelas aparece uma vez só
  const unicos = [...new Set(linhas.map(l => l.a))].map(a => {
    const ns = linhas.filter(l => l.a === a).map(l => l.n);
    return varias && ns.length < t.parcelas.length ? `${ns.map(n => `${n}ª`).join(', ')}: ${a}` : a;
  });
  return (
    <div className="fp-av">
      <Alerta c="at" t={<><b>Forma de pagamento</b>{unicos.map(a => <span key={a} style={{ display: 'block' }}>{a}</span>)}</>} />
      {botao && <div className="fp-esc">
        <button className="btn t sm" onClick={() => usar.mutate()} disabled={usar.isPending}><Ic n="check" s={18} />{usar.isPending ? 'Trocando…' : 'Usar a forma do cadastro'}</button>
        <span className="sec peq">Ou aprove com a forma que veio na cobrança. A troca fica registrada e aparece para quem aprova depois.</span>
        {usar.error && <span className="lt-erro"><Ic n="warn" s={18} />{mensagemErro(usar.error)}</span>}
      </div>}
    </div>
  );
}
