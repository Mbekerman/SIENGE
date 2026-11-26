-- Tomador da nota diferente da empresa do título (Moises, 26/11/2026: "O Tomador não está entre as empresas cadastradas.
-- Nesse caso esse alerta deve ficar vermelho e exigir justificativa. O campo de Justificativa deve ficar logo abaixo do
-- alerta e ser bem visível para todos aprovadores").
--
-- 1. erp.documentos_fiscais.tomador_excecao: a justificativa de quem lança, gravada com a nota e que não muda depois.
-- 2. Ao ligar o anexo à nota (no lançamento), se a leitura do anexo traz um tomador com CPF/CNPJ diferente do da empresa
--    do título, a nota precisa da justificativa (vale também para a empresa sem CPF/CNPJ no cadastro: não dá para
--    conferir, então pede).
-- 3. erp.recebedor_divergente passa a trazer o motivo "Tomador da nota ... não é a empresa do título: <justificativa>",
--    e api.recebedores_divergentes inclui esses títulos: o alerta e o selo aparecem para quem aprova até o pagamento.
--
-- Limite: a leitura do anexo é gravada pela própria pessoa (api.gravar_leitura) antes de ligar; quem quiser burlar tira
-- o tomador da leitura. É uma guarda do lançamento honesto, não uma trava contra má-fé (o tomador não é dado de pagamento).

alter table erp.documentos_fiscais
  add column tomador_excecao text check (tomador_excecao is null or length(trim(tomador_excecao)) between 5 and 500);

-- A justificativa nasce com a nota e não muda (nem some).
create function erp.tg_documento_tomador() returns trigger language plpgsql as $$
begin
  if new.tomador_excecao is distinct from old.tomador_excecao then
    raise exception 'A justificativa do tomador não muda depois do lançamento';
  end if;
  return new;
end $$;
create trigger t_documento_tomador before update of tomador_excecao on erp.documentos_fiscais
  for each row execute function erp.tg_documento_tomador();

-- CPF/CNPJ só com letras e dígitos, em maiúsculas (o CNPJ alfanumérico tem letras).
create function erp._doc_normal(p text) returns text language sql immutable as $$
  select nullif(upper(regexp_replace(coalesce(p, ''), '[^0-9A-Za-z]', '', 'g')), '') $$;

-- O tomador lido no anexo, quando não é a empresa da nota (nulo quando bate ou não há tomador lido).
create function erp.tomador_divergente(p_documento uuid) returns text language sql stable as $$
  select min(t.doc) from (
    select erp._doc_normal(a.leitura->'tomador'->>'documento') doc from erp.anexos a where a.documento_id = p_documento) t
   where t.doc is not null
     and t.doc is distinct from (select erp._doc_normal(pe.documento) from erp.documentos_fiscais d
                                   join erp.empresas e on e.id = d.empresa_id join erp.pessoas pe on pe.id = e.pessoa_id
                                  where d.id = p_documento) $$;

create function erp.tg_anexo_tomador() returns trigger language plpgsql as $$
declare v_tom text;
begin
  if new.documento_id is null or old.documento_id is not null then return null; end if;
  v_tom := erp.tomador_divergente(new.documento_id);
  if v_tom is not null and (select tomador_excecao from erp.documentos_fiscais where id = new.documento_id) is null then
    raise exception 'O tomador da nota (%) não é a empresa do título: justifique para lançar', v_tom;
  end if;
  return null;
end $$;
create trigger t_anexo_tomador after update of documento_id on erp.anexos
  for each row execute function erp.tg_anexo_tomador();

-- lancar_titulo grava a justificativa com a nota
do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('api.lancar_titulo(jsonb)'::regprocedure);
  v_novo := replace(v_def,
    $r$insert into erp.documentos_fiscais (empresa_id, emitente_id, compromisso_id, tipo, numero, serie, emissao, competencia, valor_bruto)$r$,
    $r$insert into erp.documentos_fiscais (empresa_id, emitente_id, compromisso_id, tipo, numero, serie, emissao, competencia, valor_bruto, tomador_excecao)$r$);
  v_novo := replace(v_novo,
    $r$coalesce(trim(p->>'serie'), ''), (p->>'emissao')::date, (p->>'competencia')::date, (p->>'valor')::numeric)$r$,
    $r$coalesce(trim(p->>'serie'), ''), (p->>'emissao')::date, (p->>'competencia')::date, (p->>'valor')::numeric,
          nullif(trim(p->>'tomador_excecao'), ''))$r$);
  if position('tomador_excecao)' in v_novo) = 0 or position($r$nullif(trim(p->>'tomador_excecao'), '')$r$ in v_novo) = 0 then
    raise exception 'api.lancar_titulo: ponto de troca não achado';
  end if;
  execute v_novo;
end $$;

-- O motivo do tomador entra antes dos das parcelas (invoker, como antes)
create or replace function erp.recebedor_divergente(p_titulo uuid) returns text[] language sql stable as $$
  select coalesce(array_agg(m order by n, o), '{}') from (
    select 0 as n, 0 as o, format('Tomador da nota (%s) não é a empresa do título: %s',
                                  coalesce(erp.tomador_divergente(d.id), 'lido no anexo'), d.tomador_excecao) as m
      from erp.titulos t join erp.documentos_fiscais d on d.id = t.documento_id
     where t.id = p_titulo and t.situacao not in ('quitado', 'cancelado') and d.tomador_excecao is not null
    union all
    select g.numero as n, x.o, x.m
      from erp.parcela_pagamentos g join erp.titulos t on t.id = g.titulo_id
      cross join lateral (values
        (1, case when g.pix_excecao is not null then format('Parcela %s: chave PIX de outra pessoa (%s)', g.numero, g.pix_excecao) end),
        (2, case when g.pix_copia_cola_excecao is not null then format('Parcela %s: PIX copia e cola sem o fornecedor como recebedor (%s)', g.numero, g.pix_copia_cola_excecao) end),
        (3, case when g.boleto_excecao is not null then format('Parcela %s: beneficiário do boleto não é o fornecedor (%s)', g.numero, g.boleto_excecao) end)) x(o, m)
     where g.titulo_id = p_titulo and t.situacao not in ('quitado', 'cancelado') and x.m is not null) y $$;

create or replace function api.recebedores_divergentes() returns table (id uuid, motivos text[])
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select t.id, erp.recebedor_divergente(t.id)
    from erp.titulos t
   where t.sentido = 'pagar' and t.situacao not in ('quitado', 'cancelado')
     and (exists (select 1 from erp.parcela_pagamentos g where g.titulo_id = t.id
                   and (g.pix_excecao is not null or g.pix_copia_cola_excecao is not null or g.boleto_excecao is not null))
          or exists (select 1 from erp.documentos_fiscais d where d.id = t.documento_id and d.tomador_excecao is not null)) $$;

revoke execute on function erp.tg_documento_tomador(), erp._doc_normal(text), erp.tomador_divergente(uuid), erp.tg_anexo_tomador() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function erp.tg_documento_tomador(), erp._doc_normal(text), erp.tomador_divergente(uuid), erp.tg_anexo_tomador() from anon;
  end if;
end $$;
-- quem chama erp.recebedor_divergente (e lança) precisa das de baixo; todas rodam como quem chama
grant execute on function erp._doc_normal(text), erp.tomador_divergente(uuid)
  to authenticated, erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
grant execute on function erp.tg_documento_tomador(), erp.tg_anexo_tomador()
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
