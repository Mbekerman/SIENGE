-- Só para o banco de desenvolvimento no Supabase (bkm_dev): agenda a janela do login da busca das notas
-- (migration 20261123005000). Não é migration: pg_cron é do Supabase (regra de portabilidade de 14/11/2026).
-- O job do Cloud Run roda aos 7 minutos de cada hora; a janela abre aos 5, fecha aos 15 e derruba o que sobrou aos 35.
create extension if not exists pg_cron;
select cron.schedule('busca-notas-abrir', '5 * * * *', $cron$ select erp.busca_notas_janela('abrir') $cron$);
select cron.schedule('busca-notas-fechar', '15 * * * *', $cron$ select erp.busca_notas_janela('fechar') $cron$);
select cron.schedule('busca-notas-encerrar', '35 * * * *', $cron$ select erp.busca_notas_janela('encerrar') $cron$);
-- para parar a busca de vez: select cron.unschedule(j) from unnest(array['busca-notas-abrir','busca-notas-fechar',
--   'busca-notas-encerrar']) j; select erp.busca_notas_janela('encerrar');
