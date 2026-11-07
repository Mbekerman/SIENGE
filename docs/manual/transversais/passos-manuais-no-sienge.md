# ⚠️ O que ainda é feito à mão no Sienge

[← Sumário](../README.md)

Estes passos **não** podem ser feitos pelo ERP BKM, porque a API do Sienge não tem o comando. Quem executa precisa entrar no Sienge. Cada página do manual repete o aviso no ponto em que o passo aparece.

| Passo manual no Sienge | Onde aparece no processo | Como o ERP BKM ajuda | Fonte |
| --- | --- | --- | --- |
| **Liberar a medição** (gera o título) | Depois da aprovação dos 2 gestores | Entrega a ficha pronta (número, data, valor, impostos lidos da nota) e completa o título depois | Documentação da API e teste de 6/nov/2026 |
| **Dar ciência do título a pagar** | Antes do pagamento, se o tipo de documento exigir | Avisa quem precisa dar a ciência e acompanha pelo aviso do Sienge | Documentação da API |
| **Autorizar o pagamento da parcela** | Último passo do financeiro antes de pagar | Mostra o que já foi aprovado no ERP BKM esperando esse clique | Documentação da API |
| **Criar contrato e aditivo** | Antes de qualquer medição; quando o saldo acaba | Avisa quando a nota passa do saldo do contrato | Documentação da API |
| **Criar pedido de compra** | Compras não regulares | ⏳ A definir no módulo de suprimentos | Documentação da API |
| **Criar empresa e obra** | Ao abrir uma SPE e um empreendimento | Liga o cadastro do ERP BKM ao do Sienge, uma vez | Documentação da API |
| **Corrigir ou apagar título criado pela API** | Depois de criado, a API só muda o vencimento; tipo, número, valor, empresa, fornecedor, emissão, parcelas e impostos só se corrigem à mão | Confere tudo antes de enviar, para o título nascer certo | Teste de 6/nov/2026 (título 8422) |
| **Gravar os dados fiscais de serviço no título** | Depois da liberação | ⏳ Pode passar a ser feito pela API; o teste parou porque falta o código da filial da empresa 2 | Teste de 6/nov/2026 |
| **Pagamento, baixa e remessa ao banco** | Depois da autorização | Acompanha pelos avisos do Sienge | Documentação da API |

⏳ Foi sugerido perguntar ao suporte do Sienge se existe liberação automática de medição e se há API (pública ou em desenvolvimento) para liberação, ciência e autorização de pagamento. Se a resposta mudar algum item, esta tabela é a primeira a ser atualizada.

**Não é passo manual, mas é limite do Sienge:** a NFS-e aceita número repetido do mesmo fornecedor no Sienge da BKM. A trava contra nota repetida é do ERP BKM.
