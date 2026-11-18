// Rastro do título (pedido do Moises, 18/11/2026): botões na gaveta que abrem popups com a origem, as aprovações de todas
// as rodadas, os pedidos de alteração com o antes e o depois, o histórico, os anexos, o contrato e o fornecedor.
// Os dados vêm de api.titulo_rastro, uma chamada só, feita quando o primeiro botão é aberto.
import { useQuery } from '@tanstack/react-query';
import { useEffect, useState, type ReactNode } from 'react';
import { data, dataHora, documento, mes, reais } from '../lib/format';
import type { NomeIcone } from '../lib/icones';
import { mensagemErro, rpc } from '../lib/supabase';
import type { Rastro as R } from '../lib/tipos';
import { ETAPA } from '../pages/Titulos';
import { Carregando, Chip, Ic, Kv, Vazio } from './Comum';

type Aba = 'origem' | 'aprovacoes' | 'alteracoes' | 'historico' | 'anexos' | 'contrato' | 'fornecedor';
const ABAS: [Aba, string, NomeIcone][] = [
  ['origem', 'Origem', 'origem'], ['aprovacoes', 'Aprovações', 'check'], ['alteracoes', 'Alterações', 'edit'],
  ['historico', 'Histórico', 'historico'], ['anexos', 'Anexos', 'anexo'], ['contrato', 'Contrato', 'money'], ['fornecedor', 'Fornecedor', 'predio'],
];
const TIPO: Record<string, string> = { contrato: 'Contrato', pedido: 'Pedido', assinatura: 'Conta recorrente', avulsa: 'Compra avulsa', guia: 'Guia', folha: 'Folha' };
const NOTA: Record<string, string> = { nfse: 'NFS-e', nfe: 'NF-e', fatura: 'Fatura', boleto: 'Boleto', guia: 'Guia', recibo: 'Recibo', outro: 'Documento' };
const PER: Record<string, string> = { mensal: 'por mês', bimestral: 'por bimestre', trimestral: 'por trimestre', semestral: 'por semestre', anual: 'por ano' };

export function RastroBotoes({ id }: { id: string }) {
  const [aba, setAba] = useState<Aba | null>(null);
  const q = useQuery({ queryKey: ['rastro', id], queryFn: () => rpc<R>('titulo_rastro', { p_id: id }), enabled: aba != null, staleTime: 30_000 });
  const r = q.data;
  const qt: Partial<Record<Aba, number>> = r ? {
    aprovacoes: r.aprovacoes.length, alteracoes: r.alteracoes.length, historico: r.historico.length, anexos: r.anexos.length,
  } : {};
  const tem = (a: Aba) => a !== 'contrato' || !r || r.contrato != null;
  return (
    <>
      <div className="rs-bar" role="toolbar" aria-label="Rastro do título">
        {ABAS.filter(([a]) => tem(a)).map(([a, rot, ic]) => (
          <button key={a} className="rs-b" onClick={() => setAba(a)}>
            <Ic n={ic} s={18} />{rot}{qt[a] ? <span className="rs-n">{qt[a]}</span> : null}
          </button>
        ))}
      </div>
      {aba && (
        <Popup titulo={ABAS.find(x => x[0] === aba)![1]} fechar={() => setAba(null)}
          abas={<div className="rs-tabs">{ABAS.filter(([a]) => tem(a)).map(([a, rot]) => <button key={a} className={a === aba ? 'on' : ''} onClick={() => setAba(a)}>{rot}</button>)}</div>}>
          {q.isLoading ? <Carregando /> : q.error ? <Vazio t={mensagemErro(q.error)} /> : r ? <Conteudo aba={aba} r={r} ir={setAba} /> : null}
        </Popup>
      )}
    </>
  );
}

/** Janela sobre a página (Material 3: raio 28, véu escuro); Esc e o véu fecham. No celular, tela cheia. */
export function Popup({ titulo, fechar, abas, children }: { titulo: string; fechar: () => void; abas?: ReactNode; children: ReactNode }) {
  useEffect(() => {
    const tecla = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopPropagation(); fechar(); } };
    document.addEventListener('keydown', tecla, true);
    return () => document.removeEventListener('keydown', tecla, true);
  }, [fechar]);
  return (
    <div className="pp-veu" onMouseDown={e => { if (e.target === e.currentTarget) fechar(); }}>
      <div className="pp" role="dialog" aria-modal="true" aria-label={titulo}>
        <div className="pp-h"><h2>{titulo}</h2><button className="icb" title="Fechar (Esc)" onClick={fechar}><Ic n="close" /></button></div>
        {abas}
        <div className="pp-b">{children}</div>
      </div>
    </div>
  );
}

