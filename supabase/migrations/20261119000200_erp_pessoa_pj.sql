-- O cadastro das pessoas PJ só o master e os designados veem (Moises, 19/11/2026, no cartão da
-- thread técnica: "Só master e designados").
--
-- Antes, erp.pessoas e erp.pessoa_papeis eram lidas por todo membro, e qualquer um descobria quem
-- recebe como PJ (nome, CPF, e-mail, telefone). Agora:
--   1. A pessoa tem a marca `restrita` (PJ). Quem vê o PJ cadastra a pessoa já marcada; a marca,
--      depois, só o master muda (pôr ou tirar).
--   2. Pessoa marcada: só o master e os designados (ve_pj) leem, gravam e veem os papéis dela.
--      O que lê pessoas pelo RLS (lista de credores, api.titulo_rastro, bi.d_pessoa) herda a regra.
--   3. Pessoa marcada só entra como credor, emitente ou contratado (título, nota, contrato,
--      previsão, pagamento) por quem vê o PJ; o sistema passa. A chave estrangeira não passa pelo
--      RLS, então sem esta trava quem soubesse o id usaria a pessoa.
-- Fica: o CPF/CNPJ continua único; quem cadastra o mesmo documento de uma pessoa PJ recebe o erro
-- de duplicidade (sabe que existe, não quem é).
-- Portabilidade: SQL puro.

alter table erp.pessoas add column restrita boolean not null default false;

-- quem está logado vê o PJ? (para as políticas; definer porque ve_pj lê designados e master)
create function erp.vejo_pj() returns boolean language sql stable
  security definer set search_path = erp, pg_catalog, pg_temp as $$
  select erp.ve_pj(erp.eu()) $$;

-- a marca muda só com o master (ou o sistema)
create function erp.tg_pessoa_restrita() returns trigger language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
begin
  if new.restrita is distinct from old.restrita and not (erp.sistema() or erp.sou_master()) then
    raise exception 'A marca de PJ da pessoa só o master muda';
  end if;
  return new;
end $$;
create trigger t_pessoa_restrita before update of restrita on erp.pessoas
  for each row execute function erp.tg_pessoa_restrita();

-- pessoa PJ só entra num registro por quem vê o PJ; TG_ARGV[0] é a coluna da pessoa
create function erp.tg_pessoa_pj_uso() returns trigger language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
declare v_pessoa uuid := (to_jsonb(new) ->> tg_argv[0])::uuid;
begin
  if v_pessoa is not null and not erp.sistema()
     and exists (select 1 from erp.pessoas p where p.id = v_pessoa and p.restrita)
     and not erp.ve_pj(erp.eu()) then
    raise exception 'Pessoa PJ só o master e os designados usam';
  end if;
  return new;
end $$;
create trigger t_pessoa_pj_uso before insert or update of pessoa_id on erp.titulos
  for each row execute function erp.tg_pessoa_pj_uso('pessoa_id');
create trigger t_pessoa_pj_uso before insert or update of emitente_id on erp.documentos_fiscais
  for each row execute function erp.tg_pessoa_pj_uso('emitente_id');
create trigger t_pessoa_pj_uso before insert or update of pessoa_id on erp.compromissos
  for each row execute function erp.tg_pessoa_pj_uso('pessoa_id');
create trigger t_pessoa_pj_uso before insert or update of pessoa_id on erp.previsoes
  for each row execute function erp.tg_pessoa_pj_uso('pessoa_id');
create trigger t_pessoa_pj_uso before insert or update of pessoa_id on erp.pagamentos
  for each row execute function erp.tg_pessoa_pj_uso('pessoa_id');

-- leitura e gravação
drop policy perfil_le on erp.pessoas;
drop policy perfil_inclui on erp.pessoas;
drop policy perfil_altera on erp.pessoas;
drop policy perfil_apaga on erp.pessoas;
create policy perfil_le on erp.pessoas for select to authenticated
  using (erp.membro() and (not restrita or erp.vejo_pj()));
create policy perfil_inclui on erp.pessoas for insert to authenticated
  with check (erp.escrevo() and (not restrita or erp.vejo_pj()));
create policy perfil_altera on erp.pessoas for update to authenticated
  using (erp.escrevo() and (not restrita or erp.vejo_pj())) with check (erp.escrevo() and (not restrita or erp.vejo_pj()));
create policy perfil_apaga on erp.pessoas for delete to authenticated
  using (erp.escrevo() and (not restrita or erp.vejo_pj()));

drop policy perfil_le on erp.pessoa_papeis;
drop policy perfil_inclui on erp.pessoa_papeis;
drop policy perfil_altera on erp.pessoa_papeis;
drop policy perfil_apaga on erp.pessoa_papeis;
-- o papel segue a pessoa: a subconsulta passa pelo RLS de pessoas de quem pergunta
create policy perfil_le on erp.pessoa_papeis for select to authenticated
  using (erp.membro() and exists (select 1 from erp.pessoas p where p.id = pessoa_id));
create policy perfil_inclui on erp.pessoa_papeis for insert to authenticated
  with check (erp.escrevo() and exists (select 1 from erp.pessoas p where p.id = pessoa_id));
create policy perfil_altera on erp.pessoa_papeis for update to authenticated
  using (erp.escrevo() and exists (select 1 from erp.pessoas p where p.id = pessoa_id))
  with check (erp.escrevo() and exists (select 1 from erp.pessoas p where p.id = pessoa_id));
create policy perfil_apaga on erp.pessoa_papeis for delete to authenticated
  using (erp.escrevo() and exists (select 1 from erp.pessoas p where p.id = pessoa_id));

-- permissões: vejo_pj é a única que a API executa (olha só quem está logado e devolve um booleano)
do $$
declare f regprocedure;
begin
  foreach f in array array['erp.vejo_pj()'::regprocedure, 'erp.tg_pessoa_restrita()'::regprocedure, 'erp.tg_pessoa_pj_uso()'::regprocedure] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('revoke execute on function %s from authenticated', f);
    execute format('grant execute on function %s to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config', f);
  end loop;
end $$;
grant execute on function erp.vejo_pj() to authenticated;
-- donos: erp_conferencia (lê tudo); o novo dono precisa de CREATE no esquema só durante a troca
create temp table _pessoa_pj_create as
  select r from unnest(array['erp_conferencia']) r where not has_schema_privilege(r, 'erp', 'create');
do $$ declare v text; begin
  for v in select r from _pessoa_pj_create loop execute format('grant create on schema erp to %I', v); end loop;
end $$;
alter function erp.vejo_pj() owner to erp_conferencia;
alter function erp.tg_pessoa_restrita() owner to erp_conferencia;
alter function erp.tg_pessoa_pj_uso() owner to erp_conferencia;
do $$ declare v text; begin
  for v in select r from _pessoa_pj_create loop execute format('revoke create on schema erp from %I', v); end loop;
end $$;
drop table _pessoa_pj_create;
