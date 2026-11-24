-- bkm_dev, 24/nov/2026: ciência só dentro do prazo (migration 20261124000100). Colar inteiro no SQL Editor.
-- A função é do erp_conferencia: o script se dá o papel (só set) e o direito de criar no esquema durante a transação.
begin;
grant erp_conferencia to current_user with inherit false, set true;
grant create on schema erp to erp_conferencia;
set local role erp_conferencia;
create or replace function erp.busca_notas_sem_ciencia(p_empresa uuid, p_limite int) returns setof text
language plpgsql stable security definer set search_path = erp, pg_catalog, pg_temp as $$
begin
  if not erp.sistema() then raise exception 'Só o serviço da busca'; end if;
  return query select n.chave from erp.notas_recebidas n join erp.notas_recebidas_xml x on x.nota_id = n.id
    where n.empresa_id = p_empresa and n.tipo = 'nfe' and n.ciencia_em is null and n.cancelada_em is null and not x.completo
      and n.emissao >= current_date - 10
    order by n.emissao desc, n.chave limit least(greatest(coalesce(p_limite, 20), 1), 20);
end $$;
reset role;
revoke create on schema erp from erp_conferencia;
revoke erp_conferencia from current_user;
commit;
