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
--   4. Pessoa marcada só aparece em lançamento de PJ: previsão de natureza restrita, e título, nota
--      ou contrato sem linha de natureza comum (o rateio do PJ já não mistura, migration
--      _erp_pj_sozinho). Assim o nome dela nunca sai num título comum (acumulado, lista de títulos).
--      O sistema (importação do Sienge) passa.
--   5. Empresa do grupo, sócio e órgão da retenção também só com pessoa PJ por quem vê o PJ.
--   6. A auditoria (lida pelo administrador, o TI) guarda a linha inteira: a linha que fala de
--      pessoa PJ, de título, nota, contrato ou previsão de PJ, ou de natureza restrita, só o master e
--      os designados leem. Quando o master tira a marca da pessoa, as linhas antigas voltam a
--      aparecer para o administrador.
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

-- pessoa PJ só entra num registro por quem vê o PJ, e só em lançamento de PJ; TG_ARGV[0] é a coluna
-- da pessoa
create function erp.tg_pessoa_pj_uso() returns trigger language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
declare v_pessoa uuid := (to_jsonb(new) ->> tg_argv[0])::uuid; v_comum boolean := false;
begin
  if v_pessoa is null or erp.sistema()
     or not exists (select 1 from erp.pessoas p where p.id = v_pessoa and p.restrita) then
    return new;
  end if;
  if not erp.ve_pj(erp.eu()) then raise exception 'Pessoa PJ só o master e os designados usam'; end if;
  -- a mesma trava do rateio (_erp_pj_sozinho): quem grava uma linha em paralelo espera
  if tg_table_name in ('titulos', 'documentos_fiscais', 'compromissos') then
    perform pg_advisory_xact_lock(hashtext('erp.rateio_pj:' || case tg_table_name when 'titulos' then 'titulo_rateios'
      when 'documentos_fiscais' then 'documento_rateios' else 'compromisso_rateios' end || ':' || new.id::text));
  end if;
  case tg_table_name
    when 'previsoes' then v_comum := not erp.natureza_restrita((to_jsonb(new) ->> 'natureza_id')::uuid);
    when 'titulos' then v_comum := exists (select 1 from erp.titulo_rateios r where r.titulo_id = new.id and not erp.natureza_restrita(r.natureza_id));
    when 'documentos_fiscais' then v_comum := exists (select 1 from erp.documento_rateios r where r.documento_id = new.id and not erp.natureza_restrita(r.natureza_id));
    when 'compromissos' then v_comum := exists (select 1 from erp.compromisso_rateios r where r.compromisso_id = new.id and not erp.natureza_restrita(r.natureza_id));
    else v_comum := false;
  end case;
  if v_comum then raise exception 'Pessoa PJ só em lançamento de PJ: a natureza tem de ser restrita'; end if;
  return new;
end $$;
create trigger t_pessoa_pj_uso before insert or update of pessoa_id on erp.titulos
  for each row execute function erp.tg_pessoa_pj_uso('pessoa_id');
create trigger t_pessoa_pj_uso before insert or update of emitente_id on erp.documentos_fiscais
  for each row execute function erp.tg_pessoa_pj_uso('emitente_id');
create trigger t_pessoa_pj_uso before insert or update of pessoa_id on erp.compromissos
  for each row execute function erp.tg_pessoa_pj_uso('pessoa_id');
create trigger t_pessoa_pj_uso before insert or update of pessoa_id, natureza_id on erp.previsoes
  for each row execute function erp.tg_pessoa_pj_uso('pessoa_id');
create trigger t_pessoa_pj_uso before insert or update of pessoa_id on erp.pagamentos
  for each row execute function erp.tg_pessoa_pj_uso('pessoa_id');
create trigger t_pessoa_pj_uso before insert or update of pessoa_id on erp.empresas
  for each row execute function erp.tg_pessoa_pj_uso('pessoa_id');
create trigger t_pessoa_pj_uso before insert or update of socio_id on erp.participacoes
  for each row execute function erp.tg_pessoa_pj_uso('socio_id');
create trigger t_pessoa_pj_uso before insert or update of orgao_id on erp.documento_retencoes
  for each row execute function erp.tg_pessoa_pj_uso('orgao_id');

-- a linha de natureza comum não entra em título, nota ou contrato de pessoa PJ
create function erp.tg_rateio_pessoa_pj() returns trigger language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
declare v_pai uuid; v_pessoa uuid;
begin
  if erp.sistema() or erp.natureza_restrita(new.natureza_id) then return null; end if;
  v_pai := (to_jsonb(new) ->> case tg_table_name when 'titulo_rateios' then 'titulo_id'
                                                 when 'documento_rateios' then 'documento_id'
                                                 else 'compromisso_id' end)::uuid;
  perform pg_advisory_xact_lock(hashtext('erp.rateio_pj:' || tg_table_name || ':' || v_pai::text));
  v_pessoa := case tg_table_name
    when 'titulo_rateios' then (select pessoa_id from erp.titulos where id = v_pai)
    when 'documento_rateios' then (select emitente_id from erp.documentos_fiscais where id = v_pai)
    else (select pessoa_id from erp.compromissos where id = v_pai) end;
  if exists (select 1 from erp.pessoas p where p.id = v_pessoa and p.restrita) then
    raise exception 'Pessoa PJ só em lançamento de PJ: a natureza tem de ser restrita';
  end if;
  return null;
