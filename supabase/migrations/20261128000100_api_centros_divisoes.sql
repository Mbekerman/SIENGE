-- Centros e divisões montados na tela (Moises, 28/11/2026: "essas árvores precisam ser editáveis/construíveis dentro do
-- sistema. Tem que poder incluir novas divisões, galhos e troncos"). O banco já tinha as regras: o centro de custo (o
-- tronco) é cadastro do administrador; a divisão (o galho, até 4 níveis abaixo do centro) só se cria, renomeia e desativa
-- por pedido aprovado (erp.pedir_mudanca_acesso, S-101); as naturezas liberadas ficam só no último nível (o de cima é a
-- soma) e mudam na hora pelo master, administrador, AF, AO ou AD; os modelos de naturezas são listas salvas.
-- Esta migration só abre esse caminho à tela, pelo esquema api (SECURITY INVOKER: valem o RLS e os gatilhos de sempre):
--   api.centros_arvore()            tudo o que a tela mostra, numa chamada
--   api.criar_centro / alterar_centro / ligar_centro   o tronco, suas naturezas e os núcleos em que vale
--   api.pedir_divisao / decidir_pedido_divisao / cancelar_pedido_divisao   o galho, pelo pedido
--   api.salvar_naturezas            a lista do último nível (liga e desliga na hora)
--   api.salvar_modelo_naturezas     guarda a lista marcada como modelo
-- E fecha uma falta: o centro de custo não tinha auditoria nem a trava de não se apagar.
-- Mover galho de lugar continua recusado (tg_divisao): espera a decisão do Moises.

-- ---------------------------------------------------------------------------------------------
-- Centro de custo: não se apaga (desativa), nome sem espaços nas pontas, e auditoria
-- ---------------------------------------------------------------------------------------------
create function erp.tg_centro_custo() returns trigger language plpgsql as $$
begin
  if tg_op in ('DELETE', 'TRUNCATE') then raise exception 'Centro de custo não se apaga; desative'; end if;
  new.nome := trim(new.nome);
  if length(new.nome) = 0 then raise exception 'Diga o nome do centro de custo'; end if;
  if length(new.nome) > 60 then raise exception 'O nome do centro de custo tem até 60 caracteres'; end if;
  return new;
end $$;
create trigger t_centro_custo before insert or update or delete on erp.centros_custo
  for each row execute function erp.tg_centro_custo();
create trigger t_centro_custo_truncate before truncate on erp.centros_custo
  for each statement execute function erp.tg_centro_custo();
create trigger t_aud_centros_custo after insert or update on erp.centros_custo
  for each row execute function erp.tg_auditoria('id');
