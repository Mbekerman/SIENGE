-- Quem aprova o cadastro da conta recorrente (Moises, 23/nov/2026, no cartão "Quem aprova o cadastro de uma conta
-- recorrente?": "Gestor + AF ou AD"). Antes (8/nov/2026) era o gestor de cada centro do rateio e AF ou AO. Agora a vaga
-- do financeiro (FIN) é da AF ou da AD, a mesma de quem aprova a nota do mês do contrato: o cadastro fixa o valor de
-- todos os meses. O gestor de cada centro continua; quem lançou ou alterou continua sem aprovar; o master continua
-- aprovando tudo de uma vez. Vale para contrato de serviço, assinatura e conta de consumo.
--
-- Aprovação já dada por alguém da AO na versão atual continua valendo (a regra nova vale para as decisões daqui em
-- diante). No bkm_dev não há conta cadastrada (conferido em 21/nov/2026), então nada fica para trás.
-- Portabilidade: SQL e plpgsql padrão.

create or replace function erp.decidir_compromisso(p_compromisso uuid, p_aprovar boolean, p_justificativa text default null)
returns text language plpgsql security definer set search_path = erp, pg_catalog, pg_temp as $$
declare c erp.compromissos; v_eu uuid := erp.eu(); v_master boolean := erp.sou_master(); v record;
begin
  perform erp.exigir_editor();
  if v_eu is null then raise exception 'Usuário sem cadastro no ERP'; end if;
  select * into c from erp.compromissos where id = p_compromisso for update;
  if c.id is null or not erp.vejo_compromisso(c.id) then raise exception 'Contrato não existe'; end if;
  if not erp.compromisso_precisa_aprovacao(c.tipo) then raise exception 'Só contrato e assinatura recorrente passam por aprovação'; end if;
  if c.situacao <> 'ativo' then raise exception 'Só contrato ativo se aprova'; end if;
  if exists (select 1 from erp.compromisso_aprovacoes where compromisso_id = c.id and versao = c.aprovacao_versao and not aprovado) then
    raise exception 'O contrato foi recusado; mude o contrato para pedir a aprovação de novo';
  end if;
  if erp.compromisso_aprovado(c.id) then raise exception 'O contrato já está aprovado'; end if;
  if not p_aprovar and length(trim(coalesce(p_justificativa, ''))) = 0 then raise exception 'Recusar exige justificativa'; end if;
  if not v_master and v_eu in (c.criado_por, c.alterado_por) then
    raise exception 'Quem lançou ou alterou o contrato não aprova';
  end if;
  if not v_master and exists (select 1 from erp.compromisso_aprovacoes
                               where compromisso_id = c.id and versao = c.aprovacao_versao and por = v_eu) then
    raise exception 'Você já aprovou este contrato';
  end if;
  if v_master then
    insert into erp.compromisso_aprovacoes (compromisso_id, versao, vaga, centro_custo_id, aprovado, justificativa, por)
    select c.id, c.aprovacao_versao, x.vaga, x.centro_custo_id, p_aprovar, p_justificativa, v_eu
      from erp.compromisso_vagas(c.id) x
     where not exists (select 1 from erp.compromisso_aprovacoes a where a.compromisso_id = c.id and a.versao = c.aprovacao_versao
                         and a.vaga = x.vaga and a.centro_custo_id is not distinct from x.centro_custo_id)
     order by x.vaga, x.centro_custo_id
     limit case when p_aprovar then null else 1 end;
    return case when p_aprovar then 'aprovado' else 'recusado' end;
  end if;
  -- a primeira vaga pendente que a pessoa ocupa (o gestor do centro, ou a AF ou a AD no financeiro)
  select x.* into v from erp.compromisso_vagas(c.id) x
   where not exists (select 1 from erp.compromisso_aprovacoes a where a.compromisso_id = c.id and a.versao = c.aprovacao_versao
                       and a.vaga = x.vaga and a.centro_custo_id is not distinct from x.centro_custo_id)
     and case when x.vaga = 'AREA' then erp._ocupa_vaga('AREA', x.centro_custo_id, v_eu)
              else erp._ocupa_vaga('AF', null, v_eu) end   -- 'AF' vale para a lista AF e para a AD
   order by x.vaga, x.centro_custo_id limit 1;
  if v.vaga is null then
    raise exception 'A aprovação deste contrato é do gestor de cada centro e da AF ou da AD';
  end if;
  insert into erp.compromisso_aprovacoes (compromisso_id, versao, vaga, centro_custo_id, aprovado, justificativa, por)
  values (c.id, c.aprovacao_versao, v.vaga, v.centro_custo_id, p_aprovar, p_justificativa, v_eu);
  return case when not p_aprovar then 'recusado' when erp.compromisso_aprovado(c.id) then 'aprovado' else 'pendente' end;
end $$;

-- O nome da vaga na tela Para aprovar.
create or replace function erp.rotulo_vaga(p_vaga text) returns text language sql stable set search_path = pg_catalog, pg_temp as $$
  select case p_vaga
    when 'AREA' then 'gestor do centro' when 'DIRETOR_AREA' then 'diretor da área' when 'FIN' then 'AF ou AD'
    when 'AF' then 'AF' when 'AO' then 'AO' when 'AD' then 'AD' when 'PJ' then 'master ou designado do PJ'
    when 'MASTER' then 'master'
    else case when p_vaga like 'P:%' then coalesce((select u.nome from erp.usuarios u where u.id::text = substr(p_vaga, 3)), 'pessoa indicada')
              else p_vaga end end $$;
