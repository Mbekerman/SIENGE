-- Janela do login do serviço da busca das notas (Moises, 23/11/2026: "pode implantar as 3").
-- O login erp_busca_notas só fica ligado alguns minutos por hora, em volta da rodada do job (Cloud Scheduler aos 7 minutos):
-- uma rotina do banco abre aos 5, fecha aos 15 (quem já está conectado segue) e aos 35 derruba qualquer sessão que tenha
-- sobrado (o job tem 25 minutos de prazo). Com a senha vazada, ela só serve dentro da janela, e nenhuma sessão passa dela.
-- Abrir só liga com o net (pg_net) fechado ao login (S-143). A agenda (pg_cron) é do Supabase e fica fora da migration
-- (supabase/dev/busca_notas_janela_agenda.sql); na produção, o mesmo vale com outro agendador.
-- Quem chama: só o dono das migrations (o postgres no Supabase), que tem ADMIN no papel por tê-lo criado.

create function erp.busca_notas_janela(p_acao text) returns text
language plpgsql set search_path = erp, pg_catalog, pg_temp as $$
declare v_net boolean; v_n int := 0;
begin
  if p_acao not in ('abrir', 'fechar', 'encerrar') then raise exception 'Ação da janela: abrir, fechar ou encerrar'; end if;
  if not exists (select 1 from pg_roles where rolname = 'erp_busca_notas') then return 'sem o login'; end if;
  if p_acao = 'abrir' then
    select exists (select 1 from pg_namespace n where n.nspname = 'net'
                    and (has_schema_privilege('erp_busca_notas', n.oid, 'USAGE')
                         or exists (select 1 from pg_class c where c.relnamespace = n.oid
                                     and has_table_privilege('erp_busca_notas', c.oid, 'SELECT'))))
      into v_net;
    if v_net then
      execute 'alter role erp_busca_notas nologin';
      raise warning 'S-143: o login da busca alcança o net; a janela não abriu';
      return 'net aberto: janela fechada';
    end if;
    execute 'alter role erp_busca_notas login';
    return 'aberta';
  end if;
  execute 'alter role erp_busca_notas nologin';
  if p_acao = 'encerrar' then
    select count(*) filter (where pg_terminate_backend(a.pid)) into v_n
      from pg_stat_activity a where a.usename = 'erp_busca_notas';
    return format('fechada; %s sessão(ões) derrubada(s)', v_n);
  end if;
  return 'fechada';
end $$;
revoke all on function erp.busca_notas_janela(text) from public;
do $$ declare r text; begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'erp_busca_notas'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on function erp.busca_notas_janela(text) from %I', r);
    end if;
  end loop;
end $$;
