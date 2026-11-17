-- Testes do banco espelho do Sienge (esquemas sienge_bruto e sienge). Dados inventados.
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = notice;

create function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(cond,false) then raise exception 'FALHOU: %', msg; end if; raise notice 'ok  %', msg; end $$;
create function pg_temp.falha(sqlcmd text, msg text) returns void language plpgsql as $$
begin
  begin execute sqlcmd; exception when others then raise notice 'ok  % (%)', msg, sqlerrm; return; end;
  raise exception 'FALHOU: esperava erro em %', msg;
end $$;

\echo '# espelho do Sienge'
begin;

-- uma parcela inventada no formato da massa /outcome
create function pg_temp.parcela(titulo int, parcela int, empresa int, valor numeric, saldo numeric) returns jsonb
language sql as $$
  select jsonb_build_object(
    'billId', titulo, 'installmentId', parcela, 'companyId', empresa, 'companyName', 'EMPRESA ' || empresa,
    'creditorId', 900, 'creditorName', 'Fornecedor Teste', 'documentIdentificationId', 'NFSE ',
    'documentNumber', '123', 'forecastDocument', 'N', 'originId', 'CP',
    'issueDate', '2026-03-10', 'billDate', '2026-03-10', 'dueDate', '2026-04-10', 'installmentBaseDate', '2026-03-10',
    'originalAmount', valor, 'balanceAmount', saldo, 'correctedBalanceAmount', saldo, 'discountAmount', 0, 'taxAmount', 0,
    'indexerId', 0, 'authorizationStatus', 'S', 'consistencyStatus', 'S',
    'registeredUserId', 'USUARIO.TESTE', 'registeredBy', 'Usuario Teste', 'registeredDate', '2026-03-10 09:15:00',
    'paymentsCategories', jsonb_build_array(
      jsonb_build_object('costCenterId', 8, 'costCenterName', 'SPE 03 - MARKETING', 'financialCategoryId', '2010505',
                         'financialCategoryName', 'COMISSAO SALDO', 'financialCategoryRate', 60,
                         'financialCategoryReducer', 'N', 'financialCategoryType', 'D'),
      jsonb_build_object('costCenterId', 8, 'costCenterName', 'SPE 03 - MARKETING', 'financialCategoryId', '2030224',
                         'financialCategoryName', 'OUTRAS DESPESAS DE PESSOAL', 'financialCategoryRate', 40,
                         'financialCategoryReducer', 'N', 'financialCategoryType', 'D')),
    'buildingsCosts', jsonb_build_array(jsonb_build_object('buildingId', 13, 'buildingName', 'OBRA TESTE',
                         'buildingUnitId', 1, 'buildingUnitName', 'U1', 'costEstimationSheetId', 'A', 'costEstimationSheetName', 'P', 'rate', 100)),
    'departamentsCosts', '[]'::jsonb,
    'authorizations', jsonb_build_array(jsonb_build_object('authorizationDate', '2026-03-11 10:00:00',
                         'authorizationUserId', 'GESTOR.TESTE', 'authorizationUserName', 'Gestor Teste', 'isLastToAuthorize', 'S')),
    'payments', case when saldo = 0 then jsonb_build_array(
      jsonb_build_object('sequencialNumber', 1, 'paymentDate', '2026-04-10', 'calculationDate', '2026-04-10',
        'operationTypeId', 1, 'operationTypeName', 'PAGAMENTO', 'grossAmount', valor, 'netAmount', valor,
        'correctedNetAmount', null, 'interestAmount', 0, 'fineAmount', 0, 'discountAmount', 0,
        'monetaryCorrectionAmount', 0, 'taxAmount', 0, 'paymentAuthentication', '',
        'bankMovements', jsonb_build_array(jsonb_build_object('id', 77, 'accountCompanyId', empresa, 'accountNumber', 'CC-1',
          'accountType', 'C', 'amount', valor, 'bankMovementDate', '2026-04-10', 'operationType', 'D', 'reconcile', 'S',
          'paymentCategories', '[]'::jsonb)))) else '[]'::jsonb end)
$$;

insert into sienge.cargas (recurso, parametros, janela_inicio, janela_fim, situacao)
values ('bulk:outcome', '{"selectionType":"I"}', '2026-01-01', '2026-12-31', 'rodando');

-- 1. camada bruta: a Muchmore sai antes de gravar
select sienge.gravar_resposta(1, 'bulk:outcome', '/outcome?selectionType=I', 1, 200, '{"x-ratelimit-remaining-day":"13"}',
  jsonb_build_object('data', jsonb_build_array(pg_temp.parcela(10, 1, 5, 100, 0), pg_temp.parcela(10, 2, 5, 100, 100),
                                               pg_temp.parcela(11, 1, 1, 50, 50)))::text, '2026-11-17 01:00+00') as r1 \gset
select pg_temp.ok((select linhas = 2 and descartadas = 1 from sienge_bruto.respostas where id = :r1),
  'bruto: a parcela da Muchmore (empresa 1) sai antes de gravar e fica contada');
