// Para aprovar (tpl.js › fAprovar e fGaveta): o que espera aprovação e a pessoa vê, numa lista só, com "é a sua vez?".
// A vez vem do banco (api.aprovacoes simula a própria decisão), e a decisão é api.decidir, a RPC de sempre por baixo.
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { AlertaCredorNovo, AlertaRecebedor, SeloCredorNovo, SeloRecebedor, useCredoresNovos, useDivergentes } from '../lib/recebedor';
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Alerta, COR, Cab, Carregando, Chip, Colunas, Gaveta, Grupo, Ic, Kv, Tiles, Vazio, type Cor, type CorChip, type Linha } from '../components/Comum';
import { RastroBotoes } from '../components/Rastro';
import { data, dataCurta, dataHora, hojeISO, reais } from '../lib/format';
import { acha, usePagina } from '../lib/navegar';
import { mensagemErro, rpc } from '../lib/supabase';
import { AvisosForma } from '../lib/forma';
import type { Aprovacao, TipoAprovacao, TituloDetalhe } from '../lib/tipos';

type F = 'vez' | 'sem' | 'venc' | 'out';
const TIPO: Record<TipoAprovacao, [string, CorChip]> = { titulo: ['Título', 'az'], previsao: ['Previsão', 'ro'], contrato: ['Conta recorrente', 'ci'] };
const COLS = [26, 14, 18, 18, 10, 14];
const ROT = [{ t: 'Fornecedor' }, { t: 'Tipo' }, { t: 'Área', x: true }, { t: 'Descrição', x: true }, { t: 'Data' }, { t: 'Valor', r: true }];

/** chave da linha no endereço: o mesmo título aparece uma vez por alçada (centro ou divisão) */
const chave = (a: Aprovacao) => [a.tipo, a.id, a.centro_id ?? '', a.divisao_id ?? ''].join('~');
/** o valor que esta pessoa aprova: a parte do centro no rateio, senão o todo */
const valorVez = (a: Aprovacao) => Number(a.parte ?? a.valor);
const rateado = (a: Aprovacao) => a.parte != null && Number(a.parte) !== Number(a.valor);
const daqui = (d: string, n: number) => { const x = new Date(`${d}T12:00:00`); x.setDate(x.getDate() + n); return x.toISOString().slice(0, 10); };
/** contrato não vence: a data dele é o início; só título e previsão entram em Vencidos e Vencem esta semana */
const vencido = (a: Aprovacao) => a.tipo !== 'contrato' && !!a.data && a.data < hojeISO();
const semana = (a: Aprovacao) => a.tipo !== 'contrato' && !!a.data && a.data >= hojeISO() && a.data <= daqui(hojeISO(), 7);
const soma = (l: Aprovacao[]) => l.reduce((s, a) => s + valorVez(a), 0);

