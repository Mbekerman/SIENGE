# Visão geral: o que é o ERP BKM

[← Sumário](README.md)

## O problema que o ERP BKM resolve

A BKM usa o Sienge em todas as áreas: engenharia, financeiro, comercial, contratos, contas a pagar e a receber, contábil, fiscal e planejamento. Ele funciona, mas é engessado, e a equipe acaba criando "gambiarras" para fazer o Sienge aceitar o que a empresa precisa. As três principais:

| Gambiarra de hoje | Por que existe | Como fica no ERP BKM |
| --- | --- | --- |
| Contrato fictício para conta de telefone, internet, aluguel | O Sienge só controla gasto recorrente por contrato | **Assinatura recorrente**, um tipo próprio de compromisso |
| Título de previsão (tipo PRV) para pôr conta de consumo no fluxo de caixa | O Sienge não tem previsão separada de dívida | **Previsão**, que não é dívida e some sozinha quando a nota chega |
| Área administrativa cadastrada como obra | O Sienge só faz orçamento de obra | **Centro de custo do tipo área**, com orçamento em dinheiro |

## A ideia: o Sienge vira o motor, o ERP BKM vira a casa

✅ **Decidido** (Moises, 6/nov/2026). O Sienge continua processando o que é mais complexo e sensível: financeiro, fiscal, contábil, banco e segurança. Todo o resto, as telas que você usa, a aprovação, o orçamento, os relatórios, mora num banco de dados próprio da BKM.

O objetivo de longo prazo é que trocar o Sienge por outro ERP seja "desplugar de um e plugar no outro". Para ser honesto sobre isso: os sistemas em volta ficam trocáveis; o financeiro em si ainda dá trabalho para migrar (histórico, plano de contas, parâmetros fiscais, treinamento).

## O que você faz no ERP BKM e o que continua no Sienge

Hoje, a API do Sienge (o canal por onde os sistemas conversam) não deixa fazer tudo. Isso define o que ainda precisa ser feito à mão no Sienge.

| Tarefa | Onde | Situação |
| --- | --- | --- |
| Subir a nota fiscal, conferir e aprovar | ERP BKM | Planejado |
| Criar a medição de um contrato que já existe | ERP BKM, que envia ao Sienge | Testado em 6/nov/2026 |
| Autorizar a medição | ERP BKM, que envia ao Sienge | Testado em 6/nov/2026 |
| **Liberar a medição** (gera o título) | **Sienge, à mão** | Não tem API |
| Completar o título depois (número da nota, vencimento, PDF) | ERP BKM, que envia ao Sienge | Testado em 6/nov/2026 |
| **Dar ciência e autorizar o pagamento do título** | **Sienge, à mão** | Não tem API |
| Criar contrato, aditivo e pedido de compra | **Sienge, à mão** | Não tem API |
| Pagamento, baixa, remessa ao banco | Sienge e banco | O ERP BKM só acompanha |

## Ordem de construção

🟡 **Proposta** discutida com o Moises em 6/nov/2026:

1. Banco próprio copiando o Sienge e o CRM (só leitura).
2. Contas a pagar e medições.
3. Suprimentos, orçamento e obra.
4. Contas a receber e banco.
5. Fiscal e contábil, por último, rodando em paralelo antes de desligar qualquer coisa.

## Ligação com o BKM Terrenos

O ERP BKM vai se juntar ao BKM Terrenos, no visual e no banco de dados. O terreno comprado no BKM Terrenos vira um empreendimento aqui, e o estudo de viabilidade de lá é a primeira versão do orçamento do empreendimento (ver [Orçamento](financeiro/orcamento-e-fluxo-de-caixa.md)).
