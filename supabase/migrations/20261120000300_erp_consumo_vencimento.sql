-- Vencimento da conta de consumo opcional (Moises, 20/11/2026: "Não precisa ser obrigatório mas o sistema pode
-- preencher automaticamente quando chega a fatura e alterar todo mês se vier em dia diferente").
--   - o dia do vencimento deixa de ser obrigatório no consumo;
--   - na conta de consumo, mudar o dia do vencimento não abre versão nova (não pede aprovação de novo): é o que a
--     fatura traz e muda de mês em mês. No contrato e na assinatura continua abrindo, porque gera as previsões.
-- O preenchimento pela fatura que chega fica para o PR das notas (o leitor e o lançamento).
-- Portabilidade: SQL puro.

alter table erp.compromissos drop constraint compromissos_consumo,
  add constraint compromissos_consumo check (tipo <> 'consumo'
    or (instalacao is not null and faixa_mensal is not null and teto_anual is not null and periodicidade is not null
        and valor_total is null and valor_periodo is null));

create or replace function erp.tg_compromisso_versao() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.aprovacao_versao := 1;
    new.alterado_por := erp.autor();
    return new;
  end if;
  if new.aprovacao_versao <> old.aprovacao_versao and not erp.agindo_como('erp_situacao') then
    raise exception 'A versão da aprovação do contrato só muda pela alteração do contrato';
  end if;
  if new.alterado_por is distinct from old.alterado_por and not erp.agindo_como('erp_situacao') then
    raise exception 'Quem alterou o contrato é posto pelo sistema';
  end if;
  -- o dia do vencimento da conta de consumo fica fora: muda com a fatura, sem nova aprovação
  if (new.empresa_id, new.tipo, new.pessoa_id, new.inicio, new.fim, new.valor_total, new.periodicidade, new.valor_periodo,
      case when new.tipo = 'consumo' then null else new.dia_vencimento end, new.caucao_percentual, new.instalacao, new.faixa_mensal, new.teto_anual)
     is distinct from
     (old.empresa_id, old.tipo, old.pessoa_id, old.inicio, old.fim, old.valor_total, old.periodicidade, old.valor_periodo,
      case when old.tipo = 'consumo' then null else old.dia_vencimento end, old.caucao_percentual, old.instalacao, old.faixa_mensal, old.teto_anual) then
    new.aprovacao_versao := old.aprovacao_versao + 1;
    new.alterado_por := erp.autor();
  end if;
  return new;
end $$;

-- api.salvar_conta: o consumo deixa de exigir o dia do vencimento (mesmo corpo, sem essa exigência)
do $$
declare v text;
  a text := $x$
                              or nullif(p->>'teto_anual', '') is null or nullif(p->>'dia_vencimento', '') is null) then
    raise exception 'Informe a instalação, a média esperada por mês, o teto no ano e o dia do vencimento';$x$;
  b text := $x$
                              or nullif(p->>'teto_anual', '') is null) then
    raise exception 'Informe a instalação, a média esperada por mês e o teto no ano';$x$;
begin
  v := pg_get_functiondef('api.salvar_conta(jsonb)'::regprocedure);
  if position(a in v) = 0 then raise exception 'api.salvar_conta mudou: refazer o remendo'; end if;
  execute replace(v, a, b);
end $$;