select pg_temp.ok(not exists (select 1 from sienge_bruto.respostas r, jsonb_array_elements(r.corpo -> 'data') x
                               where (x ->> 'companyId') = '1'),
  'bruto: nada da Muchmore fica no corpo gravado');
select pg_temp.ok(sienge.gravar_resposta(1, 'bulk:outcome', '/outcome?selectionType=I', 1, 200, '{}',
  jsonb_build_object('data', jsonb_build_array(pg_temp.parcela(10, 1, 5, 100, 0), pg_temp.parcela(10, 2, 5, 100, 100),
                                               pg_temp.parcela(11, 1, 1, 50, 50)))::text, '2026-11-17 02:00+00') = :r1,
  'bruto: a mesma resposta gravada de novo devolve o mesmo registro');
select pg_temp.falha($$select sienge.gravar_resposta(1, 'rest:bills', '/bills?senha=x', 1, 200, '{}', '{"results":[]}', now())$$,
  'bruto: consulta com credencial não se grava');

-- 2. espelho
select pg_temp.ok(sienge.carregar_parcelas_pagar(:r1) = '{"novas":2,"mudadas":0,"iguais":0,"empresas_fora":0}',
  'espelho: duas parcelas novas');
select pg_temp.ok((select count(*) = 4 and bool_and(conta in ('2010505','2030224') and centro_custo_id = 8)
                     from sienge.pagar_rateios),
  'espelho: rateio guarda a conta e o centro de custo ORIGINAIS do Sienge');
select pg_temp.ok((select sum(percentual) from sienge.pagar_rateios where titulo_id = 10 and parcela_id = 1) = 100,
  'espelho: percentuais do rateio somam 100');
select pg_temp.ok((select count(*) from sienge.pagar_baixas) = 1 and (select count(*) from sienge.pagar_baixa_movimentos) = 1
                  and (select count(*) from sienge.pagar_autorizacoes) = 2 and (select count(*) from sienge.pagar_rateios_obra) = 2,
  'espelho: baixa, movimento bancário, autorizações e rateio por obra');
select pg_temp.ok((select documento_tipo = 'NFSE' and previsao = false and cadastrado_em = '2026-03-10 09:15'
                     and emissao = '2026-03-10' and dados ->> 'creditorName' = 'Fornecedor Teste'
                     from sienge.pagar_parcelas where titulo_id = 10 and parcela_id = 1),
  'espelho: campos convertidos e a parcela inteira em dados');
select pg_temp.ok(sienge.carregar_parcelas_pagar(:r1) = '{"novas":0,"mudadas":0,"iguais":2,"empresas_fora":0}'
                  and (select count(*) from sienge.pagar_rateios) = 4,
  'espelho: carregar a mesma resposta de novo não duplica');

-- 3. mudou: a versão anterior vai para o histórico
select sienge.gravar_resposta(1, 'bulk:outcome', '/outcome?selectionType=I', 2, 200, '{}',
  jsonb_build_object('data', jsonb_build_array(pg_temp.parcela(10, 2, 5, 100, 0)))::text, '2026-11-18 01:00+00') as r2 \gset
select pg_temp.ok(sienge.carregar_parcelas_pagar(:r2) = '{"novas":0,"mudadas":1,"iguais":0,"empresas_fora":0}',
  'espelho: parcela paga depois conta como mudada');
select pg_temp.ok((select count(*) = 1 and bool_and((dados ->> 'balanceAmount')::numeric = 100) from sienge.historico
                    where tabela = 'pagar_parcelas' and chave = '{"titulo_id":10,"parcela_id":2}'),
  'espelho: a versão em aberto ficou no histórico');
select pg_temp.ok((select saldo = 0 from sienge.pagar_parcelas where titulo_id = 10 and parcela_id = 2)
                  and (select count(*) from sienge.pagar_baixas where titulo_id = 10 and parcela_id = 2) = 1
                  and (select count(*) from sienge.pagar_rateios where titulo_id = 10 and parcela_id = 2) = 2,
  'espelho: a versão nova traz a baixa, e o rateio não duplica');

-- 4. ausentes: só depois de carga concluída que leu a janela inteira
select pg_temp.falha('select sienge.marcar_ausentes_pagar(1)', 'ausentes: carga ainda rodando não marca nada');
update sienge.cargas set situacao = 'concluida' where id = 1;
-- a resposta 2 trouxe só a parcela 10/2; a 10/1 veio na resposta 1, da mesma carga
select pg_temp.ok(sienge.marcar_ausentes_pagar(1) = 0, 'ausentes: o que veio em qualquer resposta da carga fica');
insert into sienge.cargas (recurso, parametros, janela_inicio, janela_fim, situacao)
values ('bulk:outcome', '{"selectionType":"I"}', '2026-01-01', '2026-12-31', 'rodando');
select sienge.gravar_resposta(2, 'bulk:outcome', '/outcome?selectionType=I', 1, 200, '{}',
  jsonb_build_object('data', jsonb_build_array(pg_temp.parcela(10, 2, 5, 100, 0)))::text, '2026-11-19 01:00+00') as r3 \gset
