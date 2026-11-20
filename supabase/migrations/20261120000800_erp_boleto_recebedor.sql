-- Beneficiário do boleto conferido, como o recebedor do PIX copia e cola (Moises, 20/nov/2026: "Vamos fazer o mesmo
-- esquema do Pix para o Boleto"). O boleto adulterado com a linha de outra pessoa e o valor certo passava: o leitor
-- perguntava ao Asaas e só avisava na tela. Agora:
--   - a função conferir-pagamento (Edge Function, papel do sistema; antes pix-conferir) pergunta ao Asaas
--     (POST /v3/bill/simulate) quem é o beneficiário e grava em erp.boleto_conferencias; telas e avisos dizem só
--     "conferido", sem a fonte (Moises, 20/nov/2026);
--   - a parcela de boleto entra quando o CPF/CNPJ do beneficiário conferido há até 1 dia é o do credor e o valor
--     registrado (quando o banco devolve) é o da parcela; não conferido, ou de outra pessoa, só com a justificativa
--     (boleto_excecao), que quem aprova vê e que gera o alerta crítico boleto_excecao para o AF quando o título vai à
--     fila do Sienge. O limite de pedidos é o mesmo da conferência do PIX (erp.conferencia_tentativa).
-- E o selo (Moises, 20/nov/2026: "mesmo se aprovado com justificativa aquele processo deve ter um alerta em toda sua
-- vida até o pagamento mostrando a todos que não bate o recebedor com o fornecedor"): erp.recebedor_divergente diz,
-- por título, o que não bate (chave CPF/CNPJ de outra pessoa, PIX copia e cola e boleto não conferidos), e as telas
-- mostram em toda parte até o título ser pago (api.recebedores_divergentes e api.titulo).
-- A conferência só roda na gravação da forma (insert, ou mudança da forma, da linha ou da justificativa): as
-- parcelas gravadas antes desta migration ficam como estão.

-- Quem é o beneficiário do boleto segundo o banco (pela conferência). Só o sistema grava; a leitura passa pelo erp.boleto_conferido.
create table erp.boleto_conferencias (
  linha        text primary key check (erp.linha_digitavel_valida(linha)),
  cpf_cnpj     text check (cpf_cnpj ~ '^[0-9*]{11,14}$'),
  nome         text,
  valor        numeric(15,2),
  vencimento   date,
  por          uuid references erp.usuarios,
  conferido_em timestamptz not null default clock_timestamp()
);
alter table erp.boleto_conferencias enable row level security;
alter table erp.boleto_conferencias force row level security;
create policy sistema on erp.boleto_conferencias using (erp.sistema()) with check (erp.sistema());
create policy conferencia on erp.boleto_conferencias for select to erp_conferencia using (true);
revoke all on erp.boleto_conferencias from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke all on erp.boleto_conferencias from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then revoke all on erp.boleto_conferencias from authenticated; end if;
end $$;
grant select, insert, update on erp.boleto_conferencias to erp_sistema;
grant select on erp.boleto_conferencias to erp_conferencia;
create trigger t_nao_trunca before truncate on erp.boleto_conferencias for each statement execute function erp.tg_recusa_truncate();

create function erp.registrar_boleto_conferencia(p_linha text, p_cpf_cnpj text, p_nome text, p_valor numeric, p_vencimento date,
                                                 p_login text) returns void language plpgsql as $$
declare v_por uuid;
begin
  if not erp.sistema() then raise exception 'Só o sistema grava a conferência do boleto'; end if;
  select id into v_por from erp.usuarios where login_id = p_login and ativo;
  if v_por is null then raise exception 'Quem pediu a conferência não é usuário ativo do ERP'; end if;
  insert into erp.boleto_conferencias (linha, cpf_cnpj, nome, valor, vencimento, por)
  values (p_linha, nullif(regexp_replace(coalesce(p_cpf_cnpj, ''), '[^0-9*]', '', 'g'), ''), nullif(trim(p_nome), ''),
          case when p_valor > 0 then round(p_valor, 2) end, p_vencimento, v_por)
  on conflict (linha) do update set cpf_cnpj = excluded.cpf_cnpj, nome = excluded.nome, valor = excluded.valor,
    vencimento = excluded.vencimento, por = excluded.por, conferido_em = clock_timestamp();
end $$;

create function erp.boleto_conferido(p_linha text) returns jsonb language sql stable as $$
  select jsonb_build_object('cpf_cnpj', c.cpf_cnpj, 'nome', c.nome, 'valor', c.valor, 'vencimento', c.vencimento, 'em', c.conferido_em)
    from erp.boleto_conferencias c where c.linha = p_linha $$;

alter table erp.parcela_pagamentos add column boleto_excecao text   -- justificativa do beneficiário não conferido
  check (boleto_excecao is null or (forma = 'boleto' and length(trim(boleto_excecao)) > 0));

-- O beneficiário do boleto é o credor, ou vem a justificativa. Lê o credor e a conferência por baixo do RLS, como o
-- t_parcela_pagamento (o mesmo dono).
create function erp.tg_parcela_boleto_recebedor() returns trigger language plpgsql as $$
declare c jsonb; v_doc text; v_parcela numeric;
begin
  if new.forma is distinct from 'boleto' then new.boleto_excecao := null; return new; end if;
  select p.documento into v_doc from erp.titulos t join erp.pessoas p on p.id = t.pessoa_id where t.id = new.titulo_id;
  select valor into v_parcela from erp.parcelas where titulo_id = new.titulo_id and numero = new.numero;
  c := erp.boleto_conferido(new.boleto_linha);
  -- a conferência só vale com até 1 dia e, quando o banco devolve o valor, com o valor da parcela
  if c is not null and ((c->>'em')::timestamptz <= clock_timestamp() - interval '1 day'
                        or (c->>'valor' is not null and (c->>'valor')::numeric is distinct from v_parcela)) then
    c := null;
  end if;
  if c is not null and c->>'cpf_cnpj' = v_doc then
    new.boleto_excecao := null;   -- beneficiário conferido: a exceção some
    return new;
  end if;
  if length(trim(coalesce(new.boleto_excecao, ''))) = 0 then
    if c is not null then
      raise exception 'O beneficiário do boleto da parcela % (%, conferido) não é o credor (só com a justificativa da exceção)',
        new.numero, coalesce(c->>'nome', c->>'cpf_cnpj', 'sem nome');
    end if;
    raise exception 'O beneficiário do boleto da parcela % não foi conferido (só com a justificativa da exceção)', new.numero;
  end if;
  return new;
end $$;
-- o nome vem depois de t_parcela_pagamento (gatilhos rodam por ordem alfabética): a linha e o valor dela se conferem antes
create trigger t_parcela_recebedor_boleto before insert or update of forma, boleto_linha, boleto_excecao on erp.parcela_pagamentos
  for each row execute function erp.tg_parcela_boleto_recebedor();

-- O que não bate entre quem recebe e o credor, por título, até ele ser pago (vazio quando bate ou já foi pago).
-- Invoker: a pessoa só vê o que o RLS das parcelas deixa.
create function erp.recebedor_divergente(p_titulo uuid) returns text[] language sql stable as $$
  select coalesce(array_agg(m order by n, o), '{}') from (
    select g.numero as n, x.o, x.m
      from erp.parcela_pagamentos g join erp.titulos t on t.id = g.titulo_id
      cross join lateral (values
        (1, case when g.pix_excecao is not null then format('Parcela %s: chave PIX de outra pessoa (%s)', g.numero, g.pix_excecao) end),
        (2, case when g.pix_copia_cola_excecao is not null then format('Parcela %s: PIX copia e cola sem o fornecedor como recebedor (%s)', g.numero, g.pix_copia_cola_excecao) end),
        (3, case when g.boleto_excecao is not null then format('Parcela %s: beneficiário do boleto não é o fornecedor (%s)', g.numero, g.boleto_excecao) end)) x(o, m)
     where g.titulo_id = p_titulo and t.situacao not in ('quitado', 'cancelado') and x.m is not null) y $$;

revoke execute on function erp.registrar_boleto_conferencia(text, text, text, numeric, date, text),
  erp.boleto_conferido(text), erp.tg_parcela_boleto_recebedor(), erp.recebedor_divergente(uuid) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function erp.registrar_boleto_conferencia(text, text, text, numeric, date, text),
      erp.boleto_conferido(text), erp.tg_parcela_boleto_recebedor(), erp.recebedor_divergente(uuid) from anon;
  end if;
end $$;
grant execute on function erp.registrar_boleto_conferencia(text, text, text, numeric, date, text) to erp_sistema;
grant execute on function erp.boleto_conferido(text), erp.recebedor_divergente(uuid)
  to authenticated, erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
grant execute on function erp.tg_parcela_boleto_recebedor()
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
alter function erp.boleto_conferido(text) security definer set search_path = erp, pg_catalog, pg_temp;
alter function erp.tg_parcela_boleto_recebedor() security definer set search_path = erp, pg_catalog, pg_temp;
create temp table _bol_create_dado as
  select r from unnest(array['erp_conferencia']) r where not has_schema_privilege(r, 'erp', 'create');
do $$ declare v text; begin
  for v in select r from _bol_create_dado loop execute format('grant create on schema erp to %I', v); end loop;
end $$;
alter function erp.boleto_conferido(text) owner to erp_conferencia;
alter function erp.tg_parcela_boleto_recebedor() owner to erp_conferencia;
do $$ declare v text; begin
  for v in select r from _bol_create_dado loop execute format('revoke create on schema erp from %I', v); end loop;
end $$;
drop table _bol_create_dado;

-- O alerta crítico do boleto não conferido, quando o título vai à fila do Sienge (como o do PIX copia e cola)
insert into erp.tipos_evento (codigo, rotulo, modulo, critico) values
  ('boleto_excecao', 'Título vai ao Sienge com boleto de beneficiário não conferido', 'pagar', true);
insert into erp.regras_notificacao (tipo, destino, lista) values ('boleto_excecao', 'lista', 'AF');
do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('erp.sienge_enfileirar()'::regprocedure);
  v_novo := replace(v_def, $r$    n := n + 1;
$r$, $r$    n := n + 1;
    if exists (select 1 from erp.parcela_pagamentos g where g.titulo_id = r.titulo_id and g.boleto_excecao is not null) then
      perform erp.registrar_evento('boleto_excecao', 'titulos', r.titulo_id::text, r.onde[1], r.onde[2],
        jsonb_build_object('titulo_id', r.titulo_id, 'pessoa_id', r.pessoa_id,
          'parcelas', (select jsonb_agg(jsonb_build_object('numero', g.numero, 'conferido', erp.boleto_conferido(g.boleto_linha),
                                                           'justificativa', g.boleto_excecao) order by g.numero)
                         from erp.parcela_pagamentos g where g.titulo_id = r.titulo_id and g.boleto_excecao is not null),
          'motivo', 'Boleto com beneficiário não conferido'));
    end if;
$r$);
  if v_novo = v_def then raise exception 'erp.sienge_enfileirar: ponto de troca não achado'; end if;
  execute v_novo;
end $$;

-- api.lancar_titulo: "boleto_excecao" em cada parcela de boleto
do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('api.lancar_titulo(jsonb)'::regprocedure);
  v_novo := replace(v_def, 'pix_copia_cola, pix_copia_cola_excecao)', 'pix_copia_cola, pix_copia_cola_excecao, boleto_excecao)');
  v_novo := replace(v_novo, $r$nullif(trim(l->>'pix_copia_cola_excecao'), ''));$r$,
                            $r$nullif(trim(l->>'pix_copia_cola_excecao'), ''), nullif(trim(l->>'boleto_excecao'), ''));$r$);
  if position('pix_copia_cola_excecao, boleto_excecao)' in v_novo) = 0 or position($r$l->>'boleto_excecao'$r$ in v_novo) = 0 then
    raise exception 'api.lancar_titulo: ponto de troca não achado';
  end if;
  execute v_novo;
