-- bkm_dev, 20/nov/2026: S-140 (PR do credor conferido, migration 20261120001100). Colar inteiro no SQL Editor.
-- Se alguma conferência do fim falhar, dá erro e nada fica.
begin;
grant erp_conferencia to current_user with inherit false, set true;
grant create on schema erp to erp_conferencia;

-- S-140 (aprovado pelo Moises em 20/nov/2026): credor cadastrado com o CPF/CNPJ do golpista e o nome do fornecedor de
-- verdade. A conferência do recebedor (PIX copia e cola e boleto) só comparava o documento: o boleto do golpista batia
-- com o documento do "credor" e quem aprova lia o nome do fornecedor. Duas partes:
--   1. O nome conferido de quem recebe também tem de bater com a razão social do credor (o nome fantasia não vale). Nome diferente
--      conta como "não confere": a forma de pagamento só entra com a justificativa da exceção, que fica no selo
--      "recebedor não confere" até o pagamento. As mensagens dizem só "conferido", sem a fonte (Moises, 20/nov/2026).
--      Regra do nome (erp.nome_confere): maiúsculas, sem acento e sem pontuação; tiram-se as palavras de forma
--      jurídica, as ligações e as genéricas (CONSTRUTORA, SERVICOS, ENGENHARIA...); confere se a primeira palavra que
--      sobra de um dos nomes está no outro. Assim "ACME ENG LTDA" confere com "ACME ENGENHARIA LTDA", e "JOAO DA SILVA"
--      não confere com "ACME ENGENHARIA". Sem nome na conferência, confere (não há o que comparar).
--   2. Selo "credor novo" para quem aprova: o credor nunca teve outro título que já tenha ido ao Sienge ou sido pago
--      (erp.credor_novo). Não usa a data do cadastro, que se contorna esperando. Na transição, os credores trazidos do
--      Sienge também aparecem como novos até o primeiro título deles sair pelo ERP.

