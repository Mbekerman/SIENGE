// Como a conta recorrente paga (Moises, 23/11/2026): PIX fixo, TED ou "vem com cada cobrança", gravado no cadastro e
// aprovado com ele (migration 20261123000300_erp_conta_pagamento.sql). Não é obrigatório; a lista "Pronto para gerar
// títulos" mostra o que falta para a nota do mês virar título sem pedir mais nada.
import { Ic } from '../components/Comum';
import { documento } from '../lib/format';
import { Campo, chave, type PixTipo } from './Lancar';

export type Modo = 'pix' | 'ted' | 'cobranca';
export interface Pag {
  modo: Modo; pix_tipo: PixTipo; pix_chave: string; banco: string; agencia: string; agencia_digito: string;
  conta: string; conta_digito: string; conta_tipo: 'corrente' | 'poupanca'; titular_documento: string; excecao: string;
}
/** Como vem do banco (api.conta → pagamento). */
export type PagGravado = { [K in keyof Pag]: K extends 'modo' ? Modo : string | null };

const MODOS: [Modo | '', string][] = [['', 'Ainda não informado'], ['pix', 'PIX fixo (a mesma chave todo mês)'], ['ted', 'TED (a mesma conta todo mês)'], ['cobranca', 'Vem com cada cobrança (boleto ou PIX copia e cola)']];
const PIX: [PixTipo, string][] = [['cpf_cnpj', 'CPF ou CNPJ'], ['email', 'E-mail'], ['telefone', 'Telefone'], ['aleatoria', 'Chave aleatória']];
const so = (s: string) => s.replace(/\D/g, '');
const docSo = (s: string) => s.toUpperCase().replace(/[^0-9A-Z]/g, '');   // CPF/CNPJ, também o alfanumérico

export const pagVazio = (modo: Modo, doc: string | null | undefined): Pag => ({
  modo, pix_tipo: 'cpf_cnpj', pix_chave: doc ?? '', banco: '', agencia: '', agencia_digito: '', conta: '', conta_digito: '',
  conta_tipo: 'corrente', titular_documento: doc ?? '', excecao: '',
});
export const pagDoBanco = (g: PagGravado | null | undefined): Pag | null => g ? {
  modo: g.modo, pix_tipo: (g.pix_tipo ?? 'cpf_cnpj') as PixTipo, pix_chave: g.pix_chave ?? '', banco: g.banco ?? '', agencia: g.agencia ?? '',
  agencia_digito: g.agencia_digito ?? '', conta: g.conta ?? '', conta_digito: g.conta_digito ?? '',
  conta_tipo: (g.conta_tipo ?? 'corrente') as Pag['conta_tipo'], titular_documento: g.titular_documento ?? '', excecao: g.excecao ?? '',
} : null;

/** De quem é o dinheiro: o documento para onde vai (chave CPF/CNPJ ou titular da TED); nulo = não dá para comparar. */
const destino = (p: Pag) => p.modo === 'ted' ? docSo(p.titular_documento) : p.modo === 'pix' && p.pix_tipo === 'cpf_cnpj' ? docSo(p.pix_chave) : null;
export const pagaOutro = (p: Pag | null, doc: string | null | undefined) => Boolean(p && doc && destino(p) && destino(p) !== doc);

/** O que falta na forma escolhida (vazio = completa). */
export function faltaNoPag(p: Pag | null, doc: string | null | undefined): string[] {
  if (!p) return [];
  const f: string[] = [];
  if (p.modo === 'pix' && !p.pix_chave.trim()) f.push('a chave PIX');
  if (p.modo === 'ted') {
    if (so(p.banco).length !== 3) f.push('o banco (3 dígitos)');
    if (!so(p.agencia)) f.push('a agência');
    if (!so(p.conta) || !/^[0-9X]$/i.test(p.conta_digito.trim())) f.push('a conta com o dígito');
    if (![11, 14].includes(docSo(p.titular_documento).length)) f.push('o CPF ou CNPJ do titular');
  }
  if (pagaOutro(p, doc) && !p.excecao.trim()) f.push('a justificativa de pagar a outra pessoa');
  return f;
}

/** O que vai ao banco (api.salvar_conta → pagamento). */
export const pagParaBanco = (p: Pag | null) => !p ? null : p.modo === 'cobranca' ? { modo: 'cobranca' }
  : p.modo === 'pix' ? { modo: 'pix', pix_tipo: p.pix_tipo, pix_chave: chave(p.pix_tipo, p.pix_chave), excecao: p.excecao.trim() || null }
  : { modo: 'ted', banco: so(p.banco), agencia: so(p.agencia), agencia_digito: p.agencia_digito.trim().toUpperCase() || null, conta: so(p.conta),
      conta_digito: p.conta_digito.trim().toUpperCase(), conta_tipo: p.conta_tipo, titular_documento: docSo(p.titular_documento), excecao: p.excecao.trim() || null };

/** Em uma linha, para a gaveta e para quem aprova. */
export function textoPag(p: Pag | null): string | null {
  if (!p) return null;
  if (p.modo === 'cobranca') return 'Vem com cada cobrança (boleto ou PIX copia e cola)';
  if (p.modo === 'pix') return `PIX fixo · ${PIX.find(([k]) => k === p.pix_tipo)?.[1] ?? ''} ${p.pix_tipo === 'cpf_cnpj' ? documento(p.pix_chave) : p.pix_chave}`;
  return `TED · banco ${p.banco} · agência ${p.agencia}${p.agencia_digito ? `-${p.agencia_digito}` : ''} · conta ${p.conta_tipo === 'poupanca' ? 'poupança ' : ''}${p.conta}-${p.conta_digito} · titular ${documento(p.titular_documento)}`;
}