export function Aprovar() {
  const pg = usePagina<F>('/aprovar');
  const q = useQuery({ queryKey: ['aprovacoes'], queryFn: () => rpc<Aprovacao[]>('aprovacoes') });
  const div = useDivergentes();
  const novos = useCredoresNovos();
  const [aviso, setAviso] = useState<string | null>(null);
  const [marcados, setMarcados] = useState<Set<string>>(new Set());
  const qc = useQueryClient();
  useEffect(() => { if (!aviso) return; const t = setTimeout(() => setAviso(null), 5000); return () => clearTimeout(t); }, [aviso]);

  const todos = (q.data ?? []).filter(a => acha(pg.busca, a.fornecedor, a.descricao, a.area, a.empresa, a.lancado_por));
  const vez = todos.filter(a => a.vez), outros = todos.filter(a => !a.vez);
  const G: [F, string, Cor, Aprovacao[]][] = [
    ['venc', 'Vencidos', COR.vermelho, vez.filter(vencido)],
    ['sem', 'Vencem esta semana', COR.terra, vez.filter(semana)],
    ['vez', 'Depois', COR.azul, vez.filter(a => !vencido(a) && !semana(a))],
    ['out', 'Esperando outra pessoa', COR.cinza, outros],
  ];
  // Na minha vez mostra os três grupos da vez; os outros contadores, só o seu grupo
  const grupos = G.filter(g => !pg.filtro || pg.filtro === g[0] || (pg.filtro === 'vez' && g[0] !== 'out'));
  // seleção em lote: só o que está na vez da pessoa e à vista (filtro e busca); cada item passa pela decisão de sempre
  const visiveis = grupos.flatMap(g => g[3]).filter(a => a.vez);
  const sel = visiveis.filter(a => marcados.has(chave(a)));
  const todosMarcados = visiveis.length > 0 && sel.length === visiveis.length;
  const trocar = (k: string) => setMarcados(m => { const n = new Set(m); if (n.has(k)) n.delete(k); else n.add(k); return n; });
  const lote = useMutation({
    mutationFn: async (itens: Aprovacao[]) => {
      const erros: string[] = []; let ok = 0;
      for (const a of itens) {
        try { await rpc<string>('decidir', { p_tipo: a.tipo, p_id: a.id, p_decisao: 'aprovar', p_justificativa: null, p_centro: a.centro_id, p_divisao: a.divisao_id }); ok++; }
        catch (e) { erros.push(`${a.fornecedor ?? a.descricao ?? 'item'}: ${mensagemErro(e)}`); }
      }
      return { ok, erros };
    },
    onSettled: () => { for (const k of ['aprovacoes', 'titulos', 'previsoes', 'contratos', 'titulo', 'rastro']) qc.invalidateQueries({ queryKey: [k] }); },
    onSuccess: ({ ok, erros }) => {
      setMarcados(new Set());
      setAviso(erros.length ? `${ok} aprovado${ok === 1 ? '' : 's'}; ${erros.length} não: ${erros.join(' · ')}` : `${ok} aprovado${ok === 1 ? '' : 's'}.`);
    },
  });
  const linha = (a: Aprovacao): Linha => {
    const dt = a.data && <span className={`num ${vencido(a) ? 'atras' : ''}`}>{vencido(a) && <Ic n="warn" s={16} />}{dataCurta(a.data)}</span>;
    return {
      id: chave(a),
      titulo: a.vez
        ? <span className="apr-ck"><input type="checkbox" checked={marcados.has(chave(a))} aria-label={`Marcar ${a.fornecedor ?? a.descricao ?? 'item'}`}
            onClick={e => e.stopPropagation()} onKeyDown={e => e.stopPropagation()} onChange={() => trocar(chave(a))} />{a.fornecedor ?? a.descricao ?? '—'}{a.tipo === 'titulo' && <><SeloRecebedor motivos={div.get(a.id)} /><SeloCredorNovo desde={novos.get(a.id)} /></>}</span>
        : <span className="apr-ck"><span className="apr-ck-v" />{a.fornecedor ?? a.descricao ?? '—'}{a.tipo === 'titulo' && <><SeloRecebedor motivos={div.get(a.id)} /><SeloCredorNovo desde={novos.get(a.id)} /></>}</span>,
      cels: [
        { c: <Chip t={TIPO[a.tipo][0]} c={TIPO[a.tipo][1]} /> },
        { c: a.area, x: true },
        { c: a.descricao, x: true },
        { c: dt },
        { c: <span title={rateado(a) ? `Parte desta área; total ${reais(a.valor)}` : undefined}>{reais(valorVez(a))}</span>, r: true },
      ],
      valor: reais(valorVez(a)),
      sub: <>{dt}<Chip t={TIPO[a.tipo][0]} c={TIPO[a.tipo][1]} />{a.area && <span>{a.area}</span>}</>,
    };
  };
  const aberto = todos.find(a => chave(a) === pg.id) ?? (q.data ?? []).find(a => chave(a) === pg.id);
  const vazio = !grupos.some(g => g[3].length);
  return (
    <>
      <div className="f-pag">
        <Cab t="Para aprovar" abas={false}>
          {(pg.filtro || pg.busca) && <button className="btn t" onClick={pg.limpar}>Limpar filtro</button>}
        </Cab>
        <Tiles itens={[
          { k: 'vez', r: 'Na minha vez', cor: COR.azul, n: vez.length, v: vez.length ? reais(soma(vez)) : undefined },
          { k: 'sem', r: 'Vencem em 7 dias', cor: COR.terra, n: G[1][3].length },
          { k: 'venc', r: 'Vencidos', cor: COR.vermelho, n: G[0][3].length, alerta: true },
          { k: 'out', r: 'Esperando outra pessoa', cor: COR.cinza, n: outros.length },
        ] as { k: F; r: string; cor: Cor; n: number; v?: string; alerta?: boolean }[]} on={pg.filtro} mudar={pg.mudarFiltro} />
        {q.isLoading ? <Carregando /> : q.error ? <Vazio t={mensagemErro(q.error)} />
          : vazio ? <Vazio t={pg.busca || pg.filtro ? 'Nada encontrado.' : 'Nada esperando aprovação.'} limpar={pg.busca || pg.filtro ? pg.limpar : undefined} />
          : <>
              {visiveis.length > 0 && (
                <div className={`apr-lote ${sel.length ? 'on' : ''}`}>
                  <label className="apr-ck"><input type="checkbox" checked={todosMarcados} ref={el => { if (el) el.indeterminate = sel.length > 0 && !todosMarcados; }}
                    onChange={() => setMarcados(todosMarcados ? new Set() : new Set(visiveis.map(chave)))} />
                    {sel.length ? `${sel.length} selecionado${sel.length === 1 ? '' : 's'} · ${reais(soma(sel))}` : `Selecionar todos (${visiveis.length})`}</label>
                  <span className="esp" />
                  {sel.length > 0 && <>
                    <button className="btn t" onClick={() => setMarcados(new Set())} disabled={lote.isPending}>Limpar</button>
                    <button className="btn p" onClick={() => lote.mutate(sel)} disabled={lote.isPending}>{lote.isPending ? 'Aprovando…' : `Aprovar ${sel.length}`}</button>
                  </>}
                </div>
              )}
              <Colunas cols={COLS} rot={ROT} />
              {grupos.map(([k, nome, cor, it]) => (
                <Grupo key={k} nome={nome} cor={cor} linhas={it.map(linha)} total={reais(soma(it))} sel={pg.id} abrir={pg.abrir} cols={COLS} fechado={k === 'out' && pg.filtro !== 'out'} />
              ))}
            </>}
      </div>
      {pg.id && (aberto
        ? <GavetaAprovar key={pg.id} a={aberto} motivos={aberto.tipo === 'titulo' ? div.get(aberto.id) : undefined} novo={aberto.tipo === 'titulo' ? novos.get(aberto.id) : undefined} fechar={pg.fechar} feito={m => { setAviso(m); pg.fechar(); }} />
        : !q.isLoading && <Gaveta titulo="Para aprovar" fechar={pg.fechar}><Vazio t="Este item não espera mais aprovação, ou você não o vê." /></Gaveta>)}
      {aviso && <div className="snack" role="status" style={{ position: 'fixed' }}><span>{aviso}</span><button onClick={() => setAviso(null)}>Fechar</button></div>}
    </>
  );
}

