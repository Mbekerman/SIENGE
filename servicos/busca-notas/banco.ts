// O banco do ERP para o serviço da busca, pelo postgres.js, com o login erp_busca_notas (Moises, 23/11/2026: acesso só
// à caixa). Esse login não tem tabela nem papel: só chama as sete funções da caixa (migration 20261123003000).
// JSON vai por sql.json (JSON.stringify::jsonb no postgres.js vira jsonb string).
import postgres from 'postgres';
import type { Banco, Leitura, Origem } from './ciclo.ts';

export type BancoPg = Banco & { cnpj(empresa: string): Promise<string | null>; netAberto(): Promise<boolean>; fechar(): Promise<void> };

// S-143: o pg_net do Supabase não fecha pelo SQL Editor. O login só é ligado com ele fechado, e o serviço confere de novo
// a cada rodada (uma atualização do Supabase pode reabrir). A mesma consulta está nos testes do banco (erp.sql).
export const SQL_NET_ABERTO = `select exists (select 1 from pg_namespace n where n.nspname = 'net'
  and (has_schema_privilege(n.oid, 'USAGE')
       or exists (select 1 from pg_class c where c.relnamespace = n.oid and has_table_privilege(c.oid, 'SELECT')))) as v`;

// ca: o certificado raiz do Supabase (Database > SSL), para conferir o servidor e o nome dele (verify-full), não só cifrar.
export function bancoPg(url: string, ca: string): BancoPg {
  // Uma conexão só, aberta no começo e mantida a rodada inteira: o login só fica ligado dos minutos 5 a 15 de cada hora
  // (migration 20261123005000), então reconectar depois disso falharia.
  const sql = postgres(url, { max: 1, prepare: false, idle_timeout: 0, max_lifetime: null, connect_timeout: 30, onnotice: () => {},
                              ssl: { ca, rejectUnauthorized: true } });
  return {
    async netAberto() {
      const [r] = await sql.unsafe(SQL_NET_ABERTO);
      return Boolean(r?.v);
    },
    async cnpj(empresa) {
      const [r] = await sql`select erp.busca_notas_empresa(${empresa}::uuid) as v`;
      return (r?.v as string | null) ?? null;
    },
    async leitura(empresa, origem: Origem): Promise<Leitura> {
      const [r] = await sql`select ultimo_nsu, lida, bloqueado_ate from erp.busca_notas_leitura(${empresa}::uuid, ${origem})`;
      return { ultimoNsu: Number(r.ultimo_nsu), lida: Boolean(r.lida), bloqueadoAte: r.bloqueado_ate ? new Date(r.bloqueado_ate) : null };
    },
    async gravarNota(empresa, nota, xml, completo) {
      await sql`select erp.registrar_nota_recebida(${empresa}::uuid, ${sql.json(nota)}, ${xml}, ${completo})`;
    },
    async gravarEvento(empresa, e, xml) {
      await sql`select erp.registrar_evento_nota_recebida(${empresa}::uuid, ${e.chave}, ${e.codigo}, ${e.cancelamento}, ${e.nsu}::bigint, ${xml})`;
    },
    async gravarLeitura(empresa, origem, ultimo, maximo, bloqueadoAte, erro) {
      await sql`select erp.registrar_leitura_notas(${empresa}::uuid, ${origem}, ${ultimo}::bigint, ${maximo}::bigint,
                                                   ${bloqueadoAte}::timestamptz, ${erro})`;
    },
    async semCiencia(empresa, limite) {
      const rs = await sql`select c from erp.busca_notas_sem_ciencia(${empresa}::uuid, ${limite}::int) c`;
      return rs.map((r) => r.c as string);
    },
    async gravarCiencia(chave) {
      await sql`select erp.registrar_ciencia_nota_recebida(${chave})`;
    },
    async fechar() { await sql.end({ timeout: 5 }); },
  };
}
