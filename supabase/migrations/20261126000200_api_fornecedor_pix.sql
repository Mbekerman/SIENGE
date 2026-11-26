-- PIX por e-mail ou telefone (Moises, 26/11/2026: "Se for Email, deve abrir opção de escolha entre os emails cadastrados
-- no registro dela no sistema ou incluir um novo, idem para telefone"). As chaves conhecidas do fornecedor: o e-mail e o
-- telefone do cadastro e as chaves de e-mail e telefone já usadas com ele (títulos e contas que a pessoa vê, pelo RLS).
-- Invoker: quem não vê o fornecedor ou o título não recebe nada dele. Uma chave nova digitada fica só na parcela.
create function api.fornecedor_chaves_pix(p_fornecedor uuid) returns table (tipo text, chave text, origem text)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select distinct on (x.tipo, x.chave) x.tipo, x.chave, x.origem from (
    select 'email' tipo, lower(trim(p.email)) chave, 'cadastro' origem, 0 ordem from erp.pessoas p
     where p.id = p_fornecedor and nullif(trim(p.email), '') is not null
    union all
    select 'telefone', trim(p.telefone), 'cadastro', 0 from erp.pessoas p
     where p.id = p_fornecedor and nullif(trim(p.telefone), '') is not null
    union all
    select g.pix_tipo, g.pix_chave, 'usada', 1 from erp.parcela_pagamentos g join erp.titulos t on t.id = g.titulo_id
     where t.pessoa_id = p_fornecedor and g.pix_tipo in ('email', 'telefone')
    union all
    select c.pix_tipo, c.pix_chave, 'conta', 1 from erp.compromisso_pagamentos c join erp.compromissos k on k.id = c.compromisso_id
     where k.pessoa_id = p_fornecedor and c.pix_tipo in ('email', 'telefone')) x
   order by x.tipo, x.chave, x.ordem $$;
revoke execute on function api.fornecedor_chaves_pix(uuid) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke execute on function api.fornecedor_chaves_pix(uuid) from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then revoke execute on function api.fornecedor_chaves_pix(uuid) from service_role; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then grant execute on function api.fornecedor_chaves_pix(uuid) to authenticated; end if;
end $$;
