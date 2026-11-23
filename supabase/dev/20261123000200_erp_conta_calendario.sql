-- bkm_dev, 23/nov/2026: previsão mês a mês da conta recorrente (migration 20261123000200). Colar inteiro no SQL Editor.
-- Se a conferência do fim falhar, dá erro e nada fica.
--
-- O postgres não é superusuário no bkm_dev: ele se dá erp_conferencia (para o gatilho de auditoria) e erp_situacao (dono
-- do gatilho da versão e do erp.gerar_previsoes_assinatura), só com set e sem herdar, e o create no esquema para o
-- erp_situacao; tudo sai antes do commit.
begin;
grant erp_conferencia to current_user with inherit false, set true;
grant erp_situacao to current_user with inherit false, set true;
grant create on schema erp to erp_situacao;

-- Previsão mês a mês da conta recorrente (Moises, 23/nov/2026): o cadastro do contrato de serviço, da assinatura
-- mensal e da conta de consumo pode ter um valor por mês, no lugar do valor igual todo mês. Regras aprovadas por ele
-- no mesmo dia ("1) ok 2) ok 3) ok 4) ok"):
--   1. Contrato de serviço: a soma dos meses tem de bater com o valor do contrato. Se não bate, a tela pergunta se
--      ajusta o contrato (o valor vira a soma) ou o calendário, e faz o ajuste escolhido; o banco só aceita igual.
--      O contrato com calendário tem data de fim e todos os meses da vigência.
--   2. Conta sem data de fim: a tela mostra 12 meses; depois do último mês gravado vale o valor do último mês
--      (erp.valor_do_mes), então o calendário "anda" sozinho sem gravar nada.
--   3. Conta de consumo: o mês a mês é a previsão de cada mês (a comparação da fatura com o mês entra no PR das notas);
--      os meses de cada ano somam no máximo o teto no ano.
--   4. Mudar um mês muda a versão do cadastro e ele volta para a aprovação, como mudar o valor. Depois da primeira
--      aprovação, os meses que já passaram não mudam (nem se incluem nem se apagam).
-- Sem calendário, nada muda: vale o valor igual. Assinatura com período maior que o mês (bimestral...) não tem
-- calendário nesta versão (leitura minha).
-- As previsões da assinatura passam a usar o valor de cada mês (erp.gerar_previsoes_assinatura); o mês com zero não
-- gera previsão. Gerar as previsões sozinhas e refazê-las quando o calendário muda fica para o PR das previsões.
-- Portabilidade: SQL e plpgsql padrão.

create table erp.compromisso_meses (
  compromisso_id uuid not null references erp.compromissos on delete cascade,
  competencia    date not null check (extract(day from competencia) = 1),
  valor          numeric(15,2) not null check (valor >= 0),
  primary key (compromisso_id, competencia)
);
alter table erp.compromisso_meses enable row level security;
alter table erp.compromisso_meses force row level security;
create policy sistema on erp.compromisso_meses using (erp.sistema()) with check (erp.sistema());
create policy conferencia on erp.compromisso_meses for select to erp_conferencia using (true);
create policy operacao on erp.compromisso_meses to erp_situacao, erp_reclassificacao, erp_acesso using (true) with check (true);
create policy perfil_le on erp.compromisso_meses for select to authenticated using (erp.vejo_compromisso(compromisso_id));
create policy perfil_inclui on erp.compromisso_meses for insert to authenticated with check (erp.lanco_compromisso(compromisso_id));
create policy perfil_altera on erp.compromisso_meses for update to authenticated
  using (erp.lanco_compromisso(compromisso_id)) with check (erp.lanco_compromisso(compromisso_id));
create policy perfil_apaga on erp.compromisso_meses for delete to authenticated using (erp.lanco_compromisso(compromisso_id));
revoke all on erp.compromisso_meses from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke all on erp.compromisso_meses from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then revoke all on erp.compromisso_meses from service_role; end if;
end $$;
grant select, insert, update, delete on erp.compromisso_meses to authenticated, erp_sistema, erp_situacao, erp_reclassificacao, erp_acesso;
grant select on erp.compromisso_meses to erp_conferencia;
create trigger t_nao_trunca before truncate on erp.compromisso_meses for each statement execute function erp.tg_recusa_truncate();
-- o postgres não executa erp.tg_auditoria: o gatilho é criado como erp_conferencia, com o direito de gatilho só aqui
grant trigger on erp.compromisso_meses to erp_conferencia;
set local role erp_conferencia;
create trigger t_aud_compromisso_meses after insert or update or delete on erp.compromisso_meses
  for each row execute function erp.tg_auditoria('compromisso_id');
