# Reclassificar lançamentos e fechar o mês

[← Sumário](../README.md)

## Fechamento do mês

✅ **Decidido** (Moises, 7/nov/2026): o sistema terá fechamento de mês, um conceito que a BKM ainda não usa. Fechar um mês trava o passado: mudar algo dele exige alçada mais alta, porque o número já pode ter sido entregue ao banco, à Caixa, a um sócio ou ao contador.

- O fechamento é por empresa.
- 🟡 Só a diretoria fecha e reabre, e sempre em ordem (não se fecha março com fevereiro aberto). Assim está no banco de dados de 7/nov/2026; falta confirmação explícita.
- O trimestre é o **do calendário** (jan–mar, abr–jun...) e fecha quando o último mês dele é fechado ✅ (Moises, 7/nov/2026).
- ⏳ Falta decidir o que fazer com um pagamento atrasado de uma competência já fechada: travar, ou lançar no primeiro mês aberto.

## Reclassificação

Reclassificar é mudar a natureza de lançamentos já feitos: porque foram lançados errado, ou porque a árvore mudou e uma natureza vai deixar de existir.

✅ **Decidido** (Moises, 7/nov/2026):

- Existe uma **página de reclassificação**: escolhe-se a natureza de origem e a de destino, e pode ser a natureza inteira ou só alguns lançamentos filtrados (por obra, por período).
- **Antes de confirmar**, a página mostra o impacto: quantos lançamentos, quanto dinheiro, quais meses e empreendimentos, e se a linha da DRE ou o tipo mudam.
- **O orçado vai junto** com o realizado, senão o orçado × realizado das duas naturezas quebra.
- Cada lançamento **guarda a natureza antiga**, quem moveu e quando.
- Quando a natureza fica vazia, pode ser apagada de verdade.
- **Toda reclassificação precisa de aval** (Moises: "mesmo a reclassificação simples precisa ser feita com aval da diretoria").

### Alçadas da reclassificação

✅ **Decidido** (Moises, 7/nov/2026). Três regras são calculadas, e **vale a mais alta**:

| Regra | O que olha |
| --- | --- |
| Idade | Mês aberto; mês fechado com o trimestre aberto; trimestre fechado |
| Valor | Quanto o pedido move |
| Acumulado | Quanto a mesma pessoa já moveu no mês, somando todas as naturezas, sempre em valor absoluto |

O acumulado fecha a brecha de quebrar uma mudança grande em várias pequenas. Mover R$ 100 de A para B e depois voltar conta R$ 200, não zero. A mudança que faria a soma passar do limite já sobe para a alçada de cima.

⏳ As faixas de valor e quem aprova em cada uma ficam para a sessão de aprovações. Esboço de 7/nov/2026, a ajustar: mês aberto, gestor da área; mês fechado com trimestre aberto, diretoria; trimestre fechado, diretoria e contador. O padrão hoje no banco de dados é a diretoria em qualquer valor, e diretoria e contador no trimestre fechado, até o administrador configurar as faixas.

🟡 Proposta ainda sem resposta: corrigir a natureza de **um único lançamento num mês aberto** ser edição comum, sem a diretoria, para ela não virar gargalo das correções do dia a dia. O Moises respondeu com as alçadas, que podem cobrir esse caso com a faixa do mês aberto.

### Outras regras

- Quem pediu não aprova o próprio pedido.
- Recusar exige justificativa e encerra o pedido.
- Os lançamentos de um mesmo título vão juntos, para ele não ficar parte numa natureza e parte noutra.
- Aprovado, os próximos pagamentos daquele título já caem na natureza nova.

## Tarefa: reclassificar lançamentos

> ⏳ As telas ainda não existem.

1. Abra **Financeiro › Reclassificação** e clique em **Nova reclassificação**.
2. Escolha a natureza de origem.
3. Escolha se é **a natureza inteira** ou **só alguns lançamentos**. No segundo caso, filtre por empreendimento, período ou outro campo.
4. Escolha a natureza de destino.
5. Se é a natureza inteira e ela vai deixar de existir, marque **Apagar a origem depois**.
6. Escreva o motivo.
7. Clique em **Ver impacto** e confira: lançamentos, valor, meses, empreendimentos e se a DRE muda.
8. Envie. O sistema calcula a alçada (idade, valor e seu acumulado no mês) e manda para quem aprova.
9. Aprovado, os lançamentos mudam de natureza. O histórico guarda a natureza antiga.

## Tarefa: fechar um mês

1. Abra **Financeiro › Fechamento**.
2. Escolha a empresa e o mês.
3. Confira as pendências do mês. ⏳ Quais pendências impedem o fechamento ainda será definido.
4. Clique em **Fechar mês**.
