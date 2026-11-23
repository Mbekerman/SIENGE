-- bkm_dev, 23/nov/2026: CNPJ alfanumérico (migration 20261123003000). Colar inteiro no SQL Editor.
-- Se já foi aplicado, para logo no começo com o aviso e nada muda. Se alguma conferência do fim falhar, dá erro e nada fica.
begin;
do $$ begin
  if to_regprocedure('erp.cnpj_valido(text)') is not null then
    raise exception 'Este SQL já foi aplicado no bkm_dev (erp.cnpj_valido existe). Nada foi alterado.';
  end if;
end $$;

-- CNPJ alfanumérico (Receita Federal, a partir de julho/2026; aprovado pelo Moises em 23/nov/2026): os CNPJs novos têm
-- as 12 primeiras posições em [0-9A-Z] e os 2 dígitos verificadores numéricos; o DV é o módulo 11 de sempre, com cada
-- posição valendo o código ASCII − 48 (A = 17, B = 18...). Os CNPJs que já existem continuam só com dígitos.
-- Até aqui o banco só aceitava dígitos: um fornecedor com CNPJ alfanumérico não se cadastrava. Passa a aceitar, sempre
-- em maiúsculas e só com o DV conferido aqui:
--   1. erp.cnpj_valido(texto): a conta oficial, para os dois formatos.
--   2. Credor (erp.pessoas.documento), titular da TED (erp.compromisso_pagamentos.titular_documento) e chave PIX
--      CPF/CNPJ (erp.chave_pix_valida): o CNPJ só com dígitos fica como estava (o DV dele não se confere aqui, para não
--      recusar dado antigo trazido do Sienge); o com letra só entra com o DV certo.
--   3. Conferência de quem recebe (pix_conferencias e boleto_conferencias): aceita letras no documento devolvido.
--   4. Busca do fornecedor pelo documento e identificação da nota pelo CNPJ: não jogam fora as letras.
-- O Sienge: GET /creditors?cnpj=<alfanumérico> responde 400 "CNPJ inválido" (testado em 23/nov/2026, só leitura). O
-- envio do título manda o código do credor, não o CNPJ, e anda; a chave PIX com CNPJ alfanumérico não vai pela API (o
-- envio para com aviso e a forma de pagamento é posta à mão no Sienge) até o Sienge aceitar.
-- Fora daqui, de propósito: os órgãos das guias (erp.guia_recebedores, só CNPJs públicos que já existem).

-- 1. A conta
create function erp.cnpj_valido(p text) returns boolean language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
declare s int; r int; i int; peso int; dv int[] := '{}';
begin
  if p is null or p !~ '^[0-9A-Z]{12}[0-9]{2}$' or p ~ '^(\d)\1{13}$' then return false; end if;
  foreach r in array array[12, 13] loop
    s := 0; peso := 2;
    for i in reverse r..1 loop
      s := s + (ascii(substr(p, i, 1)) - 48) * peso;
      peso := case peso when 9 then 2 else peso + 1 end;
    end loop;
    dv := dv || case when s % 11 < 2 then 0 else 11 - s % 11 end;
  end loop;
  return dv[1] = substr(p, 13, 1)::int and dv[2] = substr(p, 14, 1)::int;
end $$;

-- CNPJ aceito no cadastro: o só de dígitos de sempre, ou o alfanumérico (com alguma letra) com o DV certo
create function erp.cnpj_aceito(p text) returns boolean language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select p ~ '^[0-9]{14}$' or (p ~ '^[0-9A-Z]{12}[0-9]{2}$' and p ~ '[A-Z]' and erp.cnpj_valido(p)) $$;

-- 2. Credor, titular da TED e chave PIX
do $$
declare c text;
begin
  for c in select conname from pg_constraint where conrelid = 'erp.pessoas'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%documento ~%' loop
    execute format('alter table erp.pessoas drop constraint %I', c);
  end loop;
  if not found then raise exception 'erp.pessoas: checagem do documento não achada'; end if;
  for c in select conname from pg_constraint where conrelid = 'erp.compromisso_pagamentos'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%titular_documento ~%' loop
    execute format('alter table erp.compromisso_pagamentos drop constraint %I', c);
  end loop;
  if not found then raise exception 'erp.compromisso_pagamentos: checagem do titular não achada'; end if;
end $$;
alter table erp.pessoas add constraint pessoas_documento_check
  check (documento is null or case tipo when 'fisica' then documento ~ '^[0-9]{11}$' else erp.cnpj_aceito(documento) end);
alter table erp.compromisso_pagamentos add constraint compromisso_pagamentos_titular_documento_check
  check (titular_documento ~ '^[0-9]{11}$' or erp.cnpj_aceito(titular_documento));

create or replace function erp.chave_pix_valida(p_tipo text, p_chave text) returns boolean language sql immutable as $$
  select case p_tipo
    when 'cpf_cnpj' then p_chave ~ '^[0-9]{11}$' or erp.cnpj_aceito(p_chave)
    when 'email' then p_chave ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' and length(p_chave) <= 77
    when 'telefone' then p_chave ~ '^\+55[1-9][0-9][0-9]{8,9}$'
    when 'aleatoria' then p_chave ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    else false end $$;

