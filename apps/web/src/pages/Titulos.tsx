// Títulos: lista agrupada pela etapa, com os contadores que filtram e a gaveta do título (tpl.js › fLancar, fGrupo, fGaveta).
import { useQuery } from '@tanstack/react-query';
import { Alerta, COR, Cab, Carregando, Chip, Colunas, Gaveta, Grupo, Ic, Kv, Li, Secao, Tiles, Vazio, type Cor, type CorChip, type Linha } from '../components/Comum';
import { data, dataCurta, dataHora, documento, hojeISO, mes, reais } from '../lib/format';
import { acha, usePagina } from '../lib/navegar';
import { mensagemErro, rpc } from '../lib/supabase';
import type { EtapaTitulo, Titulo, TituloDetalhe } from '../lib/tipos';
import { RastroBotoes } from '../components/Rastro';
import { LancarTitulo } from './Lancar';
import { useSessao } from '../lib/sessao';
import { useNavigate, useSearchParams } from 'react-router-dom';

export const ETAPA: Record<EtapaTitulo, [string, CorChip]> = {
  rascunho: ['Rascunho', 'ci'], revisao: ['Em revisão', 'at'], recusado: ['Recusado', 'cr'], aprovacao: ['Em aprovação', 'az'],
  aprovado: ['Aprovado', 'ok'], sienge: ['No Sienge', 'ro'], erro_sienge: ['Não chegou ao Sienge', 'cr'], pago: ['Pago', 'ok'], cancelado: ['Cancelado', 'ci'],
};
type F = 'rasc' | 'aprov' | 'sienge' | 'pago';
/** grupos: a mesma cor no contador e no grupo; `p` é a etapa que dá nome ao grupo (essa não ganha chip na linha) */
const G: [F, string, Cor, EtapaTitulo[], EtapaTitulo][] = [
  ['rasc', 'Rascunhos', COR.cinza, ['rascunho', 'revisao', 'recusado'], 'rascunho'],
  ['aprov', 'Em aprovação', COR.azul, ['aprovacao'], 'aprovacao'],
  ['sienge', 'No Sienge', COR.roxo, ['aprovado', 'sienge', 'erro_sienge'], 'sienge'],
  ['pago', 'Pagos', COR.verde, ['pago'], 'pago'],
];
const COLS = [28, 17, 18, 11, 11, 15];
const ROT = [{ t: 'Fornecedor' }, { t: 'Situação' }, { t: 'Área', x: true }, { t: 'Documento', x: true }, { t: 'Vencimento' }, { t: 'Valor', r: true }];
/** chip só quando a etapa não é a que dá nome ao grupo (Recusado em Rascunhos, Não chegou ao Sienge em No Sienge) */
const chip = (t: Titulo) => G.some(g => g[4] === t.etapa) || t.etapa === 'cancelado' ? null : <Chip t={ETAPA[t.etapa][0]} c={ETAPA[t.etapa][1]} />;
const venc = (t: Titulo) => atrasado(t)
  ? <span className="num atras" title="Vencido"><Ic n="warn" s={16} />{dataCurta(t.vencimento)}</span>
  : <span className="num">{dataCurta(t.vencimento)}</span>;
const soma = (l: Titulo[]) => l.reduce((a, t) => a + Number(t.valor), 0);
const atrasado = (t: Titulo) => !!t.vencimento && t.vencimento < hojeISO() && !['pago', 'cancelado'].includes(t.etapa);

export function Titulos() {
  const pg = usePagina<F>('/titulos');
  const q = useQuery({ queryKey: ['titulos'], queryFn: () => rpc<Titulo[]>('titulos') });
  const { eu } = useSessao();
  const [sp, setSp] = useSearchParams();
  const novo = sp.get('novo') === '1';
  const nav = useNavigate();
  const semNovo = () => { const n = new URLSearchParams(sp); n.delete('novo'); const s = n.toString(); return s ? `?${s}` : ''; };
  const abrirNovo = (v: boolean) => { const n = new URLSearchParams(sp); if (v) n.set('novo', '1'); else n.delete('novo'); setSp(n); };
  const todos = (q.data ?? []).filter(t => acha(pg.busca, t.fornecedor, t.documento, t.numero, t.fornecedor_documento, t.areas, t.sienge_id));
  const grupos = G.filter(g => !pg.filtro || pg.filtro === g[0]);
  const linha = (t: Titulo): Linha => ({
    id: t.id,
    titulo: t.fornecedor,
    cels: [
      { c: chip(t) },
      { c: t.areas, x: true },
      { c: t.documento, x: true },
      { c: venc(t) },
      { c: reais(t.valor), r: true },
    ],
    valor: reais(t.valor),
    sub: <>{venc(t)}{chip(t)}</>,
  });
  const cancelados = todos.filter(t => t.etapa === 'cancelado');
  return (
    <>
      <div className="f-pag">
        <Cab t="Títulos">
          {(pg.filtro || pg.busca) && <button className="btn t" onClick={pg.limpar}>Limpar filtro</button>}
          {eu?.escreve && <button className="btn p" onClick={() => abrirNovo(true)}><Ic n="add" s={18} />Lançar título</button>}
        </Cab>
        <Tiles itens={G.map(([k, r, cor, e]) => { const it = todos.filter(t => e.includes(t.etapa)); return { k, r, cor, n: it.length, v: it.length ? reais(soma(it)) : undefined }; })} on={pg.filtro} mudar={pg.mudarFiltro} />
        {q.isLoading ? <Carregando /> : q.error ? <Vazio t={mensagemErro(q.error)} />
          : !grupos.some(g => todos.some(t => g[3].includes(t.etapa))) && !(!pg.filtro && cancelados.length) ? <Vazio t={pg.busca || pg.filtro ? 'Nada encontrado.' : 'Nenhum título.'} limpar={pg.busca || pg.filtro ? pg.limpar : undefined} />
          : <>
              <Colunas cols={COLS} rot={ROT} />
              {grupos.map(([k, nome, cor, e]) => {
                const it = todos.filter(t => e.includes(t.etapa));
                return <Grupo key={k} nome={nome} cor={cor} linhas={it.map(linha)} total={reais(soma(it))} sel={pg.id} abrir={pg.abrir} cols={COLS} />;
              })}
              {!pg.filtro && <Grupo nome="Cancelados" cor={COR.cinza} linhas={cancelados.map(linha)} sel={pg.id} abrir={pg.abrir} cols={COLS} fechado />}
            </>}
      </div>
      {pg.id && <GavetaTitulo id={pg.id} fechar={pg.fechar} />}
      {novo && <LancarTitulo fechar={() => abrirNovo(false)} lancado={id => nav(`/titulos/${id}${semNovo()}`)} />}
    </>
  );
}

