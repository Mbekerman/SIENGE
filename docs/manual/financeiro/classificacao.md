# Como todo valor é classificado

[← Sumário](../README.md)

## As cinco perguntas

✅ **Decidido** (7/nov/2026). Todo valor do sistema (orçamento, previsão, título, pagamento) responde às mesmas cinco perguntas, cada uma com um campo próprio:

| Pergunta | Campo | Exemplo |
| --- | --- | --- |
| De quem é o gasto? | Empresa e centro de custo | SPE Vila Maria / Empreendimento Vila Maria |
| Que gasto é? | Natureza | Comerciais › Marketing › Marketing online |
| Quando? | Competência e data de caixa | competência out/2027, pago em nov/2027 |
| Em que momento do projeto? | Fase | Obras |
| Quem responde? | Área (até 3 níveis) | Comercial › Marketing |

### O que muda em relação a hoje

Hoje a BKM usa "centro de custo Marketing, natureza MKT Online, motivo verba Google". No ERP BKM:

| Hoje | No ERP BKM |
| --- | --- |
| Centro de custo: Marketing | Natureza: Comerciais › **Marketing** |
| Natureza: MKT Online | Natureza: Comerciais › Marketing › **Marketing online** |
| Motivo: verba de mídia Google | Mais um nível da natureza (… › Mídia Google) **ou** só a descrição do lançamento |
| (não existia) | Centro de custo: o empreendimento, ou a Sede se for institucional |
| (não existia) | Área: Comercial › Marketing |

**Regra para decidir se o "motivo" vira nível da natureza:** se você quer orçar e comparar por ele ("quanto previ e quanto gastei de Google no ano"), ele é um nível. Se só explica aquele gasto ("campanha de março"), ele vai na descrição.

**Por que não um centro de custo por tipo de gasto:** com 30 empreendimentos e 10 tipos seriam 300 centros de custo, e cada regra ou relatório teria de listar os que entram. Separando as perguntas, "marketing da empresa inteira", "marketing do Vila Maria" e "tudo o que a área de Marketing gastou" viram três filtros sobre os mesmos dados.

## Três eixos separados: centro de custo, área e natureza

✅ **Decidido** (Moises, 8/nov/2026). Cada lançamento leva três classificações separadas, mais a fase:

- **Centro de custo:** de quem é o gasto (um empreendimento ou a empresa).
- **Área:** quem responde pelo gasto. As áreas formam uma árvore de **até 3 níveis** (por exemplo, Administrativo › Financeiro). Cada nível tem de 1 a 3 aprovadores.
- **Natureza:** só o tipo de gasto (Marketing online, Vigilância, Energia...).
- **Fase:** o momento do projeto (Novos negócios, Obras...).

⏳ Em aberto: se "1 a 3 aprovadores" quer dizer quantas pessoas **precisam** aprovar naquele nível ou quantas estão na lista para **qualquer uma** aprovar. Também em aberto: se o gasto pode ser lançado em qualquer nível da área (por exemplo, uma consultoria do Administrativo inteiro) e se quem vê um nível vê os de baixo (proposta).

🟡 Proposta enviada ao Moises, ainda não decidida: o centro de custo passa a ser só "de quem é o gasto", um por empreendimento e um por área da empresa. Hoje o Sienge tem 97 centros, uns 9 por SPE, que misturam tipo de gasto e momento; esses dois iriam para a natureza e para a fase.

## A árvore de naturezas

✅ **Decidido** (7/nov/2026):

- **Uma árvore só** para a empresa inteira, com quantos níveis cada galho precisar.
- **O topo da árvore é o mesmo da viabilidade do BKM Terrenos** (Terreno, Obras, Comerciais, Gerais, Financeiras, Taxas...), para que viabilidade, orçamento e realizado se comparem sem conversão.
- **A árvore é dinâmica:** novas naturezas são criadas pela tela, sem programador (Moises, 7/nov/2026).
- **O topo também é editável** (Moises, no documento do modelo v1: "concordo, mas tem que ser editável"). Isso substitui a proposta de travar o topo.
- **A árvore é feita do zero**, não copiada do plano financeiro do Sienge (Moises, 7/nov/2026). O plano do Sienge fica ligado a ela por correspondência, por trás.

