// Lançar título (com nota): a janela do protótipo aprovado (tpl.js › fNovo), lendo e gravando pelo esquema api
// (migration 20261119000200_api_lancar_titulo.sql). Tudo grava numa chamada só (api.lancar_titulo): se o banco
// recusar algo, nada fica pela metade e a mensagem dele aparece no pé da janela.
import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Alerta, Carregando, Chip, Ic } from '../components/Comum';
import { Popup } from '../components/Rastro';
import { data, dividir, documento, hojeISO, lerReais, reais } from '../lib/format';
import { recebedorPix, type Conferido } from '../lib/pix';
import { mensagemErro, rpc, supabase } from '../lib/supabase';
import { abrirComSenha, acordarLeitor, leitorLigado, subirArquivo, TIPOS_ACEITOS } from '../lib/leitor';
import { casarBoletos, conferirValores, juntarLeituras } from '../lib/conjunto';
import { pagDoBanco, textoPag } from './ComoPaga';
import { Escolha } from '../components/Escolha';
import type { ContaCadastro, Contrato, FornecedorBusca, Identificacao, Leitura, NaturezaLancavel, OpcoesLancamento, PrevisaoParaNota, ResultadoLeitor } from '../lib/tipos';

type Forma = 'pix' | 'boleto' | 'ted' | 'cadastro';
export type PixTipo = 'cpf_cnpj' | 'email' | 'telefone' | 'aleatoria';
export interface Linha { k: number; nucleo: string; centro: string; divisao: string; natureza: string; pct: string }
interface Ted { banco: string; agencia: string; agencia_digito: string; conta: string; conta_digito: string; conta_tipo: 'corrente' | 'poupanca'; titular: string; excecao: string }
interface Parcela { k: number; vencimento: string; valor: string; forma: Forma; pix_tipo: PixTipo; pix_chave: string; boleto: string; excecao: string; pix_cc: string; cc_exc: string; bol_exc: string; ted: Ted }

const TIPOS: [string, string][] = [['nfse', 'NFS-e'], ['nfe', 'NF-e'], ['fatura', 'Fatura'], ['boleto', 'Boleto'], ['iptu', 'IPTU'], ['itbi', 'ITBI'], ['darf', 'DARF'], ['darm', 'DARM'], ['dare', 'DARE'], ['recibo', 'Recibo'], ['outro', 'Outro']];
const FORMA: Record<Forma, string> = { pix: 'PIX', boleto: 'Boleto', ted: 'TED', cadastro: 'Do cadastro' };
const PIX: [PixTipo, string][] = [['cpf_cnpj', 'CPF ou CNPJ'], ['email', 'E-mail'], ['telefone', 'Telefone'], ['aleatoria', 'Chave aleatória']];
let seq = 1;
export const novaLinha = (pct = '100'): Linha => ({ k: seq++, nucleo: '', centro: '', divisao: '', natureza: '', pct });
const novaParcela = (base?: Parcela, doc?: string | null): Parcela => ({
  k: seq++, vencimento: '', valor: '', forma: base?.forma ?? 'pix', pix_tipo: base?.pix_tipo ?? 'cpf_cnpj',
  pix_chave: base?.pix_chave ?? (doc ?? ''), boleto: '', excecao: base?.excecao ?? '', pix_cc: '', cc_exc: '', bol_exc: '',
  ted: base?.ted ?? { banco: '', agencia: '', agencia_digito: '', conta: '', conta_digito: '', conta_tipo: 'corrente', titular: doc ?? '', excecao: '' },
});
const so = (s: string) => s.replace(/\D/g, '');
const docSo = (s: string) => s.toUpperCase().replace(/[^0-9A-Z]/g, '');
/** O que falta na TED da parcela (vazio = completa). */
function faltaTed(t: Ted, docForn: string | null | undefined): boolean {
  return so(t.banco).length !== 3 || !so(t.agencia) || !so(t.conta) || !/^[0-9X]$/i.test(t.conta_digito.trim())
    || ![11, 14].includes(docSo(t.titular).length) || Boolean(docForn && docSo(t.titular) !== docForn && !t.excecao.trim());
}

/** A chave como o banco aceita: CPF/CNPJ sem pontuação, e-mail minúsculo, telefone com +55. */
export function chave(t: PixTipo, v: string): string {
  const s = v.trim();
  if (t === 'cpf_cnpj') return s.toUpperCase().replace(/[^0-9A-Z]/g, '');   // também o CNPJ alfanumérico
  if (t === 'telefone') { const d = s.replace(/\D/g, ''); return d.startsWith('55') && d.length >= 12 ? `+${d}` : `+55${d}`; }
  return s.toLowerCase();
}