function Conteudo({ aba, r, ir }: { aba: Aba; r: R; ir: (a: Aba) => void }) {
  switch (aba) {
    case 'origem': return <Origem r={r} ir={ir} />;
    case 'aprovacoes': return <Aprovacoes r={r} />;
    case 'alteracoes': return <Alteracoes r={r} />;
    case 'historico': return <Historico r={r} />;
    case 'anexos': return <Anexos r={r} />;
    case 'contrato': return <Contrato r={r} />;
    case 'fornecedor': return <Fornecedor r={r} />;
  }
}

const Nada = ({ t }: { t: string }) => <p className="sec rs-nada">{t}</p>;
const Pessoa = ({ n }: { n: string | null }) => <span className="rs-av" aria-hidden="true">{(n ?? '?')[0]}</span>;

function Origem({ r, ir }: { r: R; ir: (a: Aba) => void }) {
  const o = r.origem;
  const passos: { t: string; s: string }[] = [
    ...o.previsoes.map(p => ({ t: `Previsão${p.sienge ? ` ${p.sienge}` : ''}`, s: reais(p.valor) })),
    ...(o.compromisso ? [{ t: `${TIPO[o.compromisso.tipo] ?? 'Contrato'}${o.compromisso.numero ? ` ${o.compromisso.numero}` : ''}`, s: o.compromisso.descricao }] : []),
    ...(o.nota ? [{ t: `${NOTA[o.nota.tipo] ?? 'Nota'} ${o.nota.numero}`, s: reais(o.nota.valor_bruto) }] : []),
    { t: 'Este título', s: '' },
  ];
  return (
    <>
      <ol className="rs-cad">{passos.map((p, i) => <li key={i} className={i === passos.length - 1 ? 'eu' : ''}><b>{p.t}</b>{p.s && <span>{p.s}</span>}</li>)}</ol>
      {o.compromisso && (
        <div className="rs-card">
          <div className="rs-ch"><b>{TIPO[o.compromisso.tipo]} {o.compromisso.numero}</b><button className="btn t" onClick={() => ir('contrato')}>Ver saldo e pagamentos</button></div>
          <Kv l={[
            ['Descrição', o.compromisso.descricao],
            ['Vigência', `${data(o.compromisso.inicio)}${o.compromisso.fim ? ` a ${data(o.compromisso.fim)}` : ', sem fim'}`],
            ['Valor', o.compromisso.valor_periodo ? `${reais(o.compromisso.valor_periodo)} ${PER[o.compromisso.periodicidade ?? ''] ?? ''}` : reais(o.compromisso.valor_total)],
            ['Situação', o.compromisso.situacao === 'ativo' ? 'Ativo' : o.compromisso.situacao === 'encerrado' ? 'Encerrado' : 'Cancelado'],
            ['Lançado por', o.compromisso.lancado_por],
          ]} />
        </div>
      )}
      {o.nota && (
        <div className="rs-card">
          <div className="rs-ch"><b>{NOTA[o.nota.tipo]} {o.nota.numero}{o.nota.serie ? ` série ${o.nota.serie}` : ''}</b><button className="btn t" onClick={() => ir('anexos')}>Ver arquivo</button></div>
          <Kv l={[['Emissão', data(o.nota.emissao)], ['Valor bruto', reais(o.nota.valor_bruto)], ['Lançada por', o.nota.lancada_por && `${o.nota.lancada_por} · ${dataHora(o.nota.lancada_em)}`]]} />
        </div>
      )}
      {o.previsoes.length > 0 && (
        <div className="rs-card">
          <div className="rs-ch"><b>{o.previsoes.length > 1 ? 'Previsões consumidas' : 'Previsão consumida'}</b></div>
          {o.previsoes.map(p => <div key={p.id} className="rs-li"><span>{p.sienge ?? 'Previsão'} · prevista para {data(p.data_prevista)}{p.aprovada_por && <span className="sec"> · aprovada por {p.aprovada_por}</span>}</span><b className="num">{reais(p.valor)}</b></div>)}
        </div>
      )}
      {o.substitui && <div className="rs-card"><div className="rs-ch"><b>Substitui o título {o.substitui.numero ?? ''}</b></div><p className="sec">{o.substitui.motivo}</p></div>}
      {!o.compromisso && !o.nota && !o.previsoes.length && <Nada t="Título avulso, sem contrato, nota ou previsão antes dele." />}
    </>
  );
}

