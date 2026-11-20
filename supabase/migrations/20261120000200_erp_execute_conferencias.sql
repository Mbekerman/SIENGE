-- EXECUTE das conferências do erp_conferencia (achado na conferência do bkm_dev, 20/11/2026).
--
-- previsao_aprovada_vista e contrato_aprovado_visto (20261118000500), contrato_confere (20261119000250) e
-- compromisso_vinculos (20261120000100) trocam de dono para erp_conferencia e depois fazem o revoke de public e o
-- grant aos papéis. No Postgres dos testes quem roda é superusuário e isso vale; no Supabase o postgres não é
-- superusuário nem dono depois da troca: o revoke não tira o EXECUTE que o dono deu a PUBLIC ao criar a função, e o
-- grant não entra (só aviso). Resultado no bkm_dev: as quatro com EXECUTE para PUBLIC (anon incluso) e sem grant
-- explícito. O esquema erp não sai pela API, então nada disso era chamável de fora; mesmo assim, aqui o acerto é
-- feito como o dono.
-- Portabilidade: SQL puro.

grant erp_conferencia to current_user with inherit false, set true;
set role erp_conferencia;
do $$
declare f regprocedure;
begin
  foreach f in array array['erp.previsao_aprovada_vista(uuid)', 'erp.contrato_aprovado_visto(uuid)',
                           'erp.contrato_confere(uuid, uuid, uuid, boolean)', 'erp.compromisso_vinculos(uuid)']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('grant execute on function %s to authenticated, erp_sistema, erp_situacao, erp_reclassificacao, erp_acesso', f);
  end loop;
end $$;
reset role;
revoke erp_conferencia from current_user;
