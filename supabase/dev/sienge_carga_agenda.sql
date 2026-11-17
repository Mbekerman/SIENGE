-- Só para o banco de desenvolvimento no Supabase (bkm_dev): agenda o programa de carga do Sienge.
-- Não é migration: pg_cron, pg_net e Vault são do Supabase (regra de portabilidade de 14/11/2026).
-- Na produção, a mesma rotina pode vir de outro agendador (Cloud Scheduler, por exemplo).
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- chave aleatória que o pg_cron manda e a função confere (nunca vai para o repositório)
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'sienge_carga_chave') then
    perform vault.create_secret(encode(gen_random_bytes(32), 'hex'), 'sienge_carga_chave', 'chave do pg_cron para a função sienge-carga');
  end if;
end $$;

-- de minuto em minuto, um passo da carga (a função decide se há o que fazer)
select cron.schedule('sienge-carga', '* * * * *', $cron$
  select net.http_post(
    url := 'https://zwxvmotxnjvnoigroqds.supabase.co/functions/v1/sienge-carga',
    headers := jsonb_build_object('x-carga-chave', (select decrypted_secret from vault.decrypted_secrets where name = 'sienge_carga_chave'),
                                  'content-type', 'application/json'),
    body := '{}'::jsonb,
    timeout_milliseconds := 300000)
$cron$);

-- para parar: select cron.unschedule('sienge-carga');
