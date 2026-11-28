// Cadastros › Centros e divisões (Moises, 28/11/2026: "essas árvores precisam ser editáveis/construíveis dentro do sistema.
// Tem que poder incluir novas divisões, galhos e troncos"). Um quadro por centro de custo (o tronco) com as divisões (os
// galhos, até 4 níveis) em árvore; o clique abre a gaveta do nível: nome editado no lugar, as naturezas do último nível
// (o de cima mostra a soma), os núcleos em que o centro vale e os pedidos pendentes. As regras são as do banco
// (migration 20261128000100_api_centros_divisoes): o centro é do administrador; a divisão vai por pedido aprovado (o master
// faz na hora); as naturezas mudam na hora pelo master, administrador, AF, AO e AD. Mover galho ainda não existe.
import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useSearchParams } from 'react-router-dom';
import { Alerta, Cab, Carregando, Chip, Gaveta, Ic, Kv, Secao, Vazio } from '../components/Comum';
import { acha, usePagina } from '../lib/navegar';
import { normal } from '../lib/format';
import { mensagemErro, rpc } from '../lib/supabase';
import type { ArvoreCentros } from '../lib/tipos';

type Arv = ArvoreCentros;
type Div = Arv['divisoes'][number];
type Cen = Arv['centros'][number];
type Ped = Arv['pedidos'][number];
/** Um nó da árvore: o centro (divisao nula) ou uma divisão. */
type No = { centro: Cen; div: Div | null };

const CHAVE = ['centros_arvore'];
const filhosDe = (a: Arv, centro: string, mae: string | null) => a.divisoes.filter(d => d.centro === centro && d.mae === mae);
const ativosDe = (a: Arv, centro: string, mae: string | null) => filhosDe(a, centro, mae).filter(d => d.ativa);
/** As naturezas que valem no nível: a lista dele, ou, com níveis ativos abaixo, a soma das de baixo. */
function naturezasDe(a: Arv, centro: string, mae: string | null, propria: string[]): Set<string> {
  const f = ativosDe(a, centro, mae);
  if (!f.length) return new Set(propria);
  const s = new Set<string>();
  for (const d of f) for (const n of naturezasDe(a, centro, d.id, d.naturezas)) s.add(n);
  return s;
}
const caminho = (a: Arv, d: Div | null): string[] => (d ? [...caminho(a, a.divisoes.find(x => x.id === d.mae) ?? null), d.nome] : []);

export function Centros() {
  const pg = usePagina('/centros');
  const [sp, setSp] = useSearchParams();
  const q = useQuery({ queryKey: CHAVE, queryFn: () => rpc<Arv | null>('centros_arvore') });
  const a = q.data;
  const nova = sp.get('nova');                       // 'centro' ou o id do nível de cima
  const abrirNova = (v: string | null) => { const n = new URLSearchParams(sp); if (v) n.set('nova', v); else n.delete('nova'); setSp(n); };
  const [inativos, setInativos] = useState(false);

  const no: No | null = useMemo(() => {
    if (!a || !pg.id) return null;
    const c = a.centros.find(x => x.id === pg.id);
    if (c) return { centro: c, div: null };
    const d = a.divisoes.find(x => x.id === pg.id);
    const cd = d && a.centros.find(x => x.id === d.centro);
    return d && cd ? { centro: cd, div: d } : null;
  }, [a, pg.id]);
  const ped = a && pg.id ? a.pedidos.find(p => p.id === pg.id) : undefined;

  // a busca acha o centro pelo nome dele ou de qualquer divisão
  const visivel = (c: Cen) => !pg.busca || acha(pg.busca, c.nome) || a!.divisoes.some(d => d.centro === c.id && acha(pg.busca, d.nome));
  const ativos = a ? a.centros.filter(c => c.ativo && visivel(c)) : [];
  const desl = a ? a.centros.filter(c => !c.ativo && visivel(c)) : [];

  return (
    <>
      <div className="f-pag">
        <Cab t="Centros e divisões" abas={false}>
          {pg.busca && <button className="btn t" onClick={pg.limpar}>Limpar busca</button>}
          {a?.pode.centro && <button className="btn p" onClick={() => abrirNova('centro')}><Ic n="add" s={18} />Novo centro</button>}
        </Cab>
        {q.isLoading ? <Carregando /> : q.error ? <Vazio t={mensagemErro(q.error)} /> : !a ? <Vazio t="Sem acesso." />
          : !ativos.length && !desl.length ? <Vazio t={pg.busca ? 'Nada encontrado.' : 'Nenhum centro de custo.'} limpar={pg.busca ? pg.limpar : undefined} />
          : <>
              {ativos.map(c => <Tronco key={c.id} a={a} c={c} sel={pg.id} abrir={pg.abrir} busca={pg.busca} />)}
              {desl.length > 0 && (
                <section className="f-g">
                  <button className="f-gh" onClick={() => setInativos(!inativos)} aria-expanded={inativos}>
                    <span className="sec" style={{ display: 'inline-flex' }}><Ic n={inativos ? 'seta' : 'chev'} s={18} /></span>
                    <b className="sec">Centros inativos</b><span className="f-qt">{desl.length}</span>
                  </button>
                  {inativos && desl.map(c => <Tronco key={c.id} a={a} c={c} sel={pg.id} abrir={pg.abrir} busca={pg.busca} />)}
                </section>
              )}
            </>}
      </div>
      {a && nova && <Nova a={a} em={nova} fechar={() => abrirNova(null)} criado={id => { const n = new URLSearchParams(sp); n.delete('nova'); setSp(n); if (id) pg.abrir(id); }} />}
      {a && !nova && pg.id && (
        no ? <Detalhe key={pg.id} a={a} no={no} fechar={pg.fechar} novo={() => abrirNova(no.div?.id ?? no.centro.id)} />
          : ped ? <DetPedido a={a} p={ped} fechar={pg.fechar} />
          : <Gaveta titulo="Centro ou divisão" fechar={pg.fechar}><Vazio t="Não encontrado." /></Gaveta>
      )}
    </>
  );
}