revoke execute on function erp.tg_centro_custo() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke execute on function erp.tg_centro_custo() from anon; end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Leitura: a árvore inteira, com o que cada um pode fazer
-- ---------------------------------------------------------------------------------------------
create function api.centros_arvore() returns jsonb language sql stable security invoker
set search_path = pg_catalog, pg_temp as $$
  select case when erp.membro() then jsonb_build_object(
    'pode', jsonb_build_object(
      'centro', erp.sou_admin(),                                   -- cria, renomeia, desativa e liga o tronco
      'divisao', erp.sou_admin(),                                  -- pede (o master faz na hora)
      'naturezas', erp.sou_admin() or erp.financeiro(),            -- liga e desliga na hora, e salva modelo
      'na_hora', erp.sou_master()),
    'centros', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'nome', c.nome, 'ativo', c.ativo,
        'nucleos', coalesce((select jsonb_agg(nc.nucleo_economico_id) from erp.nucleo_centros nc
                              where nc.centro_custo_id = c.id and nc.ligado), '[]'::jsonb),
        'naturezas', coalesce((select jsonb_agg(l.natureza_id) from erp.naturezas_liberadas l
                                where l.centro_custo_id = c.id and l.divisao_id is null), '[]'::jsonb))
        order by c.nome) from erp.centros_custo c), '[]'::jsonb),
    'divisoes', coalesce((select jsonb_agg(jsonb_build_object(
        'id', d.id, 'centro', d.centro_custo_id, 'mae', d.mae_id, 'nome', d.nome, 'ativa', d.ativa, 'nivel', d.nivel,
        'naturezas', coalesce((select jsonb_agg(l.natureza_id) from erp.naturezas_liberadas l
                                where l.centro_custo_id = d.centro_custo_id and l.divisao_id = d.id), '[]'::jsonb))
        order by d.nivel, d.nome) from erp.divisoes d), '[]'::jsonb),
    -- os pedidos de divisão ainda pendentes que a pessoa vê (o RLS de mudancas_acesso: quem gere acesso e quem pediu)
    'pedidos', coalesce((select jsonb_agg(jsonb_build_object(
        'id', m.id, 'operacao', m.operacao, 'dados', m.dados, 'antes', m.antes, 'motivo', m.motivo,
        'pedida_por', (select u.nome from erp.usuarios u where u.id = m.pedida_por), 'meu', m.pedida_por = erp.eu(),
        'pedida_em', m.pedida_em, 'minimo', m.minimo,
        'votos', (select count(*) from erp.mudanca_acesso_votos v where v.mudanca_id = m.id and v.aprova),
        'posso_decidir', m.pedida_por is distinct from erp.eu()
            and not exists (select 1 from erp.mudanca_acesso_votos v where v.mudanca_id = m.id and v.user_id = erp.eu())
            and (erp.sou_master()
                 or (m.aprovacao in ('lista', 'unanime') and exists (select 1 from erp.aprovadores_acesso a where a.user_id = erp.eu()))
                 or (m.aprovacao = 'delegado' and exists (select 1 from erp.delegados_acesso a where a.user_id = erp.eu()))))
        order by m.pedida_em)
        from erp.mudancas_acesso m where m.tabela = 'divisoes' and m.situacao = 'pendente'), '[]'::jsonb),
    'nucleos', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'nome', n.nome,
        'empresa', (select coalesce(e.apelido, p.nome) from erp.empresas e join erp.pessoas p on p.id = e.pessoa_id where e.id = n.empresa_id))
        order by n.nome) from erp.nucleos_economicos n where n.ativo), '[]'::jsonb),
    'naturezas', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'mae', v.mae_id, 'nome', v.nome, 'codigo', v.codigo,
        'caminho', v.caminho, 'folha', v.folha, 'ativa', v.ativa, 'nivel', v.nivel) order by v.ordem_caminho, v.nome)
        from erp.v_naturezas v), '[]'::jsonb),
    'modelos', coalesce((select jsonb_agg(jsonb_build_object('id', mo.id, 'nome', mo.nome,
        'naturezas', coalesce((select jsonb_agg(mn.natureza_id) from erp.modelo_naturezas mn where mn.modelo_id = mo.id), '[]'::jsonb))
        order by mo.nome) from erp.modelos_naturezas mo where mo.ativo), '[]'::jsonb))
  end $$;

-- ---------------------------------------------------------------------------------------------
-- Naturezas marcadas: só naturezas de último nível e ativas, sem repetição
-- ---------------------------------------------------------------------------------------------
create function api._naturezas_validas(p_naturezas uuid[]) returns uuid[] language plpgsql stable security invoker
set search_path = pg_catalog, pg_temp as $$
declare v uuid[];
begin
  select coalesce(array_agg(distinct x), '{}') into v from unnest(coalesce(p_naturezas, '{}')) x where x is not null;
  if exists (select 1 from unnest(v) x where not exists (select 1 from erp.naturezas n where n.id = x)) then
    raise exception 'Natureza não encontrada';
  end if;
  if exists (select 1 from unnest(v) x join erp.naturezas n on n.id = x where not n.ativa or not erp.natureza_folha(n.id)) then
    raise exception 'Só se liberam naturezas ativas do último nível';
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Tronco: o centro de custo
-- ---------------------------------------------------------------------------------------------
-- Cria o centro com a lista de naturezas (sem ela não se lança nada nele) e os núcleos em que vale.
create function api.criar_centro(p_nome text, p_naturezas uuid[], p_nucleos uuid[]) returns uuid language plpgsql
security invoker set search_path = pg_catalog, pg_temp as $$
declare v_id uuid; v_nat uuid[];
begin
  if not erp.sou_admin() then raise exception 'Só o administrador cria centro de custo'; end if;
  if exists (select 1 from erp.centros_custo where lower(nome) = lower(trim(coalesce(p_nome, '')))) then
    raise exception 'Já existe um centro de custo com este nome';
  end if;
  v_nat := api._naturezas_validas(p_naturezas);
  if cardinality(v_nat) = 0 then raise exception 'Marque as naturezas liberadas para lançamento no centro novo'; end if;
  insert into erp.centros_custo (nome) values (p_nome) returning id into v_id;
  insert into erp.naturezas_liberadas (centro_custo_id, natureza_id) select v_id, x from unnest(v_nat) x on conflict do nothing;
  insert into erp.nucleo_centros (nucleo_economico_id, centro_custo_id, ligado)
  select distinct x, v_id, true from unnest(coalesce(p_nucleos, '{}')) x where x is not null;
  return v_id;
end $$;

