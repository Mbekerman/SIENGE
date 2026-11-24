-- Só para o banco de desenvolvimento no Supabase (bkm_dev): agenda a carga dos credores do Sienge (servicos/sienge-credores).
-- Não é migration: pg_cron, pg_net e Vault são do Supabase (regra de portabilidade de 14/11/2026).
-- Colar depois de instalar a função sienge-credores (verify_jwt desligado) e do SQL 20261125000100.
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- chave aleatória que o pg_cron manda e a função confere (nunca vai para o repositório)
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'sienge_credores_chave') then
    perform vault.create_secret(encode(gen_random_bytes(32), 'hex'), 'sienge_credores_chave', 'chave do pg_cron para a função sienge-credores');
  end if;
end $$;

-- todo dia às 3h (horário de Brasília = 6h UTC), a lista inteira (825 credores em 24/11/2026 = 5 chamadas ao Sienge)
select cron.schedule('sienge-credores', '0 6 * * *', $cron$
  select net.http_post(
    url := 'https://zwxvmotxnjvnoigroqds.supabase.co/functions/v1/sienge-credores',
    headers := jsonb_build_object('x-credores-chave', (select decrypted_secret from vault.decrypted_secrets where name = 'sienge_credores_chave'),
                                  'content-type', 'application/json'),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000)
$cron$);

-- primeira carga agora (não precisa esperar a madrugada)
select net.http_post(
  url := 'https://zwxvmotxnjvnoigroqds.supabase.co/functions/v1/sienge-credores',
  headers := jsonb_build_object('x-credores-chave', (select decrypted_secret from vault.decrypted_secrets where name = 'sienge_credores_chave'),
                                'content-type', 'application/json'),
  body := '{}'::jsonb,
  timeout_milliseconds := 120000);

-- para parar: select cron.unschedule('sienge-credores');
