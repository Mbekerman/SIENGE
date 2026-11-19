// Previsões: agrupadas pela situação, com os contadores que filtram e a gaveta (mesmo desenho dos títulos, linha F).
import { useQuery } from '@tanstack/react-query';
import { Alerta, COR, Cab, Carregando, Chip, Colunas, Gaveta, Grupo, Kv, Tiles, Vazio, type Cor, type CorChip, type Linha } from '../components/Comum';
import { data, dataCurta, mes, reais } from '../lib/format';
import { acha, usePagina } from '../lib/navegar';
import { mensagemErro, rpc } from '../lib/supabase';
import type { Previsao } from '../lib/tipos';

type F = 'esperando' | 'abertas' | 'consumidas' | 'encerradas';
const G: [F, string, Cor, (p: Previsao) => boolean][] = [
  ['esperando', 'Esperando aprovação', COR.terra, p => p.situacao === 'aberta' && p.aprovacao === 'esperando'],
  ['abertas', 'Abertas', COR.azul, p => p.situacao === 'aberta' && p.aprovacao === 'aprovada'],
  ['consumidas', 'Consumidas', COR.verde, p => p.situacao === 'consumida'],
  ['encerradas', 'Encerradas', COR.cinza, p => p.situacao === 'encerrada' || p.situacao === 'cancelada' || p.aprovacao === 'cancelada'],
];
const ORIGEM: Record<string, string> = { manual: 'Manual', assinatura: 'Contrato', saldo_contrato: 'Saldo de contrato', cronograma: 'Cronograma', orcamento: 'Orçamento' };
const SIT: Record<string, [string, CorChip]> = { esperando: ['Esperando aprovação', 'at'], abertas: ['Aberta', 'az'], consumidas: ['Consumida', 'ok'], encerradas: ['Encerrada', 'ci'] };
const COLS = [28, 14, 18, 18, 10, 12];
const ROT = [{ t: 'Fornecedor' }, { t: 'Origem' }, { t: 'Área', x: true }, { t: 'Natureza', x: true }, { t: 'Previsto' }, { t: 'Valor', r: true }];
const soma = (l: Previsao[]) => l.reduce((a, p) => a + quanto(p), 0);
const grupoDe = (p: Previsao) => G.find(g => g[3](p))?.[0] ?? 'encerradas';
const nome = (p: Previsao) => p.fornecedor ?? p.descricao ?? 'Sem fornecedor';
const quanto = (p: Previsao) => (p.situacao === 'aberta' && p.saldo != null ? Number(p.saldo) : Number(p.valor));

export function Previsoes() {
  const pg = usePagina<F>('/previsoes');
  const q = useQuery({ queryKey: ['previsoes'], queryFn: () => rpc<Previsao[]>('previsoes') });
  const todas = (q.data ?? []).filter(p => acha(pg.busca, p.fornecedor, p.descricao, p.natureza, p.area, p.contrato, p.sienge_id));
  const linha = (p: Previsao): Linha => {
    return {
      id: p.id,
      titulo: nome(p),
      cels: [
        { c: ORIGEM[p.origem] ?? p.origem },
        { c: p.area, x: true },
        { c: p.natureza, x: true },
        { c: <span className="num">{dataCurta(p.data_prevista)}</span> },
        { c: reais(quanto(p)), r: true },
      ],
      valor: reais(quanto(p)),
      sub: <><span className="num">{dataCurta(p.data_prevista)}</span><span>{p.natureza}</span></>,
    };
  };
  const sel = pg.id ? (q.data ?? []).find(p => p.id === pg.id) : undefined;
  return (
    <>
      <div className="f-pag">
        <Cab t="Previsões">{(pg.filtro || pg.busca) && <button className="btn t" onClick={pg.limpar}>Limpar filtro</button>}</Cab>
        <Tiles itens={G.map(([k, r, cor]) => { const it = todas.filter(p => grupoDe(p) === k); return { k, r, cor, n: it.length, v: it.length ? reais(soma(it)) : undefined }; })} on={pg.filtro} mudar={pg.mudarFiltro} />
        {q.isLoading ? <Carregando /> : q.error ? <Vazio t={mensagemErro(q.error)} />
          : !todas.some(p => !pg.filtro || grupoDe(p) === pg.filtro) ? <Vazio t={pg.busca || pg.filtro ? 'Nada encontrado.' : 'Nenhuma previsão.'} limpar={pg.busca || pg.filtro ? pg.limpar : undefined} />
          : <>
              <Colunas cols={COLS} rot={ROT} />
              {G.filter(g => !pg.filtro || pg.filtro === g[0]).map(([k, n, cor]) => {
                const it = todas.filter(p => grupoDe(p) === k);
                return <Grupo key={k} nome={n} cor={cor} linhas={it.map(linha)} total={reais(soma(it))} sel={pg.id} abrir={pg.abrir} cols={COLS} fechado={k === 'encerradas' && !pg.filtro} />;
              })}
            </>}
      </div>
      {pg.id && (
        sel ? (
          <Gaveta titulo={nome(sel)} sub={<Chip t={SIT[grupoDe(sel)][0]} c={SIT[grupoDe(sel)][1]} />} fechar={pg.fechar}>
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
          <Gaveta titulo="Previsão" fechar={pg.fechar}>{q.isLoading ? <Carregando /> : <Vazio t="Previsão não encontrada ou sem acesso." />}</Gaveta>
        )
      )}
    </>
  );
}