-- Renomeia, desativa ou reativa o centro (nulo = não muda).
create function api.alterar_centro(p_centro uuid, p_nome text, p_ativo boolean) returns void language plpgsql
security invoker set search_path = pg_catalog, pg_temp as $$
begin
  if not erp.sou_admin() then raise exception 'Só o administrador muda centro de custo'; end if;
  if p_nome is not null and exists (select 1 from erp.centros_custo where lower(nome) = lower(trim(p_nome)) and id <> p_centro) then
    raise exception 'Já existe um centro de custo com este nome';
  end if;
  update erp.centros_custo set nome = coalesce(p_nome, nome), ativo = coalesce(p_ativo, ativo) where id = p_centro;
  if not found then raise exception 'Centro de custo não encontrado'; end if;
end $$;

-- Liga ou desliga o centro num núcleo (desligar não apaga o histórico; só impede lançamento novo).
create function api.ligar_centro(p_centro uuid, p_nucleo uuid, p_ligado boolean) returns void language plpgsql
security invoker set search_path = pg_catalog, pg_temp as $$
begin
  if not erp.sou_admin() then raise exception 'Só o administrador liga e desliga centro de custo no núcleo'; end if;
  insert into erp.nucleo_centros (nucleo_economico_id, centro_custo_id, ligado) values (p_nucleo, p_centro, coalesce(p_ligado, false))
  on conflict (nucleo_economico_id, centro_custo_id) do update set ligado = excluded.ligado
   where erp.nucleo_centros.ligado is distinct from excluded.ligado;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Galho: a divisão, sempre pelo pedido (o master faz na hora; os outros esperam a aprovação)
-- ---------------------------------------------------------------------------------------------
-- p_operacao 'incluir' (centro_custo_id ou mae_id, nome, e naturezas ou copiar_de) ou 'alterar' (id, e nome ou ativa).
-- Devolve o pedido, a situação dele (aplicada ou pendente) e a divisão.
create function api.pedir_divisao(p_operacao text, p_dados jsonb, p_motivo text) returns jsonb language plpgsql
security invoker set search_path = pg_catalog, pg_temp as $$
declare v_dados jsonb := coalesce(p_dados, '{}'::jsonb); v_id uuid; v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if p_operacao not in ('incluir', 'alterar') then raise exception 'Divisão só se cria, renomeia, desativa ou reativa'; end if;
  if v_dados ? 'nome' then
    v_dados := jsonb_set(v_dados, '{nome}', to_jsonb(trim(v_dados->>'nome')));
    if length(v_dados->>'nome') = 0 then raise exception 'Diga o nome da divisão'; end if;
    if length(v_dados->>'nome') > 60 then raise exception 'O nome da divisão tem até 60 caracteres'; end if;
  end if;
  if p_operacao = 'incluir' then
    if not v_dados ? 'nome' then raise exception 'Diga o nome da divisão'; end if;
    if v_dados ? 'naturezas' then
      v_dados := jsonb_set(v_dados, '{naturezas}',
                           to_jsonb(api._naturezas_validas(array(select jsonb_array_elements_text(v_dados->'naturezas')::uuid))));
    end if;
    -- o mesmo nome no mesmo nível de cima já existe ou já foi pedido
    if exists (select 1 from erp.divisoes d
                where d.centro_custo_id = coalesce((select x.centro_custo_id from erp.divisoes x where x.id = (v_dados->>'mae_id')::uuid),
                                                   (v_dados->>'centro_custo_id')::uuid)
                  and d.mae_id is not distinct from (v_dados->>'mae_id')::uuid and lower(d.nome) = lower(v_dados->>'nome'))
       or exists (select 1 from erp.mudancas_acesso m where m.tabela = 'divisoes' and m.situacao = 'pendente' and m.operacao = 'incluir'
                     and m.dados->>'mae_id' is not distinct from v_dados->>'mae_id'
                     and (v_dados ? 'mae_id' or m.dados->>'centro_custo_id' = v_dados->>'centro_custo_id')
                     and lower(m.dados->>'nome') = lower(v_dados->>'nome')) then
      raise exception 'Já existe (ou já foi pedida) uma divisão com este nome no mesmo lugar';
    end if;
  end if;
  v_id := erp.pedir_mudanca_acesso('divisoes', p_operacao, v_dados,
                                   coalesce(v_motivo, case when erp.sou_master() then 'Pela tela Centros e divisões' end));
  return (select jsonb_build_object('pedido', m.id, 'situacao', m.situacao, 'divisao', m.dados->>'id')
            from erp.mudancas_acesso m where m.id = v_id);
end $$;

create function api.decidir_pedido_divisao(p_pedido uuid, p_aprova boolean, p_justificativa text) returns text language plpgsql
security invoker set search_path = pg_catalog, pg_temp as $$
begin
  if not exists (select 1 from erp.mudancas_acesso where id = p_pedido and tabela = 'divisoes') then
    raise exception 'Pedido de divisão não encontrado';
  end if;
  return erp.decidir_mudanca_acesso(p_pedido, p_aprova, nullif(trim(coalesce(p_justificativa, '')), ''));