/** O quadro de um centro de custo com a árvore das divisões. */
function Tronco({ a, c, sel, abrir, busca }: { a: Arv; c: Cen; sel?: string; abrir: (id: string) => void; busca: string }) {
  const [ab, setAb] = useState(true);
  const nat = naturezasDe(a, c.id, null, c.naturezas).size;
  const ndiv = a.divisoes.filter(d => d.centro === c.id && d.ativa).length;
  const pend = a.pedidos.filter(p => p.operacao === 'incluir' && !p.dados.mae_id && p.dados.centro_custo_id === c.id);
  return (
    <section className={`f-g cd-tr ${ab ? 'ab' : ''}`}>
      <div className={`cd-l cd-c ${sel === c.id ? 'sel' : ''}`}>
        <button className="icb cd-ab" onClick={() => setAb(!ab)} aria-expanded={ab} title={ab ? 'Recolher' : 'Abrir'}><Ic n={ab ? 'seta' : 'chev'} s={18} /></button>
        <button className="cd-n" onClick={() => abrir(c.id)}>
          <b>{c.nome}</b>
          <span className="sec peq">{[ndiv ? `${ndiv} ${ndiv === 1 ? 'divisão' : 'divisões'}` : 'Sem divisão', `${nat} ${nat === 1 ? 'natureza' : 'naturezas'}`, `${c.nucleos.length} ${c.nucleos.length === 1 ? 'núcleo' : 'núcleos'}`].join(' · ')}</span>
          {!c.ativo && <Chip t="Inativo" c="ci" />}
          {nat === 0 && c.ativo && <Chip t="Sem natureza" c="at" />}
        </button>
      </div>
      {ab && (
        <div className="cd-gal">
          {filhosDe(a, c.id, null).filter(d => d.ativa || !busca).map(d => <Galho key={d.id} a={a} d={d} sel={sel} abrir={abrir} busca={busca} />)}
          {pend.map(p => <Pendente key={p.id} p={p} nivel={1} sel={sel} abrir={abrir} />)}
        </div>
      )}
    </section>
  );
}