end $$;

-- api.titulo: a conferência do boleto e a justificativa na parcela, e o selo do título
do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('api.titulo(uuid)'::regprocedure);
  v_novo := replace(v_def, $r$'pix_copia_cola_excecao', f.pix_copia_cola_excecao)$r$,
    $r$'pix_copia_cola_excecao', f.pix_copia_cola_excecao,
                   'boleto_conferido', erp.boleto_conferido(f.boleto_linha), 'boleto_excecao', f.boleto_excecao)$r$);
  v_novo := replace(v_novo, $r$'sienge_erro',$r$, $r$'recebedor_divergente', erp.recebedor_divergente(t.id), 'sienge_erro',$r$);
  if position('boleto_excecao' in v_novo) = 0 or position('recebedor_divergente' in v_novo) = 0 then
    raise exception 'api.titulo: ponto de troca não achado';
  end if;
  execute v_novo;
end $$;

-- O selo nas listas (títulos, aprovar): os títulos a pagar que a pessoa vê, ainda não pagos, em que o recebedor não
-- bate com o fornecedor, com o que não bate
create function api.recebedores_divergentes() returns table (id uuid, motivos text[])
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select t.id, erp.recebedor_divergente(t.id)
    from erp.titulos t
   where t.sentido = 'pagar' and t.situacao not in ('quitado', 'cancelado')
     and exists (select 1 from erp.parcela_pagamentos g where g.titulo_id = t.id
                  and (g.pix_excecao is not null or g.pix_copia_cola_excecao is not null or g.boleto_excecao is not null)) $$;
revoke execute on function api.recebedores_divergentes() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke execute on function api.recebedores_divergentes() from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then grant execute on function api.recebedores_divergentes() to authenticated; end if;
end $$;
