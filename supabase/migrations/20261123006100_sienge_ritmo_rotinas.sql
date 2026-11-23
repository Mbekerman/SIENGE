-- Ritmo das rotinas do Sienge (residual do S-143, aceito pelo Moises em 23/11/2026): as chaves que o pg_cron manda
-- às funções sienge-escrita e sienge-carga passam pela fila do pg_net, que no Supabase qualquer login direto lê.
-- Quem pegasse uma chave chamaria as funções à vontade e gastaria as cotas da API do Sienge (sem mexer em dinheiro:
-- as funções não recebem parâmetro de valor). Defesa: cada rotina só roda se a última rodada aceita foi há pelo menos
-- N segundos; acima disso a função responde 429 e não chama o Sienge. A agenda é de minuto em minuto (50 s de folga).

create table sienge.ritmo_rotinas (
  rotina text primary key,
  ultima timestamptz not null
);

-- true quando a rotina pode rodar agora (e marca a rodada); false quando a anterior foi há menos de p_segundos.
create function sienge.ritmo(p_rotina text, p_segundos int) returns boolean
language sql set search_path = sienge, pg_catalog, pg_temp as $$
  with marcada as (
    insert into sienge.ritmo_rotinas as r (rotina, ultima) values (p_rotina, clock_timestamp())
    on conflict (rotina) do update set ultima = excluded.ultima
     where r.ultima <= excluded.ultima - make_interval(secs => greatest(p_segundos, 0))
    returning 1)
  select exists (select 1 from marcada)
$$;

-- segurança, como o resto do esquema sienge (20261117000100)
grant select, insert, update, delete on sienge.ritmo_rotinas to sienge_carga;
grant execute on function sienge.ritmo(text, int) to sienge_carga;
revoke execute on function sienge.ritmo(text, int) from public;
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'authenticator'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on sienge.ritmo_rotinas from %I', r);
      execute format('revoke all on function sienge.ritmo(text, int) from %I', r);
    end if;
  end loop;
end $$;
alter table sienge.ritmo_rotinas enable row level security;
alter table sienge.ritmo_rotinas force row level security;
create policy carga on sienge.ritmo_rotinas to sienge_carga using (true) with check (true);
create trigger t_nao_trunca before truncate on sienge.ritmo_rotinas for each statement execute function sienge.tg_recusa_truncate();
