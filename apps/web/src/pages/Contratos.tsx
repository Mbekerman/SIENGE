// Contas recorrentes: contratos e assinaturas agrupados pelo tipo, com os contadores que filtram (tpl.js › fContas).
import { useQuery } from '@tanstack/react-query';
import { Alerta, COR, Cab, Carregando, Chip, Colunas, Gaveta, Grupo, Kv, Tiles, Vazio, type Linha } from '../components/Comum';
import { data, hojeISO, reais, reais0 } from '../lib/format';
import { acha, usePagina } from '../lib/navegar';
import { mensagemErro, rpc } from '../lib/supabase';
import type { Contrato } from '../lib/tipos';

type F = 'ativos' | 'aprovacao' | 'vence' | 'encerrados';
const PER: Record<string, string> = { mensal: 'por mês', bimestral: 'por bimestre', trimestral: 'por trimestre', semestral: 'por semestre', anual: 'por ano' };
const em60 = () => { const d = new Date(); d.setDate(d.getDate() + 60); return d.toISOString().slice(0, 10); };
const ativo = (c: Contrato) => c.situacao === 'ativo';
const FILTRO: Record<F, (c: Contrato) => boolean> = {
  ativos: c => ativo(c) && c.aprovado !== false,
  aprovacao: c => ativo(c) && c.aprovado === false,
  vence: c => ativo(c) && !!c.fim && c.fim >= hojeISO() && c.fim <= em60(),
  encerrados: c => !ativo(c),
};
const sit = (c: Contrato) => !ativo(c) ? <Chip t={c.situacao === 'cancelado' ? 'Cancelado' : 'Encerrado'} c="ci" />
  : c.aprovado === false ? <Chip t="Em aprovação" c="at" /> : <Chip t="Ativo" c="ok" />;
const COLS = [30, 17, 19, 9, 12, 13];
const ROT = [{ t: 'Fornecedor' }, { t: 'Natureza' }, { t: 'Área', x: true }, { t: 'Vence' }, { t: 'Situação' }, { t: 'Valor', r: true }];
const valor = (c: Contrato) => c.valor_periodo != null ? `${reais(c.valor_periodo)}` : c.valor_total != null ? reais(c.valor_total) : '—';

export function Contratos() {
  const pg = usePagina<F>('/contratos');
  const q = useQuery({ queryKey: ['contratos'], queryFn: () => rpc<Contrato[]>('contratos') });
  const todos = (q.data ?? []).filter(c => acha(pg.busca, c.fornecedor, c.numero, c.descricao, c.naturezas, c.areas));
  const vis = todos.filter(c => pg.filtro ? FILTRO[pg.filtro](c) : ativo(c));
  const linha = (c: Contrato): Linha => ({
    id: c.id,
    titulo: c.fornecedor ?? c.descricao,
    cels: [
      { c: c.naturezas },
      { c: c.areas, x: true },
      { c: c.dia_vencimento ? `dia ${c.dia_vencimento}` : '' },
      { c: sit(c) },
      { c: valor(c), r: true },
    ],
    valor: valor(c),
    sub: <><span>{[c.naturezas, c.dia_vencimento && `dia ${c.dia_vencimento}`].filter(Boolean).join(' · ')}</span>{sit(c)}</>,
  });
  const soma = (l: Contrato[]) => l.filter(c => c.periodicidade === 'mensal').reduce((a, c) => a + Number(c.valor_periodo ?? 0), 0);
  const ctr = vis.filter(c => c.tipo === 'contrato'), ass = vis.filter(c => c.tipo === 'assinatura');
  const sel = pg.id ? (q.data ?? []).find(c => c.id === pg.id) : undefined;
  return (
    <>
      <div className="f-pag">
        <Cab t="Contas recorrentes">{(pg.filtro || pg.busca) && <button className="btn t" onClick={pg.limpar}>Limpar filtro</button>}</Cab>
        <Tiles itens={[
          { k: 'ativos' as F, r: 'Ativas', cor: COR.verde, n: todos.filter(FILTRO.ativos).length, v: soma(todos.filter(FILTRO.ativos)) ? `${reais0(soma(todos.filter(FILTRO.ativos)))} por mês` : undefined },
          { k: 'aprovacao' as F, r: 'Em aprovação', cor: COR.terra, n: todos.filter(FILTRO.aprovacao).length },
          { k: 'vence' as F, r: 'Vencem em 60 dias', cor: COR.terra, n: todos.filter(FILTRO.vence).length, alerta: true },
          { k: 'encerrados' as F, r: 'Encerradas', cor: COR.cinza, n: todos.filter(FILTRO.encerrados).length },
        ]} on={pg.filtro} mudar={pg.mudarFiltro} />
        {q.isLoading ? <Carregando /> : q.error ? <Vazio t={mensagemErro(q.error)} />
          : !vis.length ? <Vazio t={pg.busca || pg.filtro ? 'Nada encontrado.' : 'Nenhuma conta recorrente.'} limpar={pg.busca || pg.filtro ? pg.limpar : undefined} />
          : <>
              <Colunas cols={COLS} rot={ROT} />
              <Grupo nome="Contratos de serviço" cor={COR.azul} linhas={ctr.map(linha)} total={soma(ctr) ? `${reais0(soma(ctr))} por mês` : undefined} sel={pg.id} abrir={pg.abrir} cols={COLS} />
              <Grupo nome="Assinaturas" cor={COR.roxo} linhas={ass.map(linha)} total={soma(ass) ? `${reais0(soma(ass))} por mês` : undefined} sel={pg.id} abrir={pg.abrir} cols={COLS} />
            </>}
      </div>
      {pg.id && (
        sel ? (
          <Gaveta titulo={sel.fornecedor ?? sel.descricao} sub={sit(sel)} fechar={pg.fechar}>
            <div className="big num">{valor(sel)}{sel.periodicidade && <span className="sec" style={{ fontSize: 16, marginLeft: 8 }}>{PER[sel.periodicidade]}</span>}</div>
            {ativo(sel) && sel.aprovado === false && <Alerta c="at" t="Cadastro em aprovação" />}
            <Kv l={[
              ['Tipo', sel.tipo === 'assinatura' ? 'Assinatura' : 'Contrato de serviço'],
              ['Descrição', sel.descricao],
              ['Número', sel.numero],
              ['Vigência', `${data(sel.inicio)}${sel.fim ? ` a ${data(sel.fim)}` : ', sem prazo'}`],
              ['Vencimento', sel.dia_vencimento ? `dia ${sel.dia_vencimento}` : null],
              ['Valor total', sel.valor_total != null ? reais(sel.valor_total) : null],
              ['Onde entra', sel.areas],
              ['Natureza', sel.naturezas],
              ['Empresa', sel.empresa],
              ['Previsões em aberto', sel.previsoes_abertas],
              ['Lançado por', sel.lancado_por],
            ]} />
          </Gaveta>
        ) : (
          <Gaveta titulo="Conta recorrente" fechar={pg.fechar}>{q.isLoading ? <Carregando /> : <Vazio t="Não encontrada ou sem acesso." />}</Gaveta>
        )
      )}
    </>
  );
}
