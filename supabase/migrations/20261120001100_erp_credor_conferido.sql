-- S-140 (aprovado pelo Moises em 20/nov/2026): credor cadastrado com o CPF/CNPJ do golpista e o nome do fornecedor de
-- verdade. A conferência do recebedor (PIX copia e cola e boleto) só comparava o documento: o boleto do golpista batia
-- com o documento do "credor" e quem aprova lia o nome do fornecedor. Duas partes:
--   1. O nome conferido de quem recebe também tem de bater com o nome (ou o nome fantasia) do credor. Nome diferente
--      conta como "não confere": a forma de pagamento só entra com a justificativa da exceção, que fica no selo
--      "recebedor não confere" até o pagamento. As mensagens dizem só "conferido", sem a fonte (Moises, 20/nov/2026).
--      Regra do nome (erp.nome_confere): maiúsculas, sem acento e sem pontuação; tiram-se as palavras de forma
--      jurídica e as ligações (LTDA, ME, EPP, EIRELI, SA, CIA, DE, DA, DO...); confere se a primeira palavra que sobra
--      de um dos nomes está no outro. Assim "ACME ENG LTDA" confere com "ACME ENGENHARIA LTDA", e "JOAO DA SILVA" não
--      confere com "ACME ENGENHARIA". Sem nome na conferência, confere (não há o que comparar).
--   2. Selo "credor novo" para quem aprova: o credor nunca teve outro título que já tenha ido ao Sienge ou sido pago
--      (erp.credor_novo). Não usa a data do cadastro, que se contorna esperando. Na transição, os credores trazidos do
--      Sienge também aparecem como novos até o primeiro título deles sair pelo ERP.

-- ---------------------------------------------------------------------------------------------
-- 1. Nome
-- ---------------------------------------------------------------------------------------------
create function erp._nome_palavras(p_nome text) returns text[] language sql immutable set search_path = pg_catalog, pg_temp as $$
  select coalesce(array_agg(w order by o), '{}') from unnest(regexp_split_to_array(
           trim(regexp_replace(upper(translate(coalesce(p_nome, ''),
             'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ', 'AAAAAEEEEIIIIOOOOOUUUUCNaaaaaeeeeiiiiooooouuuucn')), '[^A-Z0-9]+', ' ', 'g')), ' ')) with ordinality x(w, o)
   where w <> '' and w not in ('LTDA', 'LIMITADA', 'ME', 'MEI', 'EPP', 'EIRELI', 'SA', 'S', 'A', 'CIA', 'SLU', 'SS',
                              'DE', 'DA', 'DO', 'DAS', 'DOS', 'E', 'EM') $$;

create function erp.nome_confere(p_conferido text, p_nome text, p_fantasia text) returns boolean language sql immutable
set search_path = pg_catalog, pg_temp as $$
  with c as (select erp._nome_palavras(p_conferido) w),
       n as (select erp._nome_palavras(p_nome) || erp._nome_palavras(p_fantasia) w,
                    erp._nome_palavras(p_nome) a, erp._nome_palavras(p_fantasia) f)
  select cardinality(c.w) = 0
      or c.w[1] = any(n.w)
      or (cardinality(n.a) > 0 and n.a[1] = any(c.w))
      or (cardinality(n.f) > 0 and n.f[1] = any(c.w))
    from c, n $$;

-- O recebedor conferido é o credor do título: mesmo CPF/CNPJ e o nome confere. Lê o credor por baixo do RLS (dono
-- erp_conferencia, como os gatilhos que a chamam).
create function erp._credor_confere(c jsonb, p_titulo uuid) returns boolean language sql stable as $$
  select c is not null and coalesce((select c->>'cpf_cnpj' = p.documento and erp.nome_confere(c->>'nome', p.nome, p.nome_fantasia)
                                       from erp.titulos t join erp.pessoas p on p.id = t.pessoa_id where t.id = p_titulo), false) $$;

