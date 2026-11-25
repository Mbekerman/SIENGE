// Nova previsão (Moises, 25/11/2026: "Não tem como adicionar previsão"): a janela do Lançar título (Lancar.tsx), com o
// que a previsão manual tem: empresa, fornecedor opcional, onde entra (uma linha: núcleo, centro, divisão e natureza),
// competência, data prevista, valor e descrição. Grava numa chamada só (api.lancar_previsao, migration
// 20261125005000); as regras (perfil, natureza, divisão, PJ, alçada) são as do banco, e a mensagem dele aparece no pé.
import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alerta, Carregando, Ic } from '../components/Comum';
import { Popup } from '../components/Rastro';
import { documento, hojeISO, lerReais, reais } from '../lib/format';
import { mensagemErro, rpc } from '../lib/supabase';
import { BuscaFornecedor, Campo, LinhaRateio, divisoesDe, juntar, novaLinha, type Linha } from './Lancar';
import type { FornecedorBusca, NaturezaLancavel, OpcoesLancamento } from '../lib/tipos';

export function NovaPrevisao({ fechar, lancada }: { fechar: () => void; lancada: (id: string) => void }) {
  const qc = useQueryClient();
  const op = useQuery({ queryKey: ['lancamento_opcoes'], queryFn: () => rpc<OpcoesLancamento | null>('lancamento_opcoes') });
  const [empresa, setEmpresa] = useState('');
  const [forn, setForn] = useState<FornecedorBusca | null>(null);
  const [linha, setLinha] = useState<Linha>(novaLinha());
  const [comp, setComp] = useState(hojeISO().slice(0, 7));
  const [dataPrev, setDataPrev] = useState('');
  const [valorTxt, setValorTxt] = useState('');
  const [desc, setDesc] = useState('');
  const [tentou, setTentou] = useState(false);

  const o = op.data;
  const emp = o?.empresas.find(e => e.id === empresa);
  useEffect(() => { if (o && !empresa && o.empresas.length === 1) setEmpresa(o.empresas[0].id); }, [o, empresa]);
  const valor = lerReais(valorTxt);
  // a mesma consulta da linha (fica no cache): diz se a natureza escolhida é a restrita do PJ
  const divs = divisoesDe(o, linha.centro);
  const pronta = Boolean(linha.nucleo && linha.centro && (!divs.length || linha.divisao));
  const nq = useQuery({
    queryKey: ['naturezas_lancaveis', linha.nucleo, linha.centro, linha.divisao],
    queryFn: () => rpc<NaturezaLancavel[]>('naturezas_lancaveis', { p_nucleo: linha.nucleo, p_centro: linha.centro, p_divisao: linha.divisao || null }),
    enabled: pronta,
  });
  const pj = Boolean(nq.data?.find(n => n.id === linha.natureza)?.restrita);

  const falta: string[] = [];
  if (!empresa) falta.push('a empresa');
  if (!linha.nucleo || !linha.centro || !linha.natureza || (divs.length > 0 && !linha.divisao)) falta.push('onde entra (núcleo, centro e natureza)');
  if (!comp) falta.push('a competência');
  if (!dataPrev) falta.push('a data prevista');
  if (!valor || valor <= 0) falta.push('o valor');
  if (!forn && !desc.trim()) falta.push('a descrição (previsão sem fornecedor)');

  const enviar = useMutation({
    mutationFn: () => rpc<string>('lancar_previsao', { p: {
      empresa, fornecedor: forn?.id ?? null, nucleo: linha.nucleo, centro: linha.centro, divisao: linha.divisao || null,
      natureza: linha.natureza, competencia: `${comp}-01`, data_prevista: dataPrev, valor, descricao: desc.trim() || null,
    } }),
    onSuccess: id => { qc.invalidateQueries({ queryKey: ['previsoes'] }); lancada(id); },
  });
  const lancar = () => { setTentou(true); if (!falta.length) enviar.mutate(); };

  return (
    <Popup titulo="Nova previsão" fechar={fechar} pe={<>
      {enviar.error ? <span className="lt-erro"><Ic n="warn" s={18} />{mensagemErro(enviar.error)}</span>
        : tentou && falta.length ? <span className="lt-erro"><Ic n="warn" s={18} />Falta {juntar(falta)}.</span> : <span className="esp" />}
      <button className="btn t" onClick={fechar}>Cancelar</button>
      <button className="btn p" onClick={lancar} disabled={enviar.isPending}>{enviar.isPending ? 'Lançando…' : 'Lançar'}</button>
    </>}>
      {op.isLoading ? <Carregando /> : op.error ? <Alerta c="cr" t={mensagemErro(op.error)} /> : !o ? <Alerta c="at" t="Seu papel só permite consulta: você não lança previsões." /> : <>
        <p className="sec lt-intro">A previsão vai para a aprovação. Aprovada, ela entra no Sienge como título de previsão (PRV) e espera a nota que vai consumi-la.</p>

        <section className="lt-sec"><h3>Previsão</h3><div className="kv lt-kv">
          <Campo r="Empresa">
            <select className={`lt-in ${tentou && !empresa ? 'err' : ''}`} value={empresa} onChange={e => { setEmpresa(e.target.value); setLinha(novaLinha()); }}>
              <option value="">Escolha a empresa que vai pagar</option>
              {o.empresas.map(e => <option key={e.id} value={e.id} title={e.razao_social}>{e.nome}{e.documento ? ` · ${documento(e.documento)}` : ''}</option>)}
            </select>
          </Campo>
          <Campo r="Fornecedor" msg="Opcional. Sem fornecedor, qualquer nota da mesma área e natureza pode consumir a previsão.">
            <BuscaFornecedor v={forn} erro={false} mudar={setForn} />
          </Campo>
          <Campo r="Competência e data prevista">
            <div className="lt-lin">
              <input type="month" className={`lt-in ${tentou && !comp ? 'err' : ''}`} value={comp} onChange={e => setComp(e.target.value)} aria-label="Competência" />
              <input type="date" className={`lt-in ${tentou && !dataPrev ? 'err' : ''}`} value={dataPrev} onChange={e => setDataPrev(e.target.value)} aria-label="Data prevista" />
            </div>
          </Campo>
          <Campo r="Valor">
            <input className={`lt-in num lt-valor ${tentou && !valor ? 'err' : ''}`} inputMode="decimal" placeholder="R$ 0,00" value={valorTxt}
              onChange={e => setValorTxt(e.target.value)} onBlur={() => valor && setValorTxt(reais(valor))} />
          </Campo>
          <Campo r="Descrição" topo msg={forn ? 'Opcional.' : 'Obrigatória sem fornecedor: é o nome da previsão na lista e no Sienge.'}>
            <textarea className={`lt-in ${tentou && !forn && !desc.trim() ? 'err' : ''}`} rows={2} maxLength={500} value={desc}
              placeholder="Ex.: Campanha de dezembro no Google" onChange={e => setDesc(e.target.value)} />
          </Campo>
        </div></section>

        <section className="lt-sec"><h3>Onde entra</h3>
          {!emp ? <p className="sec peq">Escolha a empresa para ver os núcleos.</p>
            : <LinhaRateio l={linha} o={o} emp={emp} varias={false} valor={valor} tentou={tentou} mudar={m => setLinha(l => ({ ...l, ...m }))} tirar={() => undefined} />}
          {pj && <span className="nt at">Natureza PJ: a previsão fica só com o master e quem ele designou, é aprovada pelo master e não vai ao Sienge como PRV.</span>}
        </section>
      </>}
    </Popup>
  );
}
