// Lançar título (com nota): a janela do protótipo aprovado (tpl.js › fNovo), lendo e gravando pelo esquema api
// (migration 20261119000200_api_lancar_titulo.sql). Tudo grava numa chamada só (api.lancar_titulo): se o banco
// recusar algo, nada fica pela metade e a mensagem dele aparece no pé da janela.
import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alerta, Carregando, Chip, Ic } from '../components/Comum';
import { Popup } from '../components/Rastro';
import { data, dividir, documento, hojeISO, lerReais, reais } from '../lib/format';
import { mensagemErro, rpc } from '../lib/supabase';
import type { FornecedorBusca, NaturezaLancavel, OpcoesLancamento, PrevisaoParaNota } from '../lib/tipos';

type Forma = 'pix' | 'boleto';
type PixTipo = 'cpf_cnpj' | 'email' | 'telefone' | 'aleatoria';
interface Linha { k: number; nucleo: string; centro: string; divisao: string; natureza: string; pct: string }
interface Parcela { k: number; vencimento: string; forma: Forma; pix_tipo: PixTipo; pix_chave: string; boleto: string; excecao: string }

const TIPOS: [string, string][] = [['nfse', 'NFS-e'], ['nfe', 'NF-e'], ['fatura', 'Fatura'], ['boleto', 'Boleto'], ['recibo', 'Recibo'], ['outro', 'Outro']];
const PIX: [PixTipo, string][] = [['cpf_cnpj', 'CPF ou CNPJ'], ['email', 'E-mail'], ['telefone', 'Telefone'], ['aleatoria', 'Chave aleatória']];
let seq = 1;
const novaLinha = (pct = '100'): Linha => ({ k: seq++, nucleo: '', centro: '', divisao: '', natureza: '', pct });
const novaParcela = (base?: Parcela, doc?: string | null): Parcela => ({
  k: seq++, vencimento: '', forma: base?.forma ?? 'pix', pix_tipo: base?.pix_tipo ?? 'cpf_cnpj',
  pix_chave: base?.pix_chave ?? (doc ?? ''), boleto: '', excecao: base?.excecao ?? '',
});

/** A chave como o banco aceita: CPF/CNPJ só dígitos, e-mail minúsculo, telefone com +55. */
function chave(t: PixTipo, v: string): string {
  const s = v.trim();
  if (t === 'cpf_cnpj') return s.replace(/\D/g, '');
  if (t === 'telefone') { const d = s.replace(/\D/g, ''); return d.startsWith('55') && d.length >= 12 ? `+${d}` : `+55${d}`; }
  return s.toLowerCase();
}

function Campo({ r, children, msg, topo }: { r: string; children: ReactNode; msg?: ReactNode; topo?: boolean }) {
  return <>
    <div className="k" style={topo ? { alignSelf: 'start', paddingTop: 14 } : undefined}>{r}</div>
    <div className="v lt-v">{children}{msg && <span className="sec peq">{msg}</span>}</div>
  </>;
}

