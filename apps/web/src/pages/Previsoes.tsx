// Previsões: agrupadas pela situação, com os contadores que filtram e a gaveta (mesmo desenho dos títulos, linha F).
import { useQuery } from '@tanstack/react-query';
import { Abas, Alerta, Cab, Chip, Gaveta, Grupo, Kv, Tiles, Vazio, type CorChip, type Linha } from '../components/Comum';
import { data, dataCurta, mes, reais } from '../lib/format';
import { acha, usePagina } from '../lib/navegar';
import { mensagemErro, rpc } from '../lib/supabase';
import type { Previsao } from '../lib/tipos';

type F = 'esperando' | 'abertas' | 'consumidas' | 'encerradas';
const G: [F, string, string, (p: Previsao) => boolean][] = [
  ['esperando', 'Esperando aprovação', '#c67355', p => p.situacao === 'aberta' && p.aprovacao === 'esperando'],
  ['abertas', 'Abertas', '#0094fe', p => p.situacao === 'aberta' && p.aprovacao === 'aprovada'],
  ['consumidas', 'Consumidas', '#7d8a3e', p => p.situacao === 'consumida'],
  ['encerradas', 'Encerradas ou canceladas', '#747775', p => p.situacao === 'encerrada' || p.situacao === 'cancelada' || p.aprovacao === 'cancelada'],
];
const ORIGEM: Record<string, string> = { manual: 'Manual', assinatura: 'Contrato', saldo_contrato: 'Saldo de contrato', cronograma: 'Cronograma', orcamento: 'Orçamento' };
const SIT: Record<string, [string, CorChip]> = { esperando: ['Esperando aprovação', 'at'], abertas: ['Aberta', 'az'], consumidas: ['Consumida', 'ok'], encerradas: ['Encerrada', 'ci'] };
const grupoDe = (p: Previsao) => G.find(g => g[3](p))?.[0] ?? 'encerradas';
const nome = (p: Previsao) => p.fornecedor ?? p.descricao ?? 'Sem fornecedor';
const quanto = (p: Previsao) => (p.situacao === 'aberta' && p.saldo != null ? Number(p.saldo) : Number(p.valor));

export function Previsoes() {
  const pg = usePagina<F>('/previsoes');
  const q = useQuery({ queryKey: ['previsoes'], queryFn: () => rpc<Previsao[]>('previsoes') });
  const todas = (q.data ?? []).filter(p => acha(pg.busca, p.fornecedor, p.descricao, p.natureza, p.area, p.contrato, p.sienge_id));
  const linha = (p: Previsao): Linha => {
    const s = SIT[grupoDe(p)];
    return {
      id: p.id,
      titulo: nome(p),
      cels: [
        { c: <Chip t={s[0]} c={s[1]} /> },
        { c: <span className="sec">{p.area}</span>, x: true },
        { c: <span className="sec">{p.natureza}</span>, x: true },
        { c: <span className="num">{dataCurta(p.data_prevista)}</span> },
        { c: reais(quanto(p)), r: true },
      ],
      valor: reais(quanto(p)),
      sub: <><span>{p.natureza}</span><span className="num">{dataCurta(p.data_prevista)}</span></>,
    };
  };
  const sel = pg.id ? (q.data ?? []).find(p => p.id === pg.id) : undefined;
  return (
    <>
      <div className="f-pag">
        <Abas />
        <Cab t="Previsões" />
        <Tiles itens={G.map(([k, r]) => ({ k, r, n: todas.filter(p => grupoDe(p) === k).length }))} on={pg.filtro} mudar={pg.mudarFiltro} />
        {q.isLoading ? <Vazio t="Carregando…" /> : q.error ? <Vazio t={mensagemErro(q.error)} />
          : !todas.length ? <Vazio t={pg.busca ? 'Nada encontrado.' : 'Nenhuma previsão.'} />
          : G.filter(g => !pg.filtro || pg.filtro === g[0]).map(([k, n, cor]) => {
              const it = todas.filter(p => grupoDe(p) === k);
              return <Grupo key={k} nome={n} cor={cor} linhas={it.map(linha)} total={reais(it.reduce((a, p) => a + quanto(p), 0))} sel={pg.id} abrir={pg.abrir} cols={[30, 17, 19, 15, 8, 11]} fechado={k === 'encerradas' && !pg.filtro} />;
            })}
      </div>
      {pg.id && (
        sel ? (
          <Gaveta titulo={nome(sel)} sub={SIT[grupoDe(sel)][0]} fechar={pg.fechar}>
            <div className="big num">{reais(sel.valor)}</div>
            {sel.situacao === 'aberta' && sel.saldo != null && Number(sel.saldo) !== Number(sel.valor) && <Alerta c="at" t={`Saldo ${reais(sel.saldo)}`} />}
            <Kv l={[
              ['Previsto para', data(sel.data_prevista)],
              ['Competência', mes(sel.competencia)],
              ['Fornecedor', sel.fornecedor ?? 'Sem fornecedor'],
              ['Onde entra', sel.area],
              ['Natureza', sel.natureza],
              ['Núcleo', sel.nucleo],
              ['Empresa', sel.empresa],
              ['Origem', ORIGEM[sel.origem] ?? sel.origem],
              ['Contrato', sel.contrato],
              ['Previsão no Sienge', sel.sienge_id],
              ['Lançada por', sel.lancado_por],
              ['Descrição', sel.descricao],
            ]} />
          </Gaveta>
        ) : (
          <Gaveta titulo="Previsão" fechar={pg.fechar}><Vazio t={q.isLoading ? 'Carregando…' : 'Previsão não encontrada ou sem acesso.'} /></Gaveta>
        )
      )}
    </>
  );
}
