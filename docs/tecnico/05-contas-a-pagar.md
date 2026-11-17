# 5. Fluxo técnico do contas a pagar

Primeiro módulo do sistema. Escopo (Moises, 6/nov/2026): lançar as notas mensais sobre contratos já criados à mão no Sienge, inclusive os pagamentos do dia a dia.

Situação: o lado do banco próprio (documento, título, parcela, pagamento, quitação, caução, livro) está **[Construído]** (na `develop` desde 14/nov/2026) no `erp` v0 (ver [03](03-banco-de-dados.md)). O lançamento no Sienge, a leitura de PDF, as telas e a aprovação estão **[Desenhados]**.

## 5.1 Ciclo de vida no `erp` [Construído]

```
compromisso (contrato, pedido, assinatura recorrente, avulsa, guia, folha)
   └─ previsões  ── gerar_previsoes_assinatura / saldo de contrato / orçamento
documento fiscal (nota, boleto, guia) + retenções + rateio
   └─ lancar_documento ─┬─ título do fornecedor pelo líquido (bruto − retenções − caução)
                        ├─ um título por imposto retido, contra o órgão
                        ├─ entrada no extrato de caução do contrato
                        └─ consome as previsões do contrato, da mais antiga
título (rascunho) ── confirmar_titulo ──> comprometido no livro, por parcela e rateio
pagamento (saída do banco) ──> realizado em "Adiantamentos a fornecedores"
quitação (pagamento × parcela, + juros, multa, desconto) ──> realizado na natureza do título
caução ── liberar_caucao ──> título ao fornecedor ou a um terceiro (com motivo)
```

Regras de modelagem que vieram do Moises (6 e 7/nov/2026) e o código segue: título com N parcelas; pagamento parcial e adiantamento aceitos; adiantamento abatido aos poucos em vários títulos do mesmo fornecedor; juros, multa e desconto só na quitação; retenções e caução na nota (caução padrão do contrato, alterável); lote bancário é só agrupamento de envio.

## 5.2 Caminho até o Sienge [Desenhado]

Desenho aceito como direção (6/nov/2026): **previsões e contratos do dia a dia ficam no nosso sistema; título no Sienge só nasce quando a nota chega, completo e conferido.** A escolha entre os dois caminhos abaixo para as notas de contrato ainda está aberta [A decidir]:

| | Por medição do contrato | Por título avulso |
| --- | --- | --- |
| Chamadas | `POST` medição (desautorizada) + anexo → aprovação no nosso sistema → `PATCH authorize` → **liberação manual no Sienge** → aviso `CLEARING_*` → `GET clearing` traz o título → `PATCH` documento, vencimento, forma de pagamento, anexo | `POST /bills` com impostos, apropriações e parcelas → forma de pagamento → anexo |
| Impostos retidos | digitados na liberação; depois conferidos com `GET /bills/{id}/taxes` contra a nota | entram na criação |
| Passo manual | a liberação | nenhum (até a autorização de pagamento) |
| Saldo do contrato no Sienge | controlado | não controlado (passa a ser nosso) |
| Risco | analista redigita parte da nota | título errado só se corrige apagando à mão no Sienge |

**[Construído, 17/nov/2026] Título avulso a partir da nota aprovada:** a nota lançada (`lancar_documento`) gera o título; quem lança informa a forma de pagamento de cada parcela (`parcela_pagamentos`); aprovado na alçada, o título entra na fila `sienge_envios` e o programa `servicos/sienge-escrita` faz o `POST /bills` e grava a forma de pagamento de cada parcela. Fora desta versão: nota com retenção ou caução, imposto, caução, adiantamento, societário, anexo do PDF e o caminho por medição. Detalhe em [04](04-integracao-sienge.md), 4.7.

Processo de aprovação da BKM hoje (Moises, 6/nov/2026): medição → aprovação de 2 gestores → analista faz a liberação (é ali que entram a nota e os impostos) → financeiro. No desenho, os 2 gestores aprovam no nosso sistema e a autorização no Sienge é consequência.