function Aprovacoes({ r }: { r: R }) {
  if (!r.aprovacoes.length) return <Nada t="Ninguém aprovou ainda." />;
  const rodadas = [...new Set(r.aprovacoes.map(a => a.rodada))].sort((a, b) => b - a);
  return (
    <>
      {rodadas.map(n => (
        <section key={n} className="rs-sec">
          <h3>{rodadas.length > 1 ? `Rodada ${n}${n === r.rodada_atual ? ', a atual' : ''}` : 'Aprovações'}</h3>
          {r.aprovacoes.filter(a => a.rodada === n).map((a, i) => (
            <div key={i} className="rs-ev">
              <Pessoa n={a.por} />
              <div className="rs-evc">
                <div><b>{a.por ?? '—'}</b> <Chip t={a.aprovado ? 'Aprovou' : 'Recusou'} c={a.aprovado ? 'ok' : 'cr'} /></div>
                <div className="sec peq">{[a.area, `fase ${a.fase} · ${a.lista}`, a.origem === 'outra_alcada' ? 'valeu pela outra alçada' : a.origem === 'ajuste' ? 'por ajuste' : null].filter(Boolean).join(' · ')}</div>
                {a.justificativa && <div className="rs-q">{a.justificativa}</div>}
              </div>
              <span className="sec peq num">{dataHora(a.em)}</span>
            </div>
          ))}
        </section>
      ))}
    </>
  );
}

function Alteracoes({ r }: { r: R }) {
  if (!r.alteracoes.length) return <Nada t="Nenhum pedido de alteração." />;
  return (
    <>
      {r.alteracoes.map((a, i) => (
        <div key={i} className="rs-card">
          <div className="rs-ch"><b>Pedido de {a.pedida_por ?? '—'}</b><span className="sec peq">{dataHora(a.pedida_em)}{a.area ? ` · ${a.area}` : ''}</span></div>
          <div className="rs-q">{a.motivo}</div>
          {a.reenviada_em
            ? <div className="rs-resp"><Ic n="back" s={16} /><span><b>{a.reenviada_por}</b> reenviou em {dataHora(a.reenviada_em)}{a.resposta ? `: ${a.resposta}` : ''}</span></div>
            : <div className="rs-resp sec"><Ic n="clock" s={16} />Esperando quem lançou</div>}
          {a.ajustes.length > 0 && (
            <table className="rs-tab"><thead><tr><th>Campo</th><th>Antes</th><th>Depois</th></tr></thead>
              <tbody>{a.ajustes.map((x, j) => <tr key={j}><td>{x.campo}</td><td className="rs-antes">{x.antes ?? '—'}</td><td>{x.depois ?? '—'}</td></tr>)}</tbody></table>
          )}
        </div>
      ))}
    </>
  );
}

function Historico({ r }: { r: R }) {
  if (!r.historico.length) return <Nada t="Sem registros." />;
  return (
    <ol className="rs-tl">
      {r.historico.map((h, i) => <li key={i}><span className="sec peq num">{dataHora(h.em)}</span><span><b>{h.por ?? 'Sistema'}</b> {h.texto}</span></li>)}
    </ol>
  );
}

const tam = (b: number) => b >= 1048576 ? `${(b / 1048576).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} MB` : `${Math.max(1, Math.round(b / 1024))} KB`;
function Anexos({ r }: { r: R }) {
  return (
    <>
      <div className="rs-anx">
        {r.anexos.map(a => (
          <a key={a.id} className="rs-ax" href={a.url ?? undefined} target="_blank" rel="noreferrer">
            <span className={`rs-th ${a.mime.startsWith('image/') ? 'img' : a.mime === 'application/pdf' ? 'pdf' : ''}`}>
              <Ic n={a.mime.startsWith('image/') || a.mime.startsWith('video/') ? 'imagem' : 'doc'} s={28} />
              <span className="rs-ext">{a.nome.split('.').pop()?.toUpperCase()}</span>
            </span>
            <b title={a.nome}>{a.nome}</b>
            <span className="sec peq">{a.categoria} · {tam(a.tamanho)}</span>
            <span className="sec peq">{a.por} · {data(a.em)}</span>
          </a>
        ))}
        <button className="rs-ax rs-add"><Ic n="upload" s={28} /><b>Adicionar anexo</b><span className="sec peq">Nota, contrato, foto ou vídeo</span></button>
      </div>
    </>
  );
}

