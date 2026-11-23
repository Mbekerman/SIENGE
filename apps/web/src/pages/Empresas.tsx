// Cadastros › Empresas: as empresas do grupo com o apelido, o nome pelo qual o sistema as chama (Moises, 23/11/2026).
// O apelido se edita no lugar, sem Editar nem Salvar (BKM Terrenos, ficha/edicao.tsx): grava ao sair do campo ou no
// Enter, Esc volta o que estava. A regra (quem muda, tamanho, repetido) está no banco, migration _erp_empresa_apelido.
import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { COR, Cab, Carregando, Chip, Colunas, Gaveta, Grupo, Kv, Vazio, type Linha } from '../components/Comum';
import { documento } from '../lib/format';
import { acha, usePagina } from '../lib/navegar';
import { mensagemErro, rpc } from '../lib/supabase';
import type { Empresa } from '../lib/tipos';

const TIPO: Record<Empresa['tipo'], string> = { holding: 'Holding', incorporadora: 'Incorporadora', construtora: 'Construtora', spe: 'SPE', outra: 'Outra' };
const COLS = [34, 40, 14, 12];
const ROT = [{ t: 'Apelido' }, { t: 'Razão social', x: true }, { t: 'CNPJ' }, { t: 'Tipo' }];
const nome = (e: Empresa) => e.apelido ?? e.razao_social;

export function Empresas() {
  const pg = usePagina('/empresas');
  const q = useQuery({ queryKey: ['empresas'], queryFn: () => rpc<Empresa[]>('empresas') });
  const todas = (q.data ?? []).filter(e => acha(pg.busca, e.apelido, e.razao_social, e.documento));
  const linha = (e: Empresa): Linha => ({
    id: e.id,
    titulo: e.apelido ?? <span className="sec" title="Sem apelido: vale a razão social">{e.razao_social}</span>,
    cels: [{ c: e.razao_social, x: true }, { c: documento(e.documento) }, { c: TIPO[e.tipo] }],
    valor: TIPO[e.tipo],
    sub: <span>{e.razao_social}</span>,
  });
  const sel = pg.id ? (q.data ?? []).find(e => e.id === pg.id) : undefined;
  return (
    <>
      <div className="f-pag">
        <Cab t="Empresas" abas={false}>{pg.busca && <button className="btn t" onClick={pg.limpar}>Limpar busca</button>}</Cab>
        {q.isLoading ? <Carregando /> : q.error ? <Vazio t={mensagemErro(q.error)} />
          : !todas.length ? <Vazio t={pg.busca ? 'Nada encontrado.' : 'Nenhuma empresa cadastrada.'} limpar={pg.busca ? pg.limpar : undefined} />
          : <>
              <Colunas cols={COLS} rot={ROT} />
              <Grupo nome="Ativas" cor={COR.azul} linhas={todas.filter(e => e.ativa).map(linha)} sel={pg.id} abrir={pg.abrir} cols={COLS} />
              <Grupo nome="Inativas" cor={COR.cinza} linhas={todas.filter(e => !e.ativa).map(linha)} sel={pg.id} abrir={pg.abrir} cols={COLS} fechado />
            </>}
      </div>
      {pg.id && (
        sel ? (
          <Gaveta titulo={nome(sel)} sub={sel.ativa ? <Chip t="Ativa" c="ok" /> : <Chip t="Inativa" c="ci" />} fechar={pg.fechar}>
            <Apelido e={sel} />
            <Kv l={[
              ['Razão social', sel.razao_social],
              ['CNPJ', documento(sel.documento)],
              ['Tipo', TIPO[sel.tipo]],
            ]} />
            <p className="sec peq">A razão social continua nos documentos, no envio ao Sienge e na conferência de quem recebe.</p>
          </Gaveta>
        ) : (
          <Gaveta titulo="Empresa" fechar={pg.fechar}>{q.isLoading ? <Carregando /> : <Vazio t="Não encontrada ou sem acesso." />}</Gaveta>
        )
      )}
    </>
  );
}

/** Campo do apelido, editado no lugar; quem não pode mudar só lê. */
function Apelido({ e }: { e: Empresa }) {
  const qc = useQueryClient();
  const [v, setV] = useState(e.apelido ?? '');
  useEffect(() => setV(e.apelido ?? ''), [e.id, e.apelido]);
  const salvar = useMutation({
    mutationFn: (a: string) => rpc<string | null>('salvar_apelido_empresa', { p_empresa: e.id, p_apelido: a }),
    onSuccess: a => { setV(a ?? ''); for (const k of ['empresas', 'titulos', 'previsoes', 'contratos', 'aprovacoes', 'lancamento_opcoes']) qc.invalidateQueries({ queryKey: [k] }); },
  });
  if (!e.posso_apelido) return <Kv l={[['Apelido', e.apelido ?? <span className="sec">Sem apelido</span>]]} />;
  const gravar = () => { if (v.trim() !== (e.apelido ?? '')) salvar.mutate(v); };
  return (
    <label className="em-ap">
      <span className="em-rot">Apelido</span>
      <input className={`lt-in ${salvar.error ? 'err' : ''}`} value={v} maxLength={40} placeholder={e.razao_social}
        onChange={x => { setV(x.target.value); salvar.reset(); }} onBlur={gravar}
        onKeyDown={x => { if (x.key === 'Enter') { x.preventDefault(); gravar(); } if (x.key === 'Escape') { x.stopPropagation(); setV(e.apelido ?? ''); salvar.reset(); } }} />
      <span className={salvar.error ? 'lt-erro' : 'sec peq'}>
        {salvar.error ? mensagemErro(salvar.error) : salvar.isPending ? 'Gravando…' : 'Nome pelo qual o sistema chama a empresa. Vazio, vale a razão social.'}
      </span>
    </label>
  );
}
