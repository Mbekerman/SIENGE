// Títulos: lista agrupada pela etapa, com os contadores que filtram e a gaveta do título (tpl.js › fLancar, fGrupo, fGaveta).
import { useQuery } from '@tanstack/react-query';
import { Abas, Alerta, Cab, Chip, Gaveta, Grupo, Kv, Li, Secao, Tiles, Vazio, type CorChip, type Linha } from '../components/Comum';
import { data, dataCurta, dataHora, documento, hojeISO, mes, reais } from '../lib/format';
import { acha, usePagina } from '../lib/navegar';
import { mensagemErro, rpc } from '../lib/supabase';
import type { EtapaTitulo, Titulo, TituloDetalhe } from '../lib/tipos';

export const ETAPA: Record<EtapaTitulo, [string, CorChip]> = {
  rascunho: ['Rascunho', 'ci'], revisao: ['Em revisão', 'at'], recusado: ['Recusado', 'cr'], aprovacao: ['Em aprovação', 'az'],
  aprovado: ['Aprovado', 'ok'], sienge: ['No Sienge', 'ro'], erro_sienge: ['Não chegou ao Sienge', 'cr'], pago: ['Pago', 'ok'], cancelado: ['Cancelado', 'ci'],
};
type F = 'rasc' | 'aprov' | 'sienge' | 'pago';
/** grupos e cores do protótipo (fLancar) */
const G: [F, string, string, EtapaTitulo[]][] = [
  ['rasc', 'Rascunhos', '#747775', ['rascunho', 'revisao', 'recusado']],
  ['aprov', 'Em aprovação', '#0094fe', ['aprovacao']],
  ['sienge', 'No Sienge', '#863d8f', ['aprovado', 'sienge', 'erro_sienge']],
  ['pago', 'Pagos', '#7d8a3e', ['pago']],
];
const atrasado = (t: Titulo) => !!t.vencimento && t.vencimento < hojeISO() && !['pago', 'cancelado'].includes(t.etapa);

export function Titulos() {
  const pg = usePagina<F>('/titulos');
  const q = useQuery({ queryKey: ['titulos'], queryFn: () => rpc<Titulo[]>('titulos') });
  const todos = (q.data ?? []).filter(t => acha(pg.busca, t.fornecedor, t.documento, t.numero, t.fornecedor_documento, t.areas, t.sienge_id));
  const grupos = G.filter(g => !pg.filtro || pg.filtro === g[0]);
  const linha = (t: Titulo): Linha => ({
    id: t.id,
    titulo: t.fornecedor,
    cels: [
      { c: <Chip t={ETAPA[t.etapa][0]} c={ETAPA[t.etapa][1]} /> },
      { c: <span className="sec">{t.areas}</span>, x: true },
      { c: <span className="sec">{t.documento}</span>, x: true },
      { c: <span className="num" style={atrasado(t) ? { color: 'var(--cr)' } : undefined}>{dataCurta(t.vencimento)}</span> },
      { c: reais(t.valor), r: true },
    ],
    valor: reais(t.valor),
    sub: <><Chip t={ETAPA[t.etapa][0]} c={ETAPA[t.etapa][1]} /><span className="num" style={atrasado(t) ? { color: 'var(--cr)' } : undefined}>{dataCurta(t.vencimento)}</span></>,
  });
  const cancelados = todos.filter(t => t.etapa === 'cancelado');
  return (
    <>
      <div className="f-pag">
        <Abas />
        <Cab t="Títulos" />
        <Tiles itens={G.map(([k, r, , e]) => ({ k, r, n: todos.filter(t => e.includes(t.etapa)).length }))} on={pg.filtro} mudar={pg.mudarFiltro} />
        {q.isLoading ? <Vazio t="Carregando…" /> : q.error ? <Vazio t={mensagemErro(q.error)} />
          : !todos.length ? <Vazio t={pg.busca ? 'Nada encontrado.' : 'Nenhum título.'} />
          : <>
              {grupos.map(([k, nome, cor, e]) => {
                const it = todos.filter(t => e.includes(t.etapa));
                return <Grupo key={k} nome={nome} cor={cor} linhas={it.map(linha)} total={reais(it.reduce((a, t) => a + Number(t.valor), 0))} sel={pg.id} abrir={pg.abrir} cols={[32, 15, 19, 11, 8, 15]} />;
              })}
              {!pg.filtro && <Grupo nome="Cancelados" cor="#747775" linhas={cancelados.map(linha)} sel={pg.id} abrir={pg.abrir} cols={[32, 15, 19, 11, 8, 15]} fechado />}
            </>}
      </div>
      {pg.id && <GavetaTitulo id={pg.id} fechar={pg.fechar} />}
    </>
  );
}

function GavetaTitulo({ id, fechar }: { id: string; fechar: () => void }) {
  const q = useQuery({ queryKey: ['titulo', id], queryFn: () => rpc<TituloDetalhe | null>('titulo', { p_id: id }) });
  const t = q.data;
  if (q.isLoading) return <Gaveta titulo="Carregando…" fechar={fechar}><span /></Gaveta>;
  if (q.error) return <Gaveta titulo="Título" fechar={fechar}><Vazio t={mensagemErro(q.error)} /></Gaveta>;
  if (!t) return <Gaveta titulo="Título" fechar={fechar}><Vazio t="Título não encontrado ou sem acesso." /></Gaveta>;
  const recusa = t.etapa === 'recusado' ? t.aprovacoes.find(a => !a.aprovado) : undefined;
  return (
    <Gaveta titulo={t.fornecedor} sub={ETAPA[t.etapa][0]} fechar={fechar}>
      <div className="big num">{reais(t.valor)}</div>
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
      {t.previsoes.length > 0 && (
        <Secao t="Previsões consumidas">
          {t.previsoes.map(p => <Li key={p.id} a={`Previsão de ${data(p.data_prevista)}`} b={reais(p.valor)} />)}
        </Secao>
      )}
      {t.aprovacoes.length > 0 && (
        <Secao t="Aprovação">
          {t.aprovacoes.map((a, i) => <Li key={i} a={`${a.aprovado ? 'Aprovou' : 'Recusou'}: ${a.por ?? '—'}`} b={dataHora(a.em)} c={[a.area, a.lista, a.justificativa].filter(Boolean).join(' · ')} />)}
        </Secao>
      )}
    </Gaveta>
  );
}