function Contrato({ r }: { r: R }) {
  const c = r.contrato;
  if (!c) return <Nada t="Este título não vem de um contrato." />;
  const base = c.valor_total ?? null;
  const pct = base ? Math.min(100, (c.lancado / base) * 100) : null;
  const pctPago = base ? Math.min(100, (c.pago / base) * 100) : null;
  return (
    <>
      <div className="rs-ch"><b>{TIPO[c.tipo]} {c.numero} · {c.descricao}</b></div>
      <div className="rs-nums">
        <div><span>{c.valor_periodo ? `Valor ${PER[c.periodicidade ?? ''] ?? ''}` : 'Valor do contrato'}</span><b className="num">{reais(c.valor_periodo ?? c.valor_total)}</b></div>
        <div><span>Já lançado</span><b className="num">{reais(c.lancado)}</b></div>
        <div><span>Pago</span><b className="num">{reais(c.pago)}</b></div>
        <div><span>Saldo</span><b className="num">{c.saldo != null ? reais(c.saldo) : '—'}</b></div>
      </div>
      {pct != null && <div className="rs-barra" aria-label={`${Math.round(pct)}% lançado`}><span className="lan" style={{ width: `${pct}%` }} /><span className="pag" style={{ width: `${pctPago}%` }} /></div>}
      {pct != null && <div className="rs-leg sec peq"><span><i className="pag" />Pago</span><span><i className="lan" />Lançado, a pagar</span><span><i />Saldo</span></div>}
      <table className="rs-tab"><thead><tr><th>Competência</th><th>Documento</th><th>Situação</th><th>Pago em</th><th className="r">Valor</th></tr></thead>
        <tbody>{c.titulos.map(t => (
          <tr key={t.id} className={t.este ? 'eu' : ''}><td>{mes(t.competencia)}</td><td>{t.documento ?? '—'}{t.este && <span className="sec"> · este</span>}</td>
            <td><Chip t={ETAPA[t.etapa][0]} c={ETAPA[t.etapa][1]} /></td><td className="num">{t.pago_em ? data(t.pago_em) : '—'}</td><td className="r num">{reais(t.valor)}</td></tr>
        ))}</tbody></table>
    </>
  );
}

function Fornecedor({ r }: { r: R }) {
  const f = r.fornecedor;
  return (
    <>
      <div className="rs-ch"><b>{f.nome}</b>{f.documento && <span className="sec">{documento(f.documento)}</span>}</div>
      <div className="rs-nums">
        <div><span>Com a BKM desde</span><b className="num">{f.desde ? mes(f.desde) : '—'}</b></div>
        <div><span>Títulos</span><b className="num">{f.titulos}</b></div>
        <div><span>Lançado em 12 meses</span><b className="num">{reais(f.total_12m)}</b></div>
        <div><span>Contratos ativos</span><b className="num">{f.contratos_ativos}</b></div>
      </div>
      <Kv l={[['E-mail', f.email], ['Telefone', f.telefone], ['Endereço', f.endereco], ['Contas', f.contas.length ? f.contas.map(c => c.descricao).join(' · ') : null]]} />
      <h3 className="rs-h3">Últimos títulos</h3>
      <table className="rs-tab"><thead><tr><th>Emissão</th><th>Documento</th><th>Área</th><th>Situação</th><th className="r">Valor</th></tr></thead>
        <tbody>{f.ultimos.map(t => (
          <tr key={t.id} className={t.este ? 'eu' : ''}><td className="num">{data(t.emissao)}</td><td>{t.documento ?? '—'}</td><td>{t.area ?? '—'}</td>
            <td><Chip t={ETAPA[t.etapa][0]} c={ETAPA[t.etapa][1]} /></td><td className="r num">{reais(t.valor)}</td></tr>
        ))}</tbody></table>
    </>
  );
}