export function Campo({ r, children, msg, topo }: { r: string; children: ReactNode; msg?: ReactNode; topo?: boolean }) {
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
  // os arquivos do título (nota, boleto, anexos): lidos um a um e juntos numa leitura só (lib/conjunto.ts)
  const [arquivos, setArquivos] = useState<ResultadoLeitor[]>([]);
  const arq = useMemo(() => juntarLeituras(arquivos), [arquivos]);
  const [cand, setCand] = useState<string | null>(null);
  const [semRet, setSemRet] = useState(false);
  const [tomExc, setTomExc] = useState('');
  const [buscaForn, setBuscaForn] = useState('');
  // emitente que o ERP não achou: a tela pergunta ao cadastro de credores do Sienge (função sienge-credores), que traz o
  // credor para o ERP; achado, o fornecedor se preenche (Moises, 24/11/2026)
  const [sienge, setSienge] = useState<BuscaSienge | null>(null);
  const fornAgora = useRef<FornecedorBusca | null>(null);
  fornAgora.current = forn;
  const escolherForn = (f: FornecedorBusca | null) => {
    setForn(f);
    setParcelas(ps => ps.map((p, i) => (i === 0 && !p.pix_chave && f?.documento ? { ...p, pix_tipo: 'cpf_cnpj', pix_chave: f.documento } : p)));
  };

  const o = op.data;
  const emp = o?.empresas.find(e => e.id === empresa);
  useEffect(() => { if (o && !empresa && o.empresas.length === 1) setEmpresa(o.empresas[0].id); }, [o, empresa]);
  const valor = lerReais(valorTxt);
  const somaPct = linhas.reduce((a, l) => a + (Number(l.pct.replace(',', '.')) || 0), 0);
  // o valor de cada parcela: o digitado (como está no documento) ou, sem nenhum, a divisão igual do Sienge
  const iguais = valor ? dividir(valor, parcelas.length) : [];
  const digitados = parcelas.map(p => lerReais(p.valor));
  const comValor = parcelas.length > 1 && digitados.some(v => v != null);
  const somaParc = Math.round(digitados.reduce<number>((a, v) => a + (v ?? 0), 0) * 100) / 100;

  // previsões que casam com as linhas completas do rateio
  const chaves = linhas.filter(l => l.nucleo && l.centro && l.natureza).map(l => ({ nucleo: l.nucleo, centro: l.centro, natureza: l.natureza }));
  const pq = useQuery({
    queryKey: ['previsoes_para_nota', empresa, forn?.id, chaves],
    queryFn: () => rpc<PrevisaoParaNota[]>('previsoes_para_nota', { p_empresa: empresa, p_fornecedor: forn!.id, p_linhas: chaves }),
    enabled: Boolean(empresa && forn && chaves.length),
  });
  const previsoes = pq.data ?? [];
  useEffect(() => { setPrevs(p => p.filter(id => previsoes.some(x => x.id === id))); }, [pq.data]); // eslint-disable-line react-hooks/exhaustive-deps

  // o arquivo: sobe ao leitor, que guarda, lê e diz o que casa; a tela se preenche e tudo continua editável
  // cada arquivo novo entra no conjunto e a tela se preenche de novo pelo conjunto (o que foi mudado à mão é refeito);
  // vários de uma vez sobem um depois do outro, e o erro de um não perde os que já subiram
  // enquanto o leitor lê, a pessoa já pode preencher: o que ela mexer nesse tempo a leitura não troca (Moises,
  // 25/11/2026: a tela não espera a leitura)
  const lendo = useRef(false);
  const mexidos = useRef(new Set<string>());
  const mao = (k: string) => { if (lendo.current) mexidos.current.add(k); };
  const subir = useMutation({ mutationFn: async (fs: File[]) => {
    lendo.current = true; mexidos.current.clear();
    // no boleto, a prévia (texto e Asaas) chega antes e a leitura completa depois toma o lugar dela (Moises, 26/11/2026)
    const pondo = (r: ResultadoLeitor) => setArquivos(a => [...a.filter(x => x.anexo.id !== r.anexo.id), r]);
    try { for (const f of fs) pondo(await subirArquivo(f, pondo)); }
    finally { lendo.current = false; }
  }, onSuccess: () => setSemRet(false) });
  // acorda o leitor ao abrir a tela, para a primeira leitura não esperar o servidor subir
  useEffect(() => { acordarLeitor(); }, []);
  const senha = useMutation({ mutationFn: (x: { id: string; s: string }) => abrirComSenha(x.id, x.s), onSuccess: r => setArquivos(a => a.map(x => (x.anexo.id === r.anexo.id ? r : x))) });
  // com a mesma base (só entrou boleto ou anexo), só as parcelas se refazem: o que foi corrigido à mão no resto fica;
  // com base nova (a nota chegou depois do boleto), a tela inteira se preenche pela nota
  const base = useRef<string | null>(null);
  const basePrevia = useRef(false);   // a base era a prévia: a leitura completa dela preenche a tela inteira
  const [refeitas, setRefeitas] = useState(false);
  useEffect(() => {
    if (!arq) { base.current = null; return; }
    if (base.current === arq.anexo.id && arq.leitura && !basePrevia.current) {
      setParcelas(parcelasLidas(arq.leitura, arq.identificacao?.pagamento ?? null, forn?.documento ?? null));
      setRefeitas(true);
    } else { preencher(arq); setRefeitas(false); }
    base.current = arq.anexo.id; basePrevia.current = Boolean(arq.previa);
  }, [arq]); // eslint-disable-line react-hooks/exhaustive-deps
  const docEmit = arq?.leitura?.emitente?.documento?.toUpperCase().replace(/[^0-9A-Z]/g, '') ?? '';
  const procurarSienge = Boolean(arq && !arq.previa && docEmit && !arq.identificacao?.fornecedor && /^([0-9]{11}|[0-9A-Z]{12}[0-9]{2})$/.test(docEmit));
  useEffect(() => {
    if (!procurarSienge || sienge?.doc === docEmit) return;
    let vivo = true;
    setSienge({ doc: docEmit, estado: 'buscando' });
    buscarCredorSienge(docEmit)
      .then(async () => {
        const l = await rpc<FornecedorBusca[]>('fornecedores', { p_busca: docEmit });
        const f = l.find(x => x.documento === docEmit);
        if (!f) return 'nao' as const;
        if (vivo && !fornAgora.current) { setBuscaForn(''); escolherForn(f); }   // quem já escolheu à mão fica
        return 'achado' as const;
      })
      .catch(() => 'erro' as const)
      .then(estado => { if (vivo) setSienge({ doc: docEmit, estado }); });
    return () => { vivo = false; };
  }, [procurarSienge, docEmit]); // eslint-disable-line react-hooks/exhaustive-deps
  const valores = arq?.leitura ? conferirValores(arq.leitura) : null;
  const comRet = Boolean(arq?.leitura && (temRetencao(arq.leitura) || valores?.retencaoSuspeita));
  // CNPJ do tomador mascarado no documento: sugere as empresas que fecham com o que aparece; quem lança confirma
  const mascaraTom = arq?.leitura?.tomador?.documento_mascara;
  const sugeridas = o && mascaraTom && !arq?.identificacao?.empresa && !empresa ? empresasPelaMascara(mascaraTom, o.empresas) : [];
  const usarCandidato = (c: Identificacao['candidatos'][number] | null) => {
    setCand(c?.id ?? null);
    if (!c) { setPrevs([]); return; }
    if (c.empresa_id && c.empresa_id !== empresa) setEmpresa(c.empresa_id);
    if (c.rateio.length) setLinhas(c.rateio.map(x => ({ ...novaLinha(String(x.percentual)), nucleo: x.nucleo, centro: x.centro, divisao: x.divisao ?? '', natureza: x.natureza })));
    setPrevs(c.tipo === 'previsao' ? [c.id] : []);
  };
  function preencher(r: ResultadoLeitor) {
    const l = r.leitura, id = r.identificacao;
    if (!l) return;
    const livre = (k: string) => !mexidos.current.has(k);
    if (id?.empresa && livre('empresa')) { setEmpresa(id.empresa.id); setLinhas([novaLinha()]); }
    const f = id?.fornecedor;
    const fb: FornecedorBusca | null = f ? { id: f.id, nome: f.nome, nome_fantasia: null, documento: f.documento, tipo: (f.documento ?? '').length === 11 ? 'fisica' : 'juridica' } : null;
    if (livre('forn')) {
      setForn(fb);
      setBuscaForn(fb ? '' : l.emitente?.documento ?? l.emitente?.nome ?? '');
    }
    if (l.tipo && TIPOS.some(([k]) => k === l.tipo) && livre('tipo')) setTipo(l.tipo);
    if (l.numero && livre('numero')) setNumero(l.numero);
    if (livre('serie')) setSerie(l.serie ?? '');
    if (l.emissao && livre('emissao')) setEmissao(l.emissao);
    const c = l.competencia ?? l.consumo?.referencia ?? l.emissao?.slice(0, 7);
    if (c && livre('comp')) setComp(c);
    if (l.valor && livre('valor')) setValorTxt(reais(l.valor));
    setParcelas(parcelasLidas(l, id?.pagamento ?? null, fb?.documento ?? null));
    const melhor = id?.candidatos.find(x => !id.empresa || x.empresa_id === id.empresa.id) ?? null;
    usarCandidato(melhor);
  }

  const muda = (k: number, m: Partial<Linha>) => setLinhas(ls => ls.map(l => (l.k === k ? { ...l, ...m } : l)));
  // as chaves de e-mail e telefone já conhecidas do fornecedor (cadastro e usadas antes), para escolher na parcela
  const cq2 = useQuery({ queryKey: ['fornecedor_chaves_pix', forn?.id], queryFn: () => rpc<ChaveConhecida[]>('fornecedor_chaves_pix', { p_fornecedor: forn!.id }), enabled: Boolean(forn) });
  const chavesForn = cq2.data ?? [];
  const mudaP = (k: number, m: Partial<Parcela>) => setParcelas(ps => ps.map(p => (p.k === k ? { ...p, ...m } : p)));

  // a conta recorrente da nota (as previsões marcadas de um contrato só): com PIX fixo ou TED aprovados no cadastro, a
  // parcela pode usar a forma do cadastro (api.lancar_titulo, forma 'cadastro'; o banco confere de novo)
  const contratos = [...new Set(previsoes.filter(p => prevs.includes(p.id)).map(p => p.compromisso_id))];
  const contrato = contratos.length === 1 ? contratos[0] : null;
  const cq = useQuery({ queryKey: ['conta', contrato], queryFn: () => rpc<ContaCadastro | null>('conta', { p_id: contrato }), enabled: Boolean(contrato) });
  const lq = useQuery({ queryKey: ['contratos'], queryFn: () => rpc<Contrato[]>('contratos'), enabled: Boolean(contrato) });
  const pagCad = contrato ? pagDoBanco(cq.data?.pagamento) : null;
  const cadastroUsavel = Boolean(pagCad && pagCad.modo !== 'cobranca' && lq.data?.find(c => c.id === contrato)?.aprovado);
  const cadastroPendente = Boolean(pagCad && pagCad.modo !== 'cobranca' && lq.data && !lq.data.find(c => c.id === contrato)?.aprovado);
  useEffect(() => { if (!cadastroUsavel) setParcelas(ps => (ps.some(p => p.forma === 'cadastro') ? ps.map(p => (p.forma === 'cadastro' ? { ...p, forma: 'pix' } : p)) : ps)); }, [cadastroUsavel]);

  // tomador lido que não é a empresa do título (Moises, 26/11/2026): alerta vermelho e justificativa obrigatória, que quem
  // aprova vê até o pagamento; o banco confere de novo pelos anexos (erp.tg_anexo_tomador)
  const tomadores = [...new Set(arquivos.map(a => docSo(a.leitura?.tomador?.documento ?? '')).filter(Boolean))];
  const nossos = new Set((o?.empresas ?? []).map(e => docSo(e.documento ?? '')).filter(Boolean));
  const tomFora = tomadores.filter(d => (emp ? d !== docSo(emp.documento ?? '') : !nossos.has(d)));
  const falta: string[] = [];
  const semJustTom = tomFora.length > 0 && tomExc.trim().length < 12;
  if (semJustTom) falta.push('a justificativa do tomador (pelo menos 12 caracteres)');
  if (comRet && !semRet) falta.push('confirmar que a nota não tem retenção (nota com retenção ainda não se lança)');
  if (!empresa) falta.push('a empresa');
  if (!forn) falta.push('o fornecedor');
  if (!numero.trim()) falta.push('o número do documento');
  if (!emissao) falta.push('a emissão');
  if (!comp) falta.push('a competência');
  if (!valor || valor <= 0) falta.push('o valor');
  if (linhas.some(l => !l.nucleo || !l.centro || !l.natureza || (divisoesDe(o, l.centro).length > 0 && !l.divisao))) falta.push('o rateio completo');
  else if (Math.abs(somaPct - 100) > 0.00005) falta.push('o rateio somando 100%');
  if (parcelas.some(p => !p.vencimento)) falta.push('o vencimento de cada parcela');
  if (comValor && digitados.some(v => v == null || v <= 0)) falta.push('o valor de cada parcela (ou de nenhuma, para saírem iguais)');
  else if (comValor && valor && Math.round(somaParc * 100) !== Math.round(valor * 100)) falta.push(`as parcelas somando o valor (estão em ${reais(somaParc)})`);
  if (parcelas.some(p => (p.forma === 'pix' ? !p.pix_chave.trim() : p.forma === 'boleto' ? !p.boleto.replace(/\D/g, '') : p.forma === 'ted' ? faltaTed(p.ted, forn?.documento) : !cadastroUsavel)))
    falta.push('a forma de pagamento de cada parcela');

  const enviar = useMutation({
    mutationFn: () => rpc<string>('lancar_titulo', { p: {
      empresa, fornecedor: forn!.id, tipo, numero: numero.trim(), serie: serie.trim(), emissao, competencia: `${comp}-01`, valor,
      compromisso: contrato,
      rateio: linhas.map(l => ({ nucleo: l.nucleo, centro: l.centro, divisao: l.divisao || null, natureza: l.natureza, percentual: Number(l.pct.replace(',', '.')) })),
      parcelas: parcelas.map(p => p.forma === 'cadastro' ? { vencimento: p.vencimento, ...(comValor ? { valor: lerReais(p.valor) } : {}), forma: 'cadastro' }
        : p.forma === 'ted' ? { vencimento: p.vencimento, ...(comValor ? { valor: lerReais(p.valor) } : {}), forma: 'ted', ted_banco: so(p.ted.banco), ted_agencia: so(p.ted.agencia),
            ted_agencia_digito: p.ted.agencia_digito.trim().toUpperCase() || null, ted_conta: so(p.ted.conta), ted_conta_digito: p.ted.conta_digito.trim().toUpperCase(),
            ted_conta_tipo: p.ted.conta_tipo, ted_titular_documento: docSo(p.ted.titular), ted_excecao: p.ted.excecao.trim() || null }
        : p.forma === 'pix'
        ? { vencimento: p.vencimento, ...(comValor ? { valor: lerReais(p.valor) } : {}), forma: 'pix', pix_tipo: p.pix_tipo, pix_chave: chave(p.pix_tipo, p.pix_chave), pix_excecao: p.excecao.trim() || null, pix_copia_cola: p.pix_cc.trim() || null, pix_copia_cola_excecao: (p.pix_cc.trim() && p.cc_exc.trim()) || null }
        : { vencimento: p.vencimento, ...(comValor ? { valor: lerReais(p.valor) } : {}), forma: 'boleto', boleto_linha: p.boleto.replace(/\D/g, ''), boleto_excecao: p.bol_exc.trim() || null, pix_copia_cola: p.pix_cc.trim() || null, pix_copia_cola_excecao: (p.pix_cc.trim() && p.cc_exc.trim()) || null }),
      previsoes: prevs, etiquetas: etq, anexos: arquivos.map(a => a.anexo.id),
      tomador_excecao: tomFora.length ? tomExc.trim() : null,
    } }),
    onSuccess: id => { qc.invalidateQueries({ queryKey: ['titulos'] }); qc.invalidateQueries({ queryKey: ['previsoes'] }); lancado(id); },
  });

  const lancar = () => { setTentou(true); if (!falta.length) enviar.mutate(); };

  return (
    <Popup titulo="Lançar título" fechar={fechar} pe={<>
      {enviar.error ? <span className="lt-erro"><Ic n="warn" s={18} />{mensagemErro(enviar.error)}</span>
        : tentou && falta.length ? <span className="lt-erro"><Ic n="warn" s={18} />Falta {juntar(falta)}.</span> : <span className="esp" />}
      <button className="btn t" onClick={fechar}>Cancelar</button>
      <button className="btn p" onClick={lancar} disabled={enviar.isPending || semJustTom} title={semJustTom ? 'Escreva a justificativa do tomador (pelo menos 12 caracteres)' : undefined}>{enviar.isPending ? 'Lançando…' : 'Lançar'}</button>
    </>}>
      {op.isLoading ? <Carregando /> : op.error ? <Alerta c="cr" t={mensagemErro(op.error)} /> : !o ? <Alerta c="at" t="Seu papel só permite consulta: você não lança títulos." /> : <>
        <p className="sec lt-intro">A nota vira um título que vai para a aprovação. Aprovado, ele segue sozinho para o Sienge com a forma de pagamento de cada parcela.</p>

        {leitorLigado && <ArquivoNota r={arq} arquivos={arquivos} tirar={id => setArquivos(a => a.filter(x => x.anexo.id !== id))}
          subindo={subir.isPending} erro={subir.error ? mensagemErro(subir.error) : null}
          escolher={fs => { senha.reset(); subir.mutate(fs); }} valor={valor} cand={cand} usar={usarCandidato}
          abrir={(id, x) => senha.mutate({ id, s: x })} abrindo={senha.isPending} erroSenha={senha.error ? mensagemErro(senha.error) : null}
          sugeridas={sugeridas} mascara={mascaraTom} usarEmpresa={id => { setEmpresa(id); setLinhas([novaLinha()]); }}
          sienge={sienge?.doc === docEmit ? sienge.estado : null} />}
        {tomFora.length > 0 && (
          <div className="lt-sec lt-exc">
            <span className="nt cr"><b>O tomador da nota ({tomFora.map(documento).join(', ')}) {emp ? `não é a empresa do título (${emp.nome})` : 'não é nenhuma empresa em que você lança'}.</b> Só lança com a justificativa, que todos os aprovadores veem até o pagamento.</span>
            <textarea className={`lt-in ${tentou && semJustTom ? 'err' : ''}`} rows={2} maxLength={500} style={{ height: 'auto', padding: '8px 12px' }}
              placeholder="Por que lançar esta nota nesta empresa?" aria-label="Justificativa do tomador" value={tomExc} onChange={e => setTomExc(e.target.value)} />
            {semJustTom && <span className="sec peq">Pelo menos 12 caracteres ({tomExc.trim().length} de 12). O botão Lançar fica desligado até lá.</span>}
          </div>
        )}
        {refeitas && <span className="nt inf">As parcelas foram preenchidas de novo com os arquivos novos; o resto da tela ficou como estava.</span>}
        {comRet && arq?.leitura && (
          <div className="lt-sec">
            <span className="nt cr">{temRetencao(arq.leitura) ? `A leitura achou retenção de imposto (${descRetencao(arq.leitura)}).` : 'As parcelas somam menos que o valor da nota, o que costuma ser retenção.'} Nota com retenção ainda não se lança: o título sairia pelo valor bruto e a BKM pagaria ao fornecedor o imposto que ela mesma tem de recolher. Espere a tela de retenções.</span>
            <label className="ab-l"><input type="checkbox" checked={semRet} onChange={e => setSemRet(e.target.checked)} />
              <span>Conferi o documento: a nota não tem retenção (a leitura errou)</span></label>
          </div>
        )}

        <section className="lt-sec"><h3>Documento</h3><div className="kv lt-kv">
          <Campo r="Empresa">
            <select className={`lt-in ${tentou && !empresa ? 'err' : ''}`} value={empresa} onChange={e => { mao('empresa'); setEmpresa(e.target.value); setLinhas([novaLinha()]); }}>
              <option value="">Escolha quem recebe a nota</option>
              {o.empresas.map(e => <option key={e.id} value={e.id} title={e.razao_social}>{e.nome}{e.documento ? ` · ${documento(e.documento)}` : ''}</option>)}
            </select>
          </Campo>
          <Campo r="Fornecedor"><BuscaFornecedor key={buscaForn} inicial={buscaForn} v={forn} erro={tentou && !forn} mudar={f => { mao('forn'); escolherForn(f); }} /></Campo>
          <Campo r="Documento">
            <div className="lt-lin">
              <select className="lt-in lt-tipo" value={tipo} onChange={e => { mao('tipo'); setTipo(e.target.value); }}>{TIPOS.map(([k, r]) => <option key={k} value={k}>{r}</option>)}</select>
              <input className={`lt-in ${tentou && !numero.trim() ? 'err' : ''}`} placeholder="Número" value={numero} onChange={e => { mao('numero'); setNumero(e.target.value); }} />
              <input className="lt-in lt-serie" placeholder="Série" value={serie} onChange={e => { mao('serie'); setSerie(e.target.value); }} />
            </div>
          </Campo>
          <Campo r="Emissão e competência">
            <div className="lt-lin">
              <input type="date" className="lt-in" value={emissao} onChange={e => { mao('emissao'); setEmissao(e.target.value); }} aria-label="Emissão" />
              <input type="month" className="lt-in" value={comp} onChange={e => { mao('comp'); setComp(e.target.value); }} aria-label="Competência" />
            </div>
          </Campo>
          <Campo r="Valor da nota" msg="Sem retenção nem caução nesta versão: o título sai pelo valor da nota.">
            <input className={`lt-in num lt-valor ${tentou && !valor ? 'err' : ''}`} inputMode="decimal" placeholder="R$ 0,00" value={valorTxt}
              onChange={e => { mao('valor'); setValorTxt(e.target.value); }} onBlur={() => valor && setValorTxt(reais(valor))} />
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
                {parcelas.length > 1
                  ? <input className={`lt-in num lt-pv ${tentou && comValor && !(digitados[i] && digitados[i]! > 0) ? 'err' : ''}`} inputMode="decimal" aria-label="Valor da parcela"
                      placeholder={iguais[i] != null ? reais(iguais[i]) : 'R$ 0,00'} value={p.valor}
                      onChange={e => mudaP(p.k, { valor: e.target.value })} onBlur={() => { const v = lerReais(p.valor); if (v != null) mudaP(p.k, { valor: reais(v) }); }} />
                  : <span className="num lt-pv">{iguais[0] != null ? reais(iguais[0]) : ''}</span>}
                <div className="f-seg">{(['pix', 'boleto', 'ted', ...(cadastroUsavel ? ['cadastro'] as const : [])] as Forma[]).map(f => (
                  <button key={f} className={p.forma === f ? 'on' : ''} onClick={() => mudaP(p.k, { forma: f })}>{FORMA[f]}</button>))}</div>
                {parcelas.length > 1 && <button className="icb" title="Tirar a parcela" onClick={() => setParcelas(ps => ps.filter(x => x.k !== p.k))}><Ic n="lixo" s={18} /></button>}
              </div>
              {p.forma === 'cadastro' && pagCad ? <span className="nt ok">Forma do cadastro da conta: {textoPag(pagCad)}</span>
              : p.forma === 'ted' ? <TedParcela t={p.ted} docForn={forn?.documento ?? null} tentou={tentou} mudar={m => mudaP(p.k, { ted: { ...p.ted, ...m } })} />
              : p.forma === 'pix' ? <>
                <ChavePix tipo={p.pix_tipo} valor={p.pix_chave} forn={forn} conhecidas={chavesForn} erro={tentou && !p.pix_chave.trim()}
                  mudar={m => mudaP(p.k, { ...(m.tipo ? { pix_tipo: m.tipo } : {}), ...(m.chave !== undefined ? { pix_chave: m.chave } : {}) })} />
                {p.pix_tipo === 'cpf_cnpj' && forn?.documento && p.pix_chave && chave('cpf_cnpj', p.pix_chave) !== forn.documento && (
                  <div className="lt-exc"><span className="nt at">A chave não é o documento do fornecedor. Só entra com a justificativa, que quem aprova vê.</span>
                    <input className="lt-in" placeholder="Por que pagar em outra chave?" value={p.excecao} onChange={e => mudaP(p.k, { excecao: e.target.value })} /></div>
                )}
              </> : <>
                <input className={`lt-in mono ${tentou && !p.boleto.replace(/\D/g, '') ? 'err' : ''}`} placeholder="Linha digitável (47 dígitos)" value={p.boleto} onChange={e => mudaP(p.k, { boleto: e.target.value })} />
                {[47, 48].includes(p.boleto.replace(/\D/g, '').length) && <RecebedorBoleto linha={p.boleto.replace(/\D/g, '')} docForn={forn?.documento ?? null}
                  valor={(comValor ? digitados[i] : iguais[i]) ?? null} exc={p.bol_exc} mudaExc={v => mudaP(p.k, { bol_exc: v })} tentou={tentou} />}
              </>}
              {/* no PIX, o copia e cola só aparece quando o arquivo trouxe o código (Moises, 26/11/2026); no boleto, sempre */}
              {(p.forma === 'boleto' || (p.forma === 'pix' && p.pix_cc !== '')) && <><input className="lt-in mono" aria-label="PIX copia e cola" placeholder={p.forma === 'boleto' ? 'PIX copia e cola do boleto (opcional)' : 'PIX copia e cola (opcional)'}
                value={p.pix_cc} onChange={e => mudaP(p.k, { pix_cc: e.target.value.replace(/[\r\n]+/g, '') })} />
              {p.pix_cc.trim() && <RecebedorPix codigo={p.pix_cc} forma={p.forma} chaveParcela={p.forma === 'pix' ? chave(p.pix_tipo, p.pix_chave) : null}
                docForn={forn?.documento ?? null} valor={(comValor ? digitados[i] : iguais[i]) ?? null} exc={p.cc_exc} mudaExc={v => mudaP(p.k, { cc_exc: v })} tentou={tentou} />}</>}
            </div>
          ))}
          {cadastroPendente && <span className="sec peq">A forma de pagamento cadastrada na conta está esperando aprovação: até lá, informe a forma desta cobrança.</span>}
          <button className="btn t sm" style={{ alignSelf: 'flex-start' }} onClick={() => setParcelas(ps => [...ps, novaParcela(ps[ps.length - 1])])}><Ic n="add" s={18} />Adicionar parcela</button>
          {parcelas.length > 1 && <span className="sec peq">{comValor
            ? (valor && Math.round(somaParc * 100) !== Math.round(valor * 100) ? `As parcelas somam ${reais(somaParc)}; o valor é ${reais(valor)}.` : 'Cada parcela fica com o valor digitado, como no documento.')
            : 'Sem o valor de cada parcela, elas saem iguais (o centavo que sobra vai na primeira, como no Sienge).'}</span>}
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

