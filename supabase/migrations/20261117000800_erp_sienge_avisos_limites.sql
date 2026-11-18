-- Limites do aviso do Sienge (S-136, revisão do PR #76; detalhe fora do repositório):
-- 1. no máximo um GET por título a cada 30 minutos: o outro aviso do mesmo título fecha sem chamar o Sienge
--    (a conferência e o cruzamento continuam);
-- 2. no máximo p_limite_hora avisos pegos por hora (padrão 10); acima disso o programa passa à conferência
--    e ao cruzamento, os avisos esperam e a lista AF é avisada uma vez por hora (sienge_avisos_excesso).
-- Portabilidade: SQL puro.

create table erp.sienge_avisos_excesso (
  hora      timestamptz primary key,
  pegos     int not null
);

insert into erp.tipos_evento (codigo, rotulo, modulo, critico) values
  ('sienge_avisos_excesso', 'Avisos do Sienge acima do limite por hora', 'pagar', true);
insert into erp.regras_notificacao (tipo, destino, lista) values ('sienge_avisos_excesso', 'lista', 'AF');

drop function erp.sienge_pegar_aviso(timestamptz);
create function erp.sienge_pegar_aviso(p_agora timestamptz default now(), p_limite_hora int default 10)
returns table (evento_id uuid, bill_id int, previsao_id uuid, tipo text) language plpgsql as $$
#variable_conflict use_column
declare a erp.sienge_avisos; v_prev uuid; v_tipo text; v_pegos int;
begin
  if not erp.sistema() then raise exception 'Só o sistema processa aviso do Sienge'; end if;
  if p_limite_hora is null or p_limite_hora < 1 then raise exception 'Limite de avisos por hora inválido'; end if;
  loop
    select * into a from erp.sienge_avisos x
     where x.processado_em is null and (x.pegado_em is null or x.pegado_em < p_agora - interval '5 minutes')
     order by x.recebido_em limit 1 for update skip locked;
    if a.evento_id is null then return; end if;
    if a.tentativas >= 5 then
      update erp.sienge_avisos set processado_em = p_agora, resultado = 'erro: 5 tentativas sem resposta do Sienge'
       where evento_id = a.evento_id;
      continue;
    end if;
    select d.previsao_id, d.tipo into v_prev, v_tipo from erp._sienge_prv_do_titulo(a.bill_id) d limit 1;
    if v_prev is null then
      update erp.sienge_avisos set processado_em = p_agora, resultado = 'a linha já não está pendente no ERP'
       where evento_id = a.evento_id;
      continue;
    end if;
    if exists (select 1 from erp.sienge_avisos y where y.bill_id = a.bill_id and y.evento_id <> a.evento_id
                  and y.pegado_em > p_agora - interval '30 minutes') then
      update erp.sienge_avisos set processado_em = p_agora,
             resultado = 'título conferido há menos de 30 minutos por outro aviso: sem chamada'
       where evento_id = a.evento_id;
      continue;
    end if;
    select count(*) into v_pegos from erp.sienge_avisos y where y.pegado_em > p_agora - interval '1 hour';
    if v_pegos >= p_limite_hora then
      insert into erp.sienge_avisos_excesso (hora, pegos) values (date_trunc('hour', p_agora), v_pegos)
      on conflict (hora) do nothing;
      if found then
        perform erp.registrar_evento('sienge_avisos_excesso', 'sienge_avisos', date_trunc('hour', p_agora)::text, null, null,
          jsonb_build_object('pegos_na_ultima_hora', v_pegos, 'limite', p_limite_hora,
                             'pendentes', (select count(*) from erp.sienge_avisos y where y.processado_em is null)));
      end if;
      return;
    end if;
    update erp.sienge_avisos set pegado_em = p_agora, tentativas = tentativas + 1 where evento_id = a.evento_id;
    return query select a.evento_id, a.bill_id, v_prev, v_tipo;
    return;
  end loop;
end $$;

-- Segurança
revoke all on erp.sienge_avisos_excesso from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on erp.sienge_avisos_excesso from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then execute 'revoke all on erp.sienge_avisos_excesso from service_role'; end if;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke execute on function erp.sienge_pegar_aviso(timestamptz, int) from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then execute 'revoke execute on function erp.sienge_pegar_aviso(timestamptz, int) from service_role'; end if;
end $$;
revoke all on erp.sienge_avisos_excesso from authenticated;
alter table erp.sienge_avisos_excesso enable row level security;
alter table erp.sienge_avisos_excesso force row level security;
create policy sistema on erp.sienge_avisos_excesso using (erp.sistema()) with check (erp.sistema());
create policy conferencia on erp.sienge_avisos_excesso for select to erp_conferencia using (true);
create trigger t_nao_trunca before truncate on erp.sienge_avisos_excesso for each statement execute function erp.tg_recusa_truncate();
grant select, insert on erp.sienge_avisos_excesso to erp_sistema;
grant select on erp.sienge_avisos_excesso to erp_conferencia;
create policy perfil_le on erp.sienge_avisos_excesso for select to authenticated using (erp.sou_master() or erp.estou_nas_listas(array['AF']));
grant select on erp.sienge_avisos_excesso to authenticated;
revoke execute on function erp.sienge_pegar_aviso(timestamptz, int) from public, authenticated;
grant execute on function erp.sienge_pegar_aviso(timestamptz, int)
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