function Galho({ a, d, sel, abrir, busca }: { a: Arv; d: Div; sel?: string; abrir: (id: string) => void; busca: string }) {
  const [ab, setAb] = useState(true);
  const filhos = filhosDe(a, d.centro, d.id);
  const pend = a.pedidos.filter(p => p.operacao === 'incluir' && p.dados.mae_id === d.id);
  const mud = a.pedidos.filter(p => p.operacao === 'alterar' && p.dados.id === d.id);
  const nat = naturezasDe(a, d.centro, d.id, d.naturezas).size;
  const tem = filhos.length + pend.length > 0;
  const folha = !filhos.some(f => f.ativa);
  return (
    <>
      <div className={`cd-l ${sel === d.id ? 'sel' : ''} ${d.ativa ? '' : 'off'}`} style={{ ['--nv' as string]: d.nivel }}>
        {tem ? <button className="icb cd-ab" onClick={() => setAb(!ab)} aria-expanded={ab} title={ab ? 'Recolher' : 'Abrir'}><Ic n={ab ? 'seta' : 'chev'} s={18} /></button>
          : <span className="cd-ab" />}
        <button className="cd-n" onClick={() => abrir(d.id)}>
          <span className={busca && acha(busca, d.nome) ? 'cd-ach' : undefined}>{d.nome}</span>
          <span className="sec peq">{folha ? `${nat} ${nat === 1 ? 'natureza' : 'naturezas'}` : `soma: ${nat}`}</span>
          {!d.ativa && <Chip t="Inativa" c="ci" />}
          {d.ativa && folha && nat === 0 && <Chip t="Sem natureza" c="at" />}
          {mud.length > 0 && <Chip t="Mudança pedida" c="at" />}
        </button>
      </div>
      {ab && filhos.map(f => <Galho key={f.id} a={a} d={f} sel={sel} abrir={abrir} busca={busca} />)}
      {ab && pend.map(p => <Pendente key={p.id} p={p} nivel={d.nivel + 1} sel={sel} abrir={abrir} />)}
    </>
  );
}

function Pendente({ p, nivel, sel, abrir }: { p: Ped; nivel: number; sel?: string; abrir: (id: string) => void }) {
  return (
    <div className={`cd-l pend ${sel === p.id ? 'sel' : ''}`} style={{ ['--nv' as string]: nivel }}>
      <span className="cd-ab" />
      <button className="cd-n" onClick={() => abrir(p.id)}><span>{p.dados.nome}</span><Chip t="Aguardando aprovação" c="at" /></button>
    </div>
  );
}

/** Invalida o que depende da árvore (as janelas de lançamento listam centros, divisões e naturezas). */
function useRecarregar() {
  const qc = useQueryClient();
  return () => { for (const k of ['centros_arvore', 'lancamento_opcoes', 'naturezas_lancaveis']) qc.invalidateQueries({ queryKey: [k] }); };
}

// ---------------------------------------------------------------------------------------------------------------------
// Gaveta do nível
// ---------------------------------------------------------------------------------------------------------------------
function Detalhe({ a, no, fechar, novo }: { a: Arv; no: No; fechar: () => void; novo: () => void }) {
  const recarregar = useRecarregar();
  const { centro: c, div: d } = no;
  const ativo = d ? d.ativa : c.ativo;
  const nomeAtual = d ? d.nome : c.nome;
  const filhosAtivos = ativosDe(a, c.id, d?.id ?? null);
  const folha = !filhosAtivos.length;
  const propria = d ? d.naturezas : c.naturezas;
  const pedidos = d ? a.pedidos.filter(p => p.operacao === 'alterar' && p.dados.id === d.id) : [];
  const podeNome = d ? a.pode.divisao : a.pode.centro;
  const [aviso, setAviso] = useState('');

  const mudar = useMutation({
    mutationFn: async (m: { nome?: string; ativo?: boolean }) => {
      if (!d) { await rpc('alterar_centro', { p_centro: c.id, p_nome: m.nome ?? null, p_ativo: m.ativo ?? null }); return 'aplicada'; }
      const r = await rpc<{ situacao: string }>('pedir_divisao', { p_operacao: 'alterar', p_dados: { id: d.id, ...(m.nome != null ? { nome: m.nome } : {}), ...(m.ativo != null ? { ativa: m.ativo } : {}) }, p_motivo: m.nome != null ? 'Renomear pela tela' : m.ativo ? 'Reativar pela tela' : 'Desativar pela tela' });
      return r.situacao;
    },
    onSuccess: s => { setAviso(s === 'pendente' ? 'Pedido enviado: vale depois da aprovação.' : ''); recarregar(); },
  });

  const trilha = [c.nome, ...caminho(a, d)].join(' › ');
  return (
    <Gaveta titulo={nomeAtual} sub={!ativo ? <Chip t={d ? 'Inativa' : 'Inativo'} c="ci" /> : undefined} fechar={fechar}
      pe={(podeNome && (ativo ? (!d || d.nivel < 4) : true)) ? <>
        {ativo && podeNome && (!d || d.nivel < 4) && <button className="btn" onClick={novo}><Ic n="add" s={18} />{d ? 'Adicionar nível abaixo' : 'Adicionar divisão'}</button>}
        <span className="esp" />
        {podeNome && <button className={`btn t ${ativo ? 'cr' : ''}`} disabled={mudar.isPending || (ativo && !!d && filhosAtivos.length > 0)}
          title={ativo && d && filhosAtivos.length ? 'Desative antes os níveis abaixo' : undefined}
          onClick={() => mudar.mutate({ ativo: !ativo })}>{ativo ? 'Desativar' : 'Reativar'}</button>}
      </> : undefined}>
      <NomeNoLugar v={nomeAtual} pode={podeNome && ativo} rotulo={d ? 'Nome da divisão' : 'Nome do centro'} gravando={mudar.isPending}
        erro={mudar.error ? mensagemErro(mudar.error) : ''} gravar={n => mudar.mutate({ nome: n })} />
      {aviso && <Alerta c="at" t={aviso} />}
      <Kv l={[['Onde fica', d ? trilha : null], ['Nível', d ? `Divisão nível ${d.nivel}` : 'Centro de custo']]} />
      {pedidos.map(p => <PedidoLinha key={p.id} p={p} />)}
      {folha
        ? <NaturezasDoNivel key={(d ?? c).id} a={a} centro={c.id} divisao={d?.id ?? null} lista={propria} pode={a.pode.naturezas && ativo} recarregar={recarregar} />
        : <Secao t={`Naturezas: a soma dos níveis abaixo (${naturezasDe(a, c.id, d?.id ?? null, propria).size})`}>
            <p className="sec peq">Só o último nível tem lista própria. Para mudar, abra o nível de baixo.</p>
            <ArvoreNat a={a} marcadas={naturezasDe(a, c.id, d?.id ?? null, propria)} so />
          </Secao>}
      {!d && <Nucleos a={a} c={c} recarregar={recarregar} />}
    </Gaveta>
  );
}