reset role;
revoke trigger on erp.compromisso_meses from erp_conferencia;

-- Mudou um mês: versão nova do cadastro (volta para a aprovação). Depois da primeira aprovação, mês passado não muda.
-- Definer do erp_situacao, como erp.tg_rateio_versao: só ele põe a versão.
create function erp.tg_meses_versao() returns trigger language plpgsql
security definer set search_path = erp, pg_catalog, pg_temp as $$
declare v_id uuid := coalesce(new.compromisso_id, old.compromisso_id); v_hoje date := erp.mes(current_date);
begin
  if tg_op = 'UPDATE' and new.valor = old.valor and new.competencia = old.competencia and new.compromisso_id = old.compromisso_id then
    return null;
  end if;
  if tg_op = 'UPDATE' and new.compromisso_id <> old.compromisso_id then raise exception 'O mês não muda de conta'; end if;
  if not erp.sistema()
     and exists (select 1 from erp.compromisso_aprovacoes a where a.compromisso_id = v_id and a.aprovado)
     and ((tg_op <> 'INSERT' and old.competencia < v_hoje) or (tg_op <> 'DELETE' and new.competencia < v_hoje)) then
    raise exception 'Mês que já passou não muda no calendário';
  end if;
  update erp.compromissos set aprovacao_versao = aprovacao_versao + 1, alterado_por = erp.autor() where id = v_id;
  return null;
end $$;
create trigger t_versao after insert or update or delete on erp.compromisso_meses
  for each row execute function erp.tg_meses_versao();

-- O calendário bate com o cadastro? Roda no fim da transação (o cadastro e os meses mudam juntos em api.salvar_conta).
create function erp._meses_conferem(p_id uuid) returns void language plpgsql stable as $$
declare c erp.compromissos; v_n int; v_soma numeric; v_min date; v_max date; v_meses int; a record;
begin
  select * into c from erp.compromissos where id = p_id;
  if c.id is null then return; end if;
  select count(*), coalesce(sum(valor), 0), min(competencia), max(competencia) into v_n, v_soma, v_min, v_max
    from erp.compromisso_meses where compromisso_id = p_id;
  if v_n = 0 then return; end if;
  if c.tipo not in ('contrato', 'assinatura', 'consumo') then
    raise exception 'Só contrato de serviço, assinatura e conta de consumo têm previsão mês a mês';
  end if;
  if c.tipo in ('assinatura', 'consumo') and c.periodicidade is distinct from 'mensal' then
    raise exception 'A previsão mês a mês só vale para conta mensal';
  end if;
  if v_min < erp.mes(c.inicio) or (c.fim is not null and v_max > erp.mes(c.fim)) then
    raise exception 'Há mês do calendário fora da vigência';
  end if;
  if c.tipo = 'contrato' then
    if c.fim is null then raise exception 'Contrato com previsão mês a mês precisa da data de fim'; end if;
    v_meses := (extract(year from c.fim)::int - extract(year from c.inicio)::int) * 12
               + extract(month from c.fim)::int - extract(month from c.inicio)::int + 1;
    if v_n <> v_meses then raise exception 'O calendário do contrato precisa ter todos os meses da vigência'; end if;
    if v_soma <> c.valor_total then
      raise exception 'A soma dos meses (R$ %) não bate com o valor do contrato (R$ %)',
        translate(to_char(v_soma, 'FM999,999,999,990.00'), ',.', '.,'), translate(to_char(c.valor_total, 'FM999,999,999,990.00'), ',.', '.,');
    end if;
  end if;
  if c.tipo = 'consumo' then
    for a in select extract(year from competencia)::int ano, sum(valor) s from erp.compromisso_meses
              where compromisso_id = p_id group by 1 having sum(valor) > c.teto_anual order by 1 loop
      raise exception 'Os meses de % somam R$ %, acima do teto no ano (R$ %)', a.ano,
        translate(to_char(a.s, 'FM999,999,999,990.00'), ',.', '.,'), translate(to_char(c.teto_anual, 'FM999,999,999,990.00'), ',.', '.,');
    end loop;
  end if;
