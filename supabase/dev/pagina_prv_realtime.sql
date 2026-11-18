-- Só para o Supabase (bkm_dev e, quando for, a produção): a página das PRV a apagar
-- (pagina/) se atualiza sozinha quando a lista muda (pedido do Moises, 18/11/2026).
-- Não é migration: o Realtime é do Supabase. O Moises aceitou ficar preso a ele aqui
-- porque a página é provisória (18/11/2026). Sem este arquivo, a página relê a lista
-- a cada 60 s e nada mais muda.
--
-- 1. Gatilho em erp.sienge_previsoes: quando muda o que a página mostra (entrou na lista,
--    saiu dela ou foi conferida), manda pelo Broadcast do Realtime o aviso "mudou" no
--    canal privado prv-apagar. O aviso não leva dado nenhum: a página relê a lista pela
--    função pagina.prv_apagar(), que confere o login. Falha do Realtime nunca derruba a
--    gravação.
-- 2. Política em realtime.messages: só o login Google @bkm.com.br (erp.login_bkm()) ouve
--    o canal prv-apagar. Nenhuma política de insert: o navegador não manda nada no canal.

create or replace function erp.tg_pagina_prv_mudou() returns trigger
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
begin
  begin
    perform realtime.send('{}'::jsonb, 'mudou', 'prv-apagar', true);
  exception when others then
    null;   -- a página continua relendo a cada 60 s
  end;
  return null;
end $$;
revoke execute on function erp.tg_pagina_prv_mudou() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function erp.tg_pagina_prv_mudou() from anon, authenticated, service_role';
  end if;
end $$;

drop trigger if exists t_pagina_prv_mudou on erp.sienge_previsoes;
create trigger t_pagina_prv_mudou after update of apagar_desde, apagado_em, conferido_em on erp.sienge_previsoes
  for each statement execute function erp.tg_pagina_prv_mudou();

drop policy if exists prv_apagar_ouvir on realtime.messages;
create policy prv_apagar_ouvir on realtime.messages for select to authenticated
  using (realtime.topic() = 'prv-apagar' and extension = 'broadcast' and erp.login_bkm());

-- Conferência (deve mostrar: t_pagina_prv_mudou | prv_apagar_ouvir)
select (select tgname from pg_trigger where tgname = 't_pagina_prv_mudou') as gatilho,
       (select polname from pg_policy where polname = 'prv_apagar_ouvir' and polrelid = 'realtime.messages'::regclass) as politica;
