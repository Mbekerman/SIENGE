# Caso completo: uma nota de R$ 10.000 do começo ao fim

[← Sumário](README.md)

Roteiro para o primeiro vídeo. Mostra o caminho inteiro de um gasto, com os números em cada etapa. 🟡 O trecho entre a confirmação da nota e o título no Sienge depende da decisão em aberto sobre medição ou título avulso; aqui segue o caminho da medição.

**Personagens:** Ana (analista), Bruno e Carla (gestores), Diego (financeiro).
**Cenário:** a empreiteira Alfa tem contrato de R$ 120.000 com a SPE Vila Maria, com caução de 5%. A BKM adiantou R$ 5.000 à Alfa no mês passado, para abater em 10% de cada nota.

## 1. O compromisso e a previsão

O contrato já está cadastrado. Ele gerou previsões mensais de R$ 10.000. No fluxo de caixa de março aparece: **previsto R$ 10.000**.

## 2. A nota chega

A Alfa manda a NFS-e 112 de R$ 10.000, com ISS de 5% retido.

Ana clica em **Lançar nota fiscal**, sobe o PDF e o sistema reconhece a Alfa e a SPE Vila Maria, e acha o contrato. O formulário vem preenchido:

| Item | Valor |
| --- | --- |
| Valor da nota | R$ 10.000,00 |
| ISS retido (5%) | − R$ 500,00 |
| Caução (5%) | − R$ 500,00 |
| Adiantamento abatido (10%) | − R$ 1.000,00 |
| **A pagar à Alfa** | **R$ 8.000,00** |

Ana confere e confirma.

## 3. O que nasceu

- Título da Alfa: R$ 9.000 (líquido de ISS e caução), dos quais R$ 1.000 já quitados pelo adiantamento. Saldo a pagar: R$ 8.000.
- Título do ISS para a prefeitura: R$ 500.
- Extrato de caução do contrato: + R$ 500.
- A previsão de março foi consumida. Fluxo de caixa: **previsto R$ 0, comprometido R$ 8.500** (mais R$ 500 de caução, que fica comprometida sem data até ser liberada).
- Saldo de adiantamento da Alfa: R$ 4.000.

## 4. Aprovação e Sienge

Bruno e Carla aprovam no ERP BKM, com o PDF na tela. O sistema autoriza a medição no Sienge. Ana recebe a tarefa e faz a liberação no Sienge com a ficha pronta. O sistema completa o título lá (número da nota, vencimento, PDF) e confere os impostos.

## 5. Pagamento

Diego autoriza a parcela no Sienge e paga R$ 8.000 por Pix no vencimento. Fluxo de caixa: **realizado R$ 8.000**. O ISS é pago na guia, no prazo dele.

## 6. No fim da obra

O gestor libera os R$ 6.000 de caução acumulados nas 12 notas, depois das avaliações. Nasce um título de R$ 6.000 para a Alfa.

## O que mostrar no vídeo

- O formulário que vem preenchido e o aviso de nota repetida, se alguém tentar subir a mesma nota de novo.
- O fluxo de caixa mudando de previsto para comprometido e para realizado.
- O extrato de caução e o saldo do adiantamento.
- O passo que ainda é feito à mão no Sienge (a liberação).