select sienge.carregar_parcelas_pagar(:r3);
update sienge.cargas set situacao = 'concluida' where id = 2;
select sienge.marcar_ausentes_pagar(2) as aus \gset
select pg_temp.ok(:aus = 1
                  and (select removido_em is not null from sienge.pagar_parcelas where titulo_id = 10 and parcela_id = 1),
  'ausentes: parcela que sumiu da janela ganha removido_em e não é apagada');
select sienge.gravar_resposta(2, 'bulk:outcome', '/outcome?selectionType=I', 2, 200, '{}',
  jsonb_build_object('data', jsonb_build_array(pg_temp.parcela(10, 1, 5, 100, 0)))::text, '2026-11-19 02:00+00') as r4 \gset
select sienge.carregar_parcelas_pagar(:r4);
select pg_temp.ok((select removido_em is null from sienge.pagar_parcelas where titulo_id = 10 and parcela_id = 1),
  'ausentes: parcela que volta perde a marca de removida');
insert into sienge.cargas (recurso, parametros, janela_inicio, janela_fim, situacao)
values ('bulk:outcome', '{"selectionType":"D"}', '2026-01-01', '2026-12-31', 'concluida');
select pg_temp.falha('select sienge.marcar_ausentes_pagar(3)', 'ausentes: carga por vencimento não marca ausentes');
insert into sienge.cargas (recurso, parametros, janela_inicio, janela_fim, situacao)
values ('bulk:outcome', '{"selectionType":"I"}', '2000-01-01', '2026-12-31', 'concluida');
select pg_temp.falha('select sienge.marcar_ausentes_pagar(4)', 'ausentes: carga concluída sem nenhuma resposta não marca nada');
select pg_temp.ok((select count(*) = 0 from sienge.pagar_parcelas where removido_em is not null and titulo_id <> 10),
  'ausentes: a recusa não deixa marca');

-- 5. nada se altera nem se apaga
select pg_temp.falha(format('update sienge_bruto.respostas set corpo = %L where id = %s', '{}', :r1), 'bruto: corpo não se altera');
select pg_temp.falha(format('delete from sienge_bruto.respostas where id = %s', :r1), 'bruto: resposta não se apaga');
update sienge_bruto.respostas set processado_em = now() where id = :r1;
select pg_temp.ok(true, 'bruto: só a marca de processado muda');
select pg_temp.falha('update sienge.historico set dados = ''{}''', 'histórico: não se altera');
select pg_temp.falha('delete from sienge.historico', 'histórico: não se apaga');
select pg_temp.falha('truncate sienge.pagar_parcelas cascade', 'espelho: TRUNCATE recusado');
select pg_temp.falha('truncate sienge_bruto.respostas cascade', 'bruto: TRUNCATE recusado');

-- 6. segurança
select pg_temp.ok(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                               where n.nspname in ('sienge', 'sienge_bruto') and c.relkind in ('r', 'p')
                                 and not (c.relrowsecurity and c.relforcerowsecurity)),
  'segurança: toda tabela com RLS ligado e forçado');
select pg_temp.ok(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                               cross join (values ('anon'), ('authenticated'), ('service_role')) r(papel)
                               cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) p(priv)
                               where n.nspname in ('sienge', 'sienge_bruto') and c.relkind in ('r', 'v', 'p')
                                 and has_table_privilege(r.papel, c.oid, p.priv))
                  and not has_schema_privilege('anon', 'sienge', 'USAGE')
                  and not has_schema_privilege('authenticated', 'sienge', 'USAGE')
                  and not has_schema_privilege('authenticated', 'sienge_bruto', 'USAGE')
                  and not has_schema_privilege('service_role', 'sienge_bruto', 'USAGE'),
  'segurança: nada para anon, authenticated e service_role');
select pg_temp.ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                               cross join (values ('anon'), ('authenticated'), ('service_role')) r(papel)
                               where n.nspname in ('sienge', 'sienge_bruto') and has_function_privilege(r.papel, p.oid, 'EXECUTE')),
  'segurança: nenhuma função do espelho executável pela API');
select pg_temp.ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                               where n.nspname in ('sienge', 'sienge_bruto') and p.prosecdef),
  'segurança: nenhuma função definer');
set local role sienge_carga;
select pg_temp.ok((select count(*) from sienge.pagar_parcelas) = 2, 'segurança: o papel da carga lê o espelho');
reset role;
set local role authenticated;
select pg_temp.falha('select count(*) from sienge.pagar_parcelas', 'segurança: o usuário logado não lê o espelho');
reset role;
rollback;

\echo '# fim do espelho'
do $$ begin raise notice 'TODOS OS TESTES DO ESPELHO PASSARAM'; end $$;
