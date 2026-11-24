# ⚠️ O que ainda é feito à mão no Sienge

[← Sumário](../README.md)

Estes passos **não** podem ser feitos pelo ERP BKM, porque a API do Sienge não tem o comando. Quem executa precisa entrar no Sienge. Cada página do manual repete o aviso no ponto em que o passo aparece.

## 🧪 Área de testes no Sienge

✅ **Criada em 17/nov/2026, a pedido do Moises.** Todo teste de lançamento vai nela, nunca nas empresas reais.

| O quê | Código | Nome |
| --- | --- | --- |
| Empresa | 11 | BKM TESTES - NAO USAR |
| Obra / centro de custo | 100 | TESTES API - NAO USAR |
| Conta corrente | TESTE-API | CONTA TESTE - NAO PAGAR (banco fictício, fora do disponível) |

> ⚠️ **Passo manual.** A API não cria empresa, obra nem conta corrente. Tudo isso se faz na tela do Sienge:
> - **Empresa:** Apoio › Empresas › Cadastros;
> - **Obra ou centro de custo:** Apoio › Obras/Centros de Custo › Cadastros;
> - **Conta corrente:** Apoio › Contas Correntes › Cadastros.
>
> **Empresa nova nasce invisível** para todos os usuários da tela. Para alguém enxergá-la, libere "Acesso aos dados da empresa" em Segurança › Autorizações › Usuários › Empresas. Hoje só o Moises tem esse acesso na empresa 11.
>
> **Para desfazer:** exclua enquanto não houver lançamento. Depois do primeiro lançamento, só dá para desativar.

## Passos manuais do dia a dia

| Passo manual no Sienge | Onde aparece no processo | Como o ERP BKM ajuda | Fonte |
| --- | --- | --- | --- |
| **Liberar a medição** (gera o título) | Depois da aprovação dos 2 gestores | Entrega a ficha pronta (número, data, valor, impostos lidos da nota) e completa o título depois | Documentação da API e teste de 6/nov/2026 |
| **Dar ciência do título a pagar** | Antes do pagamento, se o tipo de documento exigir | Avisa quem precisa dar a ciência e acompanha pelo aviso do Sienge | Documentação da API |
| **Autorizar o pagamento da parcela** | Último passo do financeiro antes de pagar | Mostra o que já foi aprovado no ERP BKM esperando esse clique | Documentação da API |
| **Criar contrato e aditivo** | Antes de qualquer medição; quando o saldo acaba | Avisa quando a nota passa do saldo do contrato | Documentação da API |
| 🟡 **Pôr a chave PIX de CNPJ com letras** (PR #133, ainda não juntado) | No envio do título ao Sienge, quando o PIX é um CNPJ com letras | A parcela fica marcada para pôr à mão no Sienge | Equipe do leitor, 23/nov/2026 |
| **Criar pedido de compra** | Compras não regulares | ⏳ A definir no módulo de suprimentos | Documentação da API |
| **Criar empresa e obra** | Ao abrir uma SPE e um empreendimento | Liga o cadastro do ERP BKM ao do Sienge, uma vez | Documentação da API |
| **Corrigir ou apagar título criado pela API** | Depois de criado, a API só muda o vencimento e os dados de pagamento (PIX); tipo, número, valor, empresa, fornecedor, emissão, parcelas e impostos só se corrigem à mão | Só cria o título com tudo preenchido e aprovado, para ele nascer certo | Testes de 6 e 8/nov/2026 (título 8422) |
| **Apagar a linha de previsão (PRV)** | Quando a previsão é encerrada, cancelada ou trocada pela nota | Lista as linhas a apagar numa página que abre com qualquer conta Google da BKM e marca sozinho quando somem (em poucos minutos, pelo aviso do Sienge, quando estiver ligado; senão em até 30 minutos). Se alguém apagar a linha de uma previsão que ainda está aberta, o ERP BKM manda outra. Linha PRV lançada à mão no Sienge aparece para o financeiro (AF) como "não é do ERP" | Decisão de 14/nov/2026; construído em 17/nov/2026; página no lugar da planilha, 18/nov/2026 |
| **Gravar os dados fiscais de serviço no título** | Depois da liberação | ⏳ Pode passar a ser feito pela API; o teste parou porque falta o código da filial da empresa 2 | Teste de 6/nov/2026 |
| **Apagar título de previsão substituído ou excluído** | Quando a nota chega e o título definitivo é criado, ou quando a previsão é excluída no ERP BKM | Liga cada título de previsão do Sienge à previsão do ERP BKM e lista numa página os que precisam ser apagados (antes, numa planilha do Google); a leitura diária aponta, também por e-mail, o que deveria ter sido apagado e continua lá, e avisa a AF se sumir um título que não estava na lista | Moises, 14/nov/2026; página em 18/nov/2026 |
| **Despesa paga por uma empresa do grupo em nome de outra** | Todo mês, até o dia 10 do mês seguinte (🟡 prazo ainda é proposta) | 🟡 Vai gerar a conta a pagar de cada empresa e mostrar o saldo a reembolsar. Até lá, a holding não lança a despesa reembolsada na conta da despesa (emite nota de débito ou registra o valor a receber) e a SPE deixa de usar a conta 2010503 (Custo fixo de PDV), lançando com a natureza original. Ver [Classificação](../financeiro/classificacao.md) | [Procedimento de 16/nov/2026](https://claude.ai/artifact/PVniSPGxFYtMP8jrymAUGL) |
| **Pagamento dos funcionários PJ** | Todo mês | ⚠️ Hoje passa inteiro pelo Sienge e pelo Nexxera, com nome e valor visíveis lá. A anonimização do ERP BKM só vale quando o Sienge sair desse fluxo | Moises, 7/nov/2026 |
| **Pagamento, baixa e remessa ao banco** | Depois da autorização | Acompanha pelos avisos do Sienge e lê de volta o que aconteceu com cada título; confere se todo título do ERP BKM chegou ao Sienge | Documentação da API; Moises, 8/nov/2026 (primeira etapa da implantação) |

⏳ Foi sugerido perguntar ao suporte do Sienge se existe liberação automática de medição e se há API (pública ou em desenvolvimento) para liberação, ciência e autorização de pagamento. Se a resposta mudar algum item, esta tabela é a primeira a ser atualizada.

**Pendente à mão no Sienge (testes):** apagar os títulos de teste 8417 e 8422 (este com PIX, credor de teste, R$ 1, vencimento em 15/03/2027, "NÃO PAGAR") e a medição 2 do contrato CTP/28.

**Não é passo manual, mas é limite do Sienge:** a NFS-e aceita número repetido do mesmo fornecedor no Sienge da BKM. A trava contra nota repetida é do ERP BKM.