/** Nome editado no lugar (como o apelido das empresas): grava ao sair ou no Enter; Esc volta. */
function NomeNoLugar({ v, pode, rotulo, gravar, gravando, erro }: { v: string; pode: boolean; rotulo: string; gravar: (n: string) => void; gravando: boolean; erro: string }) {
  const [t, setT] = useState(v);
  useEffect(() => setT(v), [v]);
  if (!pode) return null;
  const ok = () => { const n = t.trim(); if (n && n !== v) gravar(n); else setT(v); };
  return (
    <label className="em-ap">
      <span className="em-rot">{rotulo}</span>
      <input className={`lt-in ${erro ? 'err' : ''}`} value={t} maxLength={60} onChange={e => setT(e.target.value)} onBlur={ok}
        onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); ok(); } if (e.key === 'Escape') { e.stopPropagation(); setT(v); } }} />
      {(erro || gravando) && <span className={erro ? 'lt-erro' : 'sec peq'}>{erro || 'Gravando…'}</span>}
    </label>
  );
}

/** As naturezas do último nível: marcar à mão ou por modelo, e salvar (liga e desliga na hora). */
function NaturezasDoNivel({ a, centro, divisao, lista, pode, recarregar }: { a: Arv; centro: string; divisao: string | null; lista: string[]; pode: boolean; recarregar: () => void }) {
  const [m, setM] = useState(() => new Set(lista));
  useEffect(() => setM(new Set(lista)), [lista]);
  const mudou = m.size !== lista.length || lista.some(x => !m.has(x));
  const salvar = useMutation({ mutationFn: () => rpc<number>('salvar_naturezas', { p_centro: centro, p_divisao: divisao, p_naturezas: [...m] }), onSuccess: recarregar });
  return (
    <Secao t={`Naturezas liberadas (${m.size})`}>
      {pode && <Modelos a={a} marcadas={m} aplicar={s => { setM(s); salvar.reset(); }} />}
      <ArvoreNat a={a} marcadas={m} so={!pode} mudar={s => { setM(s); salvar.reset(); }} />
      {pode && (mudou || salvar.error) && (
        <div className="cd-salvar">
          {salvar.error ? <span className="lt-erro"><Ic n="warn" s={18} />{mensagemErro(salvar.error)}</span> : <span className="sec peq">Valem para os lançamentos novos; o que já foi lançado não muda.</span>}
          <span className="esp" />
          <button className="btn t" onClick={() => { setM(new Set(lista)); salvar.reset(); }}>Desfazer</button>
          <button className="btn p" disabled={salvar.isPending} onClick={() => salvar.mutate()}>{salvar.isPending ? 'Salvando…' : 'Salvar naturezas'}</button>
        </div>
      )}
    </Secao>
  );
}