-- ---------------------------------------------------------------------------------------------
-- 1. Nome
-- ---------------------------------------------------------------------------------------------
-- As palavras de um nome: maiúsculas, sem acento e sem pontuação, sem as de forma jurídica e as ligações e, com
-- p_genericas, também sem as palavras genéricas de nome de empresa (que fariam qualquer nome bater; revisão do #115).
create function erp._nome_palavras(p_nome text, p_genericas boolean) returns text[] language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select coalesce(array_agg(w order by o), '{}') from unnest(regexp_split_to_array(
           trim(regexp_replace(upper(translate(coalesce(p_nome, ''),
             'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ', 'AAAAAEEEEIIIIOOOOOUUUUCNaaaaaeeeeiiiiooooouuuucn')), '[^A-Z0-9]+', ' ', 'g')), ' ')) with ordinality x(w, o)
   where w <> '' and w not in ('LTDA', 'LIMITADA', 'ME', 'MEI', 'EPP', 'EIRELI', 'SA', 'S', 'A', 'CIA', 'SLU', 'SS',
                              'DE', 'DA', 'DO', 'DAS', 'DOS', 'E', 'EM')
     and not (p_genericas and w in ('CONSTRUTORA', 'CONSTRUCOES', 'CONSTRUCAO', 'COMERCIAL', 'COMERCIO', 'SOLUCOES', 'SERVICOS',
                                    'SERVICO', 'ENGENHARIA', 'INDUSTRIA', 'INDUSTRIAL', 'GRUPO', 'TRANSPORTES', 'TRANSPORTE',
                                    'EMPREENDIMENTOS', 'INCORPORADORA', 'PARTICIPACOES', 'ADMINISTRACAO', 'CONSULTORIA',
                                    'TECNOLOGIA', 'DISTRIBUIDORA', 'IMOBILIARIA', 'ASSESSORIA', 'EMPRESA', 'BRASIL',
                                    'NACIONAL', 'AGENCIA', 'COMUNICACAO', 'MATERIAIS', 'EQUIPAMENTOS', 'ATACADO', 'VAREJO')) $$;

-- As palavras que identificam o nome: sem as genéricas; se só sobram genéricas, com elas.
create function erp._nome_chave(p_nome text) returns text[] language sql immutable set search_path = pg_catalog, pg_temp as $$
  select case when cardinality(erp._nome_palavras(p_nome, true)) > 0 then erp._nome_palavras(p_nome, true)
              else erp._nome_palavras(p_nome, false) end $$;

-- O nome conferido bate com a razão social do credor (nunca com o nome fantasia, que quem cadastra escolhe; revisão do
-- #115): a primeira palavra que identifica um dos nomes está no outro. Sem nome na conferência, confere (não há o que
-- comparar); com nome só de forma jurídica e ligações, não confere.
create function erp.nome_confere(p_conferido text, p_nome text) returns boolean language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select length(trim(coalesce(p_conferido, ''))) = 0
      or (cardinality(c) > 0 and cardinality(n) > 0 and (c[1] = any(n) or n[1] = any(c)))
    from (select erp._nome_chave(p_conferido) c, erp._nome_chave(p_nome) n) x $$;

-- O recebedor conferido é o credor do título: mesmo CPF/CNPJ e o nome confere. Lê o credor por baixo do RLS (dono
-- erp_conferencia, como os gatilhos que a chamam).
create function erp._credor_confere(c jsonb, p_titulo uuid) returns boolean language sql stable as $$
  select c is not null and coalesce((select c->>'cpf_cnpj' = p.documento and erp.nome_confere(c->>'nome', p.nome)
                                       from erp.titulos t join erp.pessoas p on p.id = t.pessoa_id where t.id = p_titulo), false) $$;

-- (bkm_dev) as três funções são do erp_conferencia: a troca roda como ele
set local role erp_conferencia;
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
reset role;

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
revoke execute on function erp._nome_palavras(text, boolean), erp._nome_chave(text), erp.nome_confere(text, text), erp._credor_confere(jsonb, uuid),
  erp.credor_novo(uuid), api.credores_novos() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function erp._nome_palavras(text, boolean), erp._nome_chave(text), erp.nome_confere(text, text), erp._credor_confere(jsonb, uuid),
      erp.credor_novo(uuid), api.credores_novos() from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function erp._nome_palavras(text, boolean), erp._nome_chave(text), erp.nome_confere(text, text), erp.credor_novo(uuid), api.credores_novos()
      to authenticated;
  end if;
end $$;
grant execute on function erp._nome_palavras(text, boolean), erp._nome_chave(text), erp.nome_confere(text, text), erp._credor_confere(jsonb, uuid), erp.credor_novo(uuid)
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

-- Conferência antes do commit. A regra do nome roda como erp_conferencia (o postgres não executa as funções do erp);
-- o catálogo, como postgres (o erp_conferencia não usa o esquema api). Se algo falhar, nada fica.
set local role erp_conferencia;
do $$ begin
  if not erp.nome_confere('ACME ENG LTDA', 'Acme Engenharia Ltda.') or erp.nome_confere('JOAO DA SILVA', 'Acme Engenharia') then
    raise exception 'Conferência: regra do nome';
  end if;
end $$;
reset role;
do $$ begin
  if pg_get_functiondef('erp.tg_parcela_pix_copia_cola()'::regprocedure) not like '%erp._credor_confere(c, new.titulo_id)%'
     or pg_get_functiondef('erp.tg_parcela_boleto_recebedor()'::regprocedure) not like '%erp._credor_confere(c, new.titulo_id)%'
     or pg_get_functiondef('erp._conferir_recebedores(uuid)'::regprocedure) not like '%not erp._credor_confere(c, p_titulo)%'
     or pg_get_functiondef('api.titulo(uuid)'::regprocedure) not like '%credor_novo%' then
    raise exception 'Conferência: troca nas funções';
  end if;
  if (select count(*) from pg_proc where oid in ('erp._credor_confere(jsonb,uuid)'::regprocedure, 'erp.credor_novo(uuid)'::regprocedure)
        and prosecdef and pg_get_userbyid(proowner) = 'erp_conferencia') <> 2 then
    raise exception 'Conferência: dono e definer';
  end if;
end $$;
revoke create on schema erp from erp_conferencia;
revoke erp_conferencia from current_user;
commit;

-- Depois do commit (devem dar true)
select not has_schema_privilege('erp_conferencia', 'erp', 'create') as sem_create,
       not has_function_privilege('authenticated', 'erp._credor_confere(jsonb,uuid)', 'EXECUTE') as credor_confere_fora_da_api,
       has_function_privilege('authenticated', 'api.credores_novos()', 'EXECUTE') as lista_na_api;

-- Para desfazer: os gatilhos voltam a comparar só o documento rodando de novo as funções das migrations
-- 20261120000700 e 20261120000800 (com set local role erp_conferencia); depois
-- drop function api.credores_novos(); e tirar 'credor_novo' do api.titulo.