type Modo = 'recusar' | 'revisao' | null;
const RES: Record<string, string> = {
  aprovado: 'Aprovado.', pendente: 'Sua aprovação foi registrada. Falta a próxima fase.', recusado: 'Recusado. Quem lançou foi avisado.',
  revisao: 'Voltou para quem lançou ajustar.',
};

function GavetaAprovar({ a, motivos, novo, fechar, feito }: { a: Aprovacao; motivos?: string[]; novo?: string; fechar: () => void; feito: (m: string) => void }) {
  const qc = useQueryClient();
  const [modo, setModo] = useState<Modo>(null);
  const [just, setJust] = useState('');
  const [tentou, setTentou] = useState(false);
  const decidir = useMutation({
    mutationFn: (d: 'aprovar' | 'recusar' | 'revisao') => rpc<string>('decidir', {
      p_tipo: a.tipo, p_id: a.id, p_decisao: d, p_justificativa: d === 'aprovar' ? null : just.trim(), p_centro: a.centro_id, p_divisao: a.divisao_id,
    }),
    onSuccess: r => {
      for (const k of ['aprovacoes', 'titulos', 'previsoes', 'contratos', 'titulo', 'rastro']) qc.invalidateQueries({ queryKey: [k] });
      feito(RES[r] ?? 'Decisão registrada.');
    },
  });
  // o título inteiro, para os avisos da forma de pagamento e a escolha da AF (mesma chave da gaveta de Títulos)
  const tq = useQuery({ queryKey: ['titulo', a.id], queryFn: () => rpc<TituloDetalhe | null>('titulo', { p_id: a.id }), enabled: a.tipo === 'titulo' });
  const confirmar = () => { setTentou(true); if (modo && just.trim()) decidir.mutate(modo); };
  const parte = a.area ? `a parte de ${a.area.split(' › ')[0]}` : 'esta parte';
  const pe = !a.vez ? undefined : modo ? <>
    {decidir.error ? <span className="lt-erro"><Ic n="warn" s={18} />{mensagemErro(decidir.error)}</span> : <span className="esp" />}
    <button className="btn t" onClick={() => { setModo(null); setTentou(false); decidir.reset(); }}>Voltar</button>
    <button className="btn p" onClick={confirmar} disabled={decidir.isPending}>{decidir.isPending ? 'Enviando…' : modo === 'recusar' ? 'Recusar' : 'Pedir ajuste'}</button>
  </> : <>
    {decidir.error ? <span className="lt-erro"><Ic n="warn" s={18} />{mensagemErro(decidir.error)}</span> : <span className="esp" />}
    <button className="btn" onClick={() => setModo('recusar')}>Recusar</button>
    {a.tipo === 'titulo' && <button className="btn t" onClick={() => setModo('revisao')}>Pedir ajuste</button>}
    <button className="btn p apr-ok" onClick={() => decidir.mutate('aprovar')} disabled={decidir.isPending}>
      {decidir.isPending ? 'Aprovando…' : rateado(a) ? `Aprovar ${parte}` : 'Aprovar'}
    </button>
  </>;
  return (
    <Gaveta titulo={a.fornecedor ?? a.descricao ?? TIPO[a.tipo][0]} sub={<Chip t={TIPO[a.tipo][0]} c={TIPO[a.tipo][1]} />} fechar={fechar} pe={pe}>
      <div>
        <div className="big num">{reais(valorVez(a))}</div>
        {rateado(a) && <div className="sec">parte de {a.area} em {reais(a.valor)}</div>}
        {a.data && <div className="sec">{a.tipo === 'contrato' ? 'começa' : a.tipo === 'previsao' ? 'prevista para' : 'vence'} {data(a.data)}</div>}
      </div>
      {a.tipo === 'titulo' && <RastroBotoes id={a.id} />}
      <AlertaRecebedor motivos={motivos} />
      <AlertaCredorNovo desde={novo} />
      {tq.data && <AvisosForma t={tq.data} podeEscolher={a.vez} />}
      {!a.vez && a.motivo && <Alerta c="at" t={a.motivo} />}
      {modo && (
        <label className="apr-just">
          <span>{modo === 'recusar' ? 'Por que recusa?' : 'O que precisa ajustar?'}</span>
          <textarea className={`lt-in ${tentou && !just.trim() ? 'err' : ''}`} rows={4} autoFocus value={just} onChange={e => setJust(e.target.value)}
            placeholder={modo === 'recusar' ? 'Quem lançou recebe este texto.' : 'Volta para quem lançou, com este pedido.'} />
          {tentou && !just.trim() && <span className="campo-msg">{modo === 'recusar' ? 'A recusa pede a justificativa.' : 'Diga o que ajustar.'}</span>}
        </label>
      )}
      <Kv l={[
        ['Descrição', a.descricao],
        ['Área', a.area],
        ['Empresa', a.empresa],
        ['Lançado por', a.lancado_por && `${a.lancado_por}${a.lancado_em ? ` · ${dataHora(a.lancado_em)}` : ''}`],
        ['Falta aprovar', a.esperando],
      ]} />
      {a.tipo !== 'titulo' && <Link className="btn t" to={`/${a.tipo === 'previsao' ? 'previsoes' : 'contratos'}/${a.id}`}>Ver {a.tipo === 'previsao' ? 'a previsão' : 'a conta recorrente'}</Link>}
    </Gaveta>
  );
}