-- Troca a comparação do documento pela do credor nos três lugares que conferem o recebedor. Recusa se não achar o
-- trecho, para não passar pela metade.
do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('erp.tg_parcela_pix_copia_cola()'::regprocedure);
  v_novo := replace(v_def, $r$(c is not null and c->>'cpf_cnpj' = v_doc)$r$, $r$erp._credor_confere(c, new.titulo_id)$r$);
  if v_novo = v_def then raise exception 'erp.tg_parcela_pix_copia_cola: ponto de troca não achado'; end if;
  execute v_novo;

  v_def := pg_get_functiondef('erp.tg_parcela_boleto_recebedor()'::regprocedure);
  v_novo := replace(v_def, $r$if c is not null and c->>'cpf_cnpj' = v_doc then$r$, $r$if erp._credor_confere(c, new.titulo_id) then$r$);
  if v_novo = v_def then raise exception 'erp.tg_parcela_boleto_recebedor: ponto de troca não achado'; end if;
  execute v_novo;

  v_def := pg_get_functiondef('erp._conferir_recebedores(uuid)'::regprocedure);
  v_novo := replace(v_def, $r$if c is null or c->>'cpf_cnpj' is distinct from v_doc$r$, $r$if not erp._credor_confere(c, p_titulo)$r$);
  v_novo := replace(v_novo, $r$(c is not null and c->>'cpf_cnpj' = v_doc and$r$, $r$(erp._credor_confere(c, p_titulo) and$r$);
  if v_novo like '%cpf_cnpj%' or v_novo = v_def then raise exception 'erp._conferir_recebedores: ponto de troca não achado'; end if;
  execute v_novo;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 2. Credor novo
-- ---------------------------------------------------------------------------------------------
-- Para um título a pagar que a pessoa vê, ainda não pago: o dia em que o credor foi cadastrado, se ele nunca teve outro
-- título que já foi ao Sienge ou foi pago; senão nulo. Definer (dono erp_conferencia) para contar os títulos do credor
-- que a pessoa não vê; só responde sobre título que ela vê e só diz sim ou não.
create function erp.credor_novo(p_titulo uuid) returns date language sql stable as $$
  select p.criada_em::date
    from erp.titulos t join erp.pessoas p on p.id = t.pessoa_id
   where t.id = p_titulo and erp.vejo_titulo(p_titulo)
     and t.sentido = 'pagar' and t.situacao not in ('quitado', 'cancelado')
     and not exists (select 1 from erp.titulos o
                      where o.pessoa_id = t.pessoa_id and o.id <> t.id
                        and (o.situacao = 'quitado'
                             or exists (select 1 from erp.sienge_envios e where e.titulo_id = o.id and e.situacao in ('enviado', 'manual')))) $$;

-- As listas: os títulos que a pessoa vê com o selo
create function api.credores_novos() returns table (id uuid, desde date)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select t.id, erp.credor_novo(t.id)
    from erp.titulos t
   where t.sentido = 'pagar' and t.situacao not in ('quitado', 'cancelado') and erp.credor_novo(t.id) is not null $$;

-- A gaveta do título
do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('api.titulo(uuid)'::regprocedure);
  v_novo := replace(v_def, $r$'recebedor_divergente', erp.recebedor_divergente(t.id),$r$,
                           $r$'recebedor_divergente', erp.recebedor_divergente(t.id), 'credor_novo', erp.credor_novo(t.id),$r$);
  if v_novo = v_def then raise exception 'api.titulo: ponto de troca não achado'; end if;
  execute v_novo;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Permissões e dono
-- ---------------------------------------------------------------------------------------------
revoke execute on function erp._nome_palavras(text), erp.nome_confere(text, text, text), erp._credor_confere(jsonb, uuid),
  erp.credor_novo(uuid), api.credores_novos() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function erp._nome_palavras(text), erp.nome_confere(text, text, text), erp._credor_confere(jsonb, uuid),
      erp.credor_novo(uuid), api.credores_novos() from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function erp._nome_palavras(text), erp.nome_confere(text, text, text), erp.credor_novo(uuid), api.credores_novos()
      to authenticated;
  end if;
end $$;
grant execute on function erp._nome_palavras(text), erp.nome_confere(text, text, text), erp._credor_confere(jsonb, uuid), erp.credor_novo(uuid)
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
alter function erp._credor_confere(jsonb, uuid) security definer set search_path = erp, pg_catalog, pg_temp;
alter function erp.credor_novo(uuid) security definer set search_path = erp, pg_catalog, pg_temp;
create temp table _cre_create_dado as
  select r from unnest(array['erp_conferencia']) r where not has_schema_privilege(r, 'erp', 'create');
do $$ declare v text; begin
  for v in select r from _cre_create_dado loop execute format('grant create on schema erp to %I', v); end loop;
end $$;
alter function erp._credor_confere(jsonb, uuid) owner to erp_conferencia;
alter function erp.credor_novo(uuid) owner to erp_conferencia;
do $$ declare v text; begin
  for v in select r from _cre_create_dado loop execute format('revoke create on schema erp from %I', v); end loop;
end $$;
drop table _cre_create_dado;
