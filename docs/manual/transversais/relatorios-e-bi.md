# Relatórios e BI

[← Sumário](../README.md)

## Relatórios dentro do sistema

✅ **Decidido** (Moises, 8/nov/2026):

- Os **gráficos e as análises ficam no próprio sistema**. O Power BI deixa de ser usado.
- **Quem vê o quê é liberado no sistema, pessoa a pessoa.** Também dá para criar **grupos**: quem entra num grupo passa a ver o que o grupo vê.
- **O acesso combina Área e Centro de custo** (Moises, 8/nov/2026): a pessoa vê o que está ao mesmo tempo nas áreas e nos centros liberados para ela, **com herança para baixo** nas duas árvores (quem tem "São Paulo" vê todas as obras de São Paulo; quem tem "Comercial" vê Marketing e Vendas). A fase não entra no acesso.
- A **folha PJ** aparece só somada por centro de custo e mês.
- Datas e horas são gravadas e mostradas no **horário de São Paulo**. (Um pagamento às 22h do dia 31 fica no dia 31, não no mês seguinte.)
- Todas as datas de um lançamento (competência, emissão, vencimento, pagamento) podem ser usadas nos relatórios; a competência é a data padrão. Também aparecem os dias de atraso (pagamento menos vencimento) e o prazo de pagamento (pagamento menos emissão).

✅ O Power BI não fica nem como ponte (Moises, 8/nov/2026).

🟡 Proposta ainda não decidida: a natureza PJ fica fora de qualquer combinação, com acesso próprio.

## Controle de prazos do pagamento (SLA)

✅ **Decidido** (Moises, 8/nov/2026): o sistema mede **quantos dias antes do vencimento a nota foi postada** e **quanto tempo levou cada etapa** até a nota ser paga.

- O controle só vale para o que passar pelo pedido de pagamento, a partir da implantação. O Sienge não tem esse histórico, e da última etapa ele informa só o dia do pagamento, sem a hora.
- ⏳ A definir: a antecedência mínima da postagem e a meta de cada etapa (proposta: em dias úteis, definidas pelo administrador); e se o relógio para quando a nota volta para correção.

## Um livro único para todos os números

✅ **Decidido** (7/nov/2026). Cada etapa do sistema (orçamento, previsão, título, pagamento, caução) escreve linhas num **livro de lançamentos único**, sempre com as mesmas classificações: empresa, centro de custo, natureza, fase, área, competência, data de caixa e estágio (orçado, previsto, comprometido, realizado).

É desse livro que saem os relatórios, o BI, o fluxo de caixa e as respostas dos agentes de IA. Perguntas como estas viram um filtro, sem montar planilha:

- "Quanto gastei de marketing na empresa inteira em 2027?"
- "Viabilidade × orçado × realizado do Vila Maria."
- "Tudo o que a área de Marketing gastou, inclusive fora da natureza marketing."
- "Marketing por praça, por faixa MCMV, por mês."

✅ O livro só cresce: nenhuma linha é apagada ou editada. Desfazer é lançar uma linha de sinal contrário. A única exceção é a natureza, que muda pela [reclassificação](../financeiro/reclassificacao-e-fechamento.md) aprovada e guarda a anterior.

## Atributos dos empreendimentos nos relatórios

✅ Cidade, estado, regional, praça, linha de produto, faixa MCMV e outros atributos ficam no cadastro do empreendimento, e o relatório os mostra como colunas de cada lançamento (Moises aceitou em 7/nov/2026). ~~O relatório usa o valor que valia na data do lançamento.~~ ✅ **Mudou** (Moises, 8/nov/2026): a visão padrão é a de hoje (por exemplo, a regional atual do empreendimento), e há também uma foto de como era em cada mês, para comparar as duas.

## Tarefa: montar um relatório por natureza

> ⏳ As telas ainda não existem.

1. Abra **Relatórios › Lançamentos**.
2. Escolha o período e o estágio (orçado, previsto, comprometido ou realizado, ou vários lado a lado).
3. Filtre pela natureza (um galho inteiro, como Comerciais › Marketing) e, se quiser, por empresa, empreendimento, praça ou outro atributo.
4. Escolha como agrupar: por empreendimento, por mês, por praça...
5. Clique num número para ver os lançamentos que o compõem.