function GavetaTitulo({ id, fechar }: { id: string; fechar: () => void }) {
  const q = useQuery({ queryKey: ['titulo', id], queryFn: () => rpc<TituloDetalhe | null>('titulo', { p_id: id }) });
  const t = q.data;
  if (q.isLoading) return <Gaveta titulo="Título" fechar={fechar}><Carregando /></Gaveta>;
  if (q.error) return <Gaveta titulo="Título" fechar={fechar}><Vazio t={mensagemErro(q.error)} /></Gaveta>;
  if (!t) return <Gaveta titulo="Título" fechar={fechar}><Vazio t="Título não encontrado ou sem acesso." /></Gaveta>;
  const recusa = t.etapa === 'recusado' ? t.aprovacoes.find(a => !a.aprovado) : undefined;
  return (
    <Gaveta titulo={t.fornecedor} sub={<Chip t={ETAPA[t.etapa][0]} c={ETAPA[t.etapa][1]} />} fechar={fechar}>
      <div><div className="big num">{reais(t.valor)}</div>{t.vencimento && <div className="sec">vence {data(t.vencimento)}</div>}</div>
      <RastroBotoes id={t.id} />
      {t.etiquetas.length > 0 && <div className="etq-w">{t.etiquetas.map(x => <span key={x} className="etq">{x}</span>)}</div>}
      {recusa && <Alerta c="cr" t={`Recusado por ${recusa.por ?? '—'}${recusa.justificativa ? `: ${recusa.justificativa}` : ''}`} />}
      {t.etapa === 'erro_sienge' && <Alerta c="cr" t={`Não chegou ao Sienge${t.sienge_erro ? `: ${t.sienge_erro}` : ''}`} />}
      {t.etapa === 'aprovacao' && t.aprovacao_pendente && <Alerta c="at" t={`Esperando ${t.aprovacao_pendente}`} />}
      <Kv l={[
        ['Fornecedor', <span>{t.fornecedor}{t.fornecedor_documento && <span className="sec"> · {documento(t.fornecedor_documento)}</span>}</span>],
        ['Documento', t.documento],
        ['Emissão', data(t.emissao)],
        ['Competência', mes(t.competencia)],
        ['Empresa', t.empresa],
        ['Título no Sienge', t.sienge_id],
        ['Lançado por', t.lancado_por && `${t.lancado_por} · ${dataHora(t.lancado_em)}`],
        ['Descrição', t.descricao],
      ]} />
      <Secao t={t.parcelas.length > 1 ? `${t.parcelas.length} parcelas` : 'Pagamento'}>
        {t.parcelas.map(p => (
          <Li key={p.numero} a={`${t.parcelas.length > 1 ? `${p.numero}ª · ` : ''}vence ${data(p.vencimento)}`} b={reais(p.valor)}
            c={p.forma === 'pix' ? `PIX ${p.pix_tipo ?? ''} ${p.pix_chave ?? ''}${p.pix_excecao ? ` · exceção: ${p.pix_excecao}` : ''}`
              : p.forma === 'boleto' ? <span className="mono">Boleto {p.boleto_linha}</span> : 'Forma de pagamento não informada'} />
        ))}
      </Secao>
      {t.rateio.length > 0 && (
        <Secao t="Onde entra">
          {t.rateio.map((r, i) => <Li key={i} a={r.area ?? '—'} b={t.rateio.length > 1 ? `${Number(r.percentual).toLocaleString('pt-BR')}% · ${reais(r.valor)}` : undefined} c={[r.nucleo, r.natureza].filter(Boolean).join(' · ')} />)}
        </Secao>
      )}
      {t.nota && (t.nota.retencoes.length > 0 || t.nota.caucao) && (
        <Secao t={`Nota ${reais(t.nota.valor_bruto)}`}>
          {t.nota.retencoes.map(r => <Li key={r.imposto} a={`Retenção de ${r.imposto.toUpperCase()}`} b={`− ${reais(r.valor)}`} c={r.vencimento ? `recolhe em ${data(r.vencimento)}` : undefined} />)}
          {t.nota.caucao ? <Li a="Caução" b={`− ${reais(t.nota.caucao)}`} /> : null}
        </Secao>
      )}
    </Gaveta>
  );
}

