# Contas a pagar: do compromisso ao pagamento

[← Sumário](../README.md)

## O caminho de um gasto

✅ **Decidido** (7/nov/2026). Todo gasto passa por até cinco etapas, e cada uma tem o seu lugar no sistema. **A dívida só existe a partir do título.** Antes disso, o que há é expectativa.

```
Compromisso  →  Previsão  →  Documento  →  Título (parcelas)  →  Pagamento e quitação
(o acordo)      (o esperado)  (a nota)      (a dívida)            (o dinheiro que saiu)
```

| Etapa | O que é | Exemplo |
| --- | --- | --- |
| **Compromisso** | O acordo que vai gerar gasto | Contrato com a empreiteira; assinatura da internet; pedido de compra |
| **Previsão** | O gasto esperado, que ainda não é dívida | "Internet de março, cerca de R$ 400" |
| **Documento** | A nota, o boleto ou a guia que chegou | NFS-e 112 da empreiteira |
| **Título** | A dívida real, com uma ou mais parcelas | Título de R$ 9.000 em 3 parcelas |
| **Pagamento** | O dinheiro que saiu do banco | Pix de R$ 3.000 em 10/03 |

### Tipos de compromisso

✅ As origens de gasto são poucas: **contrato**, **pedido de compra**, **assinatura recorrente**, **despesa avulsa**, **guia de imposto** e **folha**. O que é variado (marketing, limpeza de terreno, vigilância, material de escritório...) é a **natureza** do gasto, que é classificação, não um tipo novo de cadastro. Ver [Classificação](classificacao.md).

✅ A **assinatura recorrente** substitui o contrato fictício de hoje: ela tem periodicidade e valor estimado por período, e gera sozinha uma previsão para cada vencimento.

### Previsão não é título

✅ **Decidido** (6 e 7/nov/2026): as previsões ficam **só no ERP BKM** e não são lançadas no Sienge. Motivo, comprovado em teste no Sienge em 6/nov/2026: um título criado pela API não pode ter tipo, número nem valor alterados depois, então uma previsão no Sienge nunca vira título real e teria de ser apagada à mão todo mês.

Quando a nota chega e o título nasce, ele **consome** a previsão correspondente, e a diferença entre o previsto e o realizado fica registrada. Uma previsão não se edita: se mudou, cancela-se e cria-se outra.

## O que se pode fazer

| Você pode | Situação |
| --- | --- |
| Lançar um título com muitas parcelas, inclusive de longo prazo (ex.: terreno em 36 vezes) | ✅ |
| Pagar uma parcela inteira com uma operação (o caso comum) | ✅ |
| Pagar só parte de uma parcela e o resto depois | ✅ (Moises, 7/nov/2026) |
| Adiantar dinheiro a um fornecedor, ligado ou não a um título, e abater aos poucos em várias parcelas e títulos | ✅ (Moises, 7/nov/2026) |
| Registrar juros, multa e desconto na hora do pagamento | ✅ (Moises, 7/nov/2026) |
| Lançar a nota com impostos retidos e caução | ✅ (Moises, 7/nov/2026) |
| Mandar vários pagamentos juntos num lote ao banco | ✅ O lote é só um agrupamento de envio; cada operação continua pagando uma parcela |

## O que não se pode fazer

| Não dá | Por quê |
| --- | --- |
| Lançar a mesma nota duas vezes (mesmo emitente, tipo, número e série) | Trava do ERP BKM. O Sienge da BKM aceita número repetido, então a trava é nossa (teste de 6/nov/2026) |
| Editar uma nota ou um título depois de confirmado | O título só muda de situação pelas quitações. Corrigir é cancelar e lançar de novo |
| Quitar mais do que o saldo da parcela ou do que o saldo do pagamento | Trava do banco de dados |
| Usar o adiantamento de um fornecedor para quitar título de outro, ou de outra empresa | A quitação só vale para a mesma empresa e a mesma pessoa |
| Lançar juros ou multa na nota | Eles só se sabem na hora de pagar, por isso ficam na quitação |
| Autorizar o pagamento ou dar ciência no Sienge pelo ERP BKM | A API do Sienge não tem esses comandos. Continuam à mão no Sienge |
| Corrigir empresa, fornecedor, emissão ou número de parcelas de um título já enviado ao Sienge | A API não altera esses campos. Precisa apagar no Sienge e lançar de novo |