/** Aplicar um modelo salvo à lista marcada, ou salvar a marcada como modelo. */
function Modelos({ a, marcadas, aplicar }: { a: Arv; marcadas: Set<string>; aplicar: (s: Set<string>) => void }) {
  const recarregar = useRecarregar();
  const [nome, setNome] = useState<string | null>(null);
  const salvar = useMutation({ mutationFn: () => rpc<string>('salvar_modelo_naturezas', { p_nome: nome, p_naturezas: [...marcadas] }), onSuccess: () => { setNome(null); recarregar(); } });
  return (
    <div className="cd-mod">
      {a.modelos.length > 0 && (
        <select className="lt-in" value="" onChange={e => { const mo = a.modelos.find(x => x.id === e.target.value); if (mo) aplicar(new Set(mo.naturezas)); }} aria-label="Aplicar modelo">
          <option value="">Aplicar um modelo…</option>
          {a.modelos.map(mo => <option key={mo.id} value={mo.id}>{mo.nome} ({mo.naturezas.length})</option>)}
        </select>
      )}
      {nome == null
        ? marcadas.size > 0 && <button className="btn t sm" onClick={() => setNome('')}>Salvar como modelo</button>
        : <>
            <input className="lt-in" autoFocus placeholder="Nome do modelo" maxLength={60} value={nome} onChange={e => { setNome(e.target.value); salvar.reset(); }}
              onKeyDown={e => { if (e.key === 'Enter' && nome.trim()) salvar.mutate(); if (e.key === 'Escape') { e.stopPropagation(); setNome(null); } }} />
            <button className="btn sm" disabled={!nome.trim() || salvar.isPending} onClick={() => salvar.mutate()}>Salvar</button>
            <button className="btn t sm" onClick={() => setNome(null)}>Cancelar</button>
            {salvar.error && <span className="lt-erro">{mensagemErro(salvar.error)}</span>}
          </>}
    </div>
  );
}

/** A árvore das naturezas com caixas: o grupo marca e desmarca as de baixo; a busca filtra pelo caminho. */
function ArvoreNat({ a, marcadas, mudar, so }: { a: Arv; marcadas: Set<string>; mudar?: (s: Set<string>) => void; so?: boolean }) {
  const [busca, setBusca] = useState('');
  const [abertos, setAbertos] = useState<Set<string>>(new Set());
  const filhos = useMemo(() => {
    const f = new Map<string | null, Arv['naturezas']>();
    for (const n of a.naturezas) { if (!n.ativa && !marcadas.has(n.id)) continue; const k = n.mae; if (!f.has(k)) f.set(k, []); f.get(k)!.push(n); }
    return f;
  }, [a.naturezas, marcadas]);
  const b = normal(busca.trim());
  const folhasDe = (id: string): string[] => { const f = filhos.get(id) ?? []; return f.length ? f.flatMap(x => folhasDe(x.id)) : [id]; };
  const passa = (n: Arv['naturezas'][number]) => !b || normal(n.caminho).includes(b) || normal(n.codigo).includes(b);
  // só leitura: mostra só o que está marcado
  const mostra = (id: string): boolean => { const n = a.naturezas.find(x => x.id === id)!; const f = filhos.get(id) ?? [];
    return f.length ? f.some(x => mostra(x.id)) : passa(n) && (!so || marcadas.has(id)); };
  const marcar = (ids: string[], on: boolean) => { if (!mudar) return; const s = new Set(marcadas); for (const i of ids) { if (on) s.add(i); else s.delete(i); } mudar(s); };
  const todas = (filhos.get(null) ?? []).flatMap(n => folhasDe(n.id));

  const linha = (n: Arv['naturezas'][number], nv: number): ReactNode => {
    if (!mostra(n.id)) return null;
    const f = filhos.get(n.id) ?? [];
    const fo = folhasDe(n.id);
    const qt = fo.filter(x => marcadas.has(x)).length;
    const ab = !!b || abertos.has(n.id);
    const ck = qt === 0 ? '' : qt === fo.length ? 'on' : 'mei';
    return (
      <div key={n.id}>
        <div className="cd-nl" style={{ ['--nv' as string]: nv }}>
          {f.length ? <button className="icb cd-ab" onClick={() => { const s = new Set(abertos); if (s.has(n.id)) s.delete(n.id); else s.add(n.id); setAbertos(s); }} aria-expanded={ab}><Ic n={ab ? 'seta' : 'chev'} s={16} /></button> : <span className="cd-ab" />}
          <label className={`cd-ck ${so ? 'so' : ''}`}>
            {!so && <input type="checkbox" checked={ck === 'on'} ref={el => { if (el) el.indeterminate = ck === 'mei'; }} onChange={e => marcar(fo, e.target.checked)} />}
            <span className={n.ativa ? undefined : 'sec'}>{n.codigo && <span className="sec num">{n.codigo} </span>}{n.nome}</span>
            {f.length > 0 && <span className="sec peq num">{qt}/{fo.length}</span>}
          </label>
        </div>
        {f.length > 0 && ab && f.map(x => linha(x, nv + 1))}
      </div>
    );
  };
  return (
    <div className="cd-nat">
      <div className="cd-nat-b">
        <input className="lt-in" placeholder="Buscar natureza" value={busca} onChange={e => setBusca(e.target.value)} aria-label="Buscar natureza" />
        {!so && <><button className="btn t sm" onClick={() => marcar(todas, true)}>Marcar todas</button><button className="btn t sm" onClick={() => marcar(todas, false)}>Desmarcar todas</button></>}
      </div>
      <div className="cd-nat-l">{(filhos.get(null) ?? []).map(n => linha(n, 0))}</div>
    </div>
  );
}

