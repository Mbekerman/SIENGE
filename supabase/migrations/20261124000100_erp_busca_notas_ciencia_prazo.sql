-- Ciência da operação só dentro do prazo (primeira rodada da busca, BKM 03, 23/11/2026): a SEFAZ recusou as 20 primeiras
-- com 596 ("evento apresentado fora do prazo"). Pela NT 2020.001 (v1.60), a ciência só vale até 10 dias da autorização
-- da NF-e. A lista pedia 90 dias, da mais velha para a mais nova, e a rodada para quando nenhuma da leva é aceita: as
-- mesmas 20 velhas voltariam toda hora e as novas nunca seriam pedidas. Agora: só as dos últimos 10 dias (pela emissão,
-- que vem antes da autorização), da mais nova para a mais velha. As mais antigas ficam em resumo (chave, emitente,
-- número, valor), que basta para achar a nota; o XML completo delas não vem mais pela ciência.
create or replace function erp.busca_notas_sem_ciencia(p_empresa uuid, p_limite int) returns setof text
language plpgsql stable security definer set search_path = erp, pg_catalog, pg_temp as $$
begin
  if not erp.sistema() then raise exception 'Só o serviço da busca'; end if;
  return query select n.chave from erp.notas_recebidas n join erp.notas_recebidas_xml x on x.nota_id = n.id
    where n.empresa_id = p_empresa and n.tipo = 'nfe' and n.ciencia_em is null and n.cancelada_em is null and not x.completo
      and n.emissao >= current_date - 10
    order by n.emissao desc, n.chave limit least(greatest(coalesce(p_limite, 20), 1), 20);
end $$;
