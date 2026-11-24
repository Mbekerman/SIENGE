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
--     se o documento já está classificado como PJ (S-144), a pessoa nasce restrita (só o master e os designados a veem).
--     Credor sem classificação entra comum: credor conhecido não prova que não é PJ, e a nota dele segue a triagem.
-- Nunca grava PIX, conta bancária, e-mail ou telefone, nem tira ou muda nada que já existe. Só o sistema chama.
create function erp.sienge_importar_credores(p_lista jsonb) returns jsonb language plpgsql
set search_path = erp, pg_catalog, pg_temp as $$
declare
  c jsonb; v_id text; v_doc text; v_tipo text; v_nome text; v_pessoa uuid; v_ligado uuid; v_atual record;
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
      -- emitente já classificado como PJ (ou com pedido de inclusão no PJ esperando) entra restrito, como a pessoa PJ
      insert into erp.pessoas (tipo, nome, nome_fantasia, documento, ativa, restrita)
      values (v_tipo, v_nome, nullif(btrim(c->>'tradeName'), ''), v_doc, coalesce((c->>'active')::boolean, true),
              v_doc is not null and erp._classe_emitente(v_doc) is not distinct from 'pj')
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
