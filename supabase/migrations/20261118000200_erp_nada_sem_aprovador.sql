-- Nada é aprovado sem aprovador (Moises, 18/11/2026: "Passa por mim. Nada é aprovado sem aprovador").
--
-- Antes, o centro sem gestor e sem faixas próprias ficava fora da alçada: o título não pedia aprovação
-- nele e a previsão lançada à mão nascia aprovada. Agora toda linha do rateio passa pela alçada do
-- centro (ou da divisão com faixas próprias); sem faixas próprias valem as gerais, e a vaga que não tem
-- quem a ocupe (o gestor que o centro não tem) manda ao master, com o aviso de falta de aprovadores.
-- Sem faixa nenhuma, a previsão vai ao master (como já era) e o título é recusado na confirmação.
-- Vale para título e previsão confirmados daqui em diante; o que já foi confirmado não muda.
-- Portabilidade: SQL puro.

create or replace function erp._definir_alcada(p_titulo uuid) returns void language plpgsql as $$
declare t erp.titulos; cc record; dv record; f erp.alcadas_pagamento; v_centro boolean;
begin
  select * into t from erp.titulos where id = p_titulo;
  if t.sentido <> 'pagar' or t.tipo in ('imposto','societario') then return; end if;
  -- dois títulos do mesmo centro confirmados ao mesmo tempo se enxergam (S-060): trava os
  -- centros do rateio, sempre na mesma ordem, até o fim da transação
  perform 1 from erp.centros_custo c
   where c.id in (select tr.centro_custo_id from erp.titulo_rateios tr where tr.titulo_id = t.id)
   order by c.id for update;
  perform erp._cobrir_adiantamento(t);
  for cc in select distinct tr.centro_custo_id from erp.titulo_rateios tr
            where tr.titulo_id = t.id and tr.centro_custo_id is not null order by tr.centro_custo_id loop
    -- a alçada da divisão com faixas próprias; a faixa diz se a linha passa também pelo centro
    v_centro := false;
    for dv in select distinct tr.divisao_id from erp.titulo_rateios tr
               where tr.titulo_id = t.id and tr.centro_custo_id = cc.centro_custo_id
                 and exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = tr.divisao_id)
               order by tr.divisao_id loop
      f := erp._fixar_alcada(t, cc.centro_custo_id, dv.divisao_id);
      v_centro := v_centro or f.passa_pelo_centro;
    end loop;
    -- a alçada do centro: as linhas sem divisão com faixas próprias, ou a faixa da divisão que
    -- manda passar pelo centro. Centro sem gestor e sem faixas próprias também entra, pelas faixas
    -- gerais: a vaga sem gente vai ao master (nada é aprovado sem aprovador, Moises, 18/11/2026)
    if v_centro
       or exists (select 1 from erp.titulo_rateios tr
                   where tr.titulo_id = t.id and tr.centro_custo_id = cc.centro_custo_id
                     and not exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = tr.divisao_id)) then
      perform erp._fixar_alcada(t, cc.centro_custo_id, null);
    end if;
  end loop;
end $$;

create or replace function erp.tg_previsao_alcada() returns trigger language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
declare f erp.alcadas_pagamento; v_centro boolean := false;
begin
  if new.sentido <> 'pagar' or new.centro_custo_id is null or erp.previsao_do_contrato(new.id) is not null
     or new.origem_previsao_id is not null then return null; end if;
  perform 1 from erp.centros_custo where id = new.centro_custo_id for update;   -- como no título (S-060)
  if new.divisao_id is not null and exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = new.divisao_id) then
    f := erp._fixar_alcada_previsao(new, new.centro_custo_id, new.divisao_id);
    v_centro := coalesce(f.passa_pelo_centro, true);
  end if;
  -- centro sem gestor e sem faixas próprias também entra: nada é aprovado sem aprovador (Moises, 18/11/2026)
  if v_centro
     or new.divisao_id is null or not exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = new.divisao_id) then
    perform erp._fixar_alcada_previsao(new, new.centro_custo_id, null);
  end if;
  return null;
end $$;

-- A faixa que decidiu fica guardada na alçada da previsão como registro, sem chave estrangeira, como na
-- do título (titulo_alcadas.alcada_id): com toda previsão passando pela alçada, a chave impediria para
-- sempre excluir uma faixa já usada. As fases e as vagas da alçada ficam copiadas nela.
alter table erp.previsao_alcadas drop constraint previsao_alcadas_alcada_id_fkey;
