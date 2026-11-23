-- Apelido das empresas do grupo (Moises, 23/nov/2026: "no cadastro das empresas eu queria poder criar um apelido pra
-- cada empresa pelo qual ela seria chamada no sistema, e não somente a razão social. Uma espécie de nome fantasia para
-- o sistema").
--
-- 1. erp.empresas.apelido: opcional, de 2 a 40 letras, sem espaço sobrando, e não se repete entre as empresas (sem
--    diferença de maiúscula). Não é o nome fantasia da pessoa (erp.pessoas.nome_fantasia, o do CNPJ): é o nome pelo
--    qual a BKM chama a empresa dentro do sistema.
-- 2. Quem dá e muda o apelido: o master, AF, AD e o administrador (Moises, 23/11/2026: "Admin também pode editar o
--    apelido"), na hora e com auditoria, como o resto do cadastro da empresa que o administrador já muda. Tipo e
--    situação da empresa continuam só com o administrador e o master.
-- 3. As telas mostram o apelido no lugar da razão social, e a razão social quando a empresa não tem apelido. A razão
--    social continua em tudo o que confere ou sai do sistema: conferência do recebedor, envio ao Sienge, documentos,
--    camada de BI (que ganha a coluna apelido ao lado).
-- 4. erp.empresas passa a ter auditoria (não tinha).
-- Portabilidade: SQL puro.

alter table erp.empresas add column apelido text
  check (apelido is null or (apelido = btrim(apelido) and char_length(apelido) between 2 and 40));
create unique index empresas_apelido on erp.empresas (lower(apelido));

-- Arruma o apelido (espaços), confere quem muda e não deixa repetir com mensagem clara (o índice garante por baixo).
create function erp.tg_empresa_apelido() returns trigger language plpgsql as $$
begin
  new.apelido := nullif(btrim(regexp_replace(coalesce(new.apelido, ''), '\s+', ' ', 'g')), '');
  if new.apelido is distinct from (case when tg_op = 'UPDATE' then old.apelido end) then
    if not (erp.sistema() or erp.sou_admin() or erp.estou_nas_listas(array['AF', 'AD'])) then
      raise exception 'Só AF, AD, o administrador e o master dão e mudam o apelido da empresa';
    end if;
    if new.apelido is not null and char_length(new.apelido) not between 2 and 40 then
      raise exception 'O apelido tem de 2 a 40 letras';
    end if;
    if new.apelido is not null and exists (select 1 from erp.empresas e where lower(e.apelido) = lower(new.apelido) and e.id <> new.id) then
      raise exception 'Já existe uma empresa com o apelido %', new.apelido;
    end if;
  end if;
  -- AF e AD passam pela regra de acesso só para o apelido: o resto da empresa segue com o administrador
  if tg_op = 'UPDATE' and (new.id, new.pessoa_id, new.tipo, new.ativa) is distinct from (old.id, old.pessoa_id, old.tipo, old.ativa)
     and not (erp.sistema() or erp.sou_admin()) then
    raise exception 'Tipo e situação da empresa só o administrador muda';
  end if;
  return new;
end $$;
create trigger t_apelido before insert or update on erp.empresas for each row execute function erp.tg_empresa_apelido();
-- S-127: função nova do erp não fica para o public (nem o anon)
revoke execute on function erp.tg_empresa_apelido() from public;
grant execute on function erp.tg_empresa_apelido()
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;

-- a regra de acesso de alterar ganha AF e AD (o gatilho acima limita ao apelido)
drop policy perfil_altera on erp.empresas;
create policy perfil_altera on erp.empresas for update to authenticated
  using (erp.sou_admin() or erp.estou_nas_listas(array['AF', 'AD']))
  with check (erp.sou_admin() or erp.estou_nas_listas(array['AF', 'AD']));

create trigger t_aud_empresas after insert or update or delete on erp.empresas
  for each row execute function erp.tg_auditoria('id');

-- ---------------------------------------------------------------------------------------------
-- Telas: o apelido no lugar da razão social (troca no texto das funções; recusa se não achar o trecho)
-- ---------------------------------------------------------------------------------------------
do $$
declare f text; v_def text; v_novo text;
begin
  foreach f in array array['api.titulos()', 'api.previsoes()', 'api.contratos()', 'api.aprovacoes()'] loop
    v_def := pg_get_functiondef(f::regprocedure);
    v_novo := replace(replace(v_def,
      '(select x.nome from erp.empresas em join erp.pessoas x', '(select coalesce(em.apelido, x.nome) from erp.empresas em join erp.pessoas x'),
      '(select pe.nome from erp.empresas em join erp.pessoas pe', '(select coalesce(em.apelido, pe.nome) from erp.empresas em join erp.pessoas pe');
    if v_novo = v_def then raise exception '%: ponto de troca não achado', f; end if;
    execute v_novo;
  end loop;

  -- Lançar título e Nova conta: a lista de empresas com o apelido (e a razão social ao lado), em ordem pelo apelido
  v_def := pg_get_functiondef('api.lancamento_opcoes()'::regprocedure);
  v_novo := replace(replace(v_def,
    $r$jsonb_build_object('id', e.id, 'nome', p.nome, 'documento', p.documento,$r$,
    $r$jsonb_build_object('id', e.id, 'nome', coalesce(e.apelido, p.nome), 'razao_social', p.nome, 'documento', p.documento,$r$),
    $r$order by p.nome)
                 from erp.empresas e$r$, $r$order by coalesce(e.apelido, p.nome))
                 from erp.empresas e$r$);
  if v_novo not like '%razao_social%' or v_novo not like '%order by coalesce(e.apelido, p.nome))%' then
    raise exception 'api.lancamento_opcoes: ponto de troca não achado';
  end if;
  execute v_novo;

  -- leitura da nota: a empresa achada pelo CNPJ do tomador
  v_def := pg_get_functiondef('api.identificar_nota(jsonb)'::regprocedure);
  v_novo := replace(v_def, $r$jsonb_build_object('id', e.id, 'nome', pe.nome, 'documento', pe.documento)$r$,
                           $r$jsonb_build_object('id', e.id, 'nome', coalesce(e.apelido, pe.nome), 'razao_social', pe.nome, 'documento', pe.documento)$r$);
  if v_novo = v_def then raise exception 'api.identificar_nota: ponto de troca não achado'; end if;
  execute v_novo;
end $$;

-- BI: a dimensão das empresas ganha o apelido (a razão social continua em "empresa")
create or replace view bi.d_empresa with (security_invoker = true, security_barrier = true) as
  select e.id as empresa_id, p.nome as empresa, p.nome_fantasia, e.tipo as empresa_tipo, p.documento as cnpj, e.ativa,
         e.apelido
    from erp.empresas e join erp.pessoas p on p.id = e.pessoa_id;

-- ---------------------------------------------------------------------------------------------
-- Cadastros › Empresas: a lista e o apelido
-- ---------------------------------------------------------------------------------------------
-- As empresas do grupo, com o que a tela mostra e se quem vê pode mudar o apelido.
create function api.empresas()
returns table (id uuid, apelido text, razao_social text, documento text, tipo text, ativa boolean, posso_apelido boolean)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select e.id, e.apelido, p.nome, p.documento, e.tipo, e.ativa,
         erp.sou_admin() or erp.estou_nas_listas(array['AF', 'AD'])
    from erp.empresas e join erp.pessoas p on p.id = e.pessoa_id
   order by not e.ativa, coalesce(e.apelido, p.nome) $$;

-- Dá, muda ou tira (vazio) o apelido; devolve o apelido gravado. A regra está no gatilho de erp.empresas.
create function api.salvar_apelido_empresa(p_empresa uuid, p_apelido text) returns text
language plpgsql volatile security invoker set search_path = pg_catalog, pg_temp as $$
declare v text;
begin
  if not (erp.sou_admin() or erp.estou_nas_listas(array['AF', 'AD'])) then
    raise exception 'Só AF, AD, o administrador e o master dão e mudam o apelido da empresa';
  end if;
  update erp.empresas set apelido = p_apelido where id = p_empresa returning apelido into v;
  if not found then raise exception 'Empresa não encontrada'; end if;
  return v;
end $$;

do $$
declare f regprocedure;
begin
  foreach f in array array['api.empresas()', 'api.salvar_apelido_empresa(uuid, text)']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
