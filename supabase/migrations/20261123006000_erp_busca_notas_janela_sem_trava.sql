-- Janela do login da busca sem a trava do pg_net (Moises, 23/11/2026, "Aceitar e liberar"): o Supabase não fecha o
-- esquema net ao PUBLIC (S-143) e o postgres não consegue revogar, então a trava de 20261123005000 nunca deixaria a
-- busca rodar. O risco que sobra foi aceito; a janela de 10 minutos por hora e a derrubada das sessões aos 35 ficam.
-- Com o net aberto, abrir avisa (warning no log do cron) e liga mesmo assim.

create or replace function erp.busca_notas_janela(p_acao text) returns text
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
    execute 'alter role erp_busca_notas login';
    if v_net then
      raise warning 'S-143 (risco aceito): o login da busca alcança o net';
      return 'aberta (net aberto)';
    end if;
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
