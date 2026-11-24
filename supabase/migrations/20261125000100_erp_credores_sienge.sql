-- Credores do Sienge no ERP (Moises, 24/nov/2026; decisão de 08/11: importar todos os credores, nenhuma conta nem PIX
-- entra aprovado). Até aqui o cadastro de pessoas do ERP não tinha os credores do Sienge, e o leitor não achava o
-- fornecedor da nota pelo CNPJ.
--
-- erp.sienge_importar_credores(lista): recebe uma página do GET /creditors do Sienge (a Edge Function sienge-credores
-- chama, como erp_sistema) e, para cada credor:
--   - já ligado (erp.codigos_externos 'sienge'/'pessoas' com o id do Sienge): não mexe; só conta e, se o documento ou o
--     nome mudaram no Sienge, devolve o aviso (quem muda pessoa já usada é o financeiro, pela tela);
--   - não ligado, com CPF/CNPJ que já é de uma pessoa do ERP sem ligação com o Sienge: liga;
--   - CPF/CNPJ de pessoa já ligada a OUTRO credor do Sienge (credor repetido lá): não liga e devolve o aviso;
--   - sem pessoa com o documento: cria a pessoa (nome, nome fantasia, documento, ativa) com o papel de fornecedor e liga;
--     a pessoa nasce restrita (só o master e os designados a veem) sempre que o documento não está classificado como
--     comum. A proteção do PJ falha fechada (decisão do Moises no cartão de 24/11/2026, "Escondidos até classificar"):
--     o Sienge não diz quem é PJ e credor conhecido não prova que não é. A que nasce restrita só por falta de classe
--     leva a marca pessoas.sem_classe; classificada como comum (pelo master ou pela triagem, erp.classificar_emitente,
--     ou pelo master em lote, erp.classificar_comuns), ela se solta; classificada como PJ, fica restrita e perde a marca.
-- Nunca grava PIX, conta bancária, e-mail ou telefone, nem tira ou muda nada que já existe. Só o sistema chama.
-- ---------------------------------------------------------------------------------------------
-- A marca da pessoa restrita só por falta de classe (vem antes da importação, que a usa)
-- ---------------------------------------------------------------------------------------------
-- Ferramenta da migration: troca trechos no corpo de uma função e a recria como o dono dela (o mesmo da 20261124001100)
create function pg_temp.trocar(p_fn regprocedure, variadic p_pares text[]) returns void language plpgsql as $$
declare v text := pg_get_functiondef(p_fn); i int; v_n int; v_dono text; v_esq text; v_dar boolean;
begin
  for i in 1 .. coalesce(array_length(p_pares, 1), 0) by 2 loop
    v_n := (length(v) - length(replace(v, p_pares[i], ''))) / length(p_pares[i]);
    if v_n <> 1 then raise exception '%: trecho achado % vezes (esperado 1): %', p_fn, v_n, left(p_pares[i], 120); end if;
    v := replace(v, p_pares[i], p_pares[i + 1]);
  end loop;
  select pg_get_userbyid(p.proowner), n.nspname into v_dono, v_esq
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.oid = p_fn;
  if v_dono = current_user then execute v; return; end if;
  v_dar := not has_schema_privilege(v_dono, v_esq, 'create');
  if v_dar then execute format('grant create on schema %I to %I', v_esq, v_dono); end if;
  execute format('set local role %I', v_dono);
  execute v;
  reset role;
  if v_dar then execute format('revoke create on schema %I from %I', v_esq, v_dono); end if;
end $$;

-- sem_classe: restrita porque ninguém classificou o documento ainda (não é o PJ de verdade). Só nasce com o sistema;
-- depois só sai (true → false), e só quando o documento ganhou classe.
alter table erp.pessoas add column sem_classe boolean not null default false;
alter table erp.pessoas add constraint pessoas_sem_classe_restrita check (not sem_classe or restrita);

