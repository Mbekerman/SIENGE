-- bkm_dev, 20/11/2026: guias como tipos próprios e CNPJ do órgão pela linha da guia (PR #112, migration 20261120000900).
-- Colar inteiro no SQL Editor do bkm_dev e rodar. Tudo numa transação: se der erro, nada fica.
begin;
-- o postgres do SQL Editor precisa poder virar erp_conferencia para passar a função a ela (tirado no fim)
grant erp_conferencia to current_user with inherit false, set true;
-- Guias de imposto como tipos próprios e o CNPJ do órgão pela linha da guia (Moises, 20/nov/2026, depois do teste
-- do leitor com 200 títulos do Sienge: "Quero sim esses tipos" e "3 pode ser então").
--   - Tipos de documento iptu, itbi, darf, darm (guia municipal) e dare (guia estadual), com os documentos de mesmo
--     nome do Sienge. 'guia' continua para as demais guias.
--   - Guia com código de barras de arrecadação (linha de 48 dígitos que começa por 8) traz o código do recebedor
--     (Febraban: segmento na posição 2 e código da empresa nas posições 16 a 19 do código de barras). A tabela
--     erp.recebedores_arrecadacao liga esse código ao CNPJ do órgão. Ao gravar a leitura, se o leitor não achou o
--     CNPJ do emitente, ele vem da tabela, com um aviso. Código fora da tabela deixa o emitente como veio.
--     Segmento 6 (empresas identificadas pelo CNPJ no próprio código) fica de fora: o código só traz a raiz.
-- A tabela começa com os credores que o financeiro já usa no Sienge para esses códigos; sem tela por ora: muda por
-- migration ou SQL no editor, com o ok do master.

-- ---------------------------------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------------------------------
alter table erp.documentos_fiscais drop constraint documentos_fiscais_tipo_check;
alter table erp.documentos_fiscais add constraint documentos_fiscais_tipo_check
  check (tipo in ('nfse','nfe','fatura','boleto','iptu','itbi','darf','darm','dare','guia','recibo','outro'));

create or replace function erp.sienge_documento(p_tipo text) returns text language sql immutable as $$
  select case p_tipo when 'nfse' then 'NFSE' when 'nfe' then 'NFE' when 'fatura' then 'FAT'
                     when 'boleto' then 'BLT' when 'iptu' then 'IPTU' when 'itbi' then 'ITBI' when 'darf' then 'DARF'
                     when 'darm' then 'DARM' when 'dare' then 'DARE' when 'guia' then 'GUIA' when 'recibo' then 'REC' end $$;

-- O nome do tipo nas telas e a lista do Lançar título: troca o trecho nas funções que já o têm (sem copiar as
-- funções inteiras). Recusa se o trecho não estiver onde se espera, para não passar pela metade.
do $$
declare f record; v_def text; v_n int := 0; v_m int := 0;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('erp', 'api') and p.prosrc like '%when ''guia'' then ''Guia''%' loop
    v_def := pg_get_functiondef(f.oid);
    v_def := replace(v_def, 'when ''guia'' then ''Guia''',
      'when ''iptu'' then ''IPTU'' when ''itbi'' then ''ITBI'' when ''darf'' then ''DARF'' when ''darm'' then ''DARM'' '
      || 'when ''dare'' then ''DARE'' when ''guia'' then ''Guia''');
    execute v_def; v_n := v_n + 1;
  end loop;
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'api' and p.prosrc like '%(''nfse'',''nfe'',''fatura'',''boleto'',''recibo'',''outro'')%' loop
    v_def := replace(pg_get_functiondef(f.oid), '(''nfse'',''nfe'',''fatura'',''boleto'',''recibo'',''outro'')',
                     '(''nfse'',''nfe'',''fatura'',''boleto'',''iptu'',''itbi'',''darf'',''darm'',''dare'',''recibo'',''outro'')');
    execute v_def; v_m := v_m + 1;
  end loop;
  if v_n < 2 or v_m <> 1 then
    raise exception 'Nome dos tipos em % funções e lista do Lançar título em % (esperado 2 ou mais e 1)', v_n, v_m;
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- CNPJ do órgão pelo código da guia
-- ---------------------------------------------------------------------------------------------
create table erp.recebedores_arrecadacao (
  segmento  text not null check (segmento ~ '^[1-579]$'),
  codigo    text not null check (codigo ~ '^[0-9]{4}$'),
  cpf_cnpj  text not null check (cpf_cnpj ~ '^[0-9]{14}$'),
  nome      text not null check (length(trim(nome)) > 0),
  primary key (segmento, codigo)
);
-- Carga inicial: os credores que o financeiro já usa no Sienge para cada código (guias e contas de 2025 e 2026 do
-- teste do leitor). O código 0185 do segmento 5 (guias estaduais) ficou de fora: no Sienge ele aparece com três
-- credores diferentes.
insert into erp.recebedores_arrecadacao (segmento, codigo, cpf_cnpj, nome) values
  ('1', '4158', '46643466000106', 'PREFEITURA DO MUNICIPIO DE SAO JOSE DOS CAMPOS'),
  ('1', '5701', '46395000000139', 'PREFEITURA DO MUNICIPIO DE SAO PAULO'),
  ('2', '0097', '43776517000180', 'CIA DE SANEAMENTO BASICO DO ESTADO DE SAO PAULO SABESP'),
  ('3', '0048', '61695227000193', 'ELETROPAULO METROPOLITANA ELETRICIDADE DE SAO PAULO S.A.'),
  ('3', '0073', '02302100000106', 'EDP SAO PAULO DISTRIBUICAO DE ENERGIA S.A.'),
  ('4', '0082', '02558157000162', 'TELEFONICA BRASIL S.A.'),
  ('4', '0114', '58526690000105', 'NET2PHONE BRASIL TELECOMUNICACOES LTDA'),
  ('5', '0385', '00394460005887', 'SECRETARIA DA RECEITA FEDERAL');
alter table erp.recebedores_arrecadacao enable row level security;
alter table erp.recebedores_arrecadacao force row level security;
create policy conferencia on erp.recebedores_arrecadacao for select to erp_conferencia using (true);
revoke all on erp.recebedores_arrecadacao from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke all on erp.recebedores_arrecadacao from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then revoke all on erp.recebedores_arrecadacao from authenticated; end if;
end $$;
grant select on erp.recebedores_arrecadacao to erp_conferencia;
create trigger t_nao_trunca before truncate on erp.recebedores_arrecadacao for each statement execute function erp.tg_recusa_truncate();
-- o postgres não executa erp.tg_auditoria: o gatilho é criado como erp_conferencia, com o direito de gatilho só aqui
grant trigger on erp.recebedores_arrecadacao to erp_conferencia;
set local role erp_conferencia;
create trigger t_auditoria after insert or update or delete on erp.recebedores_arrecadacao
  for each row execute function erp.tg_auditoria('codigo');
reset role;
revoke trigger on erp.recebedores_arrecadacao from erp_conferencia;

-- Segmento e código do recebedor de uma linha de arrecadação (48 dígitos, começa por 8); nulo se não for uma.
create function erp.codigo_arrecadacao(p_linha text) returns text[] language sql immutable as $$
  select case when p_linha ~ '^8[0-9]{47}$' and substr(p_linha, 2, 1) <> '6'
              then array[substr(p_linha, 2, 1), substr(substr(p_linha, 1, 11) || substr(p_linha, 13, 11), 16, 4)] end $$;

-- Completa o emitente da leitura pelo código da guia, quando o leitor não achou o CNPJ.
create function erp.completar_recebedor(p_leitura jsonb) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare b jsonb; c text[]; r erp.recebedores_arrecadacao;
begin
  if p_leitura is null or coalesce(p_leitura->'emitente'->>'documento', '') <> '' then return p_leitura; end if;
  for b in select * from jsonb_array_elements(case when jsonb_typeof(p_leitura->'boletos') = 'array'
                                                   then p_leitura->'boletos' else '[]' end) loop
    c := erp.codigo_arrecadacao(b->>'linha');
    if c is null then continue; end if;
    select * into r from erp.recebedores_arrecadacao where segmento = c[1] and codigo = c[2];
    if r.cpf_cnpj is null then continue; end if;
    return jsonb_set(jsonb_set(p_leitura, '{emitente}',
             coalesce(p_leitura->'emitente', '{}') || jsonb_build_object('documento', r.cpf_cnpj,
               'nome', coalesce(nullif(p_leitura->'emitente'->>'nome', ''), r.nome))),
           '{avisos}', coalesce(case when jsonb_typeof(p_leitura->'avisos') = 'array' then p_leitura->'avisos' end, '[]')
             || to_jsonb('CNPJ do emitente pelo código do recebedor na linha da guia (' || r.nome || ')'));
  end loop;
  return p_leitura;
end $$;

create or replace function api.gravar_leitura(p_anexo uuid, p_leitura jsonb) returns void
language plpgsql volatile security invoker set search_path = pg_catalog, pg_temp as $$
begin
  perform erp.exigir_editor();
  update erp.anexos set leitura = erp.completar_recebedor(p_leitura) where id = p_anexo;
  if not found then raise exception 'Anexo não encontrado'; end if;
end $$;

revoke execute on function erp.codigo_arrecadacao(text), erp.completar_recebedor(jsonb) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function erp.codigo_arrecadacao(text), erp.completar_recebedor(jsonb) from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function erp.codigo_arrecadacao(text), erp.completar_recebedor(jsonb) to authenticated;
  end if;
end $$;
grant execute on function erp.codigo_arrecadacao(text), erp.completar_recebedor(jsonb)
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;

-- dono erp_conferencia (só lê a tabela), como as outras funções de conferência
create temp table _gui_create_dado as
  select r from unnest(array['erp_conferencia']) r where not has_schema_privilege(r, 'erp', 'create');
do $$ declare v text; begin
  for v in select r from _gui_create_dado loop execute format('grant create on schema erp to %I', v); end loop;
end $$;
alter function erp.completar_recebedor(jsonb) owner to erp_conferencia;
do $$ declare v text; begin
  for v in select r from _gui_create_dado loop execute format('revoke create on schema erp from %I', v); end loop;
end $$;
drop table _gui_create_dado;
-- confere as funções como erp_conferencia (o postgres não executa as funções do erp); se falhar, nada fica
set local role erp_conferencia;
do $$ begin
  if erp.sienge_documento('itbi') is distinct from 'ITBI' then raise exception 'Conferência: documento do Sienge'; end if;
  if erp.completar_recebedor('{"boletos": [{"linha": "826700000068278700970918102694590609329178721737"}]}')->'emitente'->>'documento'
     is distinct from '43776517000180' then raise exception 'Conferência: conta de água não completou a Sabesp'; end if;
end $$;
reset role;
revoke erp_conferencia from current_user;
commit;

-- Conferência (as 7 linhas devem dar true; o documento do Sienge e a Sabesp já foram conferidos antes do commit)
select 'tabela com 8 órgãos' item, (select count(*) = 8 from erp.recebedores_arrecadacao) ok
union all select 'tipos novos no documento', (select pg_get_constraintdef(oid) like '%darf%' from pg_constraint where conname = 'documentos_fiscais_tipo_check')
union all select 'Lançar aceita darm', (select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'api' and p.prosrc like '%Tipo de documento inválido%' and p.prosrc like '%''darm''%')
union all select 'nomes nas telas', (select count(*) >= 2 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'api' and p.prosrc like '%when ''itbi'' then ''ITBI''%')
union all select 'função de erp_conferencia', (select pg_get_userbyid(proowner) = 'erp_conferencia' and prosecdef from pg_proc where oid = 'erp.completar_recebedor(jsonb)'::regprocedure)
union all select 'API sem grant na tabela', not has_table_privilege('authenticated', 'erp.recebedores_arrecadacao', 'SELECT')
union all select 'postgres sem o papel', not exists (select 1 from pg_auth_members where roleid = 'erp_conferencia'::regrole and member = current_user::regrole and (set_option or inherit_option));

-- Para desfazer (só se precisar):
-- begin;
-- create or replace function api.gravar_leitura(p_anexo uuid, p_leitura jsonb) returns void language plpgsql volatile security invoker
--   set search_path = pg_catalog, pg_temp as $$ begin perform erp.exigir_editor(); update erp.anexos set leitura = p_leitura where id = p_anexo;
--   if not found then raise exception 'Anexo não encontrado'; end if; end $$;
-- drop function erp.completar_recebedor(jsonb); drop function erp.codigo_arrecadacao(text); drop table erp.recebedores_arrecadacao;
-- (os tipos novos ficam: tirá-los só se nenhum documento usar)
-- commit;
