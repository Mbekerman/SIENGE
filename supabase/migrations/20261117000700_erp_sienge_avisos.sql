-- Aviso do Sienge (webhook) para a linha PRV apagada (Moises, 17/11/2026: "Testa" e "Pode dar o próximo
-- passo"). Teste do mesmo dia na empresa 11: o Sienge manda PAYMENT_INSTALLMENT_REMOVED em 1 segundo, uma vez
-- por parcela, com {billId, installmentId, billOrigin, documentType}, e o token do cadastro no cabeçalho
-- Authorization: Bearer.
--
-- 1. O recebedor (servicos/sienge-aviso) confere o token e só registra o aviso aqui, pelo id do evento
--    (x-sienge-id), sem agir: aviso é dado, não ordem (qualquer um pode mandar um POST).
-- 2. O programa de envio (servicos/sienge-escrita) pega o aviso pendente de um título que é linha PRV do ERP,
--    relê o título no Sienge e só com 404 age: a linha da lista do que apagar fica apagada
--    (erp.sienge_marcar_apagado); a linha esperada de previsão aberta volta à fila (erp.sienge_recriar_prv).
-- 3. O aviso de título que não é do ERP fica registrado como "não é do ERP", sem chamar o Sienge.
-- A conferência de 30 minutos e o cruzamento da madrugada continuam: aviso perdido não volta.
-- Portabilidade: SQL puro.

create table erp.sienge_avisos (
  evento_id     uuid primary key,                 -- x-sienge-id: o mesmo aviso repetido não entra duas vezes
  evento        text not null check (evento ~ '^[A-Z_]{3,60}$'),
  hook_id       text check (length(hook_id) <= 60),
  bill_id       int,
  corpo         jsonb not null,
  recebido_em   timestamptz not null default clock_timestamp(),
  tentativas    int not null default 0,
  pegado_em     timestamptz,
  processado_em timestamptz,
  resultado     text check (length(resultado) <= 300)
);
create index on erp.sienge_avisos (recebido_em) where processado_em is null;

create function erp.tg_sienge_aviso() returns trigger language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'Os avisos do Sienge só são escritos pelo sistema'; end if;
  if tg_op = 'DELETE' then raise exception 'Os avisos do Sienge não se apagam'; end if;
  if tg_op = 'UPDATE' then
    if new.evento_id <> old.evento_id or new.evento <> old.evento or new.bill_id is distinct from old.bill_id
       or new.corpo <> old.corpo or new.recebido_em <> old.recebido_em then
      raise exception 'O aviso recebido não muda';
    end if;
    if old.processado_em is not null then raise exception 'O aviso já foi processado'; end if;
  end if;
  return new;
end $$;
create trigger t_sienge_aviso before insert or update or delete on erp.sienge_avisos
  for each row execute function erp.tg_sienge_aviso();

-- A linha PRV do ERP com este id do Sienge: na lista do que apagar, ou esperada (enviada, previsão aberta).
create function erp._sienge_prv_do_titulo(p_bill int) returns table (previsao_id uuid, tipo text) language sql stable as $$
  select s.previsao_id,
         case when s.apagar_desde is not null and s.apagado_em is null then 'apagar'
              when s.situacao = 'enviado' and s.apagar_desde is null and p.situacao = 'aberta' then 'esperada' end
    from erp.sienge_previsoes s join erp.previsoes p on p.id = s.previsao_id
   where s.sienge_id = p_bill
     and ((s.apagar_desde is not null and s.apagado_em is null)
          or (s.situacao = 'enviado' and s.apagar_desde is null and p.situacao = 'aberta'));
$$;

-- O recebedor grava o aviso. Devolve se é novo. Aviso de título que não é linha PRV do ERP já nasce
-- processado ("não é do ERP"), para o programa não gastar chamada com ele.
create function erp.sienge_registrar_aviso(p_evento_id uuid, p_evento text, p_hook text, p_corpo jsonb)
returns boolean language plpgsql as $$
declare v_bill int; v_nosso boolean;
begin
  if not erp.sistema() then raise exception 'Só o sistema registra aviso do Sienge'; end if;
  if p_evento_id is null or jsonb_typeof(p_corpo) <> 'object' then raise exception 'Aviso do Sienge inválido'; end if;
  if jsonb_typeof(p_corpo->'billId') = 'number' and (p_corpo->>'billId') ~ '^[0-9]{1,9}$' then v_bill := (p_corpo->>'billId')::int; end if;
  v_nosso := v_bill is not null and exists (select 1 from erp._sienge_prv_do_titulo(v_bill));
  insert into erp.sienge_avisos (evento_id, evento, hook_id, bill_id, corpo, processado_em, resultado)
  values (p_evento_id, p_evento, left(p_hook, 60), v_bill, p_corpo,
          case when not v_nosso or p_evento <> 'PAYMENT_INSTALLMENT_REMOVED' then clock_timestamp() end,
          case when not v_nosso then 'não é linha PRV do ERP'
               when p_evento <> 'PAYMENT_INSTALLMENT_REMOVED' then 'evento sem ação' end)
  on conflict (evento_id) do nothing;
  return found;
end $$;

-- O programa pega o aviso pendente mais antigo de uma linha PRV do ERP (os avisos de cada parcela do mesmo
-- título vêm juntos: o primeiro decide e os outros fecham sem chamar o Sienge). Reserva por 5 minutos;
-- depois de 5 tentativas, o aviso fecha com erro e a conferência ou o cruzamento resolvem.
create function erp.sienge_pegar_aviso(p_agora timestamptz default now())
returns table (evento_id uuid, bill_id int, previsao_id uuid, tipo text) language plpgsql as $$
#variable_conflict use_column
declare a erp.sienge_avisos; v_prev uuid; v_tipo text;
begin
  if not erp.sistema() then raise exception 'Só o sistema processa aviso do Sienge'; end if;
  loop
    select * into a from erp.sienge_avisos x
     where x.processado_em is null and (x.pegado_em is null or x.pegado_em < p_agora - interval '5 minutes')
     order by x.recebido_em limit 1 for update skip locked;
    if a.evento_id is null then return; end if;
    if a.tentativas >= 5 then
      update erp.sienge_avisos set processado_em = p_agora, resultado = 'erro: 5 tentativas sem resposta do Sienge'
       where evento_id = a.evento_id;
      continue;
    end if;
    select d.previsao_id, d.tipo into v_prev, v_tipo from erp._sienge_prv_do_titulo(a.bill_id) d limit 1;
    if v_prev is null then
      update erp.sienge_avisos set processado_em = p_agora, resultado = 'a linha já não está pendente no ERP'
       where evento_id = a.evento_id;
      continue;
    end if;
    update erp.sienge_avisos set pegado_em = p_agora, tentativas = tentativas + 1 where evento_id = a.evento_id;
    return query select a.evento_id, a.bill_id, v_prev, v_tipo;
    return;
  end loop;
end $$;

create function erp.sienge_terminar_aviso(p_evento_id uuid, p_resultado text, p_processado boolean default true)
returns void language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'Só o sistema processa aviso do Sienge'; end if;
  update erp.sienge_avisos
     set processado_em = case when p_processado then clock_timestamp() end, resultado = left(p_resultado, 300)
   where evento_id = p_evento_id and processado_em is null;
  if not found then raise exception 'Aviso do Sienge inexistente ou já processado'; end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Segurança
-- ---------------------------------------------------------------------------------------------
do $$
declare t text; f regprocedure;
begin
  foreach t in array array['sienge_avisos'] loop
    execute format('revoke all on erp.%I from public', t);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on erp.%I from anon', t); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke all on erp.%I from service_role', t); end if;
    execute format('revoke all on erp.%I from authenticated', t);
    execute format('alter table erp.%I enable row level security', t);
    execute format('alter table erp.%I force row level security', t);
    execute format('create policy sistema on erp.%I using (erp.sistema()) with check (erp.sistema())', t);
    execute format('create policy conferencia on erp.%I for select to erp_conferencia using (true)', t);
    execute format('create trigger t_nao_trunca before truncate on erp.%I for each statement execute function erp.tg_recusa_truncate()', t);
    execute format('grant select, insert, update on erp.%I to erp_sistema', t);
    execute format('grant select on erp.%I to erp_conferencia', t);
  end loop;
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'erp' and p.proname in ('tg_sienge_aviso','_sienge_prv_do_titulo','sienge_registrar_aviso',
              'sienge_pegar_aviso','sienge_terminar_aviso') loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('revoke execute on function %s from authenticated', f);
  end loop;
end $$;
-- quem é master ou está na lista AF lê os avisos (só ids do Sienge)
create policy perfil_le on erp.sienge_avisos for select to authenticated using (erp.sou_master() or erp.estou_nas_listas(array['AF']));
grant select on erp.sienge_avisos to authenticated;

grant execute on function erp.tg_sienge_aviso(), erp._sienge_prv_do_titulo(int), erp.sienge_registrar_aviso(uuid, text, text, jsonb),
                          erp.sienge_pegar_aviso(timestamptz), erp.sienge_terminar_aviso(uuid, text, boolean)
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