/** As divisões (último nível) do centro; com o núcleo, só as em que a pessoa lança nele (Moises, 25/11/2026). */
export const divisoesDe = (o: OpcoesLancamento | null | undefined, centro: string, nucleo?: OpcoesLancamento['empresas'][number]['nucleos'][number]) => {
  const ds = o?.centros.find(c => c.id === centro)?.divisoes ?? [];
  return nucleo?.divisoes ? ds.filter(d => nucleo.divisoes!.includes(d.id)) : ds;
};
export const juntar = (l: string[]) => (l.length < 2 ? l.join('') : `${l.slice(0, -1).join(', ')} e ${l[l.length - 1]}`);

interface ChaveConhecida { tipo: PixTipo; chave: string; origem: 'cadastro' | 'usada' | 'conta' }
const ORIGEM_CHAVE = { cadastro: 'do cadastro', usada: 'já usada com ele', conta: 'da conta recorrente' };

/** A chave PIX da parcela (Moises, 26/11/2026): no CPF/CNPJ, a marca "no CNPJ do fornecedor" põe o documento dele; no
 *  e-mail e no telefone, a lista das chaves conhecidas do fornecedor ou "Outro", que abre o campo para digitar uma nova
 *  (fica só na parcela). */
function ChavePix({ tipo, valor, forn, conhecidas, erro, mudar }: {
  tipo: PixTipo; valor: string; forn: FornecedorBusca | null; conhecidas: ChaveConhecida[]; erro: boolean;
  mudar: (m: { tipo?: PixTipo; chave?: string }) => void;
}) {
  const doc = forn?.documento ?? null;
  const opcoes = useMemo(() => {
    const vistos = new Set<string>();
    return conhecidas.filter(c => c.tipo === tipo).filter(c => { const k = chave(tipo, c.chave); if (vistos.has(k)) return false; vistos.add(k); return true; });
  }, [conhecidas, tipo]);
  const escolhida = opcoes.find(c => valor && chave(tipo, c.chave) === chave(tipo, valor));
  const [outro, setOutro] = useState(false);
  const lista = (tipo === 'email' || tipo === 'telefone') && opcoes.length > 0;
  const noDoc = tipo === 'cpf_cnpj' && Boolean(doc) && chave('cpf_cnpj', valor) === doc;
  const trocarTipo = (t: PixTipo) => {
    setOutro(false);
    const primeira = conhecidas.find(c => c.tipo === t);
    mudar({ tipo: t, chave: t === 'cpf_cnpj' ? doc ?? '' : primeira ? primeira.chave : '' });
  };
  const tipoSel = <select className="lt-in lt-tipo" aria-label="Tipo da chave" value={tipo} onChange={e => trocarTipo(e.target.value as PixTipo)}>{PIX.map(([k, r]) => <option key={k} value={k}>{r}</option>)}</select>;
  if (tipo === 'cpf_cnpj' && doc) return <>
    <div className="lt-lin">{tipoSel}
      {noDoc ? <span className="lt-in lt-fixo">{documento(doc)}</span>
        : <input className={`lt-in ${erro ? 'err' : ''}`} placeholder="CPF ou CNPJ da chave" value={valor} onChange={e => mudar({ chave: e.target.value })} />}
    </div>
    <label className="ab-l"><input type="checkbox" checked={noDoc} onChange={e => mudar({ chave: e.target.checked ? doc : '' })} />
      <span>O PIX é no {doc.length === 11 ? 'CPF' : 'CNPJ'} do fornecedor</span></label>
  </>;
  if (lista && !outro && (escolhida || !valor)) return (
    <div className="lt-lin">{tipoSel}
      <select className={`lt-in ${erro ? 'err' : ''}`} aria-label="Chave PIX" value={escolhida?.chave ?? ''}
        onChange={e => { if (e.target.value === '__outro__') { setOutro(true); mudar({ chave: '' }); } else mudar({ chave: e.target.value }); }}>
        {!escolhida && <option value="">Escolha {tipo === 'email' ? 'o e-mail' : 'o telefone'}</option>}
        {opcoes.map(c => <option key={c.chave} value={c.chave}>{c.chave} ({ORIGEM_CHAVE[c.origem]})</option>)}
        <option value={'__outro__'}>{tipo === 'email' ? 'Outro e-mail…' : 'Outro telefone…'}</option>
      </select>
    </div>
  );
  return (
    <div className="lt-lin">{tipoSel}
      <input className={`lt-in ${erro ? 'err' : ''}`} autoFocus={outro} inputMode={tipo === 'telefone' ? 'tel' : tipo === 'email' ? 'email' : undefined}
        placeholder={tipo === 'email' ? 'Novo e-mail' : tipo === 'telefone' ? 'Novo telefone com DDD' : tipo === 'cpf_cnpj' ? 'CPF ou CNPJ da chave' : 'Chave PIX'}
        value={valor} onChange={e => mudar({ chave: e.target.value })} />
      {lista && <button className="btn t sm" onClick={() => { setOutro(false); mudar({ chave: opcoes[0].chave }); }}>Voltar à lista</button>}
    </div>
  );
}

