// Visão geral de Contas a pagar (pedido do Moises, 18/11/2026): alguns números do momento e um cartão por seção,
// com ícone, o que a pessoa encontra ali e o que pode fazer. Didática para quem chega; o dado vem das mesmas funções das listas.
import { useQuery } from '@tanstack/react-query';
import { Link } from 'react-router-dom';
import { Cab, COR, Ic, type Cor } from '../components/Comum';
import { hojeISO, reais0 } from '../lib/format';
import type { NomeIcone } from '../lib/icones';
import { rpc } from '../lib/supabase';
import type { Contrato, Previsao, Titulo } from '../lib/tipos';

const emDias = (n: number) => { const d = new Date(); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
const aberto = (t: Titulo) => !['pago', 'cancelado'].includes(t.etapa);
const soma = (l: { valor: number | string | null }[]) => l.reduce((a, x) => a + Number(x.valor ?? 0), 0);

type Secao = { to: string; r: string; ic: NomeIcone; cor: Cor; txt: string; faz: string[]; num: string };

export function ContasPagar() {
  const t = useQuery({ queryKey: ['titulos'], queryFn: () => rpc<Titulo[]>('titulos') }).data ?? [];
  const p = useQuery({ queryKey: ['previsoes'], queryFn: () => rpc<Previsao[]>('previsoes') }).data ?? [];
  const c = useQuery({ queryKey: ['contratos'], queryFn: () => rpc<Contrato[]>('contratos') }).data ?? [];
  const hoje = hojeISO();
  const semana = t.filter(x => aberto(x) && !!x.vencimento && x.vencimento >= hoje && x.vencimento <= emDias(7));
  const vencidos = t.filter(x => aberto(x) && !!x.vencimento && x.vencimento < hoje);
  const emAprov = t.filter(x => x.etapa === 'aprovacao');
  const prevEsp = p.filter(x => x.situacao === 'aberta' && x.aprovacao === 'esperando');
  const ativos = c.filter(x => x.situacao === 'ativo');
  const mensal = ativos.filter(x => x.periodicidade === 'mensal').reduce((a, x) => a + Number(x.valor_periodo ?? 0), 0);

  const kpis: { r: string; v: string; n: string; alerta?: boolean; to: string }[] = [
    { r: 'A pagar nos próximos 7 dias', v: reais0(soma(semana)), n: `${semana.length} ${semana.length === 1 ? 'título' : 'títulos'}`, to: '/titulos' },
    { r: 'Vencidos sem pagamento', v: reais0(soma(vencidos)), n: `${vencidos.length} ${vencidos.length === 1 ? 'título' : 'títulos'}`, alerta: vencidos.length > 0, to: '/titulos' },
    { r: 'Esperando aprovação', v: reais0(soma(emAprov) + soma(prevEsp)), n: `${emAprov.length} ${emAprov.length === 1 ? 'título' : 'títulos'} e ${prevEsp.length} ${prevEsp.length === 1 ? 'previsão' : 'previsões'}`, to: '/titulos?f=aprov' },
    { r: 'Contas recorrentes', v: `${reais0(mensal)}`, n: `por mês, ${ativos.length} ativas`, to: '/contratos' },
  ];
  const secoes: Secao[] = [
    {
      to: '/titulos', r: 'Títulos', ic: 'doc', cor: COR.azul,
      txt: 'Cada nota, fatura ou boleto que a BKM vai pagar. O título vai do rascunho à aprovação, depois ao Sienge e ao pagamento.',
      faz: ['Ver em que passo está cada título', 'Saber quem ainda precisa aprovar', 'Achar o que venceu ou não chegou ao Sienge'],
      num: `${t.filter(aberto).length} em aberto`,
    },
    {
      to: '/previsoes', r: 'Previsões', ic: 'clock', cor: COR.terra,
      txt: 'Gastos combinados antes do serviço acontecer. Aprovada, a previsão reserva o valor, e a nota que chega depois consome o saldo.',
      faz: ['Ver o que já está reservado', 'Acompanhar o saldo de cada previsão', 'Saber o que espera aprovação'],
      num: `${p.filter(x => x.situacao === 'aberta').length} abertas`,
    },
    {
      to: '/contratos', r: 'Contas recorrentes', ic: 'repetir', cor: COR.verde,
      txt: 'Contratos de serviço e assinaturas que se repetem: o valor de cada período, o dia do vencimento e até quando valem.',
      faz: ['Ver o que a BKM paga todo mês', 'Saber o que vence nos próximos 60 dias', 'Consultar contratos encerrados'],
      num: `${ativos.length} ativas`,
    },
  ];
  return (
    <div className="f-pag cp">
      <Cab t="Contas a pagar" />
      <div className="cp-kpis">
        {kpis.map(k => (
          <Link key={k.r} to={k.to} className="cp-kpi">
            <span className="cp-kr">{k.r}</span>
            <span className={`cp-kv num ${k.alerta ? 'atras' : ''}`}>{k.v}</span>
            <span className="cp-kn">{k.n}</span>
          </Link>
        ))}
      </div>
      <div className="cp-cards">
        {secoes.map(s => (
          <Link key={s.to} to={s.to} className="cp-card" style={{ ['--cc' as string]: s.cor.c, ['--ct' as string]: s.cor.t }}>
            <span className="cp-ic"><Ic n={s.ic} s={32} /></span>
            <span className="cp-t">{s.r}<span className="cp-num">{s.num}</span></span>
            <span className="cp-txt">{s.txt}</span>
            <span className="cp-faz">{s.faz.map(f => <span key={f}><Ic n="check" s={18} />{f}</span>)}</span>
            <span className="cp-ir">Abrir {s.r}<Ic n="fwd" s={18} /></span>
          </Link>
        ))}
      </div>
    </div>
  );
}