end $$;

create function erp.tg_meses_conferem() returns trigger language plpgsql as $$
begin
  if tg_table_name = 'compromissos' then perform erp._meses_conferem(new.id);
  else perform erp._meses_conferem(coalesce(new.compromisso_id, old.compromisso_id));
  end if;
  return null;
end $$;
create constraint trigger t_meses_conferem after insert or update or delete on erp.compromisso_meses
  deferrable initially deferred for each row execute function erp.tg_meses_conferem();
create constraint trigger t_meses_conferem after update of tipo, inicio, fim, valor_total, periodicidade, teto_anual on erp.compromissos
  deferrable initially deferred for each row execute function erp.tg_meses_conferem();

-- O valor previsto de um mês: o do calendário; sem o mês no calendário, o do último mês gravado antes dele (conta sem
-- fim, que "anda" sozinha); sem calendário, o valor igual (contrato: o valor ÷ os meses da vigência). Nulo = não sabe.
create function erp.valor_do_mes(p_id uuid, p_mes date) returns numeric language sql stable as $$
  select coalesce(
    (select m.valor from erp.compromisso_meses m where m.compromisso_id = p_id and m.competencia = erp.mes(p_mes)),
    (select m.valor from erp.compromisso_meses m where m.compromisso_id = p_id and m.competencia < erp.mes(p_mes)
      order by m.competencia desc limit 1),
    (select case c.tipo when 'assinatura' then c.valor_periodo when 'consumo' then c.faixa_mensal
                        when 'contrato' then case when c.fim is not null then round(c.valor_total /
                          ((extract(year from c.fim)::int - extract(year from c.inicio)::int) * 12
                           + extract(month from c.fim)::int - extract(month from c.inicio)::int + 1), 2) end end
       from erp.compromissos c where c.id = p_id
        and not exists (select 1 from erp.compromisso_meses m where m.compromisso_id = p_id))) $$;

-- As previsões da assinatura com o valor de cada mês (mesmo corpo do 20261117000300, com erp.valor_do_mes).
set local role erp_situacao;
create or replace function erp.gerar_previsoes_assinatura(p_compromisso uuid, p_ate date) returns int
language plpgsql security definer set search_path = erp, pg_catalog, pg_temp as $$
declare c erp.compromissos; d date; v_passo interval; n int := 0; r record; v numeric;
begin
  perform erp.exigir_editor();
  select * into c from erp.compromissos where id = p_compromisso;
  if c.id is null or not (erp.sistema() or erp.lanco_compromisso(c.id)) then raise exception 'Contrato não existe'; end if;
  if c.tipo <> 'assinatura' or c.situacao <> 'ativo' then raise exception 'Só assinatura ativa gera previsões'; end if;
  if not erp.rateio_completo('compromisso', c.id) then raise exception 'O rateio da assinatura não soma 100%%'; end if;
  v_passo := case c.periodicidade when 'mensal' then '1 month' when 'bimestral' then '2 months'
             when 'trimestral' then '3 months' when 'semestral' then '6 months' else '1 year' end::interval;
  d := erp.mes(c.inicio);
  while d <= least(p_ate, coalesce(c.fim, p_ate)) loop
    v := erp.valor_do_mes(c.id, d);
    if v > 0 and not exists (select 1 from erp.previsoes where compromisso_id = c.id and competencia = d and situacao <> 'cancelada') then
      for r in select * from erp.ratear('compromisso', c.id, v) loop
        insert into erp.previsoes (empresa_id, origem, compromisso_id, pessoa_id, nucleo_economico_id, natureza_id,
                                      centro_custo_id, divisao_id, subdivisao_id, competencia, data_prevista, valor, descricao)
        values (c.empresa_id, 'assinatura', c.id, c.pessoa_id, r.nucleo_economico_id, r.natureza_id, r.centro_custo_id, r.divisao_id, r.subdivisao_id,
                d, least(d + (coalesce(c.dia_vencimento, 1) - 1), (d + interval '1 month - 1 day')::date),
                r.valor, c.descricao);
      end loop;
      n := n + 1;
    end if;
    d := (d + v_passo)::date;
  end loop;
  return n;