🟡 **Propostas** ainda sem confirmação:

- Só o administrador (ou o controller) cria naturezas, para não surgir "MKT Online", "Marketing online" e "Mkt digital" lado a lado.
- Só se lança no último nível (não se lança em "Comerciais", só em "Marketing online").
- A natureza nova herda as características da mãe (ver abaixo), e pode ser mudada.
- Natureza com lançamentos não se apaga direto: primeiro se reclassifica (ver [Reclassificação](reclassificacao-e-fechamento.md)).
- Natureza desativada não recebe lançamentos novos; os antigos continuam onde estão.
- Mover um galho com lançamentos para outra mãe mostra antes quanto do histórico muda de lugar.
- Mudar o lugar, o tipo, a linha da DRE ou a do fluxo de caixa de uma natureza que já tem lançamentos é só com a diretoria, porque mexe nos relatórios do passado.
- Como o topo é editável: quem edita o topo e o que acontece com a comparação com a viabilidade quando ele muda. ⏳

### Características de cada natureza

✅ **Decidido** (7/nov/2026): a classificação contábil-gerencial é **característica da natureza**, não uma escolha a cada lançamento. Quem lança escolhe só "Mídia Google", e o sistema já sabe o resto.

| Característica | Valores |
| --- | --- |
| Tipo | operacional, não operacional, movimentação |
| Linha da DRE | receita, dedução, custo, despesa comercial... |
| Linha do fluxo de caixa | operacional, investimento, financiamento |
| Redutora | sim ou não (devolução, estorno, desconto obtido) |

**Movimentação não é despesa:** transferência entre contas próprias, aplicação, resgate, aporte e distribuição entre sócios mexem no saldo do banco, mas ficam fora da DRE.

**Regra:** se uma mesma natureza às vezes é operacional e às vezes não, na verdade são duas naturezas.

### A carga inicial da árvore

🟡 Existe um rascunho (v0) com 11 grupos e cerca de 45 galhos no [documento do modelo v1](https://claude.ai/artifact/YXuHgVNLaMPRtpxJ8YWCPt). ⏳ Quatro pontos em que ele difere da viabilidade atual aguardam decisão do Moises:

1. Impostos sobre a receita passam de Financeiras para Deduções.
2. Custo de capital fica só no orçado, porque nunca vira pagamento.
3. Taxas de gestão entre empresas do grupo viram um par de lançamentos (despesa numa, receita na outra).
4. ITBI e registro das unidades vendidas vão para Comerciais › Custos de repasse.

## Rateio

✅ **Decidido** (7/nov/2026): um gasto que serve a vários empreendimentos ou naturezas (campanha institucional, aluguel da sede) é dividido em percentuais. Cada parte conta para o seu centro de custo.

## Tarefa: criar uma natureza nova

> ⏳ As telas ainda não existem.

1. Abra **Configurações › Naturezas**.
2. Encontre na árvore o galho onde a nova natureza vai ficar e clique em **Adicionar dentro**.
3. Dê o nome. Antes de salvar, confira na árvore se não existe outra com o mesmo sentido.
4. Confira o tipo, a linha da DRE e a do fluxo de caixa, que vêm da mãe. Mude só se for diferente.
5. Salve. A natureza já aparece para lançamento e para orçamento.

## Tarefa: lançar um gasto com rateio

1. No lançamento (nota, previsão ou orçamento), em **Classificação**, clique em **Ratear**.
2. Inclua uma linha por parte: centro de custo, natureza e percentual.
3. Confira que a soma dá 100%.
4. Salve. Cada parte aparece no relatório do seu centro de custo.
