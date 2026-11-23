// Nova conta recorrente e alterar conta (tpl.js › fNovaConta): contrato de serviço, assinatura ou conta de consumo,
// com o rateio. Grava numa chamada só (api.salvar_conta, migration 20261120000100_erp_conta_recorrente.sql); a
// conta nasce em aprovação, e alterar valor, vigência, fornecedor ou rateio de uma aprovada a manda de novo.
import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alerta, Carregando, Ic } from '../components/Comum';
import { Popup } from '../components/Rastro';
import { documento, hojeISO, lerReais, reais } from '../lib/format';
import { mensagemErro, rpc } from '../lib/supabase';
import type { ContaCadastro, Contrato, FornecedorBusca, OpcoesLancamento } from '../lib/tipos';
import { BuscaFornecedor, Campo, LinhaRateio, divisoesDe, juntar, novaLinha, type Linha } from './Lancar';
import { Calendario, centavos, completar, igual, mesesDaVigencia, type Meses } from './Calendario';
import { ComoPaga, Pronto, faltaNoPag, pagDoBanco, pagParaBanco, type Pag } from './ComoPaga';

type Tipo = Contrato['tipo'];
const TIPOS: [Tipo, string, string][] = [
  ['assinatura', 'Assinatura', 'Valor fixo por mês ou período'],
  ['contrato', 'Contrato de serviço', 'Valor total do contrato'],
  ['consumo', 'Conta de consumo', 'Luz, água, telefone'],
];
const PERIODOS: [string, string][] = [['mensal', 'Por mês'], ['bimestral', 'Por bimestre'], ['trimestral', 'Por trimestre'], ['semestral', 'Por semestre'], ['anual', 'Por ano']];
const txt = (n: number | null | undefined) => (n == null ? '' : reais(n));

