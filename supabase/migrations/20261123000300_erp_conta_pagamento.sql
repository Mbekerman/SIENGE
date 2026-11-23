-- Como a conta recorrente paga (Moises, 23/nov/2026): o cadastro do contrato de serviço, da assinatura e da conta de
-- consumo diz como os títulos vão ser pagos, para a nota do mês gerar o título sem pedir mais nada. Três formas:
--   - PIX fixo: a mesma chave todo mês;
--   - TED: a mesma conta bancária todo mês ("2) inclua a opção"; o Sienge aceita pela
--     /bills/{id}/installments/{n}/payment-information/bank-transfer, bill-debt-v1.yaml);
--   - vem com cada cobrança: o boleto ou o PIX copia e cola chega com a nota de cada mês.
-- Não é obrigatória ("Não precisa ser obrigatório mas a pessoa deve saber os itens mínimos"): a tela mostra o que falta
-- para gerar os títulos sem preenchimento adicional.
-- Proteção, como a forma de pagamento da parcela (S-125):
--   - a chave PIX por CPF/CNPJ e a conta da TED são do fornecedor (o mesmo CPF/CNPJ); de outra pessoa, só com a
--     justificativa da exceção, que quem aprova vê;
--   - a forma faz parte do cadastro aprovado: incluir, mudar ou tirar volta o cadastro para a aprovação (versão nova),
--     então nunca entra aprovada sem o gestor e a AF ou a AD verem;
--   - trocar o fornecedor confere de novo (gatilho adiado, no fim da transação).
-- Quando a cobrança do mês chega com forma diferente da cadastrada, a escolha é da AF ("1) Abre a opção para o Aprovador
-- final escolher (AF)"): entra no PR da nota do mês, assim como levar a TED à parcela do título e ao Sienge.
-- Portabilidade: SQL e plpgsql padrão.

create table erp.compromisso_pagamentos (
  compromisso_id    uuid primary key references erp.compromissos on delete cascade,
  modo              text not null check (modo in ('pix', 'ted', 'cobranca')),
  pix_tipo          text check (pix_tipo in ('cpf_cnpj', 'email', 'telefone', 'aleatoria')),
  pix_chave         text check (pix_chave is null or erp.chave_pix_valida(pix_tipo, pix_chave)),
  banco             text check (banco ~ '^[0-9]{3}$'),            -- código de compensação (001, 341...)
  agencia           text check (agencia ~ '^[0-9]{1,6}$'),
  agencia_digito    text check (agencia_digito ~ '^[0-9X]$'),
  conta             text check (conta ~ '^[0-9]{1,14}$'),
  conta_digito      text check (conta_digito ~ '^[0-9X]$'),
  conta_tipo        text check (conta_tipo in ('corrente', 'poupanca')),
  titular_documento text check (titular_documento ~ '^([0-9]{11}|[0-9]{14})$'),
  excecao           text check (length(trim(excecao)) > 0),        -- por que pagar a outra pessoa (chave CPF/CNPJ ou TED)
  check ((modo = 'pix') = (pix_tipo is not null and pix_chave is not null)),
  check ((modo = 'ted') = (banco is not null and agencia is not null and conta is not null and conta_digito is not null
                           and conta_tipo is not null and titular_documento is not null)),
  check (modo = 'ted' or (agencia_digito is null and banco is null and agencia is null and conta is null
                          and conta_digito is null and conta_tipo is null and titular_documento is null)),
  check (excecao is null or (modo = 'pix' and pix_tipo = 'cpf_cnpj') or modo = 'ted')
);
alter table erp.compromisso_pagamentos enable row level security;
alter table erp.compromisso_pagamentos force row level security;
create policy sistema on erp.compromisso_pagamentos using (erp.sistema()) with check (erp.sistema());
create policy conferencia on erp.compromisso_pagamentos for select to erp_conferencia using (true);
create policy operacao on erp.compromisso_pagamentos to erp_situacao, erp_reclassificacao, erp_acesso using (true) with check (true);
create policy perfil_le on erp.compromisso_pagamentos for select to authenticated using (erp.vejo_compromisso(compromisso_id));
create policy perfil_inclui on erp.compromisso_pagamentos for insert to authenticated with check (erp.lanco_compromisso(compromisso_id));
create policy perfil_altera on erp.compromisso_pagamentos for update to authenticated
  using (erp.lanco_compromisso(compromisso_id)) with check (erp.lanco_compromisso(compromisso_id));
create policy perfil_apaga on erp.compromisso_pagamentos for delete to authenticated using (erp.lanco_compromisso(compromisso_id));
revoke all on erp.compromisso_pagamentos from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke all on erp.compromisso_pagamentos from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then revoke all on erp.compromisso_pagamentos from service_role; end if;
end $$;
grant select, insert, update, delete on erp.compromisso_pagamentos to authenticated, erp_sistema, erp_situacao, erp_reclassificacao, erp_acesso;
grant select on erp.compromisso_pagamentos to erp_conferencia;
create trigger t_nao_trunca before truncate on erp.compromisso_pagamentos for each statement execute function erp.tg_recusa_truncate();
create trigger t_aud_compromisso_pagamentos after insert or update or delete on erp.compromisso_pagamentos
  for each row execute function erp.tg_auditoria('compromisso_id');

-- Mudou a forma: versão nova do cadastro (volta para a aprovação). Definer do erp_situacao, como erp.tg_meses_versao.
create function erp.tg_pagamento_versao() returns trigger language plpgsql
security definer set search_path = erp, pg_catalog, pg_temp as $$
declare v_id uuid := coalesce(new.compromisso_id, old.compromisso_id);
begin
  if tg_op = 'UPDATE' then
    if new.compromisso_id <> old.compromisso_id then raise exception 'A forma de pagamento não muda de conta'; end if;
    if row(new.*) is not distinct from row(old.*) then return null; end if;
  end if;
  update erp.compromissos set aprovacao_versao = aprovacao_versao + 1, alterado_por = erp.autor() where id = v_id;
  return null;
end $$;
create trigger t_versao after insert or update or delete on erp.compromisso_pagamentos
  for each row execute function erp.tg_pagamento_versao();

-- A chave CPF/CNPJ e a conta da TED são do fornecedor, ou vêm com a justificativa. A justificativa que sobra (a chave
-- passou a ser do fornecedor, ou a forma não pede) some, para não ficar um selo falso. Roda no fim da transação:
-- api.salvar_conta troca o fornecedor e a forma juntos.
create function erp._pagamento_confere(p_id uuid) returns void language plpgsql as $$
declare g erp.compromisso_pagamentos; v_doc text; v_do_forn boolean;
begin
  select * into g from erp.compromisso_pagamentos where compromisso_id = p_id;
  if g.compromisso_id is null or g.modo = 'cobranca' or (g.modo = 'pix' and g.pix_tipo <> 'cpf_cnpj') then return; end if;
  select p.documento into v_doc from erp.compromissos c join erp.pessoas p on p.id = c.pessoa_id where c.id = p_id;
  v_do_forn := v_doc is not null and v_doc = case g.modo when 'pix' then g.pix_chave else g.titular_documento end;
  if not v_do_forn and g.excecao is null then
    raise exception '%', case g.modo when 'pix' then 'A chave PIX por CPF/CNPJ não é o documento do fornecedor (só com a justificativa da exceção)'
                                     else 'A conta da TED não é do fornecedor (só com a justificativa da exceção)' end;
  end if;
end $$;

create function erp.tg_pagamento_excecao() returns trigger language plpgsql as $$
declare v_doc text; v_destino text := case new.modo when 'pix' then new.pix_chave else new.titular_documento end;
begin
  if new.modo = 'cobranca' or (new.modo = 'pix' and new.pix_tipo <> 'cpf_cnpj') then
    new.excecao := null;
  else
    select p.documento into v_doc from erp.compromissos c join erp.pessoas p on p.id = c.pessoa_id where c.id = new.compromisso_id;
    if v_doc is not null and v_doc = v_destino then
      new.excecao := null;
    end if;
  end if;
  return new;
end $$;
create trigger t_pagamento_excecao before insert or update on erp.compromisso_pagamentos
  for each row execute function erp.tg_pagamento_excecao();

create function erp.tg_pagamento_confere() returns trigger language plpgsql as $$
begin
  if tg_table_name = 'compromissos' then perform erp._pagamento_confere(new.id);
  elsif tg_op <> 'DELETE' then perform erp._pagamento_confere(new.compromisso_id);
  end if;
  return null;
end $$;
create constraint trigger t_pagamento_confere after insert or update on erp.compromisso_pagamentos
  deferrable initially deferred for each row execute function erp.tg_pagamento_confere();
create constraint trigger t_pagamento_confere after update of pessoa_id on erp.compromissos
  deferrable initially deferred for each row execute function erp.tg_pagamento_confere();

-- ---------------------------------------------------------------------------------------------
-- API: o cadastro devolve e grava a forma
-- ---------------------------------------------------------------------------------------------
-- api.conta ganha 'pagamento' (nulo = não informada). Mesmo corpo do 20261123000200 com a chave nova.
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
                               then erp.mes(current_date) end,
           'pagamento', (select jsonb_build_object('modo', g.modo, 'pix_tipo', g.pix_tipo, 'pix_chave', g.pix_chave,
                                  'banco', g.banco, 'agencia', g.agencia, 'agencia_digito', g.agencia_digito, 'conta', g.conta,
                                  'conta_digito', g.conta_digito, 'conta_tipo', g.conta_tipo,
                                  'titular_documento', g.titular_documento, 'excecao', g.excecao)
                           from erp.compromisso_pagamentos g where g.compromisso_id = c.id))
    from erp.compromissos c
   where c.id = p_id and c.tipo in ('contrato', 'assinatura', 'consumo') $$;