end $$;

create function api.cancelar_pedido_divisao(p_pedido uuid) returns void language plpgsql
security invoker set search_path = pg_catalog, pg_temp as $$
begin
  if not exists (select 1 from erp.mudancas_acesso where id = p_pedido and tabela = 'divisoes') then
    raise exception 'Pedido de divisão não encontrado';
  end if;
  perform erp.cancelar_mudanca_acesso(p_pedido);
end $$;

-- ---------------------------------------------------------------------------------------------
-- Naturezas do último nível (ou do centro sem divisão): a lista inteira, como fica
-- ---------------------------------------------------------------------------------------------
-- Desliga as que saíram e liga as que entraram; as travas de sempre valem (nível com níveis abaixo é a soma; natureza
-- com contrato ativo não se desliga). Devolve quantas mudaram.
create function api.salvar_naturezas(p_centro uuid, p_divisao uuid, p_naturezas uuid[]) returns int language plpgsql
security invoker set search_path = pg_catalog, pg_temp as $$
declare v_nat uuid[]; n_sai int; n_entra int;
begin
  if not (erp.sou_admin() or erp.financeiro()) then
    raise exception 'Só o master, o administrador e AF, AO ou AD ligam e desligam naturezas';
  end if;
  if p_divisao is not null and not exists (select 1 from erp.divisoes where id = p_divisao and centro_custo_id = p_centro) then
    raise exception 'A divisão não é deste centro de custo';
  end if;
  if p_divisao is null and not exists (select 1 from erp.centros_custo where id = p_centro) then
    raise exception 'Centro de custo não encontrado';
  end if;
  if (p_divisao is null and exists (select 1 from erp.divisoes where centro_custo_id = p_centro and ativa))
     or (p_divisao is not null and not erp.divisao_folha(p_divisao)) then
    raise exception 'Este nível tem níveis abaixo: as naturezas dele são a soma das de baixo';
  end if;
  v_nat := api._naturezas_validas(p_naturezas);
  -- só confere ativa e último nível das que entram; as que já estavam (e uma natureza que virou galho) só podem sair
  delete from erp.naturezas_liberadas l
   where l.centro_custo_id = p_centro and l.divisao_id is not distinct from p_divisao and not (l.natureza_id = any (v_nat));
  get diagnostics n_sai = row_count;
  insert into erp.naturezas_liberadas (centro_custo_id, divisao_id, natureza_id)
  select p_centro, p_divisao, x from unnest(v_nat) x on conflict do nothing;
  get diagnostics n_entra = row_count;
  return n_sai + n_entra;
end $$;

-- Guarda a lista marcada como modelo, para aplicar em outro nível depois.
create function api.salvar_modelo_naturezas(p_nome text, p_naturezas uuid[]) returns uuid language plpgsql
security invoker set search_path = pg_catalog, pg_temp as $$
declare v_id uuid; v_nat uuid[] := api._naturezas_validas(p_naturezas); v_nome text := trim(coalesce(p_nome, ''));
begin
  if not (erp.sou_admin() or erp.financeiro()) then
    raise exception 'Só o master, o administrador e AF, AO ou AD salvam modelos de naturezas';
  end if;
  if length(v_nome) = 0 then raise exception 'Diga o nome do modelo'; end if;
  if length(v_nome) > 60 then raise exception 'O nome do modelo tem até 60 caracteres'; end if;
  if cardinality(v_nat) = 0 then raise exception 'O modelo precisa de pelo menos uma natureza'; end if;
  if exists (select 1 from erp.modelos_naturezas where lower(nome) = lower(v_nome)) then
    raise exception 'Já existe um modelo com este nome';
  end if;
  insert into erp.modelos_naturezas (nome) values (v_nome) returning id into v_id;
  insert into erp.modelo_naturezas (modelo_id, natureza_id) select v_id, x from unnest(v_nat) x;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Segurança: só o usuário logado executa
-- ---------------------------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array['api.centros_arvore()', 'api._naturezas_validas(uuid[])', 'api.criar_centro(text, uuid[], uuid[])',
                           'api.alterar_centro(uuid, text, boolean)', 'api.ligar_centro(uuid, uuid, boolean)',
                           'api.pedir_divisao(text, jsonb, text)', 'api.decidir_pedido_divisao(uuid, boolean, text)',
                           'api.cancelar_pedido_divisao(uuid)', 'api.salvar_naturezas(uuid, uuid, uuid[])',
                           'api.salvar_modelo_naturezas(text, uuid[])'] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