end $$;
reset role;

-- ---------------------------------------------------------------------------------------------
-- API: o cadastro devolve e grava os meses
-- ---------------------------------------------------------------------------------------------
-- api.conta ganha 'meses' (o calendário gravado) e 'trava_antes' (o primeiro mês que ainda muda, quando a conta já foi
-- aprovada alguma vez; nulo = todos mudam).
create or replace function api.conta(p_id uuid) returns jsonb language sql stable security invoker
set search_path = pg_catalog, pg_temp as $$
  select jsonb_build_object('id', c.id, 'empresa', c.empresa_id, 'tipo', c.tipo, 'numero', c.numero, 'descricao', c.descricao,
           'fornecedor', (select jsonb_build_object('id', pe.id, 'nome', pe.nome, 'nome_fantasia', pe.nome_fantasia,
                                                    'documento', pe.documento, 'tipo', pe.tipo)
                            from erp.pessoas pe where pe.id = c.pessoa_id),
           'inicio', c.inicio, 'fim', c.fim, 'periodicidade', c.periodicidade, 'valor_periodo', c.valor_periodo,
           'valor_total', c.valor_total, 'dia_vencimento', c.dia_vencimento, 'caucao_percentual', c.caucao_percentual,
           'instalacao', c.instalacao, 'faixa_mensal', c.faixa_mensal, 'teto_anual', c.teto_anual, 'situacao', c.situacao,
           'rateio', coalesce((select jsonb_agg(jsonb_build_object('nucleo', r.nucleo_economico_id, 'centro', r.centro_custo_id,
                                 'divisao', coalesce(r.subdivisao_id, r.divisao_id), 'natureza', r.natureza_id,
                                 'percentual', r.percentual) order by r.percentual desc, r.id)
                                from erp.compromisso_rateios r where r.compromisso_id = c.id), '[]'::jsonb),
           'meses', coalesce((select jsonb_agg(jsonb_build_object('mes', m.competencia, 'valor', m.valor) order by m.competencia)
                                from erp.compromisso_meses m where m.compromisso_id = c.id), '[]'::jsonb),
           'trava_antes', case when exists (select 1 from erp.compromisso_aprovacoes a where a.compromisso_id = c.id and a.aprovado)
                               then erp.mes(current_date) end)
    from erp.compromissos c
   where c.id = p_id and c.tipo in ('contrato', 'assinatura', 'consumo') $$;

-- api.salvar_conta grava também p->'meses' quando vem (lista vazia ou nula = sem calendário; ausente = não mexe). Só
-- toca o mês que mudou, para não mexer em mês passado sem necessidade. Remendo sobre o corpo do 20261120000100.
do $$
declare v text; v_ancora text := E'  if not erp.rateio_completo(''compromisso'', v_id) then raise exception ''O rateio precisa somar 100%%''; end if;\n  return v_id;';
begin
  v := pg_get_functiondef('api.salvar_conta(jsonb)'::regprocedure);
  if position(v_ancora in v) = 0 then raise exception 'api.salvar_conta mudou: refazer o remendo'; end if;
  v := replace(v, v_ancora, E'  if not erp.rateio_completo(''compromisso'', v_id) then raise exception ''O rateio precisa somar 100%%''; end if;\n'
    || E'  if p ? ''meses'' then\n'
    || E'    if jsonb_typeof(p->''meses'') = ''array'' and jsonb_array_length(p->''meses'') > 0 then\n'
    || E'      if exists (select 1 from jsonb_array_elements(p->''meses'') e(x) where nullif(e.x->>''mes'', '''') is null\n'
    || E'                   or nullif(e.x->>''valor'', '''') is null or (e.x->>''valor'')::numeric < 0) then\n'
    || E'        raise exception ''Cada mês precisa da data e de um valor (zero ou mais)'';\n'
    || E'      end if;\n'
    || E'      delete from erp.compromisso_meses m where m.compromisso_id = v_id\n'
    || E'         and not exists (select 1 from jsonb_array_elements(p->''meses'') e(x) where (e.x->>''mes'')::date = m.competencia);\n'
    || E'      insert into erp.compromisso_meses as m (compromisso_id, competencia, valor)\n'
    || E'      select v_id, (e.x->>''mes'')::date, round((e.x->>''valor'')::numeric, 2) from jsonb_array_elements(p->''meses'') e(x)\n'
    || E'      on conflict (compromisso_id, competencia) do update set valor = excluded.valor where m.valor is distinct from excluded.valor;\n'
    || E'    else\n'
    || E'      delete from erp.compromisso_meses where compromisso_id = v_id;\n'
    || E'    end if;\n'
    || E'  end if;\n'
    || E'  return v_id;');
  execute v;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Donos e EXECUTE