export function LancarTitulo({ fechar, lancado }: { fechar: () => void; lancado: (id: string) => void }) {
  const qc = useQueryClient();
  const op = useQuery({ queryKey: ['lancamento_opcoes'], queryFn: () => rpc<OpcoesLancamento | null>('lancamento_opcoes') });
  const [empresa, setEmpresa] = useState('');
  const [forn, setForn] = useState<FornecedorBusca | null>(null);
  const [tipo, setTipo] = useState('nfse');
  const [numero, setNumero] = useState('');
  const [serie, setSerie] = useState('');
  const [emissao, setEmissao] = useState(hojeISO());
  const [comp, setComp] = useState(hojeISO().slice(0, 7));
  const [valorTxt, setValorTxt] = useState('');
  const [linhas, setLinhas] = useState<Linha[]>([novaLinha()]);
  const [parcelas, setParcelas] = useState<Parcela[]>([novaParcela()]);
  const [prevs, setPrevs] = useState<string[]>([]);
  const [etq, setEtq] = useState<string[]>([]);
  const [tentou, setTentou] = useState(false);

  const o = op.data;
  const emp = o?.empresas.find(e => e.id === empresa);
  useEffect(() => { if (o && !empresa && o.empresas.length === 1) setEmpresa(o.empresas[0].id); }, [o, empresa]);
  const valor = lerReais(valorTxt);
  const somaPct = linhas.reduce((a, l) => a + (Number(l.pct.replace(',', '.')) || 0), 0);
  const valores = valor ? dividir(valor, parcelas.length) : [];

  // previsões que casam com as linhas completas do rateio
  const chaves = linhas.filter(l => l.nucleo && l.centro && l.natureza).map(l => ({ nucleo: l.nucleo, centro: l.centro, natureza: l.natureza }));
  const pq = useQuery({
    queryKey: ['previsoes_para_nota', empresa, forn?.id, chaves],
    queryFn: () => rpc<PrevisaoParaNota[]>('previsoes_para_nota', { p_empresa: empresa, p_fornecedor: forn!.id, p_linhas: chaves }),
    enabled: Boolean(empresa && forn && chaves.length),
  });
  const previsoes = pq.data ?? [];
  useEffect(() => { setPrevs(p => p.filter(id => previsoes.some(x => x.id === id))); }, [pq.data]); // eslint-disable-line react-hooks/exhaustive-deps

  const muda = (k: number, m: Partial<Linha>) => setLinhas(ls => ls.map(l => (l.k === k ? { ...l, ...m } : l)));
  const mudaP = (k: number, m: Partial<Parcela>) => setParcelas(ps => ps.map(p => (p.k === k ? { ...p, ...m } : p)));

  const falta: string[] = [];
  if (!empresa) falta.push('a empresa');
  if (!forn) falta.push('o fornecedor');
  if (!numero.trim()) falta.push('o número do documento');
  if (!emissao) falta.push('a emissão');
  if (!comp) falta.push('a competência');
  if (!valor || valor <= 0) falta.push('o valor');
  if (linhas.some(l => !l.nucleo || !l.centro || !l.natureza || (divisoesDe(o, l.centro).length > 0 && !l.divisao))) falta.push('o rateio completo');
  else if (Math.abs(somaPct - 100) > 0.00005) falta.push('o rateio somando 100%');
  if (parcelas.some(p => !p.vencimento)) falta.push('o vencimento de cada parcela');
  if (parcelas.some(p => (p.forma === 'pix' ? !p.pix_chave.trim() : !p.boleto.replace(/\D/g, '')))) falta.push('a forma de pagamento de cada parcela');

  const contratos = [...new Set(previsoes.filter(p => prevs.includes(p.id)).map(p => p.compromisso_id))];
  const enviar = useMutation({
    mutationFn: () => rpc<string>('lancar_titulo', { p: {
      empresa, fornecedor: forn!.id, tipo, numero: numero.trim(), serie: serie.trim(), emissao, competencia: `${comp}-01`, valor,
      compromisso: contratos.length === 1 ? contratos[0] : null,
      rateio: linhas.map(l => ({ nucleo: l.nucleo, centro: l.centro, divisao: l.divisao || null, natureza: l.natureza, percentual: Number(l.pct.replace(',', '.')) })),
      parcelas: parcelas.map(p => p.forma === 'pix'
        ? { vencimento: p.vencimento, forma: 'pix', pix_tipo: p.pix_tipo, pix_chave: chave(p.pix_tipo, p.pix_chave), pix_excecao: p.excecao.trim() || null }
        : { vencimento: p.vencimento, forma: 'boleto', boleto_linha: p.boleto.replace(/\D/g, '') }),
      previsoes: prevs, etiquetas: etq,
    } }),
    onSuccess: id => { qc.invalidateQueries({ queryKey: ['titulos'] }); qc.invalidateQueries({ queryKey: ['previsoes'] }); lancado(id); },
  });

  const lancar = () => { setTentou(true); if (!falta.length) enviar.mutate(); };

  return (
    <Popup titulo="Lançar título" fechar={fechar} pe={<>
      {enviar.error ? <span className="lt-erro"><Ic n="warn" s={18} />{mensagemErro(enviar.error)}</span>
        : tentou && falta.length ? <span className="lt-erro"><Ic n="warn" s={18} />Falta {juntar(falta)}.</span> : <span className="esp" />}
      <button className="btn t" onClick={fechar}>Cancelar</button>
      <button className="btn p" onClick={lancar} disabled={enviar.isPending}>{enviar.isPending ? 'Lançando…' : 'Lançar'}</button>
    </>}>
      {op.isLoading ? <Carregando /> : op.error ? <Alerta c="cr" t={mensagemErro(op.error)} /> : !o ? <Alerta c="at" t="Seu papel só permite consulta: você não lança títulos." /> : <>
        <p className="sec lt-intro">A nota vira um título que vai para a aprovação. Aprovado, ele segue sozinho para o Sienge com a forma de pagamento de cada parcela.</p>

        <section className="lt-sec"><h3>Documento</h3><div className="kv lt-kv">
          <Campo r="Empresa">
            <select className={`lt-in ${tentou && !empresa ? 'err' : ''}`} value={empresa} onChange={e => { setEmpresa(e.target.value); setLinhas([novaLinha()]); }}>
              <option value="">Escolha quem recebe a nota</option>
              {o.empresas.map(e => <option key={e.id} value={e.id}>{e.nome}{e.documento ? ` · ${documento(e.documento)}` : ''}</option>)}
            </select>
          </Campo>
          <Campo r="Fornecedor"><BuscaFornecedor v={forn} erro={tentou && !forn} mudar={f => { setForn(f); setParcelas(ps => ps.map((p, i) => (i === 0 && !p.pix_chave && f?.documento ? { ...p, pix_tipo: 'cpf_cnpj', pix_chave: f.documento } : p))); }} /></Campo>
          <Campo r="Documento">
            <div className="lt-lin">
              <select className="lt-in lt-tipo" value={tipo} onChange={e => setTipo(e.target.value)}>{TIPOS.map(([k, r]) => <option key={k} value={k}>{r}</option>)}</select>
              <input className={`lt-in ${tentou && !numero.trim() ? 'err' : ''}`} placeholder="Número" value={numero} onChange={e => setNumero(e.target.value)} />
              <input className="lt-in lt-serie" placeholder="Série" value={serie} onChange={e => setSerie(e.target.value)} />
            </div>
          </Campo>
          <Campo r="Emissão e competência">
            <div className="lt-lin">
              <input type="date" className="lt-in" value={emissao} onChange={e => setEmissao(e.target.value)} aria-label="Emissão" />
              <input type="month" className="lt-in" value={comp} onChange={e => setComp(e.target.value)} aria-label="Competência" />
            </div>
          </Campo>
          <Campo r="Valor da nota" msg="Sem retenção nem caução nesta versão: o título sai pelo valor da nota.">
            <input className={`lt-in num lt-valor ${tentou && !valor ? 'err' : ''}`} inputMode="decimal" placeholder="R$ 0,00" value={valorTxt}
              onChange={e => setValorTxt(e.target.value)} onBlur={() => valor && setValorTxt(reais(valor))} />
          </Campo>
        </div></section>

        <section className="lt-sec"><h3>Onde entra</h3>
          {!emp ? <p className="sec peq">Escolha a empresa para ver os núcleos.</p> : <>
            {linhas.map(l => <LinhaRateio key={l.k} l={l} o={o} emp={emp} varias={linhas.length > 1} valor={valor} tentou={tentou}
              mudar={m => muda(l.k, m)} tirar={() => setLinhas(ls => ls.filter(x => x.k !== l.k))} />)}
            <div className="lt-lin">
              <button className="btn t sm" onClick={() => setLinhas(ls => [...ls, novaLinha(String(Math.max(0, Math.round((100 - somaPct) * 10000) / 10000)))])}><Ic n="add" s={18} />Ratear</button>
              {linhas.length > 1 && <span className={`peq ${Math.abs(somaPct - 100) > 0.00005 ? 'lt-erro' : 'sec'}`}>Soma {somaPct.toLocaleString('pt-BR', { maximumFractionDigits: 4 })}%</span>}
            </div>
          </>}
        </section>

        {forn && chaves.length > 0 && (
          <section className="lt-sec"><h3>Previsões que a nota consome</h3>
            {pq.isLoading ? <Carregando /> : !previsoes.length ? <p className="sec peq">Nenhuma previsão aberta deste fornecedor nessa área e natureza.</p> : <>
              {previsoes.map(p => (
                <label key={p.id} className="ab-l lt-prev">
                  <input type="checkbox" checked={prevs.includes(p.id)} onChange={e => setPrevs(x => (e.target.checked ? [...x, p.id] : x.filter(i => i !== p.id)))} />
                  <span style={{ flex: 1, minWidth: 0 }}>
                    <span className="lt-lin" style={{ gap: 8 }}>{p.sienge ? <b>{p.sienge}</b> : <b>Previsão de {data(p.data_prevista)}</b>}
                      {p.aprovada === false && <Chip t="Esperando aprovação" c="at" />}{p.contrato && <Chip t={`Contrato ${p.contrato}`} c="ci" />}</span>
                    <span className="sec peq" style={{ display: 'block' }}>{[p.sienge && `prevista para ${data(p.data_prevista)}`, p.area, p.descricao].filter(Boolean).join(' · ')}</span>
                  </span>
                  <span className="num" style={{ textAlign: 'right' }}>{reais(p.saldo)}{Number(p.saldo) !== Number(p.valor) && <span className="sec peq" style={{ display: 'block' }}>de {reais(p.valor)}</span>}</span>
                </label>
              ))}
              <span className="sec peq">A nota consome as marcadas, até o valor dela. Sem nenhuma marcada, consome só as do contrato, quando houver.</span>
            </>}
          </section>
        )}

        <section className="lt-sec"><h3>{parcelas.length > 1 ? `${parcelas.length} parcelas` : 'Pagamento'}</h3>
          {parcelas.map((p, i) => (
            <div key={p.k} className="lt-parc">
              <div className="lt-lin">
                <b className="lt-pn">{parcelas.length > 1 ? `${i + 1}ª` : 'Vence'}</b>
                <input type="date" className={`lt-in ${tentou && !p.vencimento ? 'err' : ''}`} value={p.vencimento} onChange={e => mudaP(p.k, { vencimento: e.target.value })} aria-label="Vencimento" />
                <span className="num lt-pv">{valores[i] != null ? reais(valores[i]) : ''}</span>
                <div className="f-seg"><button className={p.forma === 'pix' ? 'on' : ''} onClick={() => mudaP(p.k, { forma: 'pix' })}>PIX</button><button className={p.forma === 'boleto' ? 'on' : ''} onClick={() => mudaP(p.k, { forma: 'boleto' })}>Boleto</button></div>
                {parcelas.length > 1 && <button className="icb" title="Tirar a parcela" onClick={() => setParcelas(ps => ps.filter(x => x.k !== p.k))}><Ic n="lixo" s={18} /></button>}
              </div>
              {p.forma === 'pix' ? <>
                <div className="lt-lin">
                  <select className="lt-in lt-tipo" value={p.pix_tipo} onChange={e => mudaP(p.k, { pix_tipo: e.target.value as PixTipo })}>{PIX.map(([k, r]) => <option key={k} value={k}>{r}</option>)}</select>
                  <input className={`lt-in ${tentou && !p.pix_chave.trim() ? 'err' : ''}`} placeholder="Chave PIX" value={p.pix_chave} onChange={e => mudaP(p.k, { pix_chave: e.target.value })} />
                </div>
                {p.pix_tipo === 'cpf_cnpj' && forn?.documento && p.pix_chave && chave('cpf_cnpj', p.pix_chave) !== forn.documento && (
                  <div className="lt-exc"><span className="nt at">A chave não é o documento do fornecedor. Só entra com a justificativa, que quem aprova vê.</span>
                    <input className="lt-in" placeholder="Por que pagar em outra chave?" value={p.excecao} onChange={e => mudaP(p.k, { excecao: e.target.value })} /></div>
                )}
              </> : (
                <input className={`lt-in mono ${tentou && !p.boleto.replace(/\D/g, '') ? 'err' : ''}`} placeholder="Linha digitável (47 dígitos)" value={p.boleto} onChange={e => mudaP(p.k, { boleto: e.target.value })} />
              )}
            </div>
          ))}
          <button className="btn t sm" style={{ alignSelf: 'flex-start' }} onClick={() => setParcelas(ps => [...ps, novaParcela(ps[ps.length - 1])])}><Ic n="add" s={18} />Adicionar parcela</button>
          {parcelas.length > 1 && <span className="sec peq">As parcelas saem iguais; o centavo que sobra vai na primeira, como no Sienge.</span>}
        </section>

        {o.etiquetas.length > 0 && (
          <section className="lt-sec"><h3>Etiquetas</h3>
            <div className="lt-lin" style={{ flexWrap: 'wrap' }}>
              {o.etiquetas.map(x => { const on = etq.includes(x.id); return (
                <button key={x.id} className={`chip f ${on ? '' : 'off'}`} aria-pressed={on} onClick={() => setEtq(e => (on ? e.filter(i => i !== x.id) : [...e, x.id]))}>{on && <Ic n="check" s={16} />}{x.nome}</button>
              ); })}
            </div>
          </section>
        )}
      </>}
    </Popup>
  );
}