export function LinhaRateio({ l, o, emp, varias, valor, tentou, mudar, tirar }: {
  l: Linha; o: OpcoesLancamento; emp: OpcoesLancamento['empresas'][number]; varias: boolean; valor: number | null; tentou: boolean;
  mudar: (m: Partial<Linha>) => void; tirar: () => void;
}) {
  const nucleo = emp.nucleos.find(n => n.id === l.nucleo);
  const centros = o.centros.filter(c => nucleo?.centros.includes(c.id));
  const divs = divisoesDe(o, l.centro, nucleo);
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
        <Escolha erro={Boolean(err(l.nucleo))} valor={l.nucleo} rotulo="Núcleo" vazio="Núcleo" disabled={!emp.nucleos.length}
          opcoes={emp.nucleos.map(n => ({ id: n.id, nome: n.nome }))} mudar={id => mudar({ nucleo: id, centro: '', divisao: '', natureza: '' })} />
        <Escolha erro={Boolean(err(l.centro))} valor={l.centro} rotulo="Centro de custo" vazio="Centro de custo" disabled={!nucleo}
          opcoes={centros.map(c => ({ id: c.id, nome: c.nome }))} mudar={id => mudar({ centro: id, divisao: '', natureza: '' })} />
        {divs.length > 0 && (
          <Escolha erro={Boolean(err(l.divisao))} valor={l.divisao} rotulo="Divisão" vazio="Divisão (último nível)"
            opcoes={divs.map(d => ({ id: d.id, nome: d.caminho }))} mudar={id => mudar({ divisao: id, natureza: '' })} />
        )}
        <Escolha className="lt-nat" erro={Boolean(err(l.natureza))} valor={l.natureza} rotulo="Natureza" disabled={!pronta || nq.isLoading}
          vazio={!pronta ? 'Natureza' : nq.isLoading ? 'Carregando…' : nats.length ? 'Natureza (digite para buscar)' : 'Nenhuma natureza liberada para você aqui'}
          opcoes={nats.map(n => ({ id: n.id, nome: n.caminho }))} mudar={id => mudar({ natureza: id })} />
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

export function BuscaFornecedor({ v, mudar, erro, inicial = '' }: { v: FornecedorBusca | null; mudar: (f: FornecedorBusca | null) => void; erro: boolean; inicial?: string }) {
  const [txt, setTxt] = useState(inicial);
  const [busca, setBusca] = useState(inicial);
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

/** As parcelas pelo que o leitor achou: os vencimentos da nota, senão os dos boletos (o do Asaas primeiro), senão o da
 *  fatura; a linha de cada boleto válido vai na parcela dele (pelo valor e pelo vencimento, não pela ordem); sem boleto, a última chave PIX usada com o
 *  fornecedor ou o documento dele. */
export function parcelasLidas(l: NonNullable<ResultadoLeitor['leitura']>, pag: Identificacao['pagamento'], doc: string | null): Parcela[] {
  const venc = (l.parcelas ?? []).filter(p => p.vencimento);
  // cada boleto na parcela dele, pelo valor e pelo vencimento (lib/conjunto.ts); os que não casam com nenhuma ficam fora
  const validos = (l.boletos ?? []).filter(b => b.valida);
  const bol = venc.length ? casarBoletos(venc, validos) : validos;
  const n = Math.max(venc.length, bol.length, 1);
  // o valor de cada parcela como está no documento, quando todas têm (os das parcelas, senão os dos boletos)
  const vs = (n > 1 && (l.parcelas ?? []).length === n && (l.parcelas ?? []).every(p => p.valor && p.valor > 0)) ? (l.parcelas ?? []).map(p => p.valor!)
    : (n > 1 && bol.length === n && bol.every(b => b?.valor && b.valor > 0)) ? bol.map(b => b!.valor!) : null;
  const igual = vs && l.valor ? dividir(l.valor, n) : null;
  const valores = vs && !(igual && vs.every((v, i) => Math.round(v * 100) === Math.round(igual[i] * 100))) ? vs.map(v => reais(v)) : null;
  return Array.from({ length: n }, (_, i) => {
    const b = bol[i];
    const vencimento = venc[i]?.vencimento ?? (b?.conferido_asaas?.ok ? b.conferido_asaas.vencimento : undefined) ?? b?.vencimento ?? l.consumo?.vencimento ?? '';
    const valor = valores?.[i] ?? '';
    // o PIX copia e cola da parcela (o do boleto híbrido), senão, com uma parcela só, o do documento
    const pix_cc = (venc.length ? venc[i] : l.parcelas?.[i])?.pix_copia_cola ?? (n === 1 ? l.pix?.copia_e_cola : undefined) ?? '';
    if (b) return { ...novaParcela(), vencimento, valor, forma: 'boleto', boleto: b.linha, pix_cc };
    const pix = pag?.forma === 'pix' && pag.pix_chave ? { pix_tipo: (pag.pix_tipo ?? 'cpf_cnpj') as PixTipo, pix_chave: pag.pix_chave } : { pix_tipo: 'cpf_cnpj' as PixTipo, pix_chave: doc ?? '' };
    return { ...novaParcela(), vencimento, valor, forma: pag?.forma === 'boleto' ? 'boleto' : 'pix', ...pix, pix_cc };
  });
}

const NOME_TIPO: Record<string, string> = Object.fromEntries(TIPOS);
const COMP: Record<string, string> = { contrato: 'Contrato', assinatura: 'Assinatura', consumo: 'Conta de consumo', pedido: 'Pedido de compra' };

/** O que o leitor achou: os avisos dele, a nota repetida e os processos que podem ter gerado o título. */
function avisosLidos(r: ResultadoLeitor, valor: number | null, sienge: BuscaSienge['estado'] | null): { c: 'cr' | 'at' | 'inf'; t: ReactNode }[] {
  const l = r.leitura, id = r.identificacao, out: { c: 'cr' | 'at' | 'inf'; t: ReactNode }[] = [];
  if (r.erro_leitura && !r.pede_senha) out.push({ c: 'at', t: `${r.erro_leitura}. O arquivo ficou guardado; preencha à mão.` });
  for (const d of [...r.repetido_em, ...(id?.nota_repetida ?? [])].filter((x, i, a) => a.findIndex(y => y.documento_id === x.documento_id) === i))
    out.push({ c: 'cr', t: <>Esta nota já foi lançada: {NOME_TIPO[d.tipo] ?? d.tipo} {d.numero} de {data(d.emissao)}, {reais(d.valor)}{d.titulo_id && <> · <a href={`/titulos/${d.titulo_id}`} target="_blank" rel="noreferrer">abrir o título</a></>}.</> });
  if (!l) return out;
  if (l.origem === 'ia') out.push({ c: 'inf', t: 'Lido pela IA a partir da imagem do documento: confira cada campo antes de lançar.' });
  const emit = `O emitente ${l.emitente?.nome ?? ''} (${documento(l.emitente?.documento ?? '')})`;
  if (l.emitente?.documento && !id?.fornecedor) out.push(
    sienge === 'buscando' ? { c: 'inf', t: `${emit} não está no cadastro do ERP. Procurando nos credores do Sienge…` }
    : sienge === 'achado' ? { c: 'inf', t: `${emit} veio do cadastro de credores do Sienge e já está no fornecedor. Confira.` }
    : sienge === 'nao' ? { c: 'at', t: `${emit} não está no cadastro, nem depois da consulta aos credores do Sienge. Procure pelo nome ou peça o cadastro.` }
    : sienge === 'erro' ? { c: 'at', t: `${emit} não está cadastrado, e não consegui consultar o Sienge agora. Procure pelo nome ou peça o cadastro.` }
    : { c: 'at', t: `${emit} não está cadastrado. Procure pelo nome ou peça o cadastro.` });
  else if (id?.fornecedor && !id.fornecedor.fornecedor) out.push({ c: 'at', t: `${id.fornecedor.nome} está cadastrado, mas não como fornecedor.` });
  for (const b of l.boletos ?? []) {
    const a = b.conferido_asaas;
    if (!b.valida || !a) continue;
    if (!a.ok) out.push({ c: 'at', t: `O banco não confirmou o boleto: ${a.erro ?? 'sem resposta'}.` });
    else if (valor && a.valor && Math.abs(a.valor - valor) > 0.009) out.push({ c: 'at', t: `O boleto registrado no banco é de ${reais(a.valor)}, diferente do valor da nota.` });
    if (a.ok && a.beneficiario_documento && l.emitente?.documento && a.beneficiario_documento !== l.emitente.documento)
      out.push({ c: 'at', t: `O beneficiário do boleto no banco é ${a.beneficiario ?? documento(a.beneficiario_documento)}, não o emitente da nota.` });
  }
  for (const x of conferirValores(l).avisos) out.push({ c: 'at', t: x });
  for (const x of l.avisos ?? []) out.push({ c: 'at', t: x });
  const casados = new Set(casarBoletos((l.parcelas ?? []).filter(p => p.vencimento), (l.boletos ?? []).filter(b => b.valida)).filter(Boolean).map(b => b!.linha));
  const soltos = (l.parcelas ?? []).some(p => p.vencimento) ? (l.boletos ?? []).filter(b => b.valida && !casados.has(b.linha)) : [];
  if (soltos.length) out.push({ c: 'at', t: `${soltos.length === 1 ? 'Um boleto não casa' : `${soltos.length} boletos não casam`} com nenhuma parcela da nota pelo valor e pelo vencimento e ficou de fora: confira.` });
  return out;
}

function ArquivoNota({ r, arquivos, tirar, subindo, erro, escolher, valor, cand, usar, abrir, abrindo, erroSenha, sugeridas, mascara, usarEmpresa, sienge }: {
  r: ResultadoLeitor | null; arquivos: ResultadoLeitor[]; tirar: (id: string) => void;
  subindo: boolean; erro: string | null; escolher: (fs: File[]) => void; valor: number | null;
  cand: string | null; usar: (c: Identificacao['candidatos'][number] | null) => void;
  abrir: (id: string, senha: string) => void; abrindo: boolean; erroSenha: string | null;
  sugeridas: OpcoesLancamento['empresas']; mascara?: string; usarEmpresa: (id: string) => void;
  sienge: BuscaSienge['estado'] | null;
}) {
  const inp = useRef<HTMLInputElement>(null);
  const [sobre, setSobre] = useState(false);
  const [pwd, setPwd] = useState('');
  useEffect(() => { setPwd(''); }, [r]);
  const pegar = (fs?: FileList | null) => { if (fs?.length && !subindo) escolher(Array.from(fs)); };
  // o PDF com senha que falta abrir (um de cada vez)
  const comSenha = arquivos.find(a => a.pede_senha);
  const avisos = r ? avisosLidos(r, valor, sienge) : [];
  const cands = r?.identificacao?.candidatos ?? [];
  return (
    <section className="lt-sec"><h3>Arquivos do título</h3>
      <input ref={inp} type="file" accept={TIPOS_ACEITOS} multiple hidden onChange={e => { pegar(e.target.files); e.target.value = ''; }} />
      {arquivos.length > 0 ? <>
          {arquivos.map(a => (
            <div key={a.anexo.id} className="lt-arq ok">
              <Ic n="anexo" s={22} />
              <span style={{ flex: 1, minWidth: 0 }}><b className="lt-arqn" title={a.anexo.nome}>{a.anexo.nome}</b>
                <span className="sec peq" style={{ display: 'block' }}>{[a.leitura ? (a.leitura.origem === 'xml' ? `Lido do XML${a.leitura.formato ? ` (${a.leitura.formato})` : ''}` : a.previa ? 'Boleto lido pelo texto; a IA lê o resto' : 'Lido pela IA') : a.pede_senha ? 'Com senha' : 'Guardado, sem leitura',
                  a.leitura?.tipo ? NOME_TIPO[a.leitura.tipo] : null, arquivos.length > 1 && r?.anexo.id === a.anexo.id ? 'preenche a tela' : null].filter(Boolean).join(' · ')}</span></span>
              <button className="btn t sm" onClick={() => tirar(a.anexo.id)} disabled={subindo}>Tirar</button>
            </div>
          ))}
          {subindo ? <div className="lt-arq"><Carregando /><span className="sec">Lendo o arquivo… Pode ir preenchendo: o que você digitar agora a leitura não troca.</span></div>
            : <button className="btn t sm" style={{ alignSelf: 'flex-start' }} onClick={() => inp.current?.click()}>Adicionar arquivo (boleto, anexo…)</button>}
        </>
        : subindo ? <div className="lt-arq"><Carregando /><span className="sec">Lendo o arquivo… Pode ir preenchendo: o que você digitar agora a leitura não troca.</span></div>
        : (
          <button className={`lt-arq lt-solta ${sobre ? 'on' : ''}`} onClick={() => inp.current?.click()}
            onDragOver={e => { e.preventDefault(); setSobre(true); }} onDragLeave={() => setSobre(false)}
            onDrop={e => { e.preventDefault(); setSobre(false); pegar(e.dataTransfer.files); }}>
            <Ic n="upload" s={28} />
            <span><b>Comece pelos arquivos</b><span className="sec peq" style={{ display: 'block' }}>Arraste ou escolha o PDF, o XML ou a foto da nota, fatura ou boleto (até 20 MB cada). Os arquivos do mesmo título são lidos juntos: a nota preenche a tela e o boleto entra na parcela dele. Você confere tudo. Ou preencha à mão abaixo.</span></span>
          </button>
        )}
      {erro && <span className="lt-erro"><Ic n="warn" s={18} />{erro}</span>}
      {comSenha && !abrindo && (
        <form className="lt-senha" onSubmit={e => { e.preventDefault(); if (pwd) abrir(comSenha.anexo.id, pwd); }}>
          <span className="nt at">{arquivos.length > 1 ? `${comSenha.anexo.nome}: ` : ''}{comSenha.erro_leitura === 'A senha não abriu o PDF' ? 'A senha não abriu o PDF. Confira e tente de novo.' : 'O PDF tem senha e nenhum CNPJ das empresas abriu. Digite a senha para a tela se preencher, ou preencha à mão.'}</span>
          <div className="lt-lin">
            <input type="password" className="lt-in" aria-label="Senha do PDF" placeholder="Senha do PDF" autoComplete="off" maxLength={100}
              value={pwd} onChange={e => setPwd(e.target.value)} />
            <button className="btn ton" type="submit" disabled={!pwd}>Abrir</button>
          </div>
        </form>
      )}
      {abrindo && <div className="lt-arq"><Carregando /><span className="sec">Abrindo e lendo o PDF…</span></div>}
      {erroSenha && <span className="lt-erro"><Ic n="warn" s={18} />{erroSenha}</span>}
      {avisos.map((a, i) => <span key={i} className={`nt ${a.c}`}>{a.t}</span>)}
      {sugeridas.length > 0 && mascara && (
        <div className="lt-sug">
          <span className="nt at">O CNPJ de quem paga está mascarado no documento ({mascara.replace(/\*/g, '•')}). {sugeridas.length === 1 ? 'Pode ser esta empresa' : 'Pode ser uma destas empresas'}; confira antes de usar:</span>
          <div className="lt-lin">{sugeridas.map(e => <button key={e.id} type="button" className="btn ton sm" onClick={() => usarEmpresa(e.id)}>Usar {e.nome}</button>)}</div>
        </div>
      )}
      {cands.length > 0 && <>
        <span className="sec peq">De onde vem esta nota? Escolher preenche o rateio e a previsão; dá para mudar depois.</span>
        {cands.map(c => (
          <label key={c.id} className="ab-l lt-prev">
            <input type="radio" name="lt-cand" checked={cand === c.id} onChange={() => usar(c)} />
            <span style={{ flex: 1, minWidth: 0 }}>
              <b>{c.tipo === 'previsao' ? `Previsão${c.data ? ` de ${data(c.data)}` : ''}` : `${COMP[c.compromisso_tipo ?? ''] ?? 'Contrato'}${c.numero ? ` ${c.numero}` : ''}`}</b>
              {c.tipo === 'previsao' && c.compromisso_tipo && <> <Chip t={`${COMP[c.compromisso_tipo] ?? 'Contrato'}${c.numero ? ` ${c.numero}` : ''}`} c="ci" /></>}
              <span className="sec peq" style={{ display: 'block' }}>{[c.descricao, c.motivos.join(', ')].filter(Boolean).join(' · ')}</span>
            </span>
            <span className="num" style={{ textAlign: 'right' }}>{c.valor != null ? reais(c.valor) : ''}</span>
          </label>
        ))}
        <label className="ab-l lt-prev"><input type="radio" name="lt-cand" checked={cand === null} onChange={() => usar(null)} /><span>Nenhum destes</span></label>
      </>}
    </section>
  );
}

const RET: [keyof NonNullable<Leitura['retencoes']>, string][] = [['iss', 'ISS'], ['irrf', 'IRRF'], ['inss', 'INSS'], ['pis', 'PIS'], ['cofins', 'COFINS'], ['csll', 'CSLL']];
/** Retenção lida: algum tributo retido ou o líquido abaixo do bruto. Até a tela de retenções, essa nota não se lança
 *  (o envio ao Sienge só barra a nota com retenção registrada, e o Lançar título não registra retenção). */
export const temRetencao = (l: Leitura) => RET.some(([k]) => (l.retencoes?.[k] ?? 0) > 0) || Boolean(l.valor && l.valor_liquido && l.valor_liquido < l.valor - 0.009);
const descRetencao = (l: Leitura) => {
  const it = RET.filter(([k]) => (l.retencoes?.[k] ?? 0) > 0).map(([k, n]) => `${n} ${reais(l.retencoes![k]!)}`);
  return it.length ? it.join(', ') : `líquido ${reais(l.valor_liquido!)} de ${reais(l.valor!)}`;
};

/** As empresas cujo CNPJ fecha com a máscara lida (dígitos e *): com 14 posições, dígito a dígito; senão, pelo começo
 *  (antes do primeiro *) e pelo fim (depois do último *). Só sugestão: quem lança confirma. */
export function empresasPelaMascara(m: string, empresas: OpcoesLancamento['empresas']): OpcoesLancamento['empresas'] {
  const ini = m.slice(0, m.indexOf('*')), fim = m.slice(m.lastIndexOf('*') + 1);
  const fecha = (d: string) => (m.length === d.length ? [...m].every((c, i) => c === '*' || c === d[i]) : d.startsWith(ini) && d.endsWith(fim));
  return empresas.filter(e => e.documento && fecha(e.documento.replace(/\D/g, '')));
}

/** Quem recebe pelo PIX copia e cola: a leitura do código e a conferência (pela função conferir-pagamento; a tela diz só
 *  "conferido", sem a fonte, pedido do Moises de 20/11/2026). Pede a justificativa quando o banco também vai pedir (a
 *  regra de verdade é do banco, no gatilho da parcela: conferência de até 1 dia, com o valor da parcela). */
function RecebedorPix({ codigo, forma, chaveParcela, docForn, valor, exc, mudaExc, tentou }: {
  codigo: string; forma: Forma; chaveParcela: string | null; docForn: string | null; valor: number | null; exc: string; mudaExc: (v: string) => void; tentou: boolean;
}) {
  const c = codigo.trim();
  const r = recebedorPix(c);
  const conf = useQuery({
    queryKey: ['conferir-pagamento', 'pix', c], enabled: !!r && r.contas === 1 && c.length >= 30, retry: false, staleTime: 60 * 60_000,
    queryFn: async () => {
      return conferirPagamento({ codigo: c });
    },
  });
  if (!r || (!r.chave && !r.url)) return <span className="nt cr">O código não traz o recebedor PIX.</span>;
  if (r.contas > 1) return <span className="nt cr">O código traz mais de uma conta PIX e não entra.</span>;
  const a = conf.data;
  const outroValor = !!a?.cpf_cnpj && valor != null && a.valor !== valor;
  const conferido = !!a?.cpf_cnpj && a.cpf_cnpj === docForn && !outroValor;
  const peloCodigo = !r.url && !!r.chave && (forma === 'pix' ? r.chave === chaveParcela : r.chave === docForn);
  const ok = conferido || peloCodigo;
  return (
    <div className="lt-exc">
      <span className="sec peq">Recebe pelo código: {r.nome ?? 'sem nome'} · {r.url ? 'QR dinâmico' : `chave ${r.chave}`}</span>
      {conf.isFetching ? <span className="sec peq">Conferindo quem recebe…</span>
        : a?.cpf_cnpj ? <span className={`nt ${conferido ? 'ok' : 'at'}`}>Conferido: recebe {a.nome ?? 'sem nome'} ({documento(a.cpf_cnpj)}){a.banco ? `, ${a.banco}` : ''}{a.cpf_cnpj !== docForn ? ', que não é o fornecedor.' : outroValor ? `, mas cobra ${a.valor != null ? reais(a.valor) : 'outro valor'}, não o valor da parcela.` : ', que é o fornecedor.'}</span>
        : conf.error ? <span className="sec peq">Não deu para conferir: {(conf.error as Error).message}</span> : null}
      {!ok && !conf.isFetching && <>
        <span className="nt at">{a?.cpf_cnpj && a.cpf_cnpj !== docForn ? 'Quem recebe não é o fornecedor.' : outroValor ? 'O valor cobrado pelo código não é o da parcela.' : r.url ? 'Não deu para conferir quem recebe pelo código dinâmico.'
          : forma === 'pix' ? 'A chave do código não é a chave PIX da parcela.' : 'A chave do código não é o CPF/CNPJ do fornecedor.'} Só entra com a justificativa, que quem aprova vê, a AF recebe o alerta e o título fica marcado até o pagamento.</span>
        <input className={`lt-in ${tentou && !exc.trim() ? 'err' : ''}`} placeholder="Por que pagar por este código?" value={exc} onChange={e => mudaExc(e.target.value)} />
      </>}
    </div>
  );
}

type BuscaSienge = { doc: string; estado: 'buscando' | 'achado' | 'nao' | 'erro' };

/** Pergunta ao cadastro de credores do Sienge pelo CPF ou CNPJ (função sienge-credores, que traz o credor para o ERP como
 *  sistema). A resposta não diz se achou: quem decide o que a pessoa vê é a busca no ERP, depois, pelo RLS. */
async function buscarCredorSienge(doc: string): Promise<void> {
  const { error } = await supabase.functions.invoke('sienge-credores', { body: { documento: doc } });
  if (error) throw error;
}

/** Pede a conferência de quem recebe (função conferir-pagamento, que grava como sistema; o banco é quem decide). */
async function conferirPagamento(body: { codigo: string } | { linha: string }): Promise<Conferido> {
  const { data, error } = await supabase.functions.invoke<Conferido & { erro?: string }>('conferir-pagamento', { body });
  if (error) {
    const corpo = await (error as { context?: Response }).context?.json?.().catch(() => null);
    throw new Error(corpo?.erro ?? 'Não consegui conferir');
  }
  return data as Conferido;
}

/** O beneficiário do boleto, conferido como o recebedor do PIX copia e cola (Moises, 20/11/2026): entra direto quando é o
 *  fornecedor e o valor registrado é o da parcela; senão, só com a justificativa (a regra de verdade é do banco). */
function RecebedorBoleto({ linha, docForn, valor, exc, mudaExc, tentou }: {
  linha: string; docForn: string | null; valor: number | null; exc: string; mudaExc: (v: string) => void; tentou: boolean;
}) {
  const conf = useQuery({ queryKey: ['conferir-pagamento', 'boleto', linha], retry: false, staleTime: 60 * 60_000, queryFn: () => conferirPagamento({ linha }) });
  const a = conf.data;
  const outroValor = !!a?.cpf_cnpj && valor != null && a.valor != null && a.valor !== valor;
  const ok = !!a?.cpf_cnpj && a.cpf_cnpj === docForn && !outroValor;
  return (
    <div className="lt-exc">
      {conf.isFetching ? <span className="sec peq">Conferindo o beneficiário…</span>
        : a?.cpf_cnpj ? <span className={`nt ${ok ? 'ok' : 'at'}`}>Conferido: beneficiário {a.nome ?? 'sem nome'} ({documento(a.cpf_cnpj)}){a.cpf_cnpj !== docForn ? ', que não é o fornecedor.' : outroValor ? `, mas o boleto é de ${reais(a.valor!)}, não do valor da parcela.` : ', que é o fornecedor.'}</span>
        : conf.error ? <span className="sec peq">Não deu para conferir: {(conf.error as Error).message}</span> : null}
      {!ok && !conf.isFetching && <>
        <span className="nt at">{a?.cpf_cnpj && a.cpf_cnpj !== docForn ? 'O beneficiário não é o fornecedor.' : outroValor ? 'O valor do boleto não é o da parcela.' : 'O beneficiário não foi conferido.'} Só entra com a justificativa, que quem aprova vê, a AF recebe o alerta e o título fica marcado até o pagamento.</span>
        <input className={`lt-in ${tentou && !exc.trim() ? 'err' : ''}`} placeholder="Por que pagar este boleto?" value={exc} onChange={e => mudaExc(e.target.value)} />
      </>}
    </div>
  );
}

/** A conta da TED da parcela: banco, agência, conta e o titular; conta de outra pessoa só com a justificativa. */
function TedParcela({ t, docForn, tentou, mudar }: { t: Ted; docForn: string | null; tentou: boolean; mudar: (m: Partial<Ted>) => void }) {
  const err = (x: boolean) => (tentou && x ? 'err' : '');
  const outro = Boolean(docForn && docSo(t.titular) && docSo(t.titular) !== docForn);
  return <>
    <div className="lt-lin lt-ted">
      <label className="nc-dia"><span>Banco</span><input className={`lt-in num ${err(so(t.banco).length !== 3)}`} inputMode="numeric" placeholder="341" title="O código do banco, com 3 dígitos (ex.: 001, 341)" value={t.banco} onChange={e => mudar({ banco: so(e.target.value).slice(0, 3) })} /></label>
      <label><span>Agência</span><input className={`lt-in num ${err(!so(t.agencia))}`} inputMode="numeric" value={t.agencia} onChange={e => mudar({ agencia: so(e.target.value).slice(0, 6) })} /></label>
      <label className="nc-dia"><span>Díg.</span><input className="lt-in num" value={t.agencia_digito} onChange={e => mudar({ agencia_digito: e.target.value.replace(/[^0-9xX]/g, '').slice(0, 1) })} aria-label="Dígito da agência" /></label>
    </div>
    <div className="lt-lin lt-ted">
      <label><span>Conta</span><input className={`lt-in num ${err(!so(t.conta))}`} inputMode="numeric" value={t.conta} onChange={e => mudar({ conta: so(e.target.value).slice(0, 14) })} /></label>
      <label className="nc-dia"><span>Díg.</span><input className={`lt-in num ${err(!/^[0-9X]$/i.test(t.conta_digito.trim()))}`} value={t.conta_digito} onChange={e => mudar({ conta_digito: e.target.value.replace(/[^0-9xX]/g, '').slice(0, 1) })} aria-label="Dígito da conta" /></label>
      <label><span>Tipo</span><select className="lt-in" value={t.conta_tipo} onChange={e => mudar({ conta_tipo: e.target.value as Ted['conta_tipo'] })} aria-label="Tipo da conta">
        <option value="corrente">Corrente</option><option value="poupanca">Poupança</option></select></label>
    </div>
    <label className="lt-ted"><span>CPF ou CNPJ do titular</span><input className={`lt-in num ${err(![11, 14].includes(docSo(t.titular).length))}`} value={t.titular} onChange={e => mudar({ titular: e.target.value })} /></label>
    {outro && <div className="lt-exc"><span className="nt at">A conta não é do fornecedor. Só entra com a justificativa, que quem aprova vê.</span>
      <input className={`lt-in ${err(!t.excecao.trim())}`} placeholder="Por que pagar em outra conta?" value={t.excecao} onChange={e => mudar({ excecao: e.target.value })} /></div>}
  </>;
}