export function ContaRecorrente({ id, fechar, salvo }: { id?: string; fechar: () => void; salvo: (id: string) => void }) {
  const qc = useQueryClient();
  const op = useQuery({ queryKey: ['lancamento_opcoes'], queryFn: () => rpc<OpcoesLancamento | null>('lancamento_opcoes') });
  const cq = useQuery({ queryKey: ['conta', id], queryFn: () => rpc<ContaCadastro | null>('conta', { p_id: id }), enabled: Boolean(id) });
  const [tipo, setTipo] = useState<Tipo>('assinatura');
  const [empresa, setEmpresa] = useState('');
  const [forn, setForn] = useState<FornecedorBusca | null>(null);
  const [descricao, setDescricao] = useState('');
  const [numero, setNumero] = useState('');
  const [inicio, setInicio] = useState(hojeISO());
  const [fim, setFim] = useState('');
  const [dia, setDia] = useState('');
  const [per, setPer] = useState('mensal');
  const [valorTxt, setValorTxt] = useState('');
  const [instalacao, setInstalacao] = useState('');
  const [faixaTxt, setFaixaTxt] = useState('');
  const [tetoTxt, setTetoTxt] = useState('');
  const [linhas, setLinhas] = useState<Linha[]>([novaLinha()]);
  const [tentou, setTentou] = useState(false);
  // previsão mês a mês: nulo = valor igual; mexeu = manda os meses ao salvar (senão não mexe neles)
  const [meses, setMeses] = useState<Meses | null>(null);
  const [mexeuMeses, setMexeuMeses] = useState(false);
  const [vendoMeses, setVendoMeses] = useState(false);
  // como paga: nulo = não informado; mexeu = manda ao salvar (senão não mexe)
  const [pag, setPag] = useState<Pag | null>(null);
  const [mexeuPag, setMexeuPag] = useState(false);

  const c = cq.data;
  useEffect(() => {
    if (!c) return;
    setTipo(c.tipo); setEmpresa(c.empresa); setForn(c.fornecedor); setDescricao(c.descricao); setNumero(c.numero ?? '');
    setInicio(c.inicio); setFim(c.fim ?? ''); setDia(c.dia_vencimento ? String(c.dia_vencimento) : ''); setPer(c.periodicidade ?? 'mensal');
    setValorTxt(txt(c.tipo === 'contrato' ? c.valor_total : c.valor_periodo));
    setInstalacao(c.instalacao ?? ''); setFaixaTxt(txt(c.faixa_mensal)); setTetoTxt(txt(c.teto_anual));
    setPag(pagDoBanco(c.pagamento));
    setMeses(c.meses.length ? Object.fromEntries(c.meses.map(m => [m.mes.slice(0, 10), reais(Number(m.valor))])) : null);
    setLinhas(c.rateio.length ? c.rateio.map(r => ({ ...novaLinha(String(r.percentual)), nucleo: r.nucleo ?? '', centro: r.centro ?? '', divisao: r.divisao ?? '', natureza: r.natureza })) : [novaLinha()]);
  }, [c]);

  const o = op.data;
  const emp = o?.empresas.find(e => e.id === empresa);
  useEffect(() => { if (o && !id && !empresa && o.empresas.length === 1) setEmpresa(o.empresas[0].id); }, [o, id, empresa]);
  const valor = lerReais(valorTxt), faixa = lerReais(faixaTxt), teto = lerReais(tetoTxt);
  const nDia = Number(dia);
  const somaPct = linhas.reduce((a, l) => a + (Number(l.pct.replace(',', '.')) || 0), 0);
  const muda = (k: number, m: Partial<Linha>) => setLinhas(ls => ls.map(l => (l.k === k ? { ...l, ...m } : l)));
  const consumo = tipo === 'consumo';
  const lista = mesesDaVigencia(inicio, fim, hojeISO());
  const podeMeses = consumo || (tipo === 'assinatura' && per === 'mensal') || (tipo === 'contrato' && Boolean(fim) && Boolean(valor));
  const iguais = tipo === 'contrato' ? igual(Math.round((valor ?? 0) * 100), lista.length) : [];
  const igualPorMes = (i: number) => tipo === 'contrato' ? iguais[i] ?? 0 : Math.round(((consumo ? faixa : valor) ?? 0) * 100);
  const mesesFinais = meses ? completar(meses, lista, igualPorMes) : null;
  const somaMeses = mesesFinais ? Object.values(mesesFinais).reduce((a, v) => a + centavos(v), 0) : 0;
  const travaAntes = c?.trava_antes?.slice(0, 10) ?? null;
  const mudarMeses = (m: Meses | null) => { setMeses(m); setMexeuMeses(true); };
  const abrirMeses = () => { setMeses(completar(meses, lista, igualPorMes)); setMexeuMeses(true); setVendoMeses(true); };
  const anoAcimaDoTeto = consumo && mesesFinais && teto
    ? [...new Set(Object.keys(mesesFinais).map(k => k.slice(0, 4)))].find(a =>
        Object.entries(mesesFinais).filter(([k]) => k.startsWith(a)).reduce((s, [, v]) => s + centavos(v), 0) > Math.round(teto * 100))
    : undefined;

  const falta: string[] = [];
  if (!empresa) falta.push('a empresa');
  if (!forn) falta.push(consumo ? 'a concessionária' : 'o fornecedor');
  if (!descricao.trim()) falta.push('a descrição');
  if (!inicio) falta.push('o início');
  if (fim && inicio && fim < inicio) falta.push('o fim depois do início');
  if (consumo) {
    if (!instalacao.trim()) falta.push('o número da instalação');
    if (!faixa || faixa <= 0) falta.push('a média esperada por mês');
    if (!teto || teto <= 0) falta.push('o teto no ano');
  } else if (!valor || valor <= 0) falta.push(tipo === 'contrato' ? 'o valor do contrato' : 'o valor');
  if (dia && !(Number.isInteger(nDia) && nDia >= 1 && nDia <= 31)) falta.push('o dia do vencimento (1 a 31)');
  if (meses && !podeMeses) falta.push(tipo === 'contrato' ? 'o fim da vigência para a previsão mês a mês' : 'a assinatura mensal para a previsão mês a mês');
  if (anoAcimaDoTeto) falta.push(`os meses de ${anoAcimaDoTeto} dentro do teto no ano`);
  const faltaPag = faltaNoPag(pag, forn?.documento);
  if (faltaPag.length) falta.push('os dados de como paga');
  if (linhas.some(l => !l.nucleo || !l.centro || !l.natureza || (divisoesDe(o, l.centro).length > 0 && !l.divisao))) falta.push('o rateio completo');
  else if (Math.abs(somaPct - 100) > 0.00005) falta.push('o rateio somando 100%');

  const enviar = useMutation({
    mutationFn: () => rpc<string>('salvar_conta', { p: {
      id: id ?? null, tipo, empresa, fornecedor: forn!.id, descricao: descricao.trim(), numero: numero.trim(), inicio, fim: fim || null,
      dia_vencimento: dia ? nDia : null,
      periodicidade: tipo === 'contrato' ? null : consumo ? 'mensal' : per,
      valor_total: tipo === 'contrato' ? valor : null,
      valor_periodo: tipo === 'assinatura' ? valor : null,
      caucao_percentual: tipo === 'contrato' ? (c?.caucao_percentual ?? 0) : null,
      instalacao: consumo ? instalacao.trim() : null, faixa_mensal: consumo ? faixa : null, teto_anual: consumo ? teto : null,
      rateio: linhas.map(l => ({ nucleo: l.nucleo, centro: l.centro, divisao: l.divisao || null, natureza: l.natureza, percentual: Number(l.pct.replace(',', '.')) })),
      ...(mexeuPag ? { pagamento: pagParaBanco(pag) } : {}),
      ...(mexeuMeses ? { meses: mesesFinais ? Object.entries(mesesFinais).sort().map(([mes, v]) => ({ mes, valor: centavos(v) / 100 })) : [] } : {}),
    } }),
    onSuccess: novo => {
      qc.invalidateQueries({ queryKey: ['contratos'] }); qc.invalidateQueries({ queryKey: ['conta', novo] });
      qc.invalidateQueries({ queryKey: ['aprovacoes'] }); salvo(novo);
    },
  });
  // contrato com a soma dos meses diferente do valor: volta ao calendário, que pergunta o que ajustar (Moises, 23/11/2026)
  const somaDifere = tipo === 'contrato' && Boolean(mesesFinais) && somaMeses !== Math.round((valor ?? 0) * 100);
  const salvar = () => { setTentou(true); if (somaDifere && !falta.length) { setVendoMeses(true); return; } if (!falta.length) enviar.mutate(); };
  const erro = (x: boolean) => (tentou && x ? 'err' : '');
  const reaisBlur = (v: number | null, set: (s: string) => void) => () => { if (v) set(reais(v)); };

  if (vendoMeses && mesesFinais) {
    return (
      <Popup titulo="Previsão mês a mês" fechar={() => setVendoMeses(false)} pe={<>
        {anoAcimaDoTeto ? <span className="lt-erro"><Ic n="warn" s={18} />Os meses de {anoAcimaDoTeto} passam do teto no ano.</span>
          : somaDifere ? <span className="lt-erro"><Ic n="warn" s={18} />Escolha o que ajustar para a soma bater.</span>
          : <span className="sec peq esp">Mudar um mês manda a conta de novo para aprovação.</span>}
        <button className="btn p" onClick={() => setVendoMeses(false)}>Voltar ao cadastro</button>
      </>}>
        <Calendario meses={mesesFinais} mudar={mudarMeses} travaAntes={travaAntes} tipo={tipo}
          valorContrato={Math.round((valor ?? 0) * 100)} teto={Math.round((teto ?? 0) * 100)}
          ajustarContrato={cv => setValorTxt(reais(cv / 100))} />
      </Popup>
    );
  }

  return (
    <Popup titulo={id ? 'Alterar conta recorrente' : 'Nova conta recorrente'} fechar={fechar} pe={<>
      {enviar.error ? <span className="lt-erro"><Ic n="warn" s={18} />{mensagemErro(enviar.error)}</span>
        : tentou && falta.length ? <span className="lt-erro"><Ic n="warn" s={18} />Falta {juntar(falta)}.</span>
        : <span className="sec peq esp">Aprovam: o gestor de cada área e AF ou AD.</span>}
      <button className="btn t" onClick={fechar}>Cancelar</button>
      <button className="btn p" onClick={salvar} disabled={enviar.isPending || !o || (Boolean(id) && !c)}>
        {enviar.isPending ? 'Enviando…' : id ? 'Salvar' : 'Enviar para aprovação'}</button>
    </>}>
      {op.isLoading || cq.isLoading ? <Carregando /> : op.error ? <Alerta c="cr" t={mensagemErro(op.error)} />
        : cq.error ? <Alerta c="cr" t={mensagemErro(cq.error)} />
        : !o ? <Alerta c="at" t="Seu papel só permite consulta: você não cadastra contas." />
        : id && !c ? <Alerta c="at" t="Conta não encontrada ou sem acesso." /> : <>
        {id
          ? <p className="sec lt-intro">Mudar valor, vigência, fornecedor, instalação ou rateio de uma conta aprovada a manda de novo para aprovação. O tipo não muda.</p>
          : <div className="nc-tipos" role="radiogroup" aria-label="Tipo de conta">
              {TIPOS.map(([k, r, d]) => (
                <button key={k} role="radio" aria-checked={tipo === k} className={`nc-tipo ${tipo === k ? 'on' : ''}`} onClick={() => setTipo(k)}>
                  <b>{r}</b><span className="sec peq">{d}</span>
                </button>
              ))}
            </div>}

        <section className="lt-sec"><h3>Cadastro</h3><div className="kv lt-kv">
          <Campo r="Empresa">
            <select className={`lt-in ${erro(!empresa)}`} value={empresa} onChange={e => { setEmpresa(e.target.value); setLinhas([novaLinha()]); }}>
              <option value="">Escolha quem paga</option>
              {o.empresas.map(e => <option key={e.id} value={e.id} title={e.razao_social}>{e.nome}{e.documento ? ` · ${documento(e.documento)}` : ''}</option>)}
            </select>
          </Campo>
          <Campo r={consumo ? 'Concessionária' : 'Fornecedor'}><BuscaFornecedor v={forn} erro={tentou && !forn} mudar={setForn} /></Campo>
          <Campo r="Descrição"><input className={`lt-in ${erro(!descricao.trim())}`} placeholder={consumo ? 'Ex.: Luz do PDV Vila Jacuí' : 'Ex.: Limpeza do escritório'} value={descricao} onChange={e => setDescricao(e.target.value)} /></Campo>
          {consumo
            ? <Campo r="Nº da instalação" msg="Como está na fatura. É por ele que o sistema acha a fatura.">
                <input className={`lt-in mono ${erro(!instalacao.trim())}`} value={instalacao} onChange={e => setInstalacao(e.target.value)} /></Campo>
            : <Campo r="Número do contrato"><input className="lt-in" placeholder="Opcional" value={numero} onChange={e => setNumero(e.target.value)} /></Campo>}
          {consumo ? <>
            <Campo r="Média esperada por mês" msg="O valor médio da fatura de um mês.">
              <input className={`lt-in num lt-valor ${erro(!faixa)}`} inputMode="decimal" placeholder="R$ 0,00" value={faixaTxt} onChange={e => setFaixaTxt(e.target.value)} onBlur={reaisBlur(faixa, setFaixaTxt)} /></Campo>
            <Campo r="Teto no ano">
              <input className={`lt-in num lt-valor ${erro(!teto)}`} inputMode="decimal" placeholder="R$ 0,00" value={tetoTxt} onChange={e => setTetoTxt(e.target.value)} onBlur={reaisBlur(teto, setTetoTxt)} /></Campo>
          </> : (
            <Campo r={tipo === 'contrato' ? 'Valor do contrato' : 'Valor'}>
              <div className="lt-lin">
                <input className={`lt-in num lt-valor ${erro(!valor)}`} inputMode="decimal" placeholder="R$ 0,00" value={valorTxt} onChange={e => setValorTxt(e.target.value)} onBlur={reaisBlur(valor, setValorTxt)} />
                {tipo === 'assinatura' && <select className="lt-in lt-tipo" value={per} onChange={e => setPer(e.target.value)} aria-label="Periodicidade">{PERIODOS.map(([k, r]) => <option key={k} value={k}>{r}</option>)}</select>}
              </div>
            </Campo>
          )}
          <Campo r="Vigência" msg={fim ? undefined : 'Sem fim: vale até ser encerrada.'}>
            <div className="lt-lin">
              <input type="date" className={`lt-in ${erro(!inicio)}`} value={inicio} onChange={e => setInicio(e.target.value)} aria-label="Início" />
              <span className="sec">a</span>
              <input type="date" className={`lt-in ${erro(Boolean(fim && fim < inicio))}`} value={fim} onChange={e => setFim(e.target.value)} aria-label="Fim" />
            </div>
          </Campo>
          <Campo r="Vencimento" msg={consumo ? 'Na conta de consumo, a fatura que chega preenche e atualiza o dia.' : undefined}>
            <div className="lt-lin"><span className="sec">dia</span>
              <input className={`lt-in num nc-dia ${erro(Boolean(dia) && !(nDia >= 1 && nDia <= 31))}`} inputMode="numeric" placeholder="Opcional" value={dia} onChange={e => setDia(e.target.value.replace(/\D/g, '').slice(0, 2))} aria-label="Dia do vencimento" />
            </div>
          </Campo>
          <Campo r="Previsão" msg={!podeMeses ? (tipo === 'contrato' ? 'Para prever mês a mês, informe o valor e o fim da vigência.'
              : tipo === 'assinatura' ? 'Mês a mês só na assinatura mensal.' : undefined)
            : mesesFinais ? `Mês a mês, ${reais(somaMeses / 100)} em ${lista.length} meses${fim ? '' : '; depois, o valor do último mês'}.`
            : 'O mesmo valor todo mês.'}>
            <div className="lt-lin">
              <button className="btn sm" disabled={!podeMeses} onClick={abrirMeses}><Ic n="lista" s={18} />{mesesFinais ? 'Alterar mês a mês' : 'Prever mês a mês'}</button>
              {mesesFinais && <button className="btn t sm" onClick={() => mudarMeses(null)}>Voltar ao valor igual</button>}
            </div>
          </Campo>
        </div></section>

        <section className="lt-sec"><h3>Onde entra</h3>
          {!emp ? <p className="sec peq">Escolha a empresa para ver os núcleos.</p> : <>
            {linhas.map(l => <LinhaRateio key={l.k} l={l} o={o} emp={emp} varias={linhas.length > 1} valor={consumo ? faixa : tipo === 'assinatura' ? valor : null} tentou={tentou}
              mudar={m => muda(l.k, m)} tirar={() => setLinhas(ls => ls.filter(x => x.k !== l.k))} />)}
            <div className="lt-lin">
              <button className="btn t sm" onClick={() => setLinhas(ls => [...ls, novaLinha(String(Math.max(0, Math.round((100 - somaPct) * 10000) / 10000)))])}><Ic n="add" s={18} />Ratear</button>
              {linhas.length > 1 && <span className={`peq ${Math.abs(somaPct - 100) > 0.00005 ? 'lt-erro' : 'sec'}`}>Soma {somaPct.toLocaleString('pt-BR', { maximumFractionDigits: 4 })}%</span>}
            </div>
          </>}
        </section>

        <ComoPaga p={pag} mudar={x => { setPag(x); setMexeuPag(true); }} doc={forn?.documento} tentou={tentou} />
        <Pronto itens={[
          [consumo ? 'Concessionária' : 'Fornecedor', Boolean(forn)],
          ['Empresa que paga', Boolean(empresa)],
          ['Onde entra, somando 100%', !linhas.some(l => !l.nucleo || !l.centro || !l.natureza || (divisoesDe(o, l.centro).length > 0 && !l.divisao)) && Math.abs(somaPct - 100) <= 0.00005],
          [consumo ? 'Valor previsto de cada mês' : 'Valor de cada título', consumo ? Boolean(faixa) : Boolean(valor), mesesFinais ? 'mês a mês' : undefined],
          ['Dia do vencimento', Boolean(dia) || consumo, !dia && consumo ? 'vem na fatura' : undefined],
          ['Como paga', Boolean(pag) && !faltaPag.length],
        ]} />
      </>}
    </Popup>
  );
}