end $$;
create trigger t_rateio_pessoa_pj after insert or update of natureza_id, titulo_id on erp.titulo_rateios
  for each row execute function erp.tg_rateio_pessoa_pj();
create trigger t_rateio_pessoa_pj after insert or update of natureza_id, documento_id on erp.documento_rateios
  for each row execute function erp.tg_rateio_pessoa_pj();
create trigger t_rateio_pessoa_pj after insert or update of natureza_id, compromisso_id on erp.compromisso_rateios
  for each row execute function erp.tg_rateio_pessoa_pj();

-- quem está logado lê esta linha da auditoria? O administrador lê; a linha de PJ (pessoa PJ, título,
-- nota, contrato ou previsão de PJ, natureza restrita), só se ele também vê o PJ. Quem não é
-- administrador recebe sempre falso, então a função não serve para perguntar se um id é de PJ.
create function erp.vejo_auditoria(p_tabela text, p_registro text, p_antes jsonb, p_depois jsonb) returns boolean
  language plpgsql stable security definer set search_path = erp, pg_catalog, pg_temp as $$
declare d jsonb; v text;
begin
  if not erp.sou_admin() then return false; end if;
  if erp.ve_pj(erp.eu()) then return true; end if;
  foreach d in array array[p_antes, p_depois] loop
    continue when d is null;
    if p_tabela = 'pessoas' and coalesce((d ->> 'restrita')::boolean, false) then return false; end if;
    foreach v in array array[d ->> 'pessoa_id', d ->> 'emitente_id', d ->> 'socio_id', d ->> 'orgao_id',
                             case when p_tabela = 'pessoas' then d ->> 'id' end, case when p_tabela = 'pessoa_papeis' then p_registro end] loop
      continue when v is null or v !~* '^[0-9a-f-]{36}$';
      if exists (select 1 from erp.pessoas p where p.id = v::uuid and p.restrita) then return false; end if;
    end loop;
    v := coalesce(d ->> 'titulo_id', case when p_tabela = 'titulos' then d ->> 'id' end);
    if v ~* '^[0-9a-f-]{36}$' and erp.titulo_pj(v::uuid) then return false; end if;
    v := coalesce(d ->> 'previsao_id', case when p_tabela = 'previsoes' then d ->> 'id' end);
    if v ~* '^[0-9a-f-]{36}$' and erp.previsao_pj(v::uuid) then return false; end if;
    v := coalesce(d ->> 'documento_id', case when p_tabela = 'documentos_fiscais' then d ->> 'id' end);
    if v ~* '^[0-9a-f-]{36}$' and exists (select 1 from erp.documento_rateios r where r.documento_id = v::uuid and erp.natureza_restrita(r.natureza_id)) then return false; end if;
    v := coalesce(d ->> 'compromisso_id', case when p_tabela = 'compromissos' then d ->> 'id' end);
    if v ~* '^[0-9a-f-]{36}$' and exists (select 1 from erp.compromisso_rateios r where r.compromisso_id = v::uuid and erp.natureza_restrita(r.natureza_id)) then return false; end if;
    v := d ->> 'natureza_id';
    if v ~* '^[0-9a-f-]{36}$' and erp.natureza_restrita(v::uuid) then return false; end if;
  end loop;
  return true;
end $$;
drop policy perfil_le on erp.auditoria;
create policy perfil_le on erp.auditoria for select to authenticated
  using (erp.vejo_auditoria(tabela, registro, antes, depois));

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

-- permissões: a API executa só vejo_pj e vejo_auditoria (as políticas as chamam como quem lê; olham
-- só quem está logado e devolvem um booleano)
do $$
declare f regprocedure;
begin
  foreach f in array array['erp.vejo_pj()'::regprocedure, 'erp.tg_pessoa_restrita()'::regprocedure, 'erp.tg_pessoa_pj_uso()'::regprocedure,
                         'erp.tg_rateio_pessoa_pj()'::regprocedure, 'erp.vejo_auditoria(text, text, jsonb, jsonb)'::regprocedure] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('revoke execute on function %s from authenticated', f);
    execute format('grant execute on function %s to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config', f);
  end loop;
end $$;
grant execute on function erp.vejo_pj() to authenticated;
grant execute on function erp.vejo_auditoria(text, text, jsonb, jsonb) to authenticated;
-- donos: erp_conferencia (lê tudo); o novo dono precisa de CREATE no esquema só durante a troca
create temp table _pessoa_pj_create as
  select r from unnest(array['erp_conferencia']) r where not has_schema_privilege(r, 'erp', 'create');
do $$ declare v text; begin
  for v in select r from _pessoa_pj_create loop execute format('grant create on schema erp to %I', v); end loop;
end $$;
alter function erp.vejo_pj() owner to erp_conferencia;
alter function erp.tg_pessoa_restrita() owner to erp_conferencia;
alter function erp.tg_pessoa_pj_uso() owner to erp_conferencia;
alter function erp.tg_rateio_pessoa_pj() owner to erp_conferencia;
alter function erp.vejo_auditoria(text, text, jsonb, jsonb) owner to erp_conferencia;
do $$ declare v text; begin
  for v in select r from _pessoa_pj_create loop execute format('revoke create on schema erp from %I', v); end loop;
end $$;
drop table _pessoa_pj_create;
