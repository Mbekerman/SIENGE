-- Só para o banco de desenvolvimento no Supabase (bkm_dev): agenda o envio de títulos ao Sienge (servicos/sienge-escrita).
-- Não é migration: pg_cron, pg_net e Vault são do Supabase (regra de portabilidade de 14/11/2026).
-- Na produção, a mesma rotina pode vir de outro agendador (Cloud Scheduler, por exemplo).
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- chave aleatória que o pg_cron manda e a função confere (nunca vai para o repositório)
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'sienge_escrita_chave') then
    perform vault.create_secret(encode(gen_random_bytes(32), 'hex'), 'sienge_escrita_chave', 'chave do pg_cron para a função sienge-escrita');
  end if;
end $$;

-- de minuto em minuto, um título da fila (a função decide se há o que fazer)
select cron.schedule('sienge-escrita', '* * * * *', $cron$
  select net.http_post(
    url := 'https://zwxvmotxnjvnoigroqds.supabase.co/functions/v1/sienge-escrita',
    headers := jsonb_build_object('x-escrita-chave', (select decrypted_secret from vault.decrypted_secrets where name = 'sienge_escrita_chave'),
                                  'content-type', 'application/json'),
    body := '{}'::jsonb,
    timeout_milliseconds := 300000)
$cron$);

-- planilha do Google com as linhas PRV a apagar: a cada 30 minutos no horário comercial (8h às 19h30 em
-- São Paulo, segunda a sexta; o pg_cron do Supabase usa UTC) e às 6h30, depois do cruzamento da madrugada.
-- Precisa dos segredos GOOGLE_PLANILHA_CHAVE e PLANILHA_PRV_ID na função.
select cron.schedule('sienge-planilha-prv', '*/30 11-22 * * 1-5', $cron$
  select net.http_post(
    url := 'https://zwxvmotxnjvnoigroqds.supabase.co/functions/v1/sienge-escrita',
    headers := jsonb_build_object('x-escrita-chave', (select decrypted_secret from vault.decrypted_secrets where name = 'sienge_escrita_chave'),
                                  'content-type', 'application/json'),
    body := '{"tarefa": "planilha"}'::jsonb,
    timeout_milliseconds := 120000)
$cron$);
select cron.schedule('sienge-planilha-prv-madrugada', '30 9 * * *', $cron$
  select net.http_post(
    url := 'https://zwxvmotxnjvnoigroqds.supabase.co/functions/v1/sienge-escrita',
    headers := jsonb_build_object('x-escrita-chave', (select decrypted_secret from vault.decrypted_secrets where name = 'sienge_escrita_chave'),
                                  'content-type', 'application/json'),
    body := '{"tarefa": "planilha"}'::jsonb,
    timeout_milliseconds := 120000)
$cron$);

-- para parar: select cron.unschedule('sienge-escrita'); select cron.unschedule('sienge-planilha-prv');
-- select cron.unschedule('sienge-planilha-prv-madrugada');
