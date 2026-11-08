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

## Primeira etapa da implantação: o pedido de pagamento

✅ **Decidido** (Moises, 8/nov/2026):

- **A obra fica fora** desta etapa. Os demais departamentos usam o ERP BKM do compromisso até a chegada da nota.
- Quando a nota chega, quem a recebe cria no ERP BKM o **pedido de pagamento**, subindo a nota e o título. O ERP BKM guarda tudo.
- O ERP BKM **cria o título no Sienge** pela API, e o pagamento segue no Sienge até o fim.
- Depois, o ERP BKM **lê no Sienge o que aconteceu** com o título e guarda.
- **Conferência:** uma rotina do sistema confere se todos os títulos do ERP BKM chegaram mesmo ao Sienge. No começo, uma pessoa também confere à mão.
- **Relatório para cada pessoa:** cada um recebe a lista dos títulos que cadastrou e que foram ao Sienge, para conferir se foi tudo.

> ⚠️ **Passo manual no Sienge:** a autorização, o pagamento e o lote (remessa pelo Nexxera) continuam feitos no Sienge. Ver [O que ainda é feito à mão no Sienge](../transversais/passos-manuais-no-sienge.md).

✅ Também confirmado (Moises, 8/nov/2026):

- **O título vai ao Sienge pela API, nunca redigitado**, já com a nota anexada, os impostos e o PIX ou o boleto. O ERP BKM guarda o número de cada título no Sienge.
- **Pré-requisito:** enquanto os títulos passarem pelo Sienge, o pedido de pagamento só se conclui no ERP BKM com **todas as informações de pagamento** (PIX, conta ou boleto) preenchidas e aprovadas. Só então o título é criado no Sienge, já completo.
- **A conferência vai nos dois sentidos:** aponta o título do ERP BKM que não chegou ao Sienge, o título criado direto no Sienge fora do fluxo e o título mudado no Sienge depois de criado (valor, conta, PIX).
- O relatório para cada pessoa fica, mas pode sair quando a conferência à mão confirmar que o sistema não erra.

Teste de 8/nov/2026 (título 8422): o título criado pela API aceitou o PIX depois de criado, e a API aceita os impostos já na criação.

⏳ Em discussão: tirar no Sienge a permissão de criar e alterar títulos e dados bancários dos departamentos que entrarem no ERP BKM, para fechar a brecha de pagar fora do fluxo. O custo é que um lançamento urgente passa a depender do ERP BKM.

### Tarefa: criar um pedido de pagamento

> ⏳ As telas ainda não existem. Os nomes de botões são provisórios.

**Para que serve:** levar uma nota que chegou até o pagamento no Sienge, passando pelas aprovações.

**Quem faz:** quem recebeu a nota, em qualquer departamento fora a obra.

**Passo a passo:**

1. Abra **Contas a pagar › Pedidos de pagamento** e clique em **Novo pedido**.
2. Suba o arquivo da nota e o boleto ou os dados de pagamento. **Sem os dados de pagamento completos, o pedido não se conclui.**
3. Confira o fornecedor, a empresa que paga, o valor, as parcelas e os vencimentos.
4. Escolha o compromisso ou a previsão que a nota consome, se houver.
5. Classifique (centro de custo e natureza; use **Ratear** se for dividido).
6. Envie. O pedido vai para as aprovações.

**O que o sistema confere:** nota repetida (mesmo emitente, tipo, número e série) é recusada; o título só vai ao Sienge completo.

**E depois?** Aprovado, o título nasce no Sienge. Você recebe na lista do dia o que foi ao Sienge e confere. O pagamento é feito no Sienge.

**Se der errado:** se o título não aparecer no Sienge, ele entra na conferência do sistema; avise o financeiro.

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
- ✅ Pagar com juros ou multa exige uma aprovação a mais, de uma pessoa definida pelo administrador (padrão: a AD). Ver [Aprovações](../transversais/aprovacoes.md#pagamento-com-multa-ou-juros).

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
- ✅ Quando o prazo vence, o sistema avisa o financeiro e o gestor do contrato (Moises, 7/nov/2026).
- ✅ Enquanto houver um adiantamento sem nota, o fornecedor **só recebe outro adiantamento com a aprovação da AD** (Moises, 7/nov/2026; antes era "nenhum").
- ✅ **Nenhum título desse fornecedor é pago sem deduzir o adiantamento em aberto**, mesmo que o título seja de outro centro de custo, salvo com a aprovação da AD (Moises, 7/nov/2026).
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