## 5.2.1 Aprovação do contrato recorrente e da previsão [Construído, 17/nov/2026]

Decisões do Moises (8, 14 e 17/nov/2026). Só a previsão aprovada vai ao Sienge, como título PRV (4.7.1 do doc 04).

- **Contrato e assinatura** (`compromissos` dos tipos contrato e assinatura): aprovam o gestor do centro (vaga AREA) e alguém da AF ou da AO (vaga FIN), em `compromisso_aprovacoes`, por versão. Mudar empresa, tipo, credor, datas, valores, periodicidade, vencimento, caução ou o rateio (salvo só a natureza) abre uma versão nova, que pede aprovação de novo. Quem criou ou alterou por último não aprova; ninguém ocupa as duas vagas; o master aprova tudo de uma vez. `decidir_compromisso(contrato, aprovar, justificativa)`.
- **Previsão do contrato** nasce aprovada pelo contrato aprovado (`previsao_aprovada` segue `compromisso_aprovado`).
- **Previsão lançada à mão**: passa pela alçada do título (`previsao_alcadas`, `previsao_aprovacoes`), com as faixas do centro e da divisão, paralelo ou em sequência; sem faixa, vai ao master com evento. Quem lançou não aprova; recusar exige justificativa e cancela a previsão. `decidir_previsao(previsão, aprovar, justificativa, centro, divisão)`.
- **Acumulado do mês**: a previsão aprovada conta no mês dela; a nota que a consome conta só o que passa dela (o consumo vem antes de fixar a alçada do título).
- **Origem protegida**: previsão de origem `assinatura` ou `saldo_previsao` só nasce pela rotina do banco (`tg_previsao_origem`); só a de origem `assinatura` segue a aprovação do contrato. Assim, previsão lançada à mão com o id de um contrato aprovado não nasce aprovada.
- **Nota menor que a previsão: saldo ou saving** (Moises, 17/nov/2026): `encerrar_previsao(previsão, destino, data)` dá baixa na previsão parcialmente consumida (situação `encerrada`, o livro estorna o saldo). Com `saldo`, cria outra previsão com o que sobrou, na data informada (hoje ou depois), com origem `saldo_previsao`, que segue a aprovação da original e não passa por alçada própria. Com `saving`, não cria nada. `v_previsoes_a_decidir` lista as que têm consumo e saldo.
- **Envio ao Sienge**: a previsão aprovada aberta vai como título PRV; a que deixa de ser aberta vira linha a apagar à mão (ver `04-integracao-sienge.md`, 4.7.1).

## 5.3 "Lançar nota fiscal" [Desenhado]

Experiência pedida pelo Moises (6/nov/2026), com o que cada passo exige tecnicamente:

1. Upload do PDF (e do XML, opcional, que é exato). Leitura por IA devolve emitente, tomador, número, data, valores, retenções e descrição. Serviço de leitura não escolhido.
2. Achar o contrato pelo par **CNPJ do emitente + CNPJ do tomador** (o tomador diz a empresa ou SPE). Se ficar ambíguo, o usuário escolhe entre os contratos do perfil dele.
3. Formulário preenchido: valores e retenções da nota, forma de pagamento padrão do fornecedor (o Sienge já traz o Pix do credor; boleto exige código de barras por cobrança).
4. Travas: nota repetida (já no `erp`), valor acima do saldo do contrato (aditivo só no Sienge), tomador que não é empresa da BKM, divergência de retenção com alerta para o financeiro.
5. Confirmação gera o documento no `erp` e o pedido de envio ao Sienge.

Recomendações aceitas pelo Moises em 6/nov/2026: contratos novos do dia a dia com item a R$ 1,00 por unidade (o CTP/28 já é assim).

## 5.4 Depois da autorização [Desenhado]

Seleção para pagamento, remessa, pagamento e baixa continuam no Sienge e no banco. O sistema só acompanha pelos avisos (autorização, envio ao banco, baixa, estorno, movimento bancário) e avisa quem lançou a nota. Como a BKM paga hoje (remessa, integração bancária ou internet banking) ainda não foi respondido [A decidir].
