-- S-003: RLS ligado e forçado em toda tabela do esquema `erp`, negando por padrão.
-- Por ora a única política é a do sistema (erp.sistema()); as políticas por perfil
-- (núcleo econômico × centro de custo × natureza) entram junto com o primeiro grant a
-- `authenticated`, no mesmo PR. Tabela nova em migration futura: o teste de catálogo
-- recusa tabela sem RLS forçado e política que libera tudo (using/with check true).
-- Superusuário (o dono das migrations nos testes) ignora RLS mesmo forçado; no banco real,
-- os papéis da API não são superusuários.
do $$
declare t record;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'erp' and c.relkind in ('r', 'p') loop
    execute format('alter table erp.%I enable row level security', t.relname);
    execute format('alter table erp.%I force row level security', t.relname);
    execute format('create policy sistema on erp.%I using (erp.sistema()) with check (erp.sistema())', t.relname);
  end loop;
end $$;