/** Os núcleos em que o centro vale: liga e desliga na hora. */
function Nucleos({ a, c, recarregar }: { a: Arv; c: Cen; recarregar: () => void }) {
  const ligar = useMutation({ mutationFn: (x: { n: string; on: boolean }) => rpc('ligar_centro', { p_centro: c.id, p_nucleo: x.n, p_ligado: x.on }), onSuccess: recarregar });
  return (
    <Secao t={`Núcleos em que vale (${c.nucleos.length} de ${a.nucleos.length})`}>
      {ligar.error && <Alerta c="cr" t={mensagemErro(ligar.error)} />}
      <div className="cd-nuc">
        {a.nucleos.map(n => (
          <label key={n.id} className="cd-ck">
            {a.pode.centro && <input type="checkbox" checked={c.nucleos.includes(n.id)} disabled={ligar.isPending} onChange={e => ligar.mutate({ n: n.id, on: e.target.checked })} />}
            {(a.pode.centro || c.nucleos.includes(n.id)) && <><span>{n.nome}</span>{n.empresa && n.empresa !== n.nome && <span className="sec peq">{n.empresa}</span>}</>}
          </label>
        ))}
      </div>
      <p className="sec peq">Desligar não apaga o que já foi lançado; só impede lançamento novo no núcleo.</p>
    </Secao>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Pedidos
// ---------------------------------------------------------------------------------------------------------------------
function textoPedido(p: Ped) {
  if (p.operacao === 'incluir') return `Criar “${p.dados.nome}”`;
  if (p.dados.nome && p.antes && p.dados.nome !== p.antes.nome) return `Renomear para “${p.dados.nome}”`;
  return p.dados.ativa ? 'Reativar' : 'Desativar';
}

function PedidoLinha({ p }: { p: Ped }) {
  const recarregar = useRecarregar();
  const [just, setJust] = useState<string | null>(null);
  const decidir = useMutation({ mutationFn: (sim: boolean) => rpc<string>('decidir_pedido_divisao', { p_pedido: p.id, p_aprova: sim, p_justificativa: sim ? null : just }), onSuccess: recarregar });
  const cancelar = useMutation({ mutationFn: () => rpc('cancelar_pedido_divisao', { p_pedido: p.id }), onSuccess: recarregar });
  const erro = decidir.error ?? cancelar.error;
  return (
    <div className="cd-ped">
      <div><b>{textoPedido(p)}</b> <Chip t="Aguardando aprovação" c="at" /></div>
      <div className="sec peq">{p.meu ? 'Você pediu' : `${p.pedida_por ?? 'Alguém'} pediu`} · {p.motivo} · {p.votos} de {p.minimo} {p.minimo === 1 ? 'aprovação' : 'aprovações'}</div>
      {erro && <span className="lt-erro">{mensagemErro(erro)}</span>}
      {just != null && <textarea className="lt-in" rows={2} autoFocus placeholder="Por que recusa?" value={just} onChange={e => setJust(e.target.value)} />}
      <div className="cd-ped-b">
        {p.posso_decidir && (just == null
          ? <><button className="btn sm p" disabled={decidir.isPending} onClick={() => decidir.mutate(true)}>Aprovar</button><button className="btn sm" onClick={() => setJust('')}>Recusar</button></>
          : <><button className="btn sm cr" disabled={!just.trim() || decidir.isPending} onClick={() => decidir.mutate(false)}>Recusar</button><button className="btn t sm" onClick={() => setJust(null)}>Voltar</button></>)}
        {p.meu && <button className="btn t sm" disabled={cancelar.isPending} onClick={() => cancelar.mutate()}>Cancelar pedido</button>}
      </div>
    </div>
  );
}

function DetPedido({ a, p, fechar }: { a: Arv; p: Ped; fechar: () => void }) {
  const mae = a.divisoes.find(d => d.id === p.dados.mae_id);
  const c = a.centros.find(x => x.id === (mae?.centro ?? p.dados.centro_custo_id));
  return (
    <Gaveta titulo={p.dados.nome ?? 'Pedido'} sub={<Chip t="Aguardando aprovação" c="at" />} fechar={fechar}>
      <Kv l={[['Onde fica', [c?.nome, ...caminho(a, mae ?? null)].filter(Boolean).join(' › ')], ['Nível', `Divisão nível ${(mae?.nivel ?? 0) + 1}`]]} />
      <PedidoLinha p={p} />
    </Gaveta>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Novo centro ou nova divisão
// ---------------------------------------------------------------------------------------------------------------------
type Origem = 'marcar' | 'modelo' | 'copiar';

function Nova({ a, em, fechar, criado }: { a: Arv; em: string; fechar: () => void; criado: (id: string | null) => void }) {
  const recarregar = useRecarregar();
  const centro = em === 'centro';
  const cPai = a.centros.find(c => c.id === em);
  const dPai = a.divisoes.find(d => d.id === em);
  const cDe = cPai ?? a.centros.find(c => c.id === dPai?.centro);
  const mae = dPai?.id ?? null;
  const [nome, setNome] = useState('');
  const [origem, setOrigem] = useState<Origem>('marcar');
  const [marc, setMarc] = useState<Set<string>>(new Set());
  const [modelo, setModelo] = useState('');
  const [de, setDe] = useState('');
  const [nucs, setNucs] = useState<Set<string>>(new Set());
  const [motivo, setMotivo] = useState('');
  const [tentou, setTentou] = useState(false);

  // de quem copiar: no centro novo, outro centro; na divisão, uma irmã com lista própria ou, no 1º nível abaixo, o de cima
  const irmas = !centro && cDe ? ativosDe(a, cDe.id, mae).filter(d => !ativosDe(a, cDe.id, d.id).length && d.naturezas.length) : [];
  const deCima = !centro && cDe && !ativosDe(a, cDe.id, mae).length
    ? (dPai ? (dPai.naturezas.length ? { id: dPai.id, nome: `${dPai.nome} (o nível de cima)` } : null)
      : (cDe.naturezas.length ? { id: cDe.id, nome: `${cDe.nome} (o centro)` } : null)) : null;
  const copiaveis = centro ? a.centros.filter(c => c.ativo).map(c => ({ id: c.id, nome: c.nome })) : [...(deCima ? [deCima] : []), ...irmas.map(d => ({ id: d.id, nome: d.nome }))];
  useEffect(() => { if (!centro && deCima && !irmas.length) { setOrigem('copiar'); setDe(deCima.id); } }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const lista = (): string[] => {
    if (origem === 'marcar') return [...marc];
    if (origem === 'modelo') return a.modelos.find(m => m.id === modelo)?.naturezas ?? [];
    if (centro) { const c = a.centros.find(x => x.id === de); return c ? [...naturezasDe(a, c.id, null, c.naturezas)] : []; }
    return [];
  };
  const falta: string[] = [];
  if (!nome.trim()) falta.push('o nome');
  if (origem === 'copiar' ? !de : !lista().length) falta.push('as naturezas');
  if (!centro && !a.pode.na_hora && !motivo.trim()) falta.push('o motivo');

  const enviar = useMutation({
    mutationFn: async (): Promise<{ id: string | null; pendente: boolean }> => {
      if (centro) return { id: await rpc<string>('criar_centro', { p_nome: nome, p_naturezas: lista(), p_nucleos: [...nucs] }), pendente: false };
      const dados: Record<string, unknown> = { nome, ...(mae ? { mae_id: mae } : { centro_custo_id: cDe!.id }) };
      if (origem === 'copiar') dados.copiar_de = de; else dados.naturezas = lista();
      const r = await rpc<{ situacao: string; divisao: string; pedido: string }>('pedir_divisao', { p_operacao: 'incluir', p_dados: dados, p_motivo: motivo || null });
      return r.situacao === 'aplicada' ? { id: r.divisao, pendente: false } : { id: r.pedido, pendente: true };
    },
    onSuccess: r => { recarregar(); criado(r.id); },
  });
  const ir = () => { setTentou(true); if (!falta.length) enviar.mutate(); };

  if (!centro && !cDe) return <Gaveta titulo="Nova divisão" fechar={fechar}><Vazio t="Nível de cima não encontrado." /></Gaveta>;
  const onde = centro ? null : [cDe!.nome, ...caminho(a, dPai ?? null)].join(' › ');
  const nivel = (dPai?.nivel ?? 0) + 1;
  const primeiro = !centro && !ativosDe(a, cDe!.id, mae).length;
  return (
    <Gaveta titulo={centro ? 'Novo centro de custo' : `Nova divisão nível ${nivel}`} fechar={fechar} pe={<>
      {enviar.error ? <span className="lt-erro"><Ic n="warn" s={18} />{mensagemErro(enviar.error)}</span>
        : tentou && falta.length ? <span className="lt-erro"><Ic n="warn" s={18} />Falta {falta.join(', ')}.</span> : <span className="esp" />}
      <button className="btn t" onClick={fechar}>Cancelar</button>
      <button className="btn p" disabled={enviar.isPending} onClick={ir}>{enviar.isPending ? 'Enviando…' : centro || a.pode.na_hora ? 'Criar' : 'Pedir criação'}</button>
    </>}>
      {onde && <Kv l={[['Abaixo de', onde]]} />}
      <label className="em-ap">
        <span className="em-rot">Nome</span>
        <input className={`lt-in ${tentou && !nome.trim() ? 'err' : ''}`} autoFocus maxLength={60} value={nome} onChange={e => setNome(e.target.value)} />
      </label>
      {primeiro && dPai && <p className="nt at">“{dPai.nome}” passa a ser a soma dos níveis abaixo. O que já foi lançado nela fica; os lançamentos novos exigem o nível de baixo.</p>}
      <Secao t="Naturezas liberadas">
        <div className="f-seg cd-seg">
          <button className={origem === 'marcar' ? 'on' : ''} onClick={() => setOrigem('marcar')}>Marcar</button>
          {a.modelos.length > 0 && <button className={origem === 'modelo' ? 'on' : ''} onClick={() => setOrigem('modelo')}>Modelo</button>}
          {copiaveis.length > 0 && <button className={origem === 'copiar' ? 'on' : ''} onClick={() => setOrigem('copiar')}>Copiar de</button>}
        </div>
        {origem === 'marcar' && <ArvoreNat a={a} marcadas={marc} mudar={setMarc} />}
        {origem === 'modelo' && (
          <select className={`lt-in ${tentou && !modelo ? 'err' : ''}`} value={modelo} onChange={e => setModelo(e.target.value)} aria-label="Modelo">
            <option value="">Escolha o modelo</option>
            {a.modelos.map(m => <option key={m.id} value={m.id}>{m.nome} ({m.naturezas.length})</option>)}
          </select>
        )}
        {origem === 'copiar' && (
          <select className={`lt-in ${tentou && !de ? 'err' : ''}`} value={de} onChange={e => setDe(e.target.value)} aria-label="Copiar de">
            <option value="">{centro ? 'Escolha o centro' : 'Escolha a divisão irmã'}</option>
            {copiaveis.map(x => <option key={x.id} value={x.id}>{x.nome}</option>)}
          </select>
        )}
      </Secao>
      {centro && (
        <Secao t="Núcleos em que vale">
          <div className="cd-nat-b">
            <button className="btn t sm" onClick={() => setNucs(new Set(a.nucleos.map(n => n.id)))}>Marcar todos</button>
            <button className="btn t sm" onClick={() => setNucs(new Set())}>Desmarcar todos</button>
          </div>
          <div className="cd-nuc">
            {a.nucleos.map(n => (
              <label key={n.id} className="cd-ck">
                <input type="checkbox" checked={nucs.has(n.id)} onChange={e => { const s = new Set(nucs); if (e.target.checked) s.add(n.id); else s.delete(n.id); setNucs(s); }} />
                <span>{n.nome}</span>{n.empresa && n.empresa !== n.nome && <span className="sec peq">{n.empresa}</span>}
              </label>
            ))}
          </div>
        </Secao>
      )}
      {!centro && !a.pode.na_hora && (
        <label className="em-ap">
          <span className="em-rot">Motivo</span>
          <input className={`lt-in ${tentou && !motivo.trim() ? 'err' : ''}`} value={motivo} maxLength={200} onChange={e => setMotivo(e.target.value)} placeholder="Para quem vai aprovar" />
          <span className="sec peq">A divisão nova entra no acesso de quem tem as futuras, por isso passa por aprovação.</span>
        </label>
      )}
    </Gaveta>
  );
}