-- a marca de PJ: além do master e do sistema, a classificação do documento solta (comum) ou firma (pj) a sem_classe
select pg_temp.trocar('erp.tg_pessoa_restrita()',
  $t$  if new.restrita is distinct from old.restrita and not (erp.sistema() or erp.sou_master()) then$t$,
  $t$  if tg_op = 'INSERT' then
    if new.sem_classe and not erp.sistema() then raise exception 'A marca de sem classificação só o sistema põe'; end if;
    return new;
  end if;
  if new.sem_classe and not old.sem_classe then raise exception 'A marca de sem classificação só o sistema põe'; end if;
  if old.sem_classe and not new.sem_classe and not (erp.sistema() or erp.sou_master()) then
    -- a classificação gravada decide: comum solta, pj fica restrita
    if new.restrita is distinct from (erp._classe_emitente(new.documento) is distinct from 'comum')
       or (select classe from erp.emitentes_classificacao where documento = new.documento) is null then
      raise exception 'A marca de PJ da pessoa só o master muda';
    end if;
    return new;
  end if;
  if new.restrita is distinct from old.restrita and not (erp.sistema() or erp.sou_master()) then$t$);
-- o gatilho passa a olhar também a inclusão e a marca nova; criado pelo dono da função (como na 20261124001100)
drop trigger t_pessoa_restrita on erp.pessoas;
grant trigger on erp.pessoas to erp_conferencia;
set local role erp_conferencia;
create trigger t_pessoa_restrita before insert or update of restrita, sem_classe on erp.pessoas
  for each row execute function erp.tg_pessoa_restrita();
reset role;
revoke trigger on erp.pessoas from erp_conferencia;

-- a classe do emitente: a pessoa restrita só por falta de classe não conta como PJ (a NFS-e dela vai à triagem)
select pg_temp.trocar('erp._classe_emitente(text)',
  $t$where p.documento = p_documento and p.restrita)$t$, $t$where p.documento = p_documento and p.restrita and not p.sem_classe)$t$);
select pg_temp.trocar('erp.classificar_emitente(text,text)',
  $t$v_restrita := exists (select 1 from erp.pessoas p where p.documento = v_doc and p.restrita);$t$,
  $t$v_restrita := exists (select 1 from erp.pessoas p where p.documento = v_doc and p.restrita and not p.sem_classe);$t$);
-- gravada a classe, a pessoa sem classe se solta (comum) ou vira PJ de verdade (pj)
select pg_temp.trocar('erp._gravar_classe_emitente(text,text)',
  $t$on conflict (documento) do update set classe = excluded.classe, por = excluded.por, em = clock_timestamp();$t$,
  $t$on conflict (documento) do update set classe = excluded.classe, por = excluded.por, em = clock_timestamp();
  update erp.pessoas set restrita = (p_classe = 'pj'), sem_classe = false where documento = p_documento and sem_classe;$t$);

create function erp.sienge_importar_credores(p_lista jsonb) returns jsonb language plpgsql
set search_path = erp, pg_catalog, pg_temp as $$
declare
  c jsonb; v_id text; v_doc text; v_tipo text; v_nome text; v_pessoa uuid; v_ligado uuid; v_atual record; v_classe text;
  n_novos int := 0; n_ligados int := 0; n_ja int := 0; v_avisos jsonb := '[]';