const divisoesDe = (o: OpcoesLancamento | null | undefined, centro: string) => o?.centros.find(c => c.id === centro)?.divisoes ?? [];
const juntar = (l: string[]) => (l.length < 2 ? l.join('') : `${l.slice(0, -1).join(', ')} e ${l[l.length - 1]}`);

function LinhaRateio({ l, o, emp, varias, valor, tentou, mudar, tirar }: {
  l: Linha; o: OpcoesLancamento; emp: OpcoesLancamento['empresas'][number]; varias: boolean; valor: number | null; tentou: boolean;
  mudar: (m: Partial<Linha>) => void; tirar: () => void;
}) {
  const nucleo = emp.nucleos.find(n => n.id === l.nucleo);
  const centros = o.centros.filter(c => nucleo?.centros.includes(c.id));
  const divs = divisoesDe(o, l.centro);
  const pronta = Boolean(l.nucleo && l.centro && (!divs.length || l.divisao));
  const nq = useQuery({
    queryKey: ['naturezas_lancaveis', l.nucleo, l.centro, l.divisao],
    queryFn: () => rpc<NaturezaLancavel[]>('naturezas_lancaveis', { p_nucleo: l.nucleo, p_centro: l.centro, p_divisao: l.divisao || null }),
    enabled: pronta,
  });
  const nats = nq.data ?? [];
  useEffect(() => { if (nq.data && l.natureza && !nq.data.some(n => n.id === l.natureza)) mudar({ natureza: '' }); }, [nq.data]); // eslint-disable-line react-hooks/exhaustive-deps
  const pct = Number(l.pct.replace(',', '.')) || 0;
  const err = (x: string) => (tentou && !x ? 'err' : '');
  return (
    <div className="lt-rat">
      <div className="lt-grid">
        <select className={`lt-in ${err(l.nucleo)}`} value={l.nucleo} onChange={e => mudar({ nucleo: e.target.value, centro: '', divisao: '', natureza: '' })} aria-label="Núcleo">
          <option value="">Núcleo</option>{emp.nucleos.map(n => <option key={n.id} value={n.id}>{n.nome}</option>)}
        </select>
        <select className={`lt-in ${err(l.centro)}`} value={l.centro} onChange={e => mudar({ centro: e.target.value, divisao: '', natureza: '' })} disabled={!nucleo} aria-label="Centro de custo">
          <option value="">Centro de custo</option>{centros.map(c => <option key={c.id} value={c.id}>{c.nome}</option>)}
        </select>
        {divs.length > 0 && (
          <select className={`lt-in ${err(l.divisao)}`} value={l.divisao} onChange={e => mudar({ divisao: e.target.value, natureza: '' })} aria-label="Divisão">
            <option value="">Divisão (último nível)</option>{divs.map(d => <option key={d.id} value={d.id}>{d.caminho}</option>)}
          </select>
        )}
        <select className={`lt-in lt-nat ${err(l.natureza)}`} value={l.natureza} onChange={e => mudar({ natureza: e.target.value })} disabled={!pronta || nq.isLoading} aria-label="Natureza">
          <option value="">{!pronta ? 'Natureza' : nq.isLoading ? 'Carregando…' : nats.length ? 'Natureza' : 'Nenhuma natureza liberada para você aqui'}</option>
          {nats.map(n => <option key={n.id} value={n.id}>{n.caminho}</option>)}
        </select>
      </div>
      {varias && (
        <div className="lt-lin lt-pct">
          <input className="lt-in num" inputMode="decimal" value={l.pct} onChange={e => mudar({ pct: e.target.value })} aria-label="Percentual" /><span className="sec">%</span>
          <span className="num sec">{valor ? reais(Math.round(valor * pct) / 100) : ''}</span>
          <span className="esp" /><button className="icb" title="Tirar a linha" onClick={tirar}><Ic n="lixo" s={18} /></button>
        </div>
      )}
    </div>
  );
}

