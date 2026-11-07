# 7. Pendências, riscos e lixo de teste

## Perguntas abertas que afetam o código

| Pergunta | Afeta | Desde |
| --- | --- | --- |
| Qual pacote de API a BKM tem? | Se a cópia diária cabe na cota; frequência da sincronização | 6/nov |
| Código da filial da empresa 2 no Sienge | `tax-information` (dados fiscais de serviço) | 6/nov |
| Existe base de testes do Sienge? | Onde rodar testes de escrita (hoje é produção) | 6/nov |
| Notas de contrato por medição ou por título avulso? | Fluxo de envio ao Sienge ([05](05-contas-a-pagar.md)) | 6/nov |
| Suporte do Sienge: liberação automática de medição, API de liberação, de ciência e de autorização de pagamento? | Quantos passos manuais sobram | 6/nov |
| Gravar `tax-information` muda o valor retido do título? | Se impostos podem ser completados depois da liberação | 6/nov |
| Como a BKM paga hoje (remessa, integração bancária, internet banking)? | O que o sistema enxerga entre autorizado e pago | 6/nov |
| Qual é o CRM e como ligar a venda dele ao contrato de venda do Sienge (`externalId`?) | Esquemas `crm` e a ponte de vendas | 6/nov |
| Pagamento de competência já fechada: travar ou lançar no primeiro mês aberto? | Regra no `nucleo` | 7/nov |
| As 4 divergências da árvore em relação à viabilidade (impostos em Deduções, custo de capital só orçado, taxas de gestão intercompany, ITBI e registro de vendas em Comerciais) | Carga inicial (o v0 usa a proposta) | 7/nov |
| Onde fica o fluxo de aprovação do contas a pagar (esquema `pagar` do plano ou `nucleo`) | Organização dos esquemas | 7/nov |
| Servidor do adaptador (funções do Supabase, Cloud Run...) e serviço de leitura de PDF | Infraestrutura | 7/nov |
| `nucleo.usuarios` e `app.membros` do BKM Terrenos: um cadastro só? | Login e papéis compartilhados | 7/nov |
| A Nexxera ou o banco exigem assinatura da remessa (certificado, dupla assinatura)? O Moises não sabe; perguntar à Nexxera | Onde fica o certificado (Vault) e se a remessa precisa de uma segunda aprovação humana | 7/nov |

## Riscos técnicos

| Risco | O que fazer |
| --- | --- |
| Falhas de segurança do código | Lista própria em [08-seguranca.md](08-seguranca.md) |
| Cota diária pequena (pacote desconhecido); CRM, Terrenos e pagar dividem a mesma cota | Saber o pacote; medir na primeira carga; usar massa para cargas grandes |
| Aviso perdido (5 tentativas em ~10 h) e eventos inexistentes | Varredura por data de alteração e conferência periódica desde o primeiro dia |
| Título em dobro (`POST /bills` não recusa repetição; NFSE aceita número repetido) | Trava no `nucleo` + procura no espelho e na fila antes de criar |
| Título errado criado pela API só se corrige no Sienge, à mão | Conferir empresa, credor, parcelas, emissão e impostos antes de enviar |
| Lançamento pelos dois lados (financeiro lançando direto no Sienge) | Regra de exceção combinada; o espelho mostra títulos que nasceram fora |
| Webhook sem assinatura documentada | Nunca confiar no conteúdo; sempre reler pela API |
| API de terceiro muda sem aviso | `scripts/atualizar.sh` do `sienge-api-docs` todo mês e revisar o diff |
| Testes de escrita na produção do Sienge | Valores de R$ 1,00, observação "TESTE API Claude", contrato CTP/28, e registro abaixo |

## Lixo de teste no Sienge (produção)

Criado em 6/nov/2026, pode ser apagado à mão no Sienge (a API não apaga):

| Registro | Detalhe |
| --- | --- |
| Medição 2 do CTP/28 | R$ 1,50, "TESTE API Claude", autorizada e liberada |
| Título 8417 | Gerado pela liberação da medição 2; ficou NFSE 112, vencimento 10/12/2026 |
| Título 8422 | PRV, R$ 1,00, vencimento 10/03/2027, criado pela API, "TESTE API Claude" |

A medição 1 do CTP/28 (R$ 8,33) não é de teste nosso e não foi tocada.