export function ComoPaga({ p, mudar, doc, tentou }: { p: Pag | null; mudar: (p: Pag | null) => void; doc: string | null | undefined; tentou: boolean }) {
  const m = (x: Partial<Pag>) => p && mudar({ ...p, ...x });
  const falta = faltaNoPag(p, doc);
  const err = (x: boolean) => (tentou && x ? 'err' : '');
  return (
    <section className="lt-sec"><h3>Como paga</h3><div className="kv lt-kv">
      <Campo r="Forma" msg={!p ? 'Sem a forma, cada título vai pedir como pagar.'
          : p.modo === 'cobranca' ? 'O boleto ou o PIX copia e cola chega com a nota de cada mês. Se vier de outro jeito, a AF escolhe.'
          : 'Faz parte do cadastro aprovado: mudar manda de novo para aprovação.'}>
        <select className="lt-in" value={p?.modo ?? ''} aria-label="Forma de pagamento"
          onChange={e => mudar(e.target.value ? { ...(p ?? pagVazio(e.target.value as Modo, doc)), modo: e.target.value as Modo } : null)}>
          {MODOS.map(([k, r]) => <option key={k} value={k}>{r}</option>)}
        </select>
      </Campo>
      {p?.modo === 'pix' && (
        <Campo r="Chave PIX">
          <div className="lt-lin">
            <select className="lt-in lt-tipo" value={p.pix_tipo} onChange={e => m({ pix_tipo: e.target.value as PixTipo })} aria-label="Tipo da chave">
              {PIX.map(([k, r]) => <option key={k} value={k}>{r}</option>)}</select>
            <input className={`lt-in ${err(!p.pix_chave.trim())}`} placeholder="Chave PIX" value={p.pix_chave} onChange={e => m({ pix_chave: e.target.value })} />
          </div>
        </Campo>
      )}
      {p?.modo === 'ted' && <>
        <Campo r="Banco" msg="O código do banco, com 3 dígitos (ex.: 001, 341).">
          <div className="lt-lin">
            <input className={`lt-in num nc-dia ${err(so(p.banco).length !== 3)}`} inputMode="numeric" value={p.banco} onChange={e => m({ banco: so(e.target.value).slice(0, 3) })} aria-label="Banco" />
          </div>
        </Campo>
        <Campo r="Agência">
          <div className="lt-lin">
            <input className={`lt-in num ${err(!so(p.agencia))}`} inputMode="numeric" placeholder="Número" value={p.agencia} onChange={e => m({ agencia: so(e.target.value).slice(0, 6) })} aria-label="Agência" />
            <input className="lt-in num nc-dia" placeholder="Díg." value={p.agencia_digito} onChange={e => m({ agencia_digito: e.target.value.replace(/[^0-9xX]/g, '').slice(0, 1) })} aria-label="Dígito da agência" />
          </div>
        </Campo>
        <Campo r="Conta">
          <div className="lt-lin">
            <input className={`lt-in num ${err(!so(p.conta))}`} inputMode="numeric" placeholder="Número" value={p.conta} onChange={e => m({ conta: so(e.target.value).slice(0, 14) })} aria-label="Conta" />
            <input className={`lt-in num nc-dia ${err(!p.conta_digito.trim())}`} placeholder="Díg." value={p.conta_digito} onChange={e => m({ conta_digito: e.target.value.replace(/[^0-9xX]/g, '').slice(0, 1) })} aria-label="Dígito da conta" />
            <select className="lt-in lt-tipo" value={p.conta_tipo} onChange={e => m({ conta_tipo: e.target.value as Pag['conta_tipo'] })} aria-label="Tipo da conta">
              <option value="corrente">Corrente</option><option value="poupanca">Poupança</option></select>
          </div>
        </Campo>
        <Campo r="CPF ou CNPJ do titular">
          <input className={`lt-in num ${err(![11, 14].includes(docSo(p.titular_documento).length))}`} value={p.titular_documento} onChange={e => m({ titular_documento: e.target.value })} />
        </Campo>
      </>}
      {p && pagaOutro(p, doc) && (
        <Campo r="Pagar a outra pessoa">
          <div className="lt-exc"><span className="nt at">{p.modo === 'ted' ? 'A conta não é do fornecedor.' : 'A chave não é o documento do fornecedor.'} Só entra com a justificativa, que quem aprova vê.</span>
            <input className={`lt-in ${err(!p.excecao.trim())}`} placeholder="Por que pagar a outra pessoa?" value={p.excecao} onChange={e => m({ excecao: e.target.value })} /></div>
        </Campo>
      )}
      {tentou && falta.length > 0 && <Campo r=""><span className="lt-erro"><Ic n="warn" s={18} />Falta {falta.join(', ')}.</span></Campo>}
    </div></section>
  );
}

/** "Pronto para gerar títulos": cada item que a nota do mês precisa para virar título sem pedir mais nada. */
export function Pronto({ itens }: { itens: [string, boolean, string?][] }) {
  const faltam = itens.filter(([, ok]) => !ok).length;
  return (
    <section className="lt-sec nc-pronto" aria-label="Pronto para gerar títulos">
      <h3>{faltam ? `Para gerar os títulos sem pedir mais nada, falta${faltam > 1 ? 'm' : ''} ${faltam}` : 'Pronto para gerar títulos'}</h3>
      <ul>
        {itens.map(([r, ok, obs]) => (
          <li key={r} className={ok ? 'ok' : 'falta'}><Ic n={ok ? 'check' : 'info'} s={18} /><span>{r}{obs && <span className="sec peq"> · {obs}</span>}</span></li>
        ))}
      </ul>
      {faltam > 0 && <p className="sec peq">Não é obrigatório: dá para enviar assim e completar depois.</p>}
    </section>
  );
}
