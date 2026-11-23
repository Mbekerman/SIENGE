-- bkm_dev, 23/nov/2026: orçamento de área (PR #122, migration 20261123002000). Colar inteiro no SQL Editor.
-- v3 (23/nov, 21h30): as funções trocadas são recriadas inteiras (definição final da develop), depois de conferir que a
-- versão no banco é a esperada, sem contar comentários e espaços. A v1 e a v2 falharam no editor procurando trechos
-- de texto (o bkm_dev tem as funções com CRLF e uma sem um comentário). Conferido contra o pg_get_functiondef do bkm_dev.
-- Se algo falhar, dá erro e nada fica. O corpo é o mesmo da migration; o script só se dá os papéis donos das funções
-- (sem herdar, só set) durante a transação e os tira antes do commit.
begin;
grant erp_conferencia, erp_situacao, erp_acesso to current_user with inherit false, set true;
-- erp_sistema: no bkm_dev o postgres já o tem para sempre (set true, inherit false, dado em 17/11 e usado pelo envio
-- ao Sienge). Só dá (e tira no fim) se ainda não tiver; nunca mexe no grant que já existe (revisão de segurança do #122).
do $$ begin
  if not exists (select 1 from pg_auth_members where roleid = 'erp_sistema'::regrole and member = current_user::regrole and set_option) then
    execute format('grant erp_sistema to %I with inherit false, set true', current_user);
    perform set_config('bkm.tirar_erp_sistema', 'sim', true);
  end if;
end $$;

-- Orçamento de área (Moises, 23/nov/2026: "temos que ter uma criação de Orçamento, sem necessariamente estar atrelado a
-- fornecedores. Somente a Centro de custos (e seu nível) e conta financeira, pra poder lançar provisão de despesas").
--
-- Decisões do Moises no mesmo dia:
--   - Um orçamento por núcleo econômico × centro de custo e ano, com linhas por natureza, nível do centro (o próprio
--     centro ou qualquer divisão, inclusive um nível com filhos, que soma os de baixo) e mês.
--   - Cria e revisa o gestor do centro (ou o master). Aprova a AF junto com um AO ligado ao centro, ou o AD sozinho
--     (o master também). Quem montou ou mexeu por último não aprova (o master pode).
--   - É informativo: não pré-aprova nada. O título que passa do orçado segue a alçada normal. As previsões do
--     orçamento ficam fora do acumulado do mês da alçada.
--   - O orçamento aprovado vira previsões a pagar sem fornecedor, uma por linha, do mês corrente em diante, e cada
--     uma vira um PRV no Sienge (todos os meses, não só os próximos 3).
--   - O título abate o orçado sozinho: a nota consome a previsão do orçamento da mesma natureza e do mesmo mês, no
--     nível da linha do rateio ou num nível acima dele (o mais fundo primeiro). Quem lança pode marcar a nota como
--     fora do orçamento, com o motivo.
--   - A previsão aberta de cada linha vale sempre o orçado menos o consumido. Quando um título consome, é cancelado
--     ou o orçamento é revisado, a previsão daquela linha é refeita na hora (no fim da transação): a antiga é
--     encerrada e vai para a lista de PRV a apagar no Sienge, e nasce outra com o saldo, se houver. Linha que não
--     mudou fica como está. O Sienge não aceita título com valor negativo (bill-debt-v1.yaml, totalInvoiceAmount
--     mínimo 0,01).
--   - A sobra de cada mês sai depois de uma carência (padrão 10 dias depois do fim do mês, configurável).
--   - Os meses que já passaram não mudam na revisão.
--   - A vaga "AO do centro" (AO_CENTRO) também entra nas faixas da alçada de pagamento, como opção: só os AO ligados
--     ao centro a ocupam (o AD também). A vaga "AO" continua sendo de qualquer AO.
--
-- Fica de fora nesta versão: título sem nota (avulso) não consome previsão (como antes); título lançado antes da
-- aprovação do orçamento, ou de uma linha nova na revisão, não abate o orçado; o aviso de orçamento enviado vai a
-- todos os AO (a aprovação, só aos do centro).
--
-- O mesmo corpo roda no bkm_dev (supabase/dev/ com o mesmo nome), onde o postgres não é superusuário: as trocas de
-- função de outro dono passam por pg_temp.recriar (função inteira, depois de conferir a versão), a troca de dono por pg_temp.dono e os gatilhos da auditoria por
-- pg_temp.auditar, que assumem o papel certo e dão o create no esquema só durante a troca.

-- ---------------------------------------------------------------------------------------------
-- 0. Ferramentas da migration (só nesta sessão)
-- ---------------------------------------------------------------------------------------------
-- Recria a função inteira como o dono dela, se a versão no banco for a esperada.
create function pg_temp.recriar(p_fn regprocedure, p_esperado text, p_def text) returns void language plpgsql as $$
declare v_dono text; v_esq text; v_dar boolean;
begin
  -- confere a versão atual (sem comentários, espaços e quebras de linha, que o editor do Supabase pode mudar) e
  -- recria a função inteira; não depende de achar trechos no texto dela
  if md5(regexp_replace(regexp_replace(pg_get_functiondef(p_fn), '--[^' || chr(10) || ']*', '', 'g'), '\s+', '', 'g')) <> p_esperado then
    raise exception '%: a versão no banco não é a esperada (falta migration anterior?); nada foi mudado', p_fn;
  end if;
  select pg_get_userbyid(p.proowner), n.nspname into v_dono, v_esq
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.oid = p_fn;
  if v_dono = current_user then execute p_def; return; end if;
  v_dar := not has_schema_privilege(v_dono, v_esq, 'create');
  if v_dar then execute format('grant create on schema %I to %I', v_esq, v_dono); end if;
  execute format('set local role %I', v_dono);
  execute p_def;
  reset role;
  if v_dar then execute format('revoke create on schema %I from %I', v_esq, v_dono); end if;
end $$;
-- Passa a função ao dono (que precisa do create no esquema só durante a troca).
create function pg_temp.dono(p_fn regprocedure, p_dono text) returns void language plpgsql as $$
declare v_esq text := (select n.nspname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.oid = p_fn);
        v_dar boolean := not has_schema_privilege(p_dono, v_esq, 'create');
begin
  if v_dar then execute format('grant create on schema %I to %I', v_esq, p_dono); end if;
  execute format('alter function %s owner to %I', p_fn, p_dono);
  if v_dar then execute format('revoke create on schema %I from %I', v_esq, p_dono); end if;
end $$;
-- O gatilho da auditoria é criado como erp_conferencia, com o direito de gatilho só durante a criação.
create function pg_temp.auditar(p_tabela text, p_chave text) returns void language plpgsql as $$
begin
  execute format('grant trigger on erp.%I to erp_conferencia', p_tabela);
  set local role erp_conferencia;
  execute format('create trigger %I after insert or update or delete on erp.%I for each row execute function erp.tg_auditoria(%L)',
                 't_aud_' || p_tabela, p_tabela, p_chave);
  reset role;
  execute format('revoke trigger on erp.%I from erp_conferencia', p_tabela);
end $$;
-- Tabela nova: RLS forçado, as políticas de sempre, sem truncate e os grants dos papéis do banco.
create function pg_temp.tabela(t text) returns void language plpgsql as $$
begin
  execute format('revoke all on erp.%I from public', t);
  if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on erp.%I from anon', t); end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke all on erp.%I from service_role', t); end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('revoke all on erp.%I from authenticated', t); end if;
  execute format('alter table erp.%I enable row level security', t);
  execute format('alter table erp.%I force row level security', t);
  execute format('create policy sistema on erp.%I using (erp.sistema()) with check (erp.sistema())', t);
  execute format('create policy conferencia on erp.%I for select to erp_conferencia using (true)', t);
  execute format('create policy operacao on erp.%I to erp_situacao, erp_reclassificacao, erp_acesso using (true) with check (true)', t);
  execute format('create trigger t_nao_trunca before truncate on erp.%I for each statement execute function erp.tg_recusa_truncate()', t);
  execute format('grant select, insert, update, delete on erp.%I to erp_sistema, erp_situacao, erp_reclassificacao, erp_acesso', t);
  execute format('grant select on erp.%I to erp_conferencia', t);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 1. AO ligado a centros e a vaga "AO do centro"
-- ---------------------------------------------------------------------------------------------
alter table erp.listas_financeiro add column centros uuid[] not null default '{}',
  add constraint listas_financeiro_centros_ao check (lista = 'AO' or cardinality(centros) = 0);
comment on column erp.listas_financeiro.centros is
  'Só no AO: os centros de custo a que ele está ligado (aprova o orçamento desses centros e ocupa a vaga AO_CENTRO deles)';

create function erp.tg_lista_centros() returns trigger language plpgsql as $$
begin
  if exists (select 1 from unnest(new.centros) c where c is null or not exists (select 1 from erp.centros_custo x where x.id = c)) then
    raise exception 'Centro de custo do AO não existe';
  end if;
  new.centros := coalesce((select array_agg(distinct c order by c) from unnest(new.centros) c), '{}');
  return new;
end $$;
create trigger t_lista_centros before insert or update of centros on erp.listas_financeiro
  for each row execute function erp.tg_lista_centros();

-- o pedido de acesso aprovado grava os centros do AO (na alteração, sem a chave "centros", ficam os de antes)
select pg_temp.recriar('erp._aplicar_mudanca_acesso(uuid)'::regprocedure, 'b3c1708f96e8f23b276781830544880c', $def$CREATE OR REPLACE FUNCTION erp._aplicar_mudanca_acesso(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'erp', 'pg_catalog', 'pg_temp'
AS $function$
declare m erp.mudancas_acesso; d jsonb;
begin
  select * into m from erp.mudancas_acesso where id = p_id for update;
  d := m.dados;
  if m.operacao <> 'incluir' and erp._linha_acesso(m.tabela, d) is distinct from m.antes then
    update erp.mudancas_acesso set situacao = 'obsoleta', encerrada_em = clock_timestamp() where id = p_id;
    return;
  end if;
  case m.tabela
  when 'perfis_modelo' then
    if m.operacao = 'incluir' then insert into erp.perfis_modelo select * from jsonb_populate_record(null::erp.perfis_modelo, d || jsonb_build_object('ativo', coalesce((d->>'ativo')::boolean, true)));
    elsif m.operacao = 'alterar' then update erp.perfis_modelo t set nome = r.nome, descricao = r.descricao, ativo = r.ativo from jsonb_populate_record(null::erp.perfis_modelo, d) r where t.id = r.id;
    else delete from erp.perfis_modelo where id = (d->>'id')::uuid; end if;
  when 'perfil_centros' then
    -- a data de criação é sempre a de quando vale (é o corte das divisões futuras)
    if m.operacao = 'incluir' then
      insert into erp.perfil_centros (perfil_id, centro_custo_id, nivel, divisoes, divisoes_futuras)
      select r.perfil_id, r.centro_custo_id, r.nivel, coalesce(r.divisoes, 'todas'), coalesce(r.divisoes_futuras, false)
        from jsonb_populate_record(null::erp.perfil_centros, d) r;
    elsif m.operacao = 'alterar' then update erp.perfil_centros t set nivel = r.nivel, divisoes = r.divisoes, divisoes_futuras = r.divisoes_futuras from jsonb_populate_record(null::erp.perfil_centros, d) r where t.perfil_id = r.perfil_id and t.centro_custo_id = r.centro_custo_id;
    else delete from erp.perfil_centros where perfil_id = (d->>'perfil_id')::uuid and centro_custo_id = (d->>'centro_custo_id')::uuid; end if;
  when 'perfil_centro_divisoes' then
    if m.operacao = 'incluir' then insert into erp.perfil_centro_divisoes select * from jsonb_populate_record(null::erp.perfil_centro_divisoes, d);
    elsif m.operacao = 'alterar' then update erp.perfil_centro_divisoes t set incluir = r.incluir, nivel = r.nivel from jsonb_populate_record(null::erp.perfil_centro_divisoes, d) r where t.perfil_id = r.perfil_id and t.divisao_id = r.divisao_id;
    else delete from erp.perfil_centro_divisoes where perfil_id = (d->>'perfil_id')::uuid and divisao_id = (d->>'divisao_id')::uuid; end if;
  when 'divisoes' then
    if m.operacao = 'incluir' then
      insert into erp.divisoes (id, centro_custo_id, mae_id, nome, ativa)
      values ((d->>'id')::uuid,
              coalesce((d->>'centro_custo_id')::uuid, (select centro_custo_id from erp.divisoes where id = (d->>'mae_id')::uuid)),
              (d->>'mae_id')::uuid, d->>'nome', coalesce((d->>'ativa')::boolean, true));
      if d ? 'copiar_de' then
        insert into erp.naturezas_liberadas (centro_custo_id, divisao_id, natureza_id)
        select l.centro_custo_id, (d->>'id')::uuid, l.natureza_id from erp.naturezas_liberadas l, erp._origem_naturezas(d) o
         where l.centro_custo_id = o.o_centro and l.divisao_id is not distinct from o.o_divisao;
      else
        insert into erp.naturezas_liberadas (centro_custo_id, divisao_id, natureza_id)
        select distinct (select centro_custo_id from erp.divisoes where id = (d->>'id')::uuid), (d->>'id')::uuid, n::uuid
          from jsonb_array_elements_text(d->'naturezas') n
        on conflict do nothing;
      end if;
      -- o nível de cima (ou o centro) deixa de ter lista: vale a soma das de baixo
      delete from erp.naturezas_liberadas
       where centro_custo_id = (select centro_custo_id from erp.divisoes where id = (d->>'id')::uuid)
         and divisao_id is not distinct from (d->>'mae_id')::uuid;
    else update erp.divisoes set nome = d->>'nome', ativa = (d->>'ativa')::boolean where id = (d->>'id')::uuid; end if;
  when 'perfil_naturezas' then
    if m.operacao = 'incluir' then insert into erp.perfil_naturezas select * from jsonb_populate_record(null::erp.perfil_naturezas, d);
    elsif m.operacao = 'excluir' then delete from erp.perfil_naturezas where perfil_id = (d->>'perfil_id')::uuid and natureza_id = (d->>'natureza_id')::uuid;
    else raise exception 'Linha de natureza do modelo não se altera: exclua e inclua'; end if;
  when 'atribuicoes' then
    if m.operacao = 'incluir' then
      insert into erp.atribuicoes (id, user_id, perfil_id, escopo, inicio, fim)
      select r.id, r.user_id, r.perfil_id, r.escopo, coalesce((d->>'inicio')::date, current_date), r.fim
        from jsonb_populate_record(null::erp.atribuicoes, d) r;
    elsif m.operacao = 'alterar' then update erp.atribuicoes t set perfil_id = r.perfil_id, escopo = r.escopo, inicio = r.inicio, fim = r.fim from jsonb_populate_record(null::erp.atribuicoes, d) r where t.id = r.id;
    else delete from erp.atribuicoes where id = (d->>'id')::uuid; end if;
  when 'atribuicao_tipos' then
    if m.operacao = 'incluir' then insert into erp.atribuicao_tipos select * from jsonb_populate_record(null::erp.atribuicao_tipos, d);
    elsif m.operacao = 'excluir' then delete from erp.atribuicao_tipos where atribuicao_id = (d->>'atribuicao_id')::uuid and tipo_nucleo = d->>'tipo_nucleo';
    else raise exception 'Tipo da atribuição não se altera: exclua e inclua'; end if;
  when 'atribuicao_nucleos' then
    if m.operacao = 'incluir' then insert into erp.atribuicao_nucleos select * from jsonb_populate_record(null::erp.atribuicao_nucleos, d);
    elsif m.operacao = 'alterar' then update erp.atribuicao_nucleos t set incluir = r.incluir from jsonb_populate_record(null::erp.atribuicao_nucleos, d) r where t.atribuicao_id = r.atribuicao_id and t.nucleo_economico_id = r.nucleo_economico_id;
    else delete from erp.atribuicao_nucleos where atribuicao_id = (d->>'atribuicao_id')::uuid and nucleo_economico_id = (d->>'nucleo_economico_id')::uuid; end if;
  when 'excecoes_centro' then
    if m.operacao = 'incluir' then insert into erp.excecoes_centro select * from jsonb_populate_record(null::erp.excecoes_centro, d);
    elsif m.operacao = 'alterar' then update erp.excecoes_centro t set nivel = r.nivel, fim = r.fim from jsonb_populate_record(null::erp.excecoes_centro, d) r where t.user_id = r.user_id and t.nucleo_economico_id = r.nucleo_economico_id and t.centro_custo_id = r.centro_custo_id;
    else delete from erp.excecoes_centro where user_id = (d->>'user_id')::uuid and nucleo_economico_id = (d->>'nucleo_economico_id')::uuid and centro_custo_id = (d->>'centro_custo_id')::uuid; end if;
  when 'excecoes_divisao' then
    if m.operacao = 'incluir' then insert into erp.excecoes_divisao select * from jsonb_populate_record(null::erp.excecoes_divisao, d);
    elsif m.operacao = 'alterar' then update erp.excecoes_divisao t set nivel = r.nivel, fim = r.fim from jsonb_populate_record(null::erp.excecoes_divisao, d) r where t.user_id = r.user_id and t.nucleo_economico_id = r.nucleo_economico_id and t.divisao_id = r.divisao_id;
    else delete from erp.excecoes_divisao where user_id = (d->>'user_id')::uuid and nucleo_economico_id = (d->>'nucleo_economico_id')::uuid and divisao_id = (d->>'divisao_id')::uuid; end if;
  when 'excecoes_natureza' then
    if m.operacao = 'incluir' then insert into erp.excecoes_natureza select * from jsonb_populate_record(null::erp.excecoes_natureza, d);
    elsif m.operacao = 'alterar' then update erp.excecoes_natureza t set efeito = r.efeito, fim = r.fim from jsonb_populate_record(null::erp.excecoes_natureza, d) r where t.id = r.id;
    else delete from erp.excecoes_natureza where id = (d->>'id')::uuid; end if;
  when 'centro_diretores' then
    if m.operacao = 'incluir' then insert into erp.centro_diretores select * from jsonb_populate_record(null::erp.centro_diretores, d);
    elsif m.operacao = 'excluir' then delete from erp.centro_diretores where centro_custo_id = (d->>'centro_custo_id')::uuid and user_id = (d->>'user_id')::uuid;
    else raise exception 'Diretor da área não se altera: exclua e inclua'; end if;
  when 'centro_aprovadores' then
    if m.operacao = 'incluir' then insert into erp.centro_aprovadores select * from jsonb_populate_record(null::erp.centro_aprovadores, d);
    elsif m.operacao = 'excluir' then delete from erp.centro_aprovadores where centro_custo_id = (d->>'centro_custo_id')::uuid and user_id = (d->>'user_id')::uuid;
    else raise exception 'Gestor da área não se altera: exclua e inclua'; end if;
  when 'listas_financeiro' then
    if m.operacao = 'incluir' then
      insert into erp.listas_financeiro (lista, user_id, aprova_proprio, avisa_proprio, centros)
      select r.lista, r.user_id, coalesce(r.aprova_proprio, false), coalesce(r.avisa_proprio, true), coalesce(r.centros, '{}')
        from jsonb_populate_record(null::erp.listas_financeiro, d) r;
    elsif m.operacao = 'excluir' then delete from erp.listas_financeiro where lista = d->>'lista' and user_id = (d->>'user_id')::uuid;
    else update erp.listas_financeiro t set aprova_proprio = r.aprova_proprio, avisa_proprio = r.avisa_proprio, centros = coalesce(r.centros, t.centros)
           from jsonb_populate_record(null::erp.listas_financeiro, d) r where t.lista = r.lista and t.user_id = r.user_id; end if;
  when 'tipos_nucleo' then
    if m.operacao = 'incluir' then
      insert into erp.tipos_nucleo (codigo, nome, exige_empreendimento, ativo)
      select r.codigo, r.nome, coalesce(r.exige_empreendimento, false), coalesce(r.ativo, true) from jsonb_populate_record(null::erp.tipos_nucleo, d) r;
    elsif m.operacao = 'alterar' then update erp.tipos_nucleo t set nome = r.nome, exige_empreendimento = r.exige_empreendimento, ativo = r.ativo from jsonb_populate_record(null::erp.tipos_nucleo, d) r where t.codigo = r.codigo;
    else delete from erp.tipos_nucleo where codigo = d->>'codigo'; end if;
  when 'aprovadores_acesso' then
    if m.operacao = 'incluir' then insert into erp.aprovadores_acesso values ((d->>'user_id')::uuid);
    elsif m.operacao = 'excluir' then delete from erp.aprovadores_acesso where user_id = (d->>'user_id')::uuid;
    else raise exception 'Aprovador de acesso não se altera: exclua e inclua'; end if;
  when 'regra_acesso' then update erp.regra_acesso set minimo = (d->>'minimo')::int, sucessao_dias = (d->>'sucessao_dias')::int;
  when 'naturezas' then update erp.naturezas set restrita = (d->>'restrita')::boolean, mae_id = (d->>'mae_id')::uuid where id = (d->>'id')::uuid;
  when 'nucleos_economicos' then update erp.nucleos_economicos set tipo = d->>'tipo' where id = (d->>'id')::uuid;
  when 'usuarios' then update erp.usuarios set papel = d->>'papel', contador = (d->>'contador')::boolean, ativo = (d->>'ativo')::boolean where id = (d->>'id')::uuid;
  end case;
  update erp.mudancas_acesso set situacao = 'aplicada', encerrada_em = clock_timestamp() where id = p_id;
end $function$$def$);

-- a vaga AO_CENTRO: o AO ligado ao centro (ou o AD)
select pg_temp.recriar('erp._ocupa_vaga(text, uuid, uuid)'::regprocedure, '346cc9eb190d0cbbce8abb4b26d0601d', $def$CREATE OR REPLACE FUNCTION erp._ocupa_vaga(p_vaga text, p_centro uuid, p_user uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
AS $function$
begin
  if not exists (select 1 from erp.usuarios where id = p_user and ativo and not administrador and not so_sucessao) then return false; end if;
  return case
    when p_vaga = 'AREA' then exists (select 1 from erp.centro_aprovadores where centro_custo_id = p_centro and user_id = p_user)
    when p_vaga = 'DIRETOR_AREA' then exists (select 1 from erp.centro_diretores where centro_custo_id = p_centro and user_id = p_user)
    when p_vaga in ('AF','AO') then exists (select 1 from erp.listas_financeiro where lista in (p_vaga, 'AD') and user_id = p_user)
    when p_vaga = 'AO_CENTRO' then exists (select 1 from erp.listas_financeiro
                                            where user_id = p_user and (lista = 'AD' or (lista = 'AO' and p_centro = any(centros))))
    when p_vaga = 'AD' then exists (select 1 from erp.listas_financeiro where lista = 'AD' and user_id = p_user)
    when p_vaga = 'PJ' then erp.ve_pj(p_user)          -- o master ou um designado (Moises, 18/11/2026)
    when p_vaga like 'P:%' then substr(p_vaga, 3)::uuid = p_user
    else false end;
end $function$$def$);
select pg_temp.recriar('erp.tg_alcada_vagas()'::regprocedure, '7a3069eda4463f02de2de39d5a21fb73', $def$CREATE OR REPLACE FUNCTION erp.tg_alcada_vagas()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare e text; v_user uuid;
begin
  if tg_op = 'DELETE' then return old; end if;
  foreach e in array new.fases loop
    if e in ('AREA','DIRETOR_AREA','AF','AO','AO_CENTRO','AD') then continue; end if;
    if e !~ '^P:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'Vaga de aprovação inválida: % (use AREA, DIRETOR_AREA, AF, AO, AO_CENTRO, AD ou P: e o usuário)', e;
    end if;
    v_user := substr(e, 3)::uuid;
    if not exists (select 1 from erp.usuarios where id = v_user) then raise exception 'Aprovador da vaga não existe: %', v_user; end if;
    perform erp.recusar_admin_aprovador(v_user);
    perform erp.recusar_so_sucessao(v_user);
  end loop;
  if (select count(*) from unnest(new.fases) x where x like 'P:%') <> (select count(distinct x) from unnest(new.fases) x where x like 'P:%') then
    raise exception 'A mesma pessoa não ocupa duas vagas da faixa';
  end if;
  return new;
end $function$$def$);

-- ---------------------------------------------------------------------------------------------
-- 2. Carência da sobra do mês
-- ---------------------------------------------------------------------------------------------
alter table erp.regra_alcada_pagamento
  add column orcamento_carencia_dias int not null default 10 check (orcamento_carencia_dias between 0 and 60);
comment on column erp.regra_alcada_pagamento.orcamento_carencia_dias is
  'Dias depois do fim do mês em que a sobra do orçamento de área sai das previsões (e o PRV vai para a lista de apagar)';

-- ---------------------------------------------------------------------------------------------
-- 3. Versão e linhas do orçamento de área
-- ---------------------------------------------------------------------------------------------
alter table erp.orcamento_versoes drop constraint orcamento_versoes_tipo_check,
  add constraint orcamento_versoes_tipo_check check (tipo in ('viabilidade','aprovado','reprojecao','area')),
  add column nucleo_economico_id uuid references erp.nucleos_economicos,
  add column centro_custo_id     uuid references erp.centros_custo,
  add column ano                 int check (ano between 2000 and 2100),
  add column substitui_id        uuid references erp.orcamento_versoes,
  add column enviado_em          timestamptz,     -- mandado para aprovar (nulo: em montagem; a mudança e a recusa zeram)
  add column alterado_em         timestamptz,
  add column alterado_por        uuid,
  add constraint orcamento_versoes_area check ((tipo = 'area') = (nucleo_economico_id is not null and centro_custo_id is not null and ano is not null)),
  add constraint orcamento_versoes_area_obra check (tipo <> 'area' or empreendimento_id is null),
  add constraint orcamento_versoes_envio check (tipo = 'area' or (enviado_em is null and substitui_id is null));
create unique index orcamento_area_vigente on erp.orcamento_versoes (nucleo_economico_id, centro_custo_id, ano)
  where tipo = 'area' and situacao = 'vigente';
create unique index orcamento_area_rascunho on erp.orcamento_versoes (nucleo_economico_id, centro_custo_id, ano)
  where tipo = 'area' and situacao = 'rascunho';
create unique index orcamento_linhas_chave on erp.orcamento_linhas
  (versao_id, natureza_id, coalesce(subdivisao_id, divisao_id, '00000000-0000-0000-0000-000000000000'), competencia);

-- Só as operações do orçamento de área (definer erp_situacao) gravam a versão e as linhas dele.
create function erp.tg_orcamento_area() returns trigger language plpgsql as $$
declare v_tipo text;
begin
  if tg_table_name = 'orcamento_versoes' then
    v_tipo := coalesce(to_jsonb(new) ->> 'tipo', to_jsonb(old) ->> 'tipo');
    if tg_op = 'UPDATE' and to_jsonb(new) ->> 'tipo' <> to_jsonb(old) ->> 'tipo' then raise exception 'O tipo do orçamento não muda'; end if;
  else
    v_tipo := (select tipo from erp.orcamento_versoes where id = coalesce((to_jsonb(new) ->> 'versao_id')::uuid, (to_jsonb(old) ->> 'versao_id')::uuid));
    if tg_op = 'UPDATE' and to_jsonb(new) ->> 'versao_id' <> to_jsonb(old) ->> 'versao_id' then raise exception 'A linha do orçamento não muda de versão'; end if;
  end if;
  if v_tipo = 'area' and not erp.agindo_como('erp_situacao') then
    raise exception 'O orçamento de área só muda pelas operações dele (criar, salvar, enviar e decidir)';
  end if;
  if tg_table_name = 'orcamento_versoes' and tg_op = 'UPDATE' then
    if (to_jsonb(new) -> 'nucleo_economico_id', to_jsonb(new) -> 'centro_custo_id', to_jsonb(new) -> 'ano', to_jsonb(new) -> 'substitui_id')
       is distinct from
       (to_jsonb(old) -> 'nucleo_economico_id', to_jsonb(old) -> 'centro_custo_id', to_jsonb(old) -> 'ano', to_jsonb(old) -> 'substitui_id') then
      raise exception 'Núcleo, centro, ano e versão substituída do orçamento não mudam';
    end if;
  end if;
  return coalesce(new, old);
end $$;
create trigger t_orcamento_area before insert or update or delete on erp.orcamento_versoes
  for each row execute function erp.tg_orcamento_area();
create trigger t_orcamento_area before insert or update or delete on erp.orcamento_linhas
  for each row execute function erp.tg_orcamento_area();

-- o orçamento de obra continua publicado à mão; o de área, só pela aprovação
select pg_temp.recriar('erp.publicar_orcamento(uuid)'::regprocedure, '13f8fb619eebcc7da89da2ee5662e1b2', $def$CREATE OR REPLACE FUNCTION erp.publicar_orcamento(p_versao uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'erp', 'pg_catalog', 'pg_temp'
AS $function$
declare v erp.orcamento_versoes;
begin
  perform erp.exigir_editor();
  if not erp.sistema() and exists (select 1 from erp.orcamento_linhas l where l.versao_id = p_versao
                                     and not erp.lanco(l.nucleo_economico_id, l.centro_custo_id, l.natureza_id, null, l.divisao_id)) then
    raise exception 'Você não lança em todas as linhas deste orçamento';
  end if;
  select * into v from erp.orcamento_versoes where id = p_versao for update;
  if v.situacao <> 'rascunho' then raise exception 'Só se publica versão em rascunho'; end if;
  if v.tipo = 'area' then raise exception 'O orçamento de área é publicado pela aprovação'; end if;
  update erp.orcamento_versoes set situacao = 'substituida'
   where empresa_id = v.empresa_id and empreendimento_id is not distinct from v.empreendimento_id
     and tipo = v.tipo and situacao = 'vigente' and tipo <> 'reprojecao';
  insert into erp.lancamentos (estagio, orcamento_versao_id, empresa_id, nucleo_economico_id, natureza_id,
                                  centro_custo_id, divisao_id, subdivisao_id, competencia, data_caixa, valor, orcamento_linha_id)
  select 'orcado', v.id, v.empresa_id, l.nucleo_economico_id, l.natureza_id, l.centro_custo_id, l.divisao_id, l.subdivisao_id,
         l.competencia, l.data_caixa, l.valor, l.id
  from erp.orcamento_linhas l where l.versao_id = v.id;
  update erp.orcamento_versoes set situacao = 'vigente' where id = v.id;
end $function$$def$);

-- ---------------------------------------------------------------------------------------------
-- 4. A previsão do orçamento
-- ---------------------------------------------------------------------------------------------
alter table erp.previsoes add column orcamento_linha_id uuid references erp.orcamento_linhas,
  add constraint previsoes_orcamento check (orcamento_linha_id is null or (origem = 'orcamento' and pessoa_id is null
                                                                             and compromisso_id is null and sentido = 'pagar'));
create index previsoes_orcamento_abertas on erp.previsoes (centro_custo_id, natureza_id, competencia)
  where orcamento_linha_id is not null and situacao = 'aberta';

-- A previsão do orçamento nasce, se encerra e muda só pelo orçamento (nem cancelar à mão nem reclassificar).
select pg_temp.recriar('erp.tg_previsao_guarda()'::regprocedure, '7f4cbca6f3e3d700ef49f28848d71d35', $def$CREATE OR REPLACE FUNCTION erp.tg_previsao_guarda()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if tg_op = 'INSERT' then
    if new.situacao <> 'aberta' then raise exception 'Previsão nasce aberta'; end if;
    if new.orcamento_linha_id is not null and not erp.agindo_como('erp_situacao') then
      raise exception 'A previsão do orçamento de área nasce da aprovação do orçamento';
    end if;
    return new;
  end if;
  if (to_jsonb(new) - 'situacao' - 'natureza_id') <> (to_jsonb(old) - 'situacao' - 'natureza_id') then
    raise exception 'Previsão não se edita; cancele e crie outra';
  end if;
  if old.orcamento_linha_id is not null and (new.natureza_id <> old.natureza_id or not erp.agindo_como('erp_situacao')) then
    raise exception 'A previsão do orçamento de área muda só pelo orçamento (revise o orçamento)';
  end if;
  if new.natureza_id <> old.natureza_id and not erp.agindo_como('erp_reclassificacao') then
    raise exception 'A natureza da previsão só muda pela reclassificação';
  end if;
  if new.situacao <> old.situacao and not (new.situacao = 'cancelada' and old.situacao = 'aberta')
     and not erp.agindo_como('erp_situacao') then
    raise exception 'A previsão só pode ser cancelada; ela é consumida pelos títulos';
  end if;
  return new;
end $function$$def$);
-- ... e fica fora da alçada (o orçamento já foi aprovado) e do acumulado do mês (é informativo)
select pg_temp.recriar('erp.tg_previsao_alcada()'::regprocedure, 'b49a4953ca783cca60e33e0f061fb971', $def$CREATE OR REPLACE FUNCTION erp.tg_previsao_alcada()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'erp', 'pg_catalog', 'pg_temp'
AS $function$
declare f erp.alcadas_pagamento; v_centro boolean := false;
begin
  if new.sentido <> 'pagar' or erp.previsao_do_contrato(new.id) is not null
     or new.origem_previsao_id is not null or new.orcamento_linha_id is not null then return null; end if;
  if erp.natureza_restrita(new.natureza_id) then
    perform erp._fixar_alcada_previsao_pj(new);
    return null;
  end if;
  if new.centro_custo_id is null then
    perform erp._fixar_alcada_previsao_sem_centro(new);
    return null;
  end if;
  perform 1 from erp.centros_custo where id = new.centro_custo_id for update;   -- como no título (S-060)
  if new.divisao_id is not null and exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = new.divisao_id) then
    f := erp._fixar_alcada_previsao(new, new.centro_custo_id, new.divisao_id);
    v_centro := coalesce(f.passa_pelo_centro, true);
  end if;
  -- centro sem gestor e sem faixas próprias também entra: nada é aprovado sem aprovador (Moises, 18/11/2026)
  if v_centro
     or new.divisao_id is null or not exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = new.divisao_id) then
    perform erp._fixar_alcada_previsao(new, new.centro_custo_id, null);
  end if;
  return null;
end $function$$def$);
select pg_temp.recriar('erp._previsoes_no_acumulado(uuid, uuid, date, uuid, uuid, uuid, uuid)'::regprocedure, '58cad891e64cba3a8085a8e7b01cadd5', $def$CREATE OR REPLACE FUNCTION erp._previsoes_no_acumulado(p_empresa uuid, p_pessoa uuid, p_mes date, p_centro uuid, p_divisao uuid, p_nucleo uuid, p_excluir uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce(sum(erp._previsao_saldo(q.id)), 0)
    from erp.previsoes q, erp.regra_alcada_pagamento g
   where q.sentido = 'pagar' and q.situacao = 'aberta' and erp.mes(q.competencia) = erp.mes(p_mes)
     and q.id is distinct from p_excluir
     and not erp.natureza_restrita(q.natureza_id)
     and q.orcamento_linha_id is null
     and ((q.centro_custo_id = p_centro and (p_divisao is null or q.divisao_id = p_divisao))
          or (g.soma_fornecedor and p_pessoa is not null and q.pessoa_id = p_pessoa))
     and (g.acumulado = 'centro' or q.empresa_id = p_empresa)
     and (g.acumulado <> 'nucleo_centro' or q.centro_custo_id <> p_centro
          or (p_divisao is not null and q.divisao_id is distinct from p_divisao)
          or q.nucleo_economico_id is not distinct from p_nucleo) $function$$def$);
select pg_temp.recriar('erp.encerrar_previsao(uuid, text, date)'::regprocedure, 'a061daa0cc3b04df7b3aeaea05e304a6', $def$CREATE OR REPLACE FUNCTION erp.encerrar_previsao(p_previsao uuid, p_destino text, p_data date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'erp', 'pg_catalog', 'pg_temp'
AS $function$
declare p erp.previsoes; v_saldo numeric; v_nova uuid;
begin
  perform erp.exigir_editor();
  select * into p from erp.previsoes where id = p_previsao for update;
  if p.id is null or not erp.vejo_previsao(p.id) then raise exception 'Previsão não existe'; end if;
  if not erp.lanco(p.nucleo_economico_id, p.centro_custo_id, p.natureza_id, p.criada_por, p.divisao_id) then
    raise exception 'Você não lança nesta previsão';
  end if;
  if p.situacao <> 'aberta' then raise exception 'Só previsão aberta se encerra'; end if;
  if p.orcamento_linha_id is not null then raise exception 'A previsão do orçamento de área se refaz sozinha'; end if;
  if not exists (select 1 from erp.titulo_previsoes tp join erp.titulos t on t.id = tp.titulo_id
                  where tp.previsao_id = p.id and t.situacao <> 'cancelado') then
    raise exception 'A previsão ainda não foi consumida por nenhuma nota; para desistir, cancele';
  end if;
  v_saldo := erp._previsao_saldo(p.id);
  if p_destino = 'saving' then
    if p_data is not null then raise exception 'Saving não tem data'; end if;
  elsif p_destino = 'saldo' then
    if p_data is null then raise exception 'Informe a data em que o saldo será pago'; end if;
    if p_data < (now() at time zone 'America/Sao_Paulo')::date then raise exception 'A data do saldo já passou'; end if;
    if not erp.previsao_aprovada(p.id) then raise exception 'A previsão original não está aprovada; lance o saldo como previsão nova'; end if;
  else
    raise exception 'Destino é saldo ou saving';
  end if;
  update erp.previsoes set situacao = 'encerrada' where id = p.id;
  if p_destino = 'saldo' then
    insert into erp.previsoes (empresa_id, sentido, origem, origem_previsao_id, compromisso_id, pessoa_id, nucleo_economico_id,
                               natureza_id, centro_custo_id, divisao_id, subdivisao_id, competencia, data_prevista, valor, descricao)
    values (p.empresa_id, p.sentido, 'saldo_previsao', p.id, p.compromisso_id, p.pessoa_id, p.nucleo_economico_id,
            p.natureza_id, p.centro_custo_id, p.divisao_id, p.subdivisao_id, erp.mes(p_data), p_data, v_saldo,
            left('Saldo · ' || coalesce(p.descricao, ''), 500))
    returning id into v_nova;
  end if;
  return v_nova;
end $function$$def$);

-- A nota casa com a previsão do orçamento só no mesmo mês de competência e com a linha do rateio no nível da
-- previsão ou abaixo dele. As outras previsões, como antes.
create or replace function erp._previsao_casa(pr erp.previsoes, d erp.documentos_fiscais) returns boolean language sql stable as $$
  select pr.situacao = 'aberta' and pr.sentido = 'pagar' and pr.empresa_id = d.empresa_id
     and (pr.pessoa_id is null or pr.pessoa_id = d.emitente_id)
     and (pr.orcamento_linha_id is null or erp.mes(pr.competencia) = erp.mes(d.competencia))
     and exists (select 1 from erp.documento_rateios r
                 where r.documento_id = d.id
                   and r.nucleo_economico_id is not distinct from pr.nucleo_economico_id
                   and r.centro_custo_id is not distinct from pr.centro_custo_id
                   and r.natureza_id = pr.natureza_id
                   and (pr.orcamento_linha_id is null
                        or erp.nivel_acima(coalesce(pr.subdivisao_id, pr.divisao_id), coalesce(r.subdivisao_id, r.divisao_id))))
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Aprovação e "fora do orçamento"
-- ---------------------------------------------------------------------------------------------
create table erp.orcamento_aprovacoes (
  id            uuid primary key default gen_random_uuid(),
  versao_id     uuid not null references erp.orcamento_versoes,
  vaga          text not null check (vaga in ('MASTER','AD','AF','AO')),
  aprovado      boolean not null,
  justificativa text,
  por           uuid not null references erp.usuarios,
  em            timestamptz not null default clock_timestamp(),
  check (aprovado or length(trim(coalesce(justificativa, ''))) > 0)
);
create index on erp.orcamento_aprovacoes (versao_id);
create function erp.tg_orcamento_aprovacao() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'Aprovação de orçamento não se altera nem se apaga'; end if;
  if not erp.agindo_como('erp_situacao') then raise exception 'O orçamento só se aprova por erp.decidir_orcamento'; end if;
  return new;
end $$;
create trigger t_guarda before insert or update or delete on erp.orcamento_aprovacoes
  for each row execute function erp.tg_orcamento_aprovacao();

-- A nota marcada por quem lança como fora do orçamento não consome o orçado. Só enquanto a nota é rascunho.
create table erp.documentos_fora_orcamento (
  documento_id uuid primary key references erp.documentos_fiscais,
  motivo       text not null check (length(trim(motivo)) > 0),
  por          uuid,
  em           timestamptz not null default clock_timestamp()
);
create function erp.tg_fora_orcamento() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' then raise exception 'A marca de fora do orçamento não se altera; tire e ponha de novo'; end if;
  if (select situacao from erp.documentos_fiscais where id = coalesce(new.documento_id, old.documento_id)) <> 'rascunho'
     and not erp.sistema() then
    raise exception 'Só a nota ainda não lançada fica fora do orçamento';
  end if;
  if tg_op = 'INSERT' then new.por := erp.autor(); new.em := clock_timestamp(); end if;
  return coalesce(new, old);
end $$;
create trigger t_guarda before insert or update or delete on erp.documentos_fora_orcamento
  for each row execute function erp.tg_fora_orcamento();

-- ---------------------------------------------------------------------------------------------
-- 6. Regras
-- ---------------------------------------------------------------------------------------------
create function erp._hoje_sp() returns date language sql stable as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

-- O mês ainda vale para o orçamento (não passou da carência): o fim do mês mais a carência ainda não chegou.
create function erp._mes_orcamento_vale(p_competencia date) returns boolean language sql stable as $$
  select (erp.mes(p_competencia) + interval '1 month')::date + (select orcamento_carencia_dias from erp.regra_alcada_pagamento)
         > erp._hoje_sp() $$;

-- Refaz a previsão de uma linha (núcleo, centro, natureza, nível e mês): a aberta vale o orçado vigente menos o que
-- os títulos não cancelados consumiram de todas as previsões desta linha. Se a aberta já vale isso e ninguém a
-- consumiu, fica (o PRV no Sienge não muda); senão é encerrada (o PRV vai para a lista de apagar) e nasce outra com
-- o saldo, se houver. Mês vencido: só encerra. Definer erp_situacao (abaixo).
create function erp._refazer_orcamento(p_nucleo uuid, p_centro uuid, p_natureza uuid, p_nivel uuid, p_competencia date)
returns void language plpgsql as $$
declare v_ano int := extract(year from p_competencia); l erp.orcamento_linhas; v erp.orcamento_versoes;
        v_cons numeric; v_alvo numeric; v_abertas uuid[]; v_manter boolean := false;
begin
  perform pg_advisory_xact_lock(hashtext('erp.orcamento:' || p_nucleo || ':' || p_centro || ':' || v_ano));
  select * into v from erp.orcamento_versoes
   where tipo = 'area' and situacao = 'vigente' and nucleo_economico_id = p_nucleo and centro_custo_id = p_centro and ano = v_ano;
  select * into l from erp.orcamento_linhas
   where versao_id = v.id and natureza_id = p_natureza and coalesce(subdivisao_id, divisao_id) is not distinct from p_nivel
     and competencia = p_competencia;
  select coalesce(sum(tp.valor), 0) into v_cons
    from erp.previsoes q join erp.titulo_previsoes tp on tp.previsao_id = q.id join erp.titulos t on t.id = tp.titulo_id
   where q.orcamento_linha_id is not null and t.situacao <> 'cancelado'
     and q.nucleo_economico_id = p_nucleo and q.centro_custo_id = p_centro and q.natureza_id = p_natureza
     and coalesce(q.subdivisao_id, q.divisao_id) is not distinct from p_nivel and q.competencia = p_competencia;
  v_alvo := case when l.id is not null and erp._mes_orcamento_vale(p_competencia) then -l.valor - v_cons else 0 end;
  select array_agg(q.id order by q.criada_em) into v_abertas
    from erp.previsoes q
   where q.orcamento_linha_id is not null and q.situacao = 'aberta'
     and q.nucleo_economico_id = p_nucleo and q.centro_custo_id = p_centro and q.natureza_id = p_natureza
     and coalesce(q.subdivisao_id, q.divisao_id) is not distinct from p_nivel and q.competencia = p_competencia;
  if cardinality(v_abertas) = 1 and v_alvo > 0 then
    select q.valor = v_alvo and not exists (select 1 from erp.titulo_previsoes tp join erp.titulos t on t.id = tp.titulo_id
                                             where tp.previsao_id = q.id and t.situacao <> 'cancelado')
      into v_manter from erp.previsoes q where q.id = v_abertas[1];
  end if;
  if v_manter then return; end if;
  update erp.previsoes set situacao = 'encerrada' where id = any(coalesce(v_abertas, '{}'));
  if v_alvo > 0 then
    insert into erp.previsoes (empresa_id, sentido, origem, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id,
                               subdivisao_id, competencia, data_prevista, valor, descricao, orcamento_linha_id)
    values (v.empresa_id, 'pagar', 'orcamento', p_nucleo, p_natureza, p_centro, l.divisao_id, l.subdivisao_id, p_competencia,
            coalesce(l.data_caixa, (erp.mes(p_competencia) + interval '1 month - 1 day')::date), v_alvo,
            'Orçamento de área ' || v_ano, l.id);
  end if;
end $$;

-- No fim da transação em que um título consumiu uma previsão do orçamento, ou foi cancelado, a linha é refeita.
create function erp.tg_refazer_orcamento() returns trigger language plpgsql as $$
declare q record; v_titulo uuid; v_previsao uuid;
begin
  if tg_table_name = 'titulo_previsoes' then
    v_titulo := new.titulo_id; v_previsao := new.previsao_id;
  else
    v_titulo := new.id;
  end if;
  for q in select distinct p.nucleo_economico_id, p.centro_custo_id, p.natureza_id, coalesce(p.subdivisao_id, p.divisao_id) nivel,
                           p.competencia
             from erp.titulo_previsoes tp join erp.previsoes p on p.id = tp.previsao_id
            where p.orcamento_linha_id is not null and tp.titulo_id = v_titulo
              and (v_previsao is null or tp.previsao_id = v_previsao) loop
    perform erp._refazer_orcamento(q.nucleo_economico_id, q.centro_custo_id, q.natureza_id, q.nivel, q.competencia);
  end loop;
  return null;
end $$;
create constraint trigger t_refazer_orcamento after insert on erp.titulo_previsoes
  deferrable initially deferred for each row execute function erp.tg_refazer_orcamento();
create constraint trigger t_refazer_orcamento after update of situacao on erp.titulos
  deferrable initially deferred for each row when (new.situacao = 'cancelado' and old.situacao <> 'cancelado')
  execute function erp.tg_refazer_orcamento();

-- A nota consome o orçado: cada linha do rateio, no que as outras previsões (contrato, as dadas) não cobriram,
-- consome a previsão do orçamento da mesma natureza e mês, no nível da linha ou acima (a mais funda primeiro).
-- Roda dentro de erp.lancar_documento (erp_situacao).
create function erp._consumir_orcamento(p_titulo uuid, d erp.documentos_fiscais) returns void language plpgsql as $$
declare r record; p record; v_resta numeric; v_cons numeric; v_coberto numeric;
begin
  if exists (select 1 from erp.documentos_fora_orcamento f where f.documento_id = d.id) then return; end if;
  for r in select dr.*, round(d.valor_bruto * dr.percentual / 100, 2) as parte,
                  -- o que as previsões que não são do orçamento já cobriram nesta combinação, distribuído pelas linhas em ordem
                  sum(round(d.valor_bruto * dr.percentual / 100, 2)) over (partition by dr.nucleo_economico_id, dr.centro_custo_id, dr.natureza_id
                                                                            order by dr.percentual desc, dr.id) as acumulado
             from erp.documento_rateios dr where dr.documento_id = d.id
            order by dr.percentual desc, dr.id loop
    select coalesce(sum(tp.valor), 0) into v_coberto
      from erp.titulo_previsoes tp join erp.previsoes q on q.id = tp.previsao_id
     where tp.titulo_id = p_titulo and q.orcamento_linha_id is null
       and q.nucleo_economico_id is not distinct from r.nucleo_economico_id
       and q.centro_custo_id is not distinct from r.centro_custo_id and q.natureza_id = r.natureza_id;
    v_resta := least(r.parte, greatest(r.acumulado - v_coberto, 0));
    for p in select q.id from erp.previsoes q
              where q.orcamento_linha_id is not null and erp._previsao_casa(q, d)
                and q.nucleo_economico_id = r.nucleo_economico_id and q.centro_custo_id = r.centro_custo_id
                and q.natureza_id = r.natureza_id
                and erp.nivel_acima(coalesce(q.subdivisao_id, q.divisao_id), coalesce(r.subdivisao_id, r.divisao_id))
              order by coalesce((select dv.nivel from erp.divisoes dv where dv.id = coalesce(q.subdivisao_id, q.divisao_id)), 0) desc,
                       q.criada_em loop
      exit when v_resta <= 0;
      v_cons := least(v_resta, erp._previsao_saldo(p.id));
      continue when v_cons <= 0;
      insert into erp.titulo_previsoes (titulo_id, previsao_id, valor) values (p_titulo, p.id, v_cons)
        on conflict do nothing;
      if found then v_resta := v_resta - v_cons; end if;
    end loop;
  end loop;
end $$;

-- lancar_documento: as previsões do orçamento saem do consumo de antes e entram no consumo por linha do rateio
select pg_temp.recriar('erp.lancar_documento(uuid, date[], uuid[], numeric[])'::regprocedure, '43ee397e8bf323963e0426e5b8c68bdc', $def$CREATE OR REPLACE FUNCTION erp.lancar_documento(p_documento uuid, p_vencimentos date[], p_previsoes uuid[] DEFAULT NULL::uuid[], p_valores numeric[] DEFAULT NULL::numeric[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'erp', 'pg_catalog', 'pg_temp'
AS $function$
declare d erp.documentos_fiscais; v_ret numeric; v_liquido numeric; v_tit uuid; v_imp uuid; r record;
        v_resta numeric; v_cons numeric; v_lim numeric; p record; i int;
begin
  perform erp.exigir_editor();
  if not erp.sistema() and not erp.lanco_documento(p_documento) then
    raise exception 'Você não lança em todas as linhas desta nota';
  end if;
  select * into d from erp.documentos_fiscais where id = p_documento for update;
  if d.situacao <> 'rascunho' then raise exception 'O documento já foi lançado'; end if;
  if coalesce(array_length(p_vencimentos, 1), 0) = 0 then raise exception 'Informe ao menos um vencimento'; end if;
  if not erp.rateio_completo('documento', d.id) then raise exception 'O rateio do documento não soma 100%%'; end if;
  perform erp.checar_competencia('documento', d.id, d.emissao, d.competencia);
  if d.caucao_valor is null then
    d.caucao_valor := round(d.valor_bruto * coalesce((select caucao_percentual from erp.compromissos where id = d.compromisso_id), 0) / 100, 2);
  end if;
  if d.caucao_valor > 0 and d.compromisso_id is null then raise exception 'Caução só existe com contrato'; end if;
  select coalesce(sum(valor), 0) into v_ret from erp.documento_retencoes where documento_id = d.id;
  v_liquido := d.valor_bruto - v_ret - d.caucao_valor;
  if v_liquido <= 0 then raise exception 'Retenções e caução passam do valor da nota'; end if;

  v_tit := erp._criar_titulo(d.empresa_id, 'pagar', 'fornecedor', d.emitente_id, d.id, d.compromisso_id,
                                d.emissao, d.competencia, v_liquido, p_vencimentos, 'documento', d.id, null);
  -- valor de cada parcela como está no documento (boletos de valores diferentes); sem ele, iguais
  if p_valores is not null then
    if coalesce(array_length(p_valores, 1), 0) <> array_length(p_vencimentos, 1) then
      raise exception 'Informe o valor de cada parcela';
    end if;
    if exists (select 1 from unnest(p_valores) v where v is null or v <= 0 or v <> round(v, 2)) then
      raise exception 'O valor de cada parcela é maior que zero, com até 2 casas';
    end if;
    if (select sum(v) from unnest(p_valores) v) <> v_liquido then
      raise exception 'As parcelas somam %, e o valor líquido do título é %',
        replace(to_char((select sum(v) from unnest(p_valores) v), 'FM999999999990.00'), '.', ','),
        replace(to_char(v_liquido, 'FM999999999990.00'), '.', ',');
    end if;
    for i in 1..array_length(p_valores, 1) loop
      update erp.parcelas set valor = p_valores[i] where titulo_id = v_tit and numero = i;
    end loop;
  end if;
  -- consumo das previsões (as dadas, ou as abertas do mesmo contrato, da mais antiga), até o bruto.
  -- Só casa previsão da mesma empresa, do mesmo fornecedor (ou sem fornecedor) e com o mesmo
  -- núcleo, centro de custo e natureza de uma linha do rateio da nota (S-030). Previsão dada que
  -- não casa é recusada, nunca ignorada.
  if p_previsoes is not null and exists (
       select 1 from unnest(p_previsoes) as x(id)
       where not exists (select 1 from erp.previsoes pr where pr.id = x.id and erp._previsao_casa(pr, d))) then
    raise exception 'Previsão que não é desta nota: precisa ser aberta, da mesma empresa e fornecedor, e com o mesmo núcleo, centro de custo e natureza do rateio';
  end if;
  v_resta := d.valor_bruto;
  for p in
    select pr.id, pr.nucleo_economico_id, pr.centro_custo_id, pr.natureza_id from erp.previsoes pr
    where erp._previsao_casa(pr, d) and pr.orcamento_linha_id is null
      and (case when p_previsoes is not null then pr.id = any(p_previsoes)
                else d.compromisso_id is not null and pr.compromisso_id = d.compromisso_id end)
    order by pr.data_prevista, pr.criada_em
  loop
    exit when v_resta <= 0;
    -- só até a parte do bruto rateada no mesmo núcleo, centro e natureza da previsão,
    -- descontado o que outras previsões da mesma combinação já consumiram nesta nota
    select round(d.valor_bruto * coalesce(sum(dr.percentual), 0) / 100, 2)
           - coalesce((select sum(tp.valor) from erp.titulo_previsoes tp join erp.previsoes q on q.id = tp.previsao_id
                       where tp.titulo_id = v_tit
                         and q.nucleo_economico_id is not distinct from p.nucleo_economico_id
                         and q.centro_custo_id is not distinct from p.centro_custo_id
                         and q.natureza_id = p.natureza_id), 0)
      into v_lim
      from erp.documento_rateios dr
     where dr.documento_id = d.id
       and dr.nucleo_economico_id is not distinct from p.nucleo_economico_id
       and dr.centro_custo_id is not distinct from p.centro_custo_id
       and dr.natureza_id = p.natureza_id;
    v_cons := least(v_resta, erp._previsao_saldo(p.id), v_lim);
    continue when v_cons <= 0;
    insert into erp.titulo_previsoes (titulo_id, previsao_id, valor) values (v_tit, p.id, v_cons);
    v_resta := v_resta - v_cons;
  end loop;
  perform erp._consumir_orcamento(v_tit, d);   -- orçamento de área (Moises, 23/11/2026)
  -- a alçada é fixada depois do consumo: a nota conta no acumulado só o que passa do saldo da previsão
  perform erp._confirmar_titulo(v_tit);

  for r in select * from erp.documento_retencoes where documento_id = d.id loop
    v_imp := erp._criar_titulo(d.empresa_id, 'pagar', 'imposto', r.orgao_id, d.id, d.compromisso_id,
                                  d.emissao, d.competencia, r.valor, array[r.vencimento], 'documento', d.id,
                                  upper(r.imposto) || ' retido na nota ' || d.numero);
    perform erp._confirmar_titulo(v_imp);
  end loop;

  if d.caucao_valor > 0 then
    insert into erp.caucao_movimentos (compromisso_id, tipo, valor, documento_id)
    values (d.compromisso_id, 'retencao', d.caucao_valor, d.id);
  end if;

  update erp.documentos_fiscais set situacao = 'lancado', lancado_em = now(), caucao_valor = d.caucao_valor where id = d.id;
  return v_tit;
end $function$$def$);

-- O mês que passou da carência: a sobra sai (a previsão é encerrada e o PRV vai para a lista de apagar).
-- Roda no começo de cada enfileiramento do Sienge (só o sistema). Definer erp_situacao (abaixo).
create function erp.orcamento_vencer() returns int language plpgsql as $$
declare n int;
begin
  if not erp.sistema() then raise exception 'Só o sistema encerra a sobra do orçamento'; end if;
  update erp.previsoes q set situacao = 'encerrada'
   where q.orcamento_linha_id is not null and q.situacao = 'aberta' and not erp._mes_orcamento_vale(q.competencia);
  get diagnostics n = row_count;
  return n;
end $$;
select pg_temp.recriar('erp.sienge_enfileirar()'::regprocedure, 'b160dd98105adc7c7aabc682c174b665', $def$CREATE OR REPLACE FUNCTION erp.sienge_enfileirar()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare n int := 0; m int; r record;
begin
  if not erp.sistema() then raise exception 'Só o sistema enfileira o envio ao Sienge'; end if;
  perform erp.orcamento_vencer();   -- a sobra do mês do orçamento de área, depois da carência
  for r in
    with novos as (
      insert into erp.sienge_envios (titulo_id)
      select t.id from erp.titulos t
       where t.sentido = 'pagar' and t.tipo in ('fornecedor','avulso') and t.situacao = 'aberto'
         and not exists (select 1 from erp.sienge_envios e where e.titulo_id = t.id)
         and erp.titulo_aprovado(t.id)
      on conflict do nothing
      returning titulo_id)
    select x.titulo_id, t.pessoa_id,
           (select jsonb_agg(jsonb_build_object('numero', g.numero, 'pix_tipo', g.pix_tipo, 'pix_chave', g.pix_chave) order by g.numero)
              from erp.parcela_pagamentos g
             where g.titulo_id = x.titulo_id and g.forma = 'pix'
               and not erp._chave_pix_conhecida(t.pessoa_id, g.pix_chave, x.titulo_id)) as chaves,
           (select array[r2.nucleo_economico_id, r2.centro_custo_id] from erp.titulo_rateios r2
             where r2.titulo_id = x.titulo_id order by r2.percentual desc, r2.id limit 1) as onde
      from novos x join erp.titulos t on t.id = x.titulo_id
  loop
    n := n + 1;
    if exists (select 1 from erp.parcela_pagamentos g where g.titulo_id = r.titulo_id and g.boleto_excecao is not null) then
      perform erp.registrar_evento('boleto_excecao', 'titulos', r.titulo_id::text, r.onde[1], r.onde[2],
        jsonb_build_object('titulo_id', r.titulo_id, 'pessoa_id', r.pessoa_id,
          'parcelas', (select jsonb_agg(jsonb_build_object('numero', g.numero, 'conferido', erp.boleto_conferido(g.boleto_linha),
                                                           'justificativa', g.boleto_excecao) order by g.numero)
                         from erp.parcela_pagamentos g where g.titulo_id = r.titulo_id and g.boleto_excecao is not null),
          'motivo', 'Boleto com beneficiário não conferido'));
    end if;
    if exists (select 1 from erp.parcela_pagamentos g where g.titulo_id = r.titulo_id and g.pix_copia_cola_excecao is not null) then
      perform erp.registrar_evento('pix_copia_cola_excecao', 'titulos', r.titulo_id::text, r.onde[1], r.onde[2],
        jsonb_build_object('titulo_id', r.titulo_id, 'pessoa_id', r.pessoa_id,
          'parcelas', (select jsonb_agg(jsonb_build_object('numero', g.numero, 'recebedor', erp.pix_copia_cola_recebedor(g.pix_copia_cola),
                                                           'conferido', erp.pix_conferido(g.pix_copia_cola),
                                                           'justificativa', g.pix_copia_cola_excecao) order by g.numero)
                         from erp.parcela_pagamentos g where g.titulo_id = r.titulo_id and g.pix_copia_cola_excecao is not null),
          'motivo', 'PIX copia e cola com recebedor não conferido'));
    end if;
    if r.chaves is not null then
      perform erp.registrar_evento('chave_pix_nova', 'titulos', r.titulo_id::text, r.onde[1], r.onde[2],
        jsonb_build_object('titulo_id', r.titulo_id, 'pessoa_id', r.pessoa_id, 'parcelas', r.chaves,
                           'motivo', 'Chave PIX nunca usada com este credor: '
                                     || (select string_agg(c->>'pix_chave', ', ') from jsonb_array_elements(r.chaves) c)));
    end if;
  end loop;

  insert into erp.sienge_previsoes (previsao_id)
  select p.id from erp.previsoes p
   where p.sentido = 'pagar' and p.situacao = 'aberta'
     and not exists (select 1 from erp.sienge_previsoes s where s.previsao_id = p.id)
     and erp.previsao_aprovada(p.id)
  on conflict do nothing;
  get diagnostics m = row_count;

  update erp.sienge_previsoes s set apagar_desde = clock_timestamp()
    from erp.previsoes p
   where p.id = s.previsao_id and p.situacao <> 'aberta' and s.sienge_id is not null and s.apagar_desde is null;
  update erp.sienge_previsoes s set situacao = 'descartado', erro = 'A previsão saiu de aberta antes de ir ao Sienge'
    from erp.previsoes p
   where p.id = s.previsao_id and p.situacao <> 'aberta' and s.sienge_id is null and s.situacao <> 'descartado';
  return n + m;
end $function$$def$);

-- Quem é o gestor do centro, e a vaga que a pessoa ocupa na aprovação do orçamento
create function erp._gestor_orcamento(p_centro uuid, p_user uuid) returns boolean language sql stable as $$
  select exists (select 1 from erp.master where user_id = p_user)
      or exists (select 1 from erp.centro_aprovadores a join erp.usuarios u on u.id = a.user_id
                  where a.centro_custo_id = p_centro and a.user_id = p_user and u.ativo) $$;
create function erp._vaga_orcamento(p_centro uuid, p_user uuid) returns text language sql stable as $$
  select case when exists (select 1 from erp.master where user_id = p_user) then 'MASTER'
              when not exists (select 1 from erp.usuarios where id = p_user and ativo and not administrador and not so_sucessao) then null
              when exists (select 1 from erp.listas_financeiro where user_id = p_user and lista = 'AD') then 'AD'
              when exists (select 1 from erp.listas_financeiro where user_id = p_user and lista = 'AF') then 'AF'
              when exists (select 1 from erp.listas_financeiro where user_id = p_user and lista = 'AO' and p_centro = any(centros)) then 'AO'
         end $$;

-- Aprovado: o master ou o AD aprovou, ou a AF e um AO do centro, depois do último envio e sem recusa.
create function erp.orcamento_aprovado(p_versao uuid) returns boolean language sql stable as $$
  select coalesce((
    select v.enviado_em is not null
       and not exists (select 1 from erp.orcamento_aprovacoes a where a.versao_id = v.id and a.em >= v.enviado_em and not a.aprovado)
       and (exists (select 1 from erp.orcamento_aprovacoes a where a.versao_id = v.id and a.em >= v.enviado_em and a.aprovado
                     and a.vaga in ('MASTER','AD'))
            or (exists (select 1 from erp.orcamento_aprovacoes a where a.versao_id = v.id and a.em >= v.enviado_em and a.aprovado and a.vaga = 'AF')
                and exists (select 1 from erp.orcamento_aprovacoes a where a.versao_id = v.id and a.em >= v.enviado_em and a.aprovado and a.vaga = 'AO')))
      from erp.orcamento_versoes v where v.id = p_versao and v.tipo = 'area'), false) $$;

-- Os meses que já passaram ficam como na versão vigente (sem vigente, o primeiro orçamento traz o que quiser).
create function erp._orcamento_passado_igual(p_versao uuid, p_vigente uuid) returns boolean language sql stable as $$
  select p_vigente is null or not exists (
    (select natureza_id, coalesce(subdivisao_id, divisao_id), competencia, valor, data_caixa from erp.orcamento_linhas
      where versao_id = p_versao and competencia < erp.mes(erp._hoje_sp())
     except
     select natureza_id, coalesce(subdivisao_id, divisao_id), competencia, valor, data_caixa from erp.orcamento_linhas
      where versao_id = p_vigente and competencia < erp.mes(erp._hoje_sp()))
    union all
    (select natureza_id, coalesce(subdivisao_id, divisao_id), competencia, valor, data_caixa from erp.orcamento_linhas
      where versao_id = p_vigente and competencia < erp.mes(erp._hoje_sp())
     except
     select natureza_id, coalesce(subdivisao_id, divisao_id), competencia, valor, data_caixa from erp.orcamento_linhas
      where versao_id = p_versao and competencia < erp.mes(erp._hoje_sp()))) $$;

-- Publica a versão aprovada: a vigente vira substituída, o livro ganha o orçado e cada linha que ainda vale é
-- refeita (só a que mudou troca de previsão).
create function erp._publicar_orcamento_area(p_versao uuid) returns void language plpgsql as $$
declare v erp.orcamento_versoes; w erp.orcamento_versoes; k record;
begin
  select * into v from erp.orcamento_versoes where id = p_versao for update;
  select * into w from erp.orcamento_versoes
   where tipo = 'area' and situacao = 'vigente' and nucleo_economico_id = v.nucleo_economico_id
     and centro_custo_id = v.centro_custo_id and ano = v.ano for update;
  if not erp._orcamento_passado_igual(v.id, w.id) then raise exception 'Os meses que já passaram não mudam'; end if;
  update erp.orcamento_versoes set situacao = 'substituida' where id = w.id;
  update erp.orcamento_versoes set situacao = 'vigente' where id = v.id;
  insert into erp.lancamentos (estagio, orcamento_versao_id, empresa_id, nucleo_economico_id, natureza_id,
                               centro_custo_id, divisao_id, subdivisao_id, competencia, data_caixa, valor, orcamento_linha_id)
  select 'orcado', v.id, v.empresa_id, l.nucleo_economico_id, l.natureza_id, l.centro_custo_id, l.divisao_id, l.subdivisao_id,
         l.competencia, l.data_caixa, l.valor, l.id
    from erp.orcamento_linhas l where l.versao_id = v.id;
  for k in select distinct l.natureza_id, coalesce(l.subdivisao_id, l.divisao_id) nivel, l.competencia
             from erp.orcamento_linhas l where l.versao_id in (v.id, w.id) and erp._mes_orcamento_vale(l.competencia)
            order by 3, 1 loop
    perform erp._refazer_orcamento(v.nucleo_economico_id, v.centro_custo_id, k.natureza_id, k.nivel, k.competencia);
  end loop;
end $$;

-- Cria o orçamento do ano (ou a revisão do vigente, que começa como cópia dele). Só o gestor do centro ou o master.
create function erp.criar_orcamento_area(p_nucleo uuid, p_centro uuid, p_ano int) returns uuid language plpgsql as $$
declare v_eu uuid := erp.eu(); v_empresa uuid; w erp.orcamento_versoes; v_id uuid;
begin
  perform erp.exigir_editor();
  if v_eu is null then raise exception 'Usuário sem cadastro no ERP'; end if;
  if not erp._gestor_orcamento(p_centro, v_eu) then raise exception 'Só o gestor do centro de custo cria o orçamento da área'; end if;
  if p_ano is null or p_ano < extract(year from erp._hoje_sp()) - 1 or p_ano > extract(year from erp._hoje_sp()) + 5 then
    raise exception 'Ano do orçamento fora do intervalo';
  end if;
  select empresa_id into v_empresa from erp.nucleos_economicos where id = p_nucleo;
  if v_empresa is null then raise exception 'Núcleo econômico não existe'; end if;
  perform erp.checar_centro(p_nucleo, p_centro, v_empresa);
  perform pg_advisory_xact_lock(hashtext('erp.orcamento:' || p_nucleo || ':' || p_centro || ':' || p_ano));
  if exists (select 1 from erp.orcamento_versoes where tipo = 'area' and situacao = 'rascunho'
              and nucleo_economico_id = p_nucleo and centro_custo_id = p_centro and ano = p_ano) then
    raise exception 'Já há um orçamento em montagem para este núcleo, centro e ano';
  end if;
  select * into w from erp.orcamento_versoes where tipo = 'area' and situacao = 'vigente'
     and nucleo_economico_id = p_nucleo and centro_custo_id = p_centro and ano = p_ano;
  insert into erp.orcamento_versoes (empresa_id, tipo, nome, data_base, nucleo_economico_id, centro_custo_id, ano, substitui_id,
                                     alterado_em, alterado_por)
  values (v_empresa, 'area', case when w.id is null then 'Orçamento ' else 'Revisão do orçamento ' end || p_ano,
          make_date(p_ano, 1, 1), p_nucleo, p_centro, p_ano, w.id, clock_timestamp(), v_eu)
  returning id into v_id;
  insert into erp.orcamento_linhas (versao_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, subdivisao_id,
                                    competencia, data_caixa, valor)
  select v_id, l.nucleo_economico_id, l.natureza_id, l.centro_custo_id, l.divisao_id, l.subdivisao_id, l.competencia, l.data_caixa, l.valor
    from erp.orcamento_linhas l where l.versao_id = w.id;
  return v_id;
end $$;

-- Grava as linhas do orçamento em montagem (troca todas). Cada linha: natureza, nível (a divisão, de qualquer nível,
-- ou nulo para o centro), mês, valor (positivo) e, opcional, a data do caixa. A mudança tira o envio.
create function erp.salvar_orcamento_area(p_versao uuid, p_linhas jsonb) returns int language plpgsql as $$
declare v_eu uuid := erp.eu(); v erp.orcamento_versoes; x jsonb; v_nat uuid; v_nivel uuid; d erp.divisoes; v_comp date;
        v_valor numeric; v_caixa date; n int := 0; nm text;
begin
  perform erp.exigir_editor();
  select * into v from erp.orcamento_versoes where id = p_versao and tipo = 'area' for update;
  if v.id is null then raise exception 'Orçamento não existe'; end if;
  if not erp._gestor_orcamento(v.centro_custo_id, v_eu) then raise exception 'Só o gestor do centro de custo monta o orçamento da área'; end if;
  if v.situacao <> 'rascunho' then raise exception 'Só o orçamento em montagem muda; crie uma revisão'; end if;
  if jsonb_typeof(p_linhas) is distinct from 'array' then raise exception 'As linhas vão numa lista'; end if;
  delete from erp.orcamento_linhas where versao_id = v.id;
  for x in select * from jsonb_array_elements(p_linhas) loop
    v_nat := nullif(x->>'natureza', '')::uuid;
    v_nivel := nullif(x->>'nivel', '')::uuid;
    v_comp := erp.mes(nullif(x->>'competencia', '')::date);
    v_valor := nullif(x->>'valor', '')::numeric;
    v_caixa := nullif(x->>'data_caixa', '')::date;
    if v_nat is null or v_comp is null or v_valor is null then raise exception 'Cada linha precisa de natureza, mês e valor'; end if;
    if v_valor <= 0 then raise exception 'O valor orçado é positivo (a despesa prevista)'; end if;
    if extract(year from v_comp) <> v.ano then raise exception 'O mês % não é do ano do orçamento (%)', to_char(v_comp, 'MM/YYYY'), v.ano; end if;
    if v_caixa is not null and v_caixa < v_comp then raise exception 'A data do caixa não vem antes do mês da competência'; end if;
    select nome into nm from erp.naturezas where id = v_nat;
    if nm is null then raise exception 'Natureza inexistente'; end if;
    if erp.natureza_restrita(v_nat) then raise exception 'A natureza "%" é restrita e não entra no orçamento de área', nm; end if;
    if (select so_orcado from erp.naturezas where id = v_nat) then
      raise exception 'A natureza "%" é só do orçado de obra e não entra no orçamento de área', nm;
    end if;
    if v_nivel is not null then
      select * into d from erp.divisoes where id = v_nivel;
      if d.id is null or d.centro_custo_id <> v.centro_custo_id then raise exception 'O nível não é deste centro de custo'; end if;
      if not d.ativa then raise exception 'O nível "%" está desativado', d.nome; end if;
    end if;
    if not erp.natureza_ligada(v.centro_custo_id, v_nivel, v_nat) then
      raise exception 'A natureza "%" não está liberada neste nível', nm;
    end if;
    insert into erp.orcamento_linhas (versao_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, subdivisao_id,
                                      competencia, data_caixa, valor)
    values (v.id, v.nucleo_economico_id, v_nat, v.centro_custo_id,
            case when v_nivel is not null then coalesce(d.raiz_id, d.id) end,
            case when v_nivel is not null and d.raiz_id is not null and d.raiz_id <> d.id then d.id end,
            v_comp, v_caixa, -v_valor);
    n := n + 1;
  end loop;
  if not erp._orcamento_passado_igual(v.id, v.substitui_id) then raise exception 'Os meses que já passaram não mudam'; end if;
  update erp.orcamento_versoes set enviado_em = null, alterado_em = clock_timestamp(), alterado_por = v_eu where id = v.id;
  return n;
end $$;

-- Manda para aprovar. O aviso vai à AF, aos AO e ao AD.
create function erp.enviar_orcamento(p_versao uuid) returns void language plpgsql as $$
declare v_eu uuid := erp.eu(); v erp.orcamento_versoes;
begin
  perform erp.exigir_editor();
  select * into v from erp.orcamento_versoes where id = p_versao and tipo = 'area' for update;
  if v.id is null then raise exception 'Orçamento não existe'; end if;
  if not erp._gestor_orcamento(v.centro_custo_id, v_eu) then raise exception 'Só o gestor do centro de custo envia o orçamento'; end if;
  if v.situacao <> 'rascunho' then raise exception 'Só o orçamento em montagem se envia'; end if;
  if v.enviado_em is not null then raise exception 'O orçamento já foi enviado'; end if;
  if not exists (select 1 from erp.orcamento_linhas where versao_id = v.id) then raise exception 'O orçamento não tem linhas'; end if;
  if v.substitui_id is not null
     and not exists (select l.natureza_id, coalesce(l.subdivisao_id, l.divisao_id), l.competencia, l.valor, l.data_caixa
                       from erp.orcamento_linhas l where l.versao_id = v.id
                     except select l.natureza_id, coalesce(l.subdivisao_id, l.divisao_id), l.competencia, l.valor, l.data_caixa
                       from erp.orcamento_linhas l where l.versao_id = v.substitui_id)
     and not exists (select l.natureza_id, coalesce(l.subdivisao_id, l.divisao_id), l.competencia, l.valor, l.data_caixa
                       from erp.orcamento_linhas l where l.versao_id = v.substitui_id
                     except select l.natureza_id, coalesce(l.subdivisao_id, l.divisao_id), l.competencia, l.valor, l.data_caixa
                       from erp.orcamento_linhas l where l.versao_id = v.id) then
    raise exception 'A revisão está igual ao orçamento vigente';
  end if;
  update erp.orcamento_versoes set enviado_em = clock_timestamp() where id = v.id;
  perform erp.registrar_evento('orcamento_enviado', 'orcamento_versoes', v.id::text, v.nucleo_economico_id, v.centro_custo_id,
    jsonb_build_object('versao_id', v.id, 'ano', v.ano, 'revisao', v.substitui_id is not null,
                       'total', (select -sum(valor) from erp.orcamento_linhas where versao_id = v.id)));
end $$;

-- Descarta o orçamento em montagem.
create function erp.descartar_orcamento(p_versao uuid) returns void language plpgsql as $$
declare v erp.orcamento_versoes;
begin
  perform erp.exigir_editor();
  select * into v from erp.orcamento_versoes where id = p_versao and tipo = 'area' for update;
  if v.id is null then raise exception 'Orçamento não existe'; end if;
  if not erp._gestor_orcamento(v.centro_custo_id, erp.eu()) then raise exception 'Só o gestor do centro de custo descarta o orçamento'; end if;
  if v.situacao <> 'rascunho' then raise exception 'Só o orçamento em montagem se descarta'; end if;
  if exists (select 1 from erp.orcamento_aprovacoes where versao_id = v.id) then
    raise exception 'O orçamento já teve decisão; mude e envie de novo';
  end if;
  delete from erp.orcamento_versoes where id = v.id;
end $$;

-- Aprovar ou recusar o orçamento enviado. Cada pessoa ocupa uma vaga (master, AD, AF ou AO do centro) e decide uma
-- vez por envio. Recusar exige justificativa e devolve o orçamento à montagem. Aprovado, publica.
create function erp.decidir_orcamento(p_versao uuid, p_aprovar boolean, p_justificativa text default null)
returns text language plpgsql as $$
declare v_eu uuid := erp.eu(); v erp.orcamento_versoes; v_vaga text;
begin
  perform erp.exigir_editor();
  if v_eu is null then raise exception 'Usuário sem cadastro no ERP'; end if;
  select * into v from erp.orcamento_versoes where id = p_versao and tipo = 'area' for update;
  if v.id is null then raise exception 'Orçamento não existe'; end if;
  if v.situacao <> 'rascunho' or v.enviado_em is null then raise exception 'O orçamento não está esperando aprovação'; end if;
  v_vaga := erp._vaga_orcamento(v.centro_custo_id, v_eu);
  if v_vaga is null then raise exception 'A aprovação do orçamento é da AF com um AO do centro, ou do AD'; end if;
  if v_vaga <> 'MASTER' and v_eu in (v.criada_por, v.alterado_por) then
    raise exception 'Quem montou ou mudou o orçamento não aprova';
  end if;
  if not p_aprovar and length(trim(coalesce(p_justificativa, ''))) = 0 then raise exception 'Recusar exige justificativa'; end if;
  if exists (select 1 from erp.orcamento_aprovacoes where versao_id = v.id and em >= v.enviado_em and por = v_eu) then
    raise exception 'Você já decidiu este orçamento';
  end if;
  if exists (select 1 from erp.orcamento_aprovacoes where versao_id = v.id and em >= v.enviado_em and vaga = v_vaga and aprovado) then
    raise exception 'A vaga % já aprovou este orçamento', v_vaga;
  end if;
  insert into erp.orcamento_aprovacoes (versao_id, vaga, aprovado, justificativa, por)
  values (v.id, v_vaga, p_aprovar, nullif(trim(p_justificativa), ''), v_eu);
  if not p_aprovar then
    update erp.orcamento_versoes set enviado_em = null where id = v.id;
    perform erp.registrar_evento('orcamento_decidido', 'orcamento_versoes', v.id::text, v.nucleo_economico_id, v.centro_custo_id,
      jsonb_build_object('versao_id', v.id, 'ano', v.ano, 'aprovado', false, 'justificativa', p_justificativa));
    return 'recusado';
  end if;
  if not erp.orcamento_aprovado(v.id) then return 'pendente'; end if;
  perform erp._publicar_orcamento_area(v.id);
  perform erp.registrar_evento('orcamento_decidido', 'orcamento_versoes', v.id::text, v.nucleo_economico_id, v.centro_custo_id,
    jsonb_build_object('versao_id', v.id, 'ano', v.ano, 'aprovado', true));
  return 'aprovado';
end $$;

-- A vaga de quem está logado no orçamento (para a tela dizer se é a vez dele).
create function erp.minha_vaga_orcamento(p_versao uuid) returns text language sql stable as $$
  select erp._vaga_orcamento(v.centro_custo_id, erp.eu()) from erp.orcamento_versoes v where v.id = p_versao and v.tipo = 'area' $$;

-- ---------------------------------------------------------------------------------------------
-- 7. Eventos e avisos
-- ---------------------------------------------------------------------------------------------
-- gravado como o sistema (os tipos de evento entram só pela carga)
do $$ begin
  set local role erp_sistema;
  insert into erp.tipos_evento (codigo, rotulo, modulo) values
    ('orcamento_enviado', 'Orçamento de área para aprovar', 'pagar'),
    ('orcamento_decidido', 'Orçamento de área aprovado ou recusado', 'pagar');
  insert into erp.regras_notificacao (tipo, destino, lista) values
    ('orcamento_enviado', 'lista', 'AF'), ('orcamento_enviado', 'lista', 'AO'), ('orcamento_enviado', 'lista', 'AD');
  insert into erp.regras_notificacao (tipo, destino) values ('orcamento_decidido', 'gestor_centro');
  reset role;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 8. API
-- ---------------------------------------------------------------------------------------------
-- Os orçamentos de área que a pessoa vê (a versão vigente e a em montagem de cada núcleo, centro e ano).
create function api.orcamentos_area()
returns table (id uuid, nucleo_id uuid, nucleo text, centro_id uuid, centro text, ano int, situacao text, enviado_em timestamptz,
               revisao boolean, total numeric, aprovacoes jsonb, posso_editar boolean, minha_vaga text)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select v.id, v.nucleo_economico_id, n.nome, v.centro_custo_id, c.nome, v.ano, v.situacao, v.enviado_em, v.substitui_id is not null,
         (select -sum(l.valor) from erp.orcamento_linhas l where l.versao_id = v.id),
         coalesce((select jsonb_agg(jsonb_build_object('vaga', a.vaga, 'aprovado', a.aprovado, 'justificativa', a.justificativa,
                                                        'por', (select u.nome from erp.usuarios u where u.id = a.por), 'em', a.em) order by a.em)
                     from erp.orcamento_aprovacoes a where a.versao_id = v.id), '[]'::jsonb),
         v.situacao = 'rascunho' and erp.escrevo()
           and (erp.sou_master() or exists (select 1 from erp.centro_aprovadores a where a.centro_custo_id = v.centro_custo_id and a.user_id = erp.eu())),
         case when v.situacao = 'rascunho' and v.enviado_em is not null then erp.minha_vaga_orcamento(v.id) end
    from erp.orcamento_versoes v
    join erp.nucleos_economicos n on n.id = v.nucleo_economico_id
    join erp.centros_custo c on c.id = v.centro_custo_id
   where v.tipo = 'area' and v.situacao in ('vigente', 'rascunho') $$;

-- Um orçamento com as linhas: orçado, consumido pelos títulos e o realizado (títulos não cancelados da mesma natureza
-- e mês, no nível da linha ou abaixo, que a pessoa vê).
create function api.orcamento_area(p_versao uuid) returns jsonb
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select jsonb_build_object('id', v.id, 'nucleo', v.nucleo_economico_id, 'centro', v.centro_custo_id, 'ano', v.ano,
           'situacao', v.situacao, 'enviado_em', v.enviado_em, 'substitui', v.substitui_id,
           'linhas', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', l.id, 'natureza', l.natureza_id, 'natureza_nome', vn.caminho,
                      'nivel', coalesce(l.subdivisao_id, l.divisao_id),
                      'area', erp.area_linha(l.centro_custo_id, l.divisao_id, l.subdivisao_id),
                      'competencia', l.competencia, 'data_caixa', l.data_caixa, 'orcado', -l.valor,
                      'consumido', (select coalesce(sum(tp.valor), 0) from erp.previsoes q
                                      join erp.titulo_previsoes tp on tp.previsao_id = q.id join erp.titulos t on t.id = tp.titulo_id
                                     where q.orcamento_linha_id is not null and t.situacao <> 'cancelado'
                                       and q.nucleo_economico_id = l.nucleo_economico_id and q.centro_custo_id = l.centro_custo_id
                                       and q.natureza_id = l.natureza_id and q.competencia = l.competencia
                                       and coalesce(q.subdivisao_id, q.divisao_id) is not distinct from coalesce(l.subdivisao_id, l.divisao_id)),
                      'realizado', (select coalesce(round(sum(t.valor * r.percentual / 100), 2), 0)
                                      from erp.titulos t join erp.titulo_rateios r on r.titulo_id = t.id
                                     where t.sentido = 'pagar' and t.situacao <> 'cancelado'
                                       and erp.mes(t.competencia) = l.competencia
                                       and r.nucleo_economico_id = l.nucleo_economico_id and r.centro_custo_id = l.centro_custo_id
                                       and r.natureza_id = l.natureza_id
                                       and erp.nivel_acima(coalesce(l.subdivisao_id, l.divisao_id), coalesce(r.subdivisao_id, r.divisao_id))))
                    order by l.competencia, vn.caminho)
               from erp.orcamento_linhas l left join erp.v_naturezas vn on vn.id = l.natureza_id
              where l.versao_id = v.id), '[]'::jsonb))
    from erp.orcamento_versoes v where v.id = p_versao and v.tipo = 'area' $$;

create function api.criar_orcamento_area(p_nucleo uuid, p_centro uuid, p_ano int) returns uuid
language sql volatile security invoker set search_path = pg_catalog, pg_temp as $$ select erp.criar_orcamento_area(p_nucleo, p_centro, p_ano) $$;
create function api.salvar_orcamento_area(p_versao uuid, p_linhas jsonb) returns int
language sql volatile security invoker set search_path = pg_catalog, pg_temp as $$ select erp.salvar_orcamento_area(p_versao, p_linhas) $$;
create function api.enviar_orcamento(p_versao uuid) returns void
language sql volatile security invoker set search_path = pg_catalog, pg_temp as $$ select erp.enviar_orcamento(p_versao) $$;
create function api.descartar_orcamento(p_versao uuid) returns void
language sql volatile security invoker set search_path = pg_catalog, pg_temp as $$ select erp.descartar_orcamento(p_versao) $$;
-- Marca (com o motivo) ou desmarca (motivo vazio) a nota em rascunho como fora do orçamento, pelo RLS de quem chama.
create function api.fora_orcamento(p_documento uuid, p_motivo text) returns void
language plpgsql volatile security invoker set search_path = pg_catalog, pg_temp as $$
begin
  perform erp.exigir_editor();
  delete from erp.documentos_fora_orcamento where documento_id = p_documento;
  if length(trim(coalesce(p_motivo, ''))) > 0 then
    insert into erp.documentos_fora_orcamento (documento_id, motivo) values (p_documento, trim(p_motivo));
  end if;
end $$;
-- a tela Para aprovar decide o orçamento pelo mesmo api.decidir
select pg_temp.recriar('api.decidir(text, uuid, text, text, uuid, uuid)'::regprocedure, '3fa9d42a307ab21c93a4033901c48cc1', $def$CREATE OR REPLACE FUNCTION api.decidir(p_tipo text, p_id uuid, p_decisao text, p_justificativa text DEFAULT NULL::text, p_centro uuid DEFAULT NULL::uuid, p_divisao uuid DEFAULT NULL::uuid)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
begin
  if p_decisao not in ('aprovar', 'recusar', 'revisao') then raise exception 'Decisão inválida'; end if;
  if p_decisao = 'revisao' and p_tipo <> 'titulo' then raise exception 'Só o título volta para revisão'; end if;
  return case p_tipo
    when 'titulo' then erp.decidir_titulo(p_id, p_decisao = 'aprovar', nullif(trim(p_justificativa), ''), p_decisao = 'revisao', p_centro, p_divisao)
    when 'previsao' then erp.decidir_previsao(p_id, p_decisao = 'aprovar', nullif(trim(p_justificativa), ''), p_centro, p_divisao)
    when 'orcamento' then erp.decidir_orcamento(p_id, p_decisao = 'aprovar', nullif(trim(p_justificativa), ''))
    when 'contrato' then erp.decidir_compromisso(p_id, p_decisao = 'aprovar', nullif(trim(p_justificativa), ''))
    else null end;
end $function$$def$);

-- ---------------------------------------------------------------------------------------------
-- 9. Segurança
-- ---------------------------------------------------------------------------------------------
select pg_temp.tabela('orcamento_aprovacoes');
select pg_temp.tabela('documentos_fora_orcamento');
-- lê quem vê o orçamento (a versão, como as outras: todo membro) e a nota; a marca de fora do orçamento, quem
-- lança na nota grava e tira
create policy perfil_le on erp.orcamento_aprovacoes for select to authenticated using (erp.membro());
create policy perfil_le on erp.documentos_fora_orcamento for select to authenticated using (erp.vejo_documento(documento_id));
create policy perfil_inclui on erp.documentos_fora_orcamento for insert to authenticated with check (erp.lanco_documento(documento_id));
create policy perfil_apaga on erp.documentos_fora_orcamento for delete to authenticated using (erp.lanco_documento(documento_id));
grant select on erp.orcamento_aprovacoes to authenticated;
grant select, insert, delete on erp.documentos_fora_orcamento to authenticated;
select pg_temp.auditar('orcamento_aprovacoes', 'id');
select pg_temp.auditar('documentos_fora_orcamento', 'documento_id');

do $$
declare f regprocedure;
begin
  foreach f in array array['erp.tg_lista_centros()', 'erp.tg_orcamento_area()', 'erp.tg_orcamento_aprovacao()', 'erp.tg_fora_orcamento()',
    'erp._hoje_sp()', 'erp._mes_orcamento_vale(date)', 'erp._refazer_orcamento(uuid, uuid, uuid, uuid, date)', 'erp.tg_refazer_orcamento()',
    'erp._consumir_orcamento(uuid, erp.documentos_fiscais)', 'erp.orcamento_vencer()', 'erp._gestor_orcamento(uuid, uuid)',
    'erp._vaga_orcamento(uuid, uuid)', 'erp.orcamento_aprovado(uuid)', 'erp._orcamento_passado_igual(uuid, uuid)',
    'erp._publicar_orcamento_area(uuid)', 'erp.criar_orcamento_area(uuid, uuid, int)', 'erp.salvar_orcamento_area(uuid, jsonb)',
    'erp.enviar_orcamento(uuid)', 'erp.descartar_orcamento(uuid)', 'erp.decidir_orcamento(uuid, boolean, text)',
    'erp.minha_vaga_orcamento(uuid)']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('revoke execute on function %s from authenticated', f); end if;
    execute format('grant execute on function %s to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config', f);
  end loop;
  foreach f in array array['api.orcamentos_area()', 'api.orcamento_area(uuid)', 'api.criar_orcamento_area(uuid, uuid, int)',
    'api.salvar_orcamento_area(uuid, jsonb)', 'api.enviar_orcamento(uuid)', 'api.descartar_orcamento(uuid)',
    'api.fora_orcamento(uuid, text)']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('grant execute on function %s to authenticated', f); end if;
  end loop;
end $$;
-- quem está logado: as operações do orçamento, a vaga dele, e os gatilhos que as tabelas dele disparam
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function erp.criar_orcamento_area(uuid, uuid, int), erp.salvar_orcamento_area(uuid, jsonb), erp.enviar_orcamento(uuid),
      erp.descartar_orcamento(uuid), erp.decidir_orcamento(uuid, boolean, text), erp.minha_vaga_orcamento(uuid),
      erp.tg_orcamento_area(), erp.tg_orcamento_aprovacao(), erp.tg_fora_orcamento(), erp._hoje_sp(), erp._mes_orcamento_vale(date)
      to authenticated;
  end if;
end $$;
do $$
declare f text;
begin
  foreach f in array array['erp._refazer_orcamento(uuid, uuid, uuid, uuid, date)', 'erp.tg_refazer_orcamento()', 'erp.orcamento_vencer()',
    'erp._publicar_orcamento_area(uuid)', 'erp.criar_orcamento_area(uuid, uuid, int)', 'erp.salvar_orcamento_area(uuid, jsonb)',
    'erp.enviar_orcamento(uuid)', 'erp.descartar_orcamento(uuid)', 'erp.decidir_orcamento(uuid, boolean, text)',
    'erp.minha_vaga_orcamento(uuid)'] loop
    execute format('alter function %s security definer set search_path = erp, pg_catalog, pg_temp', f);
  end loop;
end $$;
-- As operações gravam como erp_situacao (as previsões, a aprovação, a versão); a vaga lê as listas por baixo do RLS.
-- O gatilho que refaz a linha é do erp_situacao: o título de quem lança refaz a previsão que ele não grava.
select pg_temp.dono(f::regprocedure, 'erp_situacao') from unnest(array[
  'erp._refazer_orcamento(uuid, uuid, uuid, uuid, date)', 'erp.tg_refazer_orcamento()', 'erp.orcamento_vencer()',
  'erp._publicar_orcamento_area(uuid)', 'erp.criar_orcamento_area(uuid, uuid, int)', 'erp.salvar_orcamento_area(uuid, jsonb)',
  'erp.enviar_orcamento(uuid)', 'erp.descartar_orcamento(uuid)', 'erp.decidir_orcamento(uuid, boolean, text)']) f;
select pg_temp.dono('erp.minha_vaga_orcamento(uuid)'::regprocedure, 'erp_conferencia');

-- conferências (dão erro e desfazem tudo se algo não ficou certo)
do $$ begin
  if pg_get_functiondef('erp.lancar_documento(uuid, date[], uuid[], numeric[])'::regprocedure) not like '%erp._consumir_orcamento(v_tit, d)%'
     or pg_get_functiondef('erp.sienge_enfileirar()'::regprocedure) not like '%erp.orcamento_vencer()%'
     or pg_get_functiondef('erp._ocupa_vaga(text, uuid, uuid)'::regprocedure) not like '%AO_CENTRO%'
     or pg_get_functiondef('api.decidir(text, uuid, text, text, uuid, uuid)'::regprocedure) not like '%erp.decidir_orcamento%' then
    raise exception 'Conferência: troca nas funções';
  end if;
  if (select count(*) from pg_proc where pronamespace = 'erp'::regnamespace and prosecdef
        and proname in ('_refazer_orcamento','tg_refazer_orcamento','orcamento_vencer','_publicar_orcamento_area','criar_orcamento_area',
                        'salvar_orcamento_area','enviar_orcamento','descartar_orcamento','decidir_orcamento','minha_vaga_orcamento')) <> 10 then
    raise exception 'Conferência: funções definer';
  end if;
  if exists (select 1 from pg_namespace n where n.nspname = 'erp'
              and (has_schema_privilege('erp_situacao', n.oid, 'create') or has_schema_privilege('erp_conferencia', n.oid, 'create'))) then
    raise exception 'Conferência: create no esquema sobrou';
  end if;
end $$;
revoke erp_conferencia, erp_situacao, erp_acesso from current_user;
do $$ begin
  if current_setting('bkm.tirar_erp_sistema', true) = 'sim' then execute format('revoke erp_sistema from %I', current_user); end if;
end $$;
commit;

-- Depois do commit (devem dar true)
select pg_has_role('erp_sistema', 'SET') = (select count(*) > 0 from pg_auth_members where roleid = 'erp_sistema'::regrole and member = current_user::regrole) as erp_sistema_como_antes,
       (select relforcerowsecurity from pg_class where oid = 'erp.orcamento_aprovacoes'::regclass) as rls_aprovacoes,
       (select relforcerowsecurity from pg_class where oid = 'erp.documentos_fora_orcamento'::regclass) as rls_fora,
       not has_function_privilege('authenticated', 'erp._refazer_orcamento(uuid, uuid, uuid, uuid, date)', 'EXECUTE') as refazer_fora_da_api,
       has_function_privilege('authenticated', 'api.orcamento_area(uuid)', 'EXECUTE') as tela_na_api;

-- Para desfazer: não há volta simples (troca várias funções). Recriar o bkm_dev a partir das migrations sem esta.
