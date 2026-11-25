-- bkm_dev, 25/nov/2026: a Nova previsão pela tela (migration 20261125005000). Colar inteiro no SQL Editor.
-- Se algo falhar, dá erro e nada fica. Pode rodar de novo sem estrago (create or replace). Nenhum papel é concedido:
-- api.lancar_previsao é do postgres e roda como quem chama (as regras são as do RLS e dos gatilhos do erp).
begin;
-- Nova previsão pela tela (Moises, 25/11/2026: "a que falta botão é a parte de Previsões. Não tem como adicionar
-- previsão"). A tela lança a previsão manual: empresa, fornecedor (opcional), onde entra (núcleo, centro, último nível
-- da divisão e natureza), competência, data prevista, valor e descrição.
--
-- Mesma regra do esquema api (migration _api_telas): SECURITY INVOKER. A gravação passa pelas mesmas políticas e
-- gatilhos de quem grava direto no erp: o RLS (erp.lanco: o perfil de quem lança no núcleo, centro, divisão e
-- natureza), a natureza do último nível ligada ao centro, a divisão exigida, a pessoa PJ só em natureza restrita,
-- quem lançou (erp.autor) e a alçada fixada ao nascer (t_alcada: faixas do centro; PJ só a vaga PJ, o master).
-- Previsão PJ continua restrita ao master e aos designados e não vira PRV no Sienge (erp.tg_sienge_previsao_pj).
-- Aqui só se confere o corpo e se escolhe a divisão de primeiro nível e o subnível, como em api.lancar_titulo.
-- Regra nova (decisão minha, avisada ao Moises): previsão sem fornecedor precisa da descrição, porque é ela que dá
-- nome à previsão na lista e ao título PRV (credor genérico) no Sienge.
-- Portabilidade: SQL puro.

-- Corpo: { empresa, fornecedor?, nucleo, centro, divisao? (o último nível), natureza, competencia (AAAA-MM-01),
--          data_prevista, valor, descricao? }
create or replace function api.lancar_previsao(p jsonb) returns uuid language plpgsql volatile security invoker
set search_path = pg_catalog, pg_temp as $$
declare v_id uuid; v_div uuid; v_raiz uuid; v_valor numeric; v_forn uuid; v_desc text;
begin
  perform erp.exigir_editor();
  if nullif(p->>'empresa', '') is null then raise exception 'Informe a empresa'; end if;
  if nullif(p->>'natureza', '') is null then raise exception 'Informe a natureza'; end if;
  if nullif(p->>'data_prevista', '') is null then raise exception 'Informe a data prevista'; end if;
  if nullif(p->>'competencia', '') is null then raise exception 'Informe a competência'; end if;
  if (p->>'competencia')::date <> date_trunc('month', (p->>'competencia')::date)::date then
    raise exception 'A competência é o primeiro dia do mês';
  end if;
  v_valor := (p->>'valor')::numeric;
  if v_valor is null or v_valor <= 0 or v_valor <> round(v_valor, 2) then
    raise exception 'O valor é maior que zero, com até 2 casas';
  end if;
  v_forn := nullif(p->>'fornecedor', '')::uuid;
  v_desc := nullif(trim(coalesce(p->>'descricao', '')), '');
  if v_forn is null and v_desc is null then raise exception 'Previsão sem fornecedor precisa da descrição'; end if;
  if length(v_desc) > 500 then raise exception 'A descrição tem até 500 caracteres'; end if;

  v_div := nullif(p->>'divisao', '')::uuid;
  select coalesce(d.raiz_id, d.id) into v_raiz from erp.divisoes d where d.id = v_div;
  if v_div is not null and v_raiz is null then raise exception 'Divisão não encontrada'; end if;

  insert into erp.previsoes (empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id,
                             natureza_id, competencia, data_prevista, valor, descricao)
  values ((p->>'empresa')::uuid, 'manual', v_forn, nullif(p->>'nucleo', '')::uuid, nullif(p->>'centro', '')::uuid, v_raiz,
          case when v_div is distinct from v_raiz then v_div end, (p->>'natureza')::uuid, (p->>'competencia')::date,
          (p->>'data_prevista')::date, v_valor, v_desc)
  returning id into v_id;
  return v_id;
end $$;

-- Segurança: só o usuário logado executa
revoke execute on function api.lancar_previsao(jsonb) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke execute on function api.lancar_previsao(jsonb) from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then revoke execute on function api.lancar_previsao(jsonb) from service_role; end if;
end $$;
grant execute on function api.lancar_previsao(jsonb) to authenticated;

do $$ begin
  if (select prosecdef from pg_proc where oid = 'api.lancar_previsao(jsonb)'::regprocedure)
     or not has_function_privilege('authenticated', 'api.lancar_previsao(jsonb)', 'EXECUTE')
     or has_function_privilege('anon', 'api.lancar_previsao(jsonb)', 'EXECUTE') then
    raise exception 'Conferência: api.lancar_previsao';
  end if;
end $$;
commit;
select 'ok: api.lancar_previsao no ar' as resultado;
