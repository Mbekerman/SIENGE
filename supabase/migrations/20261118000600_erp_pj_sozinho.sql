-- O pagamento de PJ sobe sozinho (Moises, 18/11/2026: "salário só pode subir sozinho").
--
-- O rateio de um título, de uma nota ou de um contrato não mistura natureza restrita (PJ) com
-- natureza comum. Sem isso, um designado para o PJ lançaria uma despesa comum grande com uma linha
-- PJ pequena, e o título inteiro iria só à vaga PJ, sem gestor, AF ou AO (revisão de segurança do
-- PR #84). A conferência é feita a cada linha gravada; a natureza que vira restrita depois não
-- revalida os rateios já gravados (a marca restrita só muda com o master).
-- Vale também para a linha que muda de título, nota ou contrato (update do pai). Duas gravações em
-- paralelo no mesmo pai esperam uma pela outra (trava consultiva pelo id do pai), senão cada uma só
-- veria a própria linha. A trava conta com READ COMMITTED (o padrão do Supabase): o SELECT depois
-- dela pega um retrato novo; em REPEATABLE READ ou SERIALIZABLE ela não protege.
-- A conferência é definer do erp_conferencia: lê todas as linhas do rateio, também as que o RLS
-- esconde de quem grava. Hoje quem grava no rateio vê o título inteiro (a RLS do título esconde o
-- que tem linha que ele não vê), então o definer é defesa em profundidade.
-- Portabilidade: SQL puro.

create function erp.tg_rateio_sem_mistura_pj() returns trigger language plpgsql as $$
declare v_misto boolean; v_pai uuid;
begin
  v_pai := (to_jsonb(new) ->> case tg_table_name when 'titulo_rateios' then 'titulo_id'
                                                 when 'documento_rateios' then 'documento_id'
                                                 else 'compromisso_id' end)::uuid;
  perform pg_advisory_xact_lock(hashtext('erp.rateio_pj:' || tg_table_name || ':' || v_pai::text));
  if tg_table_name = 'titulo_rateios' then
    select bool_or(erp.natureza_restrita(natureza_id)) and not bool_and(erp.natureza_restrita(natureza_id)) into v_misto
      from erp.titulo_rateios where titulo_id = new.titulo_id;
  elsif tg_table_name = 'documento_rateios' then
    select bool_or(erp.natureza_restrita(natureza_id)) and not bool_and(erp.natureza_restrita(natureza_id)) into v_misto
      from erp.documento_rateios where documento_id = new.documento_id;
  else
    select bool_or(erp.natureza_restrita(natureza_id)) and not bool_and(erp.natureza_restrita(natureza_id)) into v_misto
      from erp.compromisso_rateios where compromisso_id = new.compromisso_id;
  end if;
  if coalesce(v_misto, false) then
    raise exception 'O pagamento de PJ sobe sozinho: o rateio não mistura natureza PJ com outra natureza';
  end if;
  return null;
end $$;

create trigger t_rateio_sem_mistura_pj after insert or update of natureza_id, titulo_id on erp.titulo_rateios
  for each row execute function erp.tg_rateio_sem_mistura_pj();
create trigger t_rateio_sem_mistura_pj after insert or update of natureza_id, documento_id on erp.documento_rateios
  for each row execute function erp.tg_rateio_sem_mistura_pj();
create trigger t_rateio_sem_mistura_pj after insert or update of natureza_id, compromisso_id on erp.compromisso_rateios
  for each row execute function erp.tg_rateio_sem_mistura_pj();

alter function erp.tg_rateio_sem_mistura_pj() security definer set search_path = erp, pg_catalog, pg_temp;
-- o novo dono precisa de CREATE no esquema para receber a função (dado só aqui e tirado logo depois)
create temp table _pj_sozinho_create as
  select r from unnest(array['erp_conferencia']) r where not has_schema_privilege(r, 'erp', 'create');
do $$ declare v text; begin
  for v in select r from _pj_sozinho_create loop execute format('grant create on schema erp to %I', v); end loop;
end $$;
alter function erp.tg_rateio_sem_mistura_pj() owner to erp_conferencia;
do $$ declare v text; begin
  for v in select r from _pj_sozinho_create loop execute format('revoke create on schema erp from %I', v); end loop;
end $$;
drop table _pj_sozinho_create;

revoke execute on function erp.tg_rateio_sem_mistura_pj() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke execute on function erp.tg_rateio_sem_mistura_pj() from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then revoke execute on function erp.tg_rateio_sem_mistura_pj() from service_role; end if;
  revoke execute on function erp.tg_rateio_sem_mistura_pj() from authenticated;
end $$;