-- api.salvar_conta grava também p->'pagamento' quando vem (nulo = tira a forma; ausente = não mexe). Só regrava se
-- mudou, para não pedir aprovação de novo à toa. Remendo sobre o corpo do 20261123000200.
do $$
declare v text; v_ancora text := E'  if p ? ''meses'' then\n';
begin
  v := pg_get_functiondef('api.salvar_conta(jsonb)'::regprocedure);
  if position(v_ancora in v) = 0 then raise exception 'api.salvar_conta mudou: refazer o remendo'; end if;
  v := replace(v, v_ancora,
       E'  if p ? ''pagamento'' then\n'
    || E'    if jsonb_typeof(p->''pagamento'') = ''object'' then\n'
    || E'      insert into erp.compromisso_pagamentos as g (compromisso_id, modo, pix_tipo, pix_chave, banco, agencia, agencia_digito,\n'
    || E'                                                   conta, conta_digito, conta_tipo, titular_documento, excecao)\n'
    || E'      select v_id, x.modo, nullif(x.pix_tipo, ''''), nullif(trim(x.pix_chave), ''''), nullif(x.banco, ''''), nullif(x.agencia, ''''),\n'
    || E'             nullif(upper(x.agencia_digito), ''''), nullif(x.conta, ''''), nullif(upper(x.conta_digito), ''''), nullif(x.conta_tipo, ''''),\n'
    || E'             nullif(x.titular_documento, ''''), nullif(trim(x.excecao), '''')\n'
    || E'        from jsonb_to_record(p->''pagamento'') x(modo text, pix_tipo text, pix_chave text, banco text, agencia text,\n'
    || E'             agencia_digito text, conta text, conta_digito text, conta_tipo text, titular_documento text, excecao text)\n'
    || E'      on conflict (compromisso_id) do update set modo = excluded.modo, pix_tipo = excluded.pix_tipo, pix_chave = excluded.pix_chave,\n'
    || E'        banco = excluded.banco, agencia = excluded.agencia, agencia_digito = excluded.agencia_digito, conta = excluded.conta,\n'
    || E'        conta_digito = excluded.conta_digito, conta_tipo = excluded.conta_tipo, titular_documento = excluded.titular_documento,\n'
    || E'        excecao = excluded.excecao\n'
    || E'       where (g.modo, g.pix_tipo, g.pix_chave, g.banco, g.agencia, g.agencia_digito, g.conta, g.conta_digito, g.conta_tipo,\n'
    || E'              g.titular_documento, g.excecao) is distinct from (excluded.modo, excluded.pix_tipo, excluded.pix_chave, excluded.banco,\n'
    || E'              excluded.agencia, excluded.agencia_digito, excluded.conta, excluded.conta_digito, excluded.conta_tipo,\n'
    || E'              excluded.titular_documento, excluded.excecao);\n'
    || E'    else\n'
    || E'      delete from erp.compromisso_pagamentos where compromisso_id = v_id;\n'
    || E'    end if;\n'
    || E'  end if;\n'
    || v_ancora);
  execute v;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Donos e EXECUTE
-- ---------------------------------------------------------------------------------------------
alter function erp.tg_pagamento_versao() owner to erp_situacao;
do $$
declare f regprocedure;
begin
  foreach f in array array['erp.tg_pagamento_versao()', 'erp._pagamento_confere(uuid)', 'erp.tg_pagamento_confere()',
                           'erp.tg_pagamento_excecao()']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('revoke execute on function %s from authenticated', f);
    execute format('grant execute on function %s to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso', f);
  end loop;
end $$;
-- A conferência roda no gatilho de quem grava (invoker, pelo RLS dele): precisa do EXECUTE.
grant execute on function erp._pagamento_confere(uuid) to authenticated;