## Como juros, multa, desconto e adiantamento aparecem nos números

✅ Todo pagamento entra primeiro como **adiantamento ao fornecedor**. Cada quitação tira o valor de lá e o põe na natureza do título. Na prática:

- No pagamento comum, isso acontece no mesmo dia e você nem percebe.
- No adiantamento, o valor fica parado em "Adiantamentos" até ser abatido.
- Juros e multa vão para uma natureza própria de juros e multas pagos; o desconto obtido, para a de descontos.

Assim, o realizado do sistema sempre bate com o dinheiro que saiu do banco.

---

## Tarefa: cadastrar uma assinatura recorrente (telefone, internet, aluguel...)

> ⏳ As telas ainda não existem.

**Para que serve:** ter as contas fixas no fluxo de caixa sem criar contrato fictício.

**Passo a passo:**

1. Abra **Contas a pagar › Compromissos** e clique em **Novo compromisso**.
2. Escolha o tipo **Assinatura recorrente**.
3. Escolha o fornecedor (ver [Pessoas](../cadastros/pessoas.md)) e a empresa que paga.
4. Informe a periodicidade (mensal, por exemplo), o dia de vencimento e o valor estimado por período.
5. Em **Classificação**, escolha o centro de custo e a natureza (por exemplo, Sede e Gerais › Administrativo › Internet). Se for dividido, use **Ratear**.
6. Informe até quando gerar as previsões.
7. Salve. O sistema cria uma previsão para cada vencimento, sem duplicar.

**E depois?** Todo mês, quando a conta chega, você a lança como nota (ver [Lançar nota fiscal](lancar-nota-fiscal.md)) e ela consome a previsão do mês.

## Tarefa: pagar uma parcela

> ⏳ Ainda a definir se o pagamento será registrado no ERP BKM ou só lido do Sienge e do banco (módulo de Bancos). O roteiro abaixo vale para o registro no ERP BKM.

1. Abra **Contas a pagar › Parcelas a pagar** e filtre pelo vencimento.
2. Abra a parcela e clique em **Pagar**.
3. Escolha a conta bancária e a data do pagamento.
4. Se pagou atrasado, informe juros e multa; se teve desconto, informe o desconto.
5. Confirme. A parcela fica quitada.

## Adiantamento sem nota: prazo e travas

- ✅ Há um **prazo para a nota chegar**, de **30 dias** por padrão, que o master ou um administrador pode mudar (Moises, 7/nov/2026).
- 🟡 Quando o prazo vence, o sistema avisa o financeiro e o gestor do contrato. (Proposta que o Moises não contestou; falta confirmação explícita.)
- 🟡 Enquanto houver um adiantamento sem nota, o fornecedor não recebe outro. (Idem.)
- O adiantamento sem nota passa pela mesma aprovação do título, mais o gestor do contrato (ver [Aprovações](../transversais/aprovacoes.md#os-cinco-momentos-de-aprovação)).

## Tarefa: registrar um adiantamento e abater aos poucos

1. Abra **Contas a pagar › Pagamentos** e clique em **Novo pagamento**.
2. Escolha o fornecedor, a empresa, a conta, a data e o valor. Se for ligado a um contrato, escolha o contrato.
3. Salve sem quitar nada. O valor aparece como saldo de adiantamento do fornecedor.
4. Quando a nota seguinte chegar e o título for lançado, abra a parcela e clique em **Abater adiantamento**.
5. Informe quanto do adiantamento quita esta parcela (por exemplo, 10% de cada medição).
6. Confirme. O saldo do adiantamento diminui; o resto continua disponível para as próximas.

**O que o sistema confere:** mesmo fornecedor e mesma empresa; a quitação não passa do saldo do adiantamento nem do saldo da parcela.

## ⏳ Em aberto

- O que fazer com um pagamento atrasado de uma competência que já foi fechada: travar, ou lançar no primeiro mês aberto.
- Quem aprova o pagamento e com que alçadas (sessão de [aprovações](../transversais/aprovacoes.md)).
- Estorno de pagamento, remessa e conciliação (módulo de Bancos).