-- 3. Conferência de quem recebe: o documento como volta (com * quando mascarado), agora também com letras
do $$
declare t text; c text;
begin
  foreach t in array array['erp.pix_conferencias', 'erp.boleto_conferencias'] loop
    select conname into c from pg_constraint where conrelid = t::regclass and contype = 'c'
       and pg_get_constraintdef(oid) like '%cpf_cnpj ~%';
    if c is null then raise exception '%: checagem do documento não achada', t; end if;
    execute format('alter table %s drop constraint %I', t, c);
    execute format($f$alter table %s add constraint %I check (cpf_cnpj ~ '^[0-9A-Z*]{11,14}$')$f$, t, c);
  end loop;
end $$;

-- 4. Busca do fornecedor e identificação da nota
create or replace function api.fornecedores(p_busca text)
returns table (id uuid, nome text, nome_fantasia text, documento text, tipo text)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select p.id, p.nome, p.nome_fantasia, p.documento, p.tipo
    from erp.pessoas p
   where p.ativa and exists (select 1 from erp.pessoa_papeis pp where pp.pessoa_id = p.id and pp.papel = 'fornecedor')
     and (coalesce(trim(p_busca), '') = ''
          or p.nome ilike '%' || trim(p_busca) || '%' or p.nome_fantasia ilike '%' || trim(p_busca) || '%'
          -- pelo documento: com pelo menos 3 posições e um dígito (o CNPJ alfanumérico tem letras)
          or (length(regexp_replace(p_busca, '[^0-9A-Za-z]', '', 'g')) >= 3 and p_busca ~ '[0-9]'
              and p.documento like '%' || upper(regexp_replace(p_busca, '[^0-9A-Za-z]', '', 'g')) || '%'))
   order by p.nome
   limit 30 $$;

do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('api.identificar_nota(jsonb)'::regprocedure);
  v_novo := replace(v_def, $r$nullif(regexp_replace(coalesce(p->>'tomador', ''), '[^0-9]', '', 'g'), '')$r$,
                           $r$nullif(upper(regexp_replace(coalesce(p->>'tomador', ''), '[^0-9A-Za-z]', '', 'g')), '')$r$);
  v_novo := replace(v_novo, $r$nullif(regexp_replace(coalesce(p->>'emitente', ''), '[^0-9]', '', 'g'), '')$r$,
                            $r$nullif(upper(regexp_replace(coalesce(p->>'emitente', ''), '[^0-9A-Za-z]', '', 'g')), '')$r$);
  if v_novo like $r$%'[^0-9]', '', 'g'), '')%$r$ or v_novo = v_def then raise exception 'api.identificar_nota: ponto de troca não achado'; end if;
  execute v_novo;
end $$;

revoke execute on function erp.cnpj_valido(text), erp.cnpj_aceito(text) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function erp.cnpj_valido(text), erp.cnpj_aceito(text), api.fornecedores(text) from anon;
  end if;
end $$;
grant execute on function erp.cnpj_valido(text), erp.cnpj_aceito(text)
  to authenticated, erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;

-- Conferências antes do commit
do $$ begin
  if not (erp.cnpj_valido('12ABC34501DE35') and not erp.cnpj_valido('12ABC34501DE53') and erp.cnpj_aceito('29732041000154')
          and erp.chave_pix_valida('cpf_cnpj', '12ABC34501DE35') and not erp.chave_pix_valida('cpf_cnpj', '12ABC34501DE53')) then
    raise exception 'Conferência: a conta do DV';
  end if;
  if (select count(*) from pg_constraint where contype = 'c' and conname in ('pessoas_documento_check', 'compromisso_pagamentos_titular_documento_check')) <> 2
     or exists (select 1 from pg_constraint where contype = 'c' and conrelid in ('erp.pix_conferencias'::regclass, 'erp.boleto_conferencias'::regclass)
                   and pg_get_constraintdef(oid) like '%cpf_cnpj ~%' and pg_get_constraintdef(oid) not like '%A-Z%') then
    raise exception 'Conferência: as checagens das tabelas';
  end if;
  if pg_get_functiondef('api.identificar_nota(jsonb)'::regprocedure) not like '%[^0-9A-Za-z]%' then
    raise exception 'Conferência: api.identificar_nota';
  end if;
  -- os dados que já estão continuam valendo (a checagem nova já foi conferida no add constraint)
end $$;
commit;

-- Depois do commit (devem dar true)
select has_function_privilege('authenticated', 'erp.cnpj_valido(text)', 'EXECUTE') as cnpj_valido_na_api,
       not has_function_privilege('anon', 'erp.cnpj_valido(text)', 'EXECUTE') as fora_do_anon,
       erp.cnpj_valido('12ABC34501DE35') as exemplo_da_receita;

-- Para desfazer: as checagens antigas (só dígitos) voltam com alter table ... drop constraint e add constraint como nas
-- migrations 20261107000100 e 20261123000300 (falha se já houver CNPJ com letra gravado), erp.chave_pix_valida volta à
-- da 20261117000200, api.fornecedores à da 20261119000200 e o identificar_nota troca o [^0-9A-Za-z] de volta.
