-- Página das linhas PRV a apagar à mão no Sienge (Moises, 18/11/2026: no lugar da planilha do Google, uma
-- página para as pessoas consultarem; quem abre: qualquer login Google da BKM).
--
-- 1. erp.login_bkm(): verdadeiro só para quem entrou pelo Google com e-mail @bkm.com.br. Lê o login pela
--    mesma porta de erp.login_atual() (as claims do pedido), sem auth.uid(): portável. Login por e-mail e
--    senha não vale, mesmo com e-mail da BKM.
-- 2. erp.prv_apagar_pagina(): a lista (a mesma de erp.v_sienge_prv_apagar), security definer do
--    erp_conferencia, para ler por baixo do RLS; recusa quem não passa em erp.login_bkm(). Não exige cadastro
--    no ERP: o financeiro que apaga no Sienge pode não ter usuário no ERP.
-- 3. O esquema `pagina` é o único que vai para a API (Exposed schemas): só a função pagina.prv_apagar(),
--    que chama a de cima. O `erp` continua fora da API.
-- Portabilidade: SQL puro.

create function erp.login_bkm() returns boolean language sql stable as $$
  select coalesce(c ->> 'role', '') = 'authenticated'
     and coalesce(c -> 'app_metadata' ->> 'provider', '') = 'google'
     and lower(coalesce(c ->> 'email', '')) ~ '^[a-z0-9._%+-]+@bkm\.com\.br$'
    from (select nullif(current_setting('request.jwt.claims', true), '')::jsonb as c) x $$;

create function erp.prv_apagar_pagina()
returns table (empresa_sienge text, titulo_sienge int, documento text, valor numeric, data_prevista date,
               na_lista_desde timestamptz, conferido_em timestamptz, situacao_previsao text)
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
begin
  if not coalesce(erp.login_bkm(), false) then
    raise exception 'Entre com a conta Google da BKM' using errcode = '42501';
  end if;
  return query
  select e.codigo::text, s.sienge_id, 'PRV-' || upper(left(replace(s.previsao_id::text, '-', ''), 12)),
         p.valor, p.data_prevista, s.apagar_desde, s.conferido_em, p.situacao::text
    from erp.sienge_previsoes s
    join erp.previsoes p on p.id = s.previsao_id
    left join erp.codigos_externos e on e.sistema = 'sienge' and e.tabela = 'empresas' and e.registro_id = p.empresa_id
   where s.apagar_desde is not null and s.apagado_em is null
   order by s.apagar_desde, s.sienge_id;
end $$;
alter function erp.prv_apagar_pagina() owner to erp_conferencia;

create schema pagina;
revoke all on schema pagina from public;
create function pagina.prv_apagar()
returns table (empresa_sienge text, titulo_sienge int, documento text, valor numeric, data_prevista date,
               na_lista_desde timestamptz, conferido_em timestamptz, situacao_previsao text)
language sql stable set search_path = pg_catalog, pg_temp as $$ select * from erp.prv_apagar_pagina() $$;

-- Segurança: só o usuário logado chama (e a função recusa quem não é Google da BKM)
revoke execute on function erp.login_bkm(), erp.prv_apagar_pagina(), pagina.prv_apagar() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function erp.login_bkm(), erp.prv_apagar_pagina(), pagina.prv_apagar() from anon';
    execute 'revoke all on schema pagina from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'revoke execute on function erp.login_bkm(), erp.prv_apagar_pagina(), pagina.prv_apagar() from service_role';
  end if;
end $$;
grant usage on schema pagina to authenticated;
grant execute on function erp.login_bkm(), erp.prv_apagar_pagina(), pagina.prv_apagar() to authenticated;
grant execute on function erp.login_bkm() to erp_conferencia;