begin
  if not erp.sistema() then raise exception 'Só o sistema importa credores do Sienge'; end if;
  if jsonb_typeof(p_lista) <> 'array' then raise exception 'Lista de credores inválida'; end if;
  for c in select * from jsonb_array_elements(p_lista) loop
    v_id := case when jsonb_typeof(c->'id') = 'number' and (c->>'id') ~ '^[0-9]{1,9}$' then c->>'id' end;
    v_nome := nullif(btrim(regexp_replace(coalesce(c->>'name', ''), '\s+', ' ', 'g')), '');
    if v_id is null or v_nome is null then
      v_avisos := v_avisos || jsonb_build_object('id', c->'id', 'motivo', 'sem código ou sem nome');
      continue;
    end if;
    -- CNPJ (14, com ou sem letras) ou CPF (11); o que não é nenhum dos dois entra sem documento
    v_doc := nullif(upper(regexp_replace(coalesce(nullif(c->>'cnpj', ''), c->>'cpf', ''), '[^0-9A-Za-z]', '', 'g')), '');
    v_tipo := case when v_doc ~ '^[0-9]{11}$' then 'fisica' when erp.cnpj_aceito(coalesce(v_doc, '')) then 'juridica' end;
    if v_tipo is null then
      if v_doc is not null then v_avisos := v_avisos || jsonb_build_object('id', v_id::int, 'motivo', 'documento inválido: entrou sem documento'); end if;
      v_doc := null;
      v_tipo := case when nullif(c->>'cpf', '') is not null then 'fisica' else 'juridica' end;
    end if;

    select registro_id into v_ligado from erp.codigos_externos where sistema = 'sienge' and tabela = 'pessoas' and codigo = v_id;
    if v_ligado is not null then
      n_ja := n_ja + 1;
      select documento, nome into v_atual from erp.pessoas where id = v_ligado;
      if v_atual.documento is distinct from v_doc then
        v_avisos := v_avisos || jsonb_build_object('id', v_id::int, 'motivo', 'o documento no Sienge mudou; o ERP ficou como estava');
      end if;
      continue;
    end if;

    v_pessoa := null;
    if v_doc is not null then
      select id into v_pessoa from erp.pessoas where documento = v_doc;
      if v_pessoa is not null and exists (select 1 from erp.codigos_externos where sistema = 'sienge' and tabela = 'pessoas' and registro_id = v_pessoa) then
        v_avisos := v_avisos || jsonb_build_object('id', v_id::int, 'motivo', 'o mesmo documento é de outro credor do Sienge');
        continue;
      end if;
    end if;
    if v_pessoa is null then
      -- só o classificado como comum entra visível; o resto, restrito (o sem classe com a marca sem_classe)
      v_classe := case when v_doc is not null then erp._classe_emitente(v_doc) end;
      insert into erp.pessoas (tipo, nome, nome_fantasia, documento, ativa, restrita, sem_classe)
      values (v_tipo, v_nome, nullif(btrim(c->>'tradeName'), ''), v_doc, coalesce((c->>'active')::boolean, true),
              v_classe is distinct from 'comum', v_classe is null)
      returning id into v_pessoa;
      insert into erp.pessoa_papeis (pessoa_id, papel) values (v_pessoa, 'fornecedor');
      n_novos := n_novos + 1;
    else
      n_ligados := n_ligados + 1;
    end if;
    insert into erp.codigos_externos (sistema, tabela, registro_id, codigo) values ('sienge', 'pessoas', v_pessoa, v_id);
  end loop;
  return jsonb_build_object('novos', n_novos, 'ligados', n_ligados, 'ja_ligados', n_ja, 'avisos', v_avisos);
end $$;

revoke execute on function erp.sienge_importar_credores(jsonb) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke execute on function erp.sienge_importar_credores(jsonb) from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then revoke execute on function erp.sienge_importar_credores(jsonb) from authenticated; end if;
end $$;
grant execute on function erp.sienge_importar_credores(jsonb) to erp_sistema;

-- ---------------------------------------------------------------------------------------------
-- Lote do master: classifica como comum os documentos dados que são de pessoa escondida só por falta de classe
-- ---------------------------------------------------------------------------------------------
create function erp.classificar_comuns(p_documentos text[]) returns int language plpgsql
set search_path = erp, pg_catalog, pg_temp as $$
declare d text; n int := 0;
begin
  if not (erp.membro() and erp.sou_master()) then raise exception 'Só o master classifica em lote'; end if;
  if coalesce(array_length(p_documentos, 1), 0) > 1000 then raise exception 'No máximo 1000 de cada vez'; end if;
  foreach d in array coalesce(p_documentos, '{}') loop
    d := upper(regexp_replace(coalesce(d, ''), '[^0-9A-Za-z]', '', 'g'));
    if exists (select 1 from erp.pessoas p where p.documento = d and p.sem_classe)
       and not exists (select 1 from erp.emitentes_classificacao c where c.documento = d)
       and not exists (select 1 from erp.emitentes_pedidos q where q.documento = d and q.situacao = 'pendente') then
      perform erp.classificar_emitente(d, 'comum');
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function erp.classificar_comuns(text[]) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke execute on function erp.classificar_comuns(text[]) from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then grant execute on function erp.classificar_comuns(text[]) to authenticated; end if;
end $$;