function BuscaFornecedor({ v, mudar, erro }: { v: FornecedorBusca | null; mudar: (f: FornecedorBusca | null) => void; erro: boolean }) {
  const [txt, setTxt] = useState('');
  const [busca, setBusca] = useState('');
  const [ab, setAb] = useState(false);
  useEffect(() => { const t = setTimeout(() => setBusca(txt), 250); return () => clearTimeout(t); }, [txt]);
  const q = useQuery({ queryKey: ['fornecedores', busca], queryFn: () => rpc<FornecedorBusca[]>('fornecedores', { p_busca: busca }), enabled: ab && busca.trim().length >= 2 });
  const lista = useMemo(() => q.data ?? [], [q.data]);
  if (v) return (
    <div className="lt-lin"><span style={{ flex: 1, minWidth: 0 }}>{v.nome}{v.documento && <span className="sec"> · {documento(v.documento)}</span>}</span>
      <button className="btn t sm" onClick={() => { mudar(null); setTxt(''); }}>Trocar</button></div>
  );
  return (
    <div className="lt-busca">
      <input className={`lt-in ${erro ? 'err' : ''}`} placeholder="Nome, nome fantasia ou CNPJ" value={txt} autoFocus
        onChange={e => { setTxt(e.target.value); setAb(true); }} onFocus={() => setAb(true)} onBlur={() => setTimeout(() => setAb(false), 150)} />
      {ab && busca.trim().length >= 2 && (
        <div className="lt-op" role="listbox">
          {q.isLoading ? <div className="sec peq lt-o">Buscando…</div> : !lista.length ? <div className="sec peq lt-o">Nenhum fornecedor encontrado.</div>
            : lista.map(f => (
              <button key={f.id} className="lt-o" role="option" onMouseDown={e => e.preventDefault()} onClick={() => { mudar(f); setAb(false); }}>
                <span>{f.nome}</span><span className="sec peq">{[f.nome_fantasia, f.documento && documento(f.documento)].filter(Boolean).join(' · ')}</span>
              </button>
            ))}
        </div>
      )}
    </div>
  );
}