-- ---------------------------------------------------------------------------------------------
do $$
declare f regprocedure;
begin
  foreach f in array array['erp.tg_meses_versao()', 'erp._meses_conferem(uuid)', 'erp.tg_meses_conferem()',
                           'erp.valor_do_mes(uuid, date)']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('revoke execute on function %s from authenticated', f);
    execute format('grant execute on function %s to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso', f);
  end loop;
end $$;
-- A conferência do calendário roda no gatilho de quem grava (invoker): precisa do EXECUTE. O valor do mês é leitura
-- invoker, pelo RLS de quem chama. As funções de gatilho não se chamam direto.
grant execute on function erp._meses_conferem(uuid), erp.valor_do_mes(uuid, date) to authenticated;

-- o dono do gatilho da versão (o gerar_previsoes_assinatura já é do erp_situacao)
alter function erp.tg_meses_versao() owner to erp_situacao;

-- Conferência antes do commit (como postgres: só lê o catálogo).
do $$ begin
  if (select count(*) from pg_proc where oid in ('erp.tg_meses_versao()'::regprocedure, 'erp.gerar_previsoes_assinatura(uuid,date)'::regprocedure)
        and prosecdef and pg_get_userbyid(proowner) = 'erp_situacao') <> 2 then
    raise exception 'Conferência: dono e definer';
  end if;
  if pg_get_functiondef('erp.gerar_previsoes_assinatura(uuid,date)'::regprocedure) not like '%erp.valor_do_mes(c.id, d)%'
     or pg_get_functiondef('api.salvar_conta(jsonb)'::regprocedure) not like '%erp.compromisso_meses%'
     or pg_get_functiondef('api.conta(uuid)'::regprocedure) not like '%trava_antes%' then
    raise exception 'Conferência: troca nas funções';
  end if;
  if (select count(*) from pg_trigger where tgrelid = 'erp.compromisso_meses'::regclass and not tgisinternal) <> 4
     or not exists (select 1 from pg_trigger where tgrelid = 'erp.compromissos'::regclass and tgname = 't_meses_conferem') then
    raise exception 'Conferência: gatilhos';
  end if;
  if not (select relrowsecurity and relforcerowsecurity from pg_class where oid = 'erp.compromisso_meses'::regclass)
     or has_table_privilege('anon', 'erp.compromisso_meses', 'SELECT')
     or has_function_privilege('authenticated', 'erp.tg_meses_versao()', 'EXECUTE') then
    raise exception 'Conferência: RLS e permissões';
  end if;
end $$;
revoke create on schema erp from erp_situacao;
revoke erp_situacao from current_user;
revoke erp_conferencia from current_user;
commit;

-- Depois do commit (devem dar true)
select not has_schema_privilege('erp_situacao', 'erp', 'create') as sem_create,
       not pg_has_role(current_user, 'erp_situacao', 'MEMBER') and not pg_has_role(current_user, 'erp_conferencia', 'MEMBER') as sem_papeis,
       has_table_privilege('authenticated', 'erp.compromisso_meses', 'SELECT') as api_le_meses;

-- Para desfazer: drop table erp.compromisso_meses cascade; drop function erp.tg_meses_versao(), erp.tg_meses_conferem(),
-- erp._meses_conferem(uuid), erp.valor_do_mes(uuid, date); rodar de novo erp.gerar_previsoes_assinatura da migration
-- 20261117000300 (como erp_situacao), api.conta da 20261120000100 e tirar o bloco dos meses de api.salvar_conta.
