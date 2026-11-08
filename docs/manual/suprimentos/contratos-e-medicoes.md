# Contratos e medições

[← Sumário](../README.md)

## Como é hoje na BKM

Processo atual (Moises, 6/nov/2026): o analista cria a medição no Sienge, ela vai para a aprovação de **2 gestores**, volta para o analista fazer a **liberação** (é ali que se digita a nota e os impostos) e só então vai para o financeiro. Os impostos não ficam no contrato; são digitados na liberação.

Hoje também quase tudo entra por contrato, inclusive contratos fictícios para contas de telefone, internet e aluguel, ou por pedido de compra nas compras não regulares. No ERP BKM, as contas fixas passam a ser **assinaturas recorrentes** (ver [Contas a pagar](../financeiro/contas-a-pagar.md)).

## Escopo inicial

~~✅ Decidido (Moises, 6/nov/2026): o primeiro passo é lançar medições mensais sobre contratos já criados à mão no Sienge.~~

✅ **Mudou** (Moises, 8/nov/2026): a obra fica fora da primeira etapa, e **as medições de obra ficam paradas até a fase de suprimentos**. Os demais departamentos começam pelo [pedido de pagamento](../financeiro/contas-a-pagar.md#primeira-etapa-da-implantação-o-pedido-de-pagamento). O que está abaixo vale para quando as medições voltarem.

## O que se pode e o que não se pode fazer pelo ERP BKM

O que vale para o Sienge foi conferido na documentação da API e, onde indicado, testado no contrato de teste CTP/28 em 6/nov/2026.

| Ação | Pelo ERP BKM? |
| --- | --- |
| Criar medição de um contrato que já existe | ✅ Sim (testado) |
| Criar a medição "aguardando autorização" | ✅ Sim (testado) |
| Anexar o PDF da nota na medição | ✅ Sim (testado) |
| Autorizar ou reprovar a medição | ✅ Sim (testado). Atenção: uma chamada só autoriza, e no Sienge o responsável aparece como "Sienge Api". Por isso a aprovação dos 2 gestores precisa acontecer no ERP BKM antes |
| **Liberar a medição** (gera o título) | ❌ Não. Só no Sienge, à mão |
| Completar o título gerado (tipo e número do documento, vencimento, PDF) | ✅ Sim (testado no título 8417) |
| Gravar os dados fiscais de serviço no título | ⏳ Não testado até o fim: falta o código da filial da empresa |
| Informar os impostos na medição | ❌ Não. A API não aceita |
| Medir por valor em vez de quantidade | ❌ Não pela API. O sistema converte valor em quantidade (ver abaixo) |
| Criar contrato, aditivo ou pedido de compra | ❌ Não. Só no Sienge |
| Apagar uma medição | ❌ Não |

### Valor da nota e quantidade da medição

A API do Sienge só aceita medição por quantidade, com no máximo 4 casas decimais. O sistema converte: quantidade = valor da nota ÷ preço unitário do item.

- 🟡 **Contratos novos do dia a dia:** item a **R$ 1,00 por unidade** (como o CTP/28). A quantidade é o próprio valor da nota e nunca há diferença de centavos. O Moises respondeu "ok" em 6/nov/2026.
- **Contratos normais que já existem:** se o valor não fechar no centavo (por exemplo, item de R$ 5.000,00 e nota de R$ 4.873,22 pode perder R$ 0,22), o sistema avisa antes de lançar, para ajustar na liberação.

### Saldo do contrato

Quando o saldo do contrato acaba, é preciso aditivo, que só se faz no Sienge. Vale cadastrar os contratos do dia a dia com folga de valor ou de prazo.

---

## Tarefa: lançar a medição mensal de um contrato

> ⏳ As telas ainda não existem, e o caminho até o Sienge (medição ou título avulso) ainda está em aberto; ver [Lançar nota fiscal](../financeiro/lancar-nota-fiscal.md#-em-aberto-como-a-nota-chega-ao-sienge). O roteiro abaixo vale para o caminho da medição.

1. Lance a nota em **Lançar nota fiscal** (ver [o passo a passo](../financeiro/lancar-nota-fiscal.md)). O sistema cria a medição no Sienge, aguardando autorização, com o PDF anexado.
2. **Gestores:** cada um dos 2 gestores abre a medição no ERP BKM, confere a nota na tela e aprova.
3. Com as 2 aprovações, o sistema autoriza a medição no Sienge sozinho.
4. **Analista:** recebe a tarefa de liberação com a ficha pronta (número, data, valor e impostos já lidos da nota).
5. No **Sienge**, faz a liberação da medição, digitando o mínimo que a tela exige.
6. O Sienge avisa que a liberação terminou. O sistema pega o título gerado, completa número da nota, vencimento e PDF, e confere os impostos contra a nota.
7. O título segue para o financeiro.

**Se der errado:**

| Situação | O que fazer |
| --- | --- |
| A liberação não aparece no ERP BKM | Confira no Sienge se a liberação foi concluída; o aviso do Sienge pode atrasar, e o sistema confere de tempos em tempos |
| Os impostos do título não batem com a nota | O financeiro decide antes de seguir |
