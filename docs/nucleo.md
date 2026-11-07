# Núcleo do ERP BKM: dicionário das tabelas (v0)

Versão 0, de 7/nov/2026. Ela traduz em tabelas o desenho da sabatina, que está no doc [Núcleo do ERP BKM: modelo v1](https://claude.ai/artifact/YXuHgVNLaMPRtpxJ8YWCPt). Todas as tabelas ficam no esquema `nucleo`, no mesmo Supabase do BKM Terrenos, acima do espelho do Sienge (`sienge_bruto` e `sienge`).

O SQL está em `supabase/migrations/` e os testes em `supabase/tests/nucleo.sql` (108 testes). Para rodar: `bash supabase/tests/run.sh`.

Este documento cobre o contas a pagar, a raiz (empresas e sócios), a árvore de naturezas, o livro de lançamentos e a reclassificação. Contas a receber, bancos, aprovação geral e engenharia ficam para as próximas sessões.

## Como ler

- **Regra no banco.** O que tem regra (confirmar título, quitar, reclassificar, fechar mês) só acontece por função do banco, com teste. A tela só chama a função.
- **O livro só cresce.** Nenhuma linha do livro é apagada ou editada. Desfazer é lançar uma linha de sinal contrário. A única exceção é a natureza, que muda pela reclassificação aprovada e guarda a natureza antiga.
- **Sinal.** No livro, entrada é positiva e saída é negativa. Nas tabelas de origem (título, pagamento, nota), os valores são sempre positivos.

## 1. Raiz

| Tabela | O que guarda | Regras principais |
|---|---|---|
| `usuarios` | Quem usa o ERP: papel (diretor, gestor, analista, leitura), se é contador, se é administrador | Administrador mexe na configuração. Contador vota nas alçadas que pedem o contador |
| `pessoas` | Uma tabela só para todo mundo: fornecedor, cliente, sócio, corretor, funcionário, órgão público, banco | CPF ou CNPJ único, só dígitos, com o tamanho certo |
| `pessoa_papeis` | Os papéis de cada pessoa | A mesma pessoa pode ser fornecedora e cliente sem cadastro duplicado |
| `empresas` | Empresas do grupo: holding, incorporadora, construtora, SPE | Cada empresa é uma pessoa (o CNPJ fica em `pessoas`) |
| `participacoes` | Quem é sócio de quem, com quanto e desde quando até quando | Em nenhum dia a soma passa de 100%. O mesmo sócio não tem duas participações no mesmo período. A empresa não é sócia de si mesma |
| `empreendimentos` | O empreendimento, ligado à sua SPE (1 para 1) | Só em empresa do tipo SPE, e uma SPE tem um empreendimento só. Guarda o código do terreno no BKM Terrenos |
| `atributos`, `atributo_opcoes` | Lista extensível de atributos de BI (praça, regional, linha de produto, faixa MCMV...) | O administrador cria atributos novos. Atributo de lista só aceita as opções cadastradas |
| `empreendimento_atributos` | O valor de cada atributo em cada empreendimento, com vigência | Não há dois valores do mesmo atributo no mesmo período. Os relatórios pegam o valor da data do lançamento |
| `centros_custo` | De quem é o gasto: um empreendimento ou uma área da empresa (Marketing, Administrativo...) | O centro do empreendimento fica na SPE dele. A área deixa de ser cadastrada como obra fingida |
| `departamentos`, `fases` | Listas de quem responde e do momento do projeto | Editáveis |
| `codigos_externos` | O código de cada registro no Sienge, no CRM ou no BKM Terrenos | Para trocar de ERP, troca-se esta tabela e não o modelo |

## 2. Árvore de naturezas

| Tabela | O que guarda | Regras principais |
|---|---|---|
| `linhas_dre` | As linhas da DRE (receita bruta, deduções, custo do terreno...) | Editáveis |
| `naturezas` | A árvore, com quantos níveis forem precisos. Cada natureza aponta para a mãe e tem tipo (operacional, não operacional, movimentação), linha da DRE, linha do fluxo de caixa, "só no orçado" e "redutora" | Veja as regras abaixo |
| `naturezas_sistema` | As naturezas que o próprio sistema usa: adiantamentos, juros e multas pagos, descontos obtidos e movimentos entre sócios | O administrador pode trocar o galho, mas a chave continua existindo |
| `v_naturezas` | Visão com o caminho legível ("Comerciais › Marketing › Online") e os níveis 1 a 4 | |

Regras da árvore (decididas em 7/nov/2026):

1. Só o administrador cria, renomeia, move e desativa naturezas, incluindo as do topo. Tudo fica na auditoria.
2. Uma natureza nova nasce com as características da mãe. Elas podem ser trocadas depois.
3. Só se lança no último nível. Uma natureza que já tem lançamentos não pode ganhar galhos abaixo dela: antes, os lançamentos precisam ser reclassificados.
4. Uma natureza desativada não recebe lançamentos novos, e os antigos continuam onde estão.
5. Uma natureza com lançamentos não se apaga direto. Ela é esvaziada pela reclassificação, que a apaga no fim.
6. Quando a natureza tem lançamentos, mudar o lugar dela na árvore, o tipo, a linha da DRE ou o fluxo de caixa mexe nos relatórios do passado. Por isso só a diretoria pode fazer essas mudanças.

A carga inicial é o rascunho v0 do doc, com 11 grupos e 4 níveis em Marketing. As 4 divergências em relação à viabilidade ainda esperam a sua decisão. A carga já usa a minha proposta para cada uma: impostos sobre a receita em Deduções, custo de capital só no orçado, taxas de gestão como grupo próprio e ITBI e registro das unidades vendidas em Comerciais.

## 3. Do compromisso ao pagamento

| Tabela | O que guarda | Regras principais |
|---|---|---|
| `compromissos` | O acordo que gera gasto: contrato, pedido, assinatura recorrente, avulsa, guia ou folha | A assinatura exige periodicidade e valor por período, e substitui o contrato fictício. O contrato traz o percentual de caução |
| `compromisso_rateios` | O rateio do compromisso por centro, natureza, fase e departamento | Natureza do último nível e ativa. Despesa exige centro de custo |
| `previsoes` | O gasto esperado que ainda não é dívida | Não se edita: cancela-se e cria-se outra. É consumida pelos títulos e substitui o título de previsão |
| `documentos_fiscais` | A nota, o boleto ou a guia que chegou, com o valor bruto e a caução retida | Não aceita nota repetida do mesmo emitente (mesmo tipo, número e série), uma trava que o Sienge não tem. Depois de lançada, não se edita |
| `documento_retencoes` | Os impostos retidos na nota (ISS, INSS, IR, PIS, COFINS, CSLL) e o órgão que recebe cada um | |
| `documento_rateios` | O rateio da nota | |
| `titulos` | A dívida real (ou o direito a receber), em rascunho até ser confirmada | Confirmado, o título não se edita e só muda de situação pelas quitações |
| `titulo_rateios` | O rateio do título | Muda só com o título em rascunho, ou pela reclassificação |
| `parcelas` | Os vencimentos do título | Precisam somar o valor do título |
| `titulo_previsoes` | Quanto de cada previsão o título consumiu | Não passa do saldo da previsão. A previsão zerada fica "consumida" |
| `pagamentos` | O dinheiro que saiu do banco, numa operação | Não se altera; o estorno virá com o módulo de bancos |
| `quitacoes` | Quanto de um pagamento quitou cada parcela, mais juros, multa e desconto | Não passa do saldo da parcela nem do saldo do pagamento. Só vale para a mesma empresa e a mesma pessoa. Não se apaga |
| `caucao_movimentos` | O extrato da caução por contrato: retenção, liberação e uso para pagar terceiro | O saldo nunca fica negativo. O uso para pagar terceiro exige motivo |
| `movimentos_societarios` | Aporte, integralização, distribuição, mútuo e devolução de mútuo | Cada movimento é um par ligado: título a pagar numa empresa e a receber na outra |
| `contas_bancarias`, `lotes_bancarios` | Contas e lotes de envio ao banco | O lote é só um agrupamento |

### O que cada função faz

- **`gerar_previsoes_assinatura(assinatura, até)`** cria uma previsão por período, no dia de vencimento combinado, sem duplicar.
- **`lancar_documento(nota, vencimentos)`** lança a nota inteira de uma vez:
  1. Cria o título do fornecedor pelo valor líquido (bruto menos retenções e caução), com as parcelas.
  2. Cria um título por imposto retido, contra o órgão que recebe.
  3. Registra a retenção no extrato de caução.
  4. Consome as previsões do contrato, da mais antiga, até o valor bruto.
- **`confirmar_titulo(título)`** confere se o rateio soma 100% e se as parcelas somam o valor, e grava o comprometido no livro.
- **`pagar_parcela(parcela, conta, data, juros, multa, desconto)`** é o atalho do dia a dia: um pagamento que quita a parcela inteira.
- **`liberar_caucao(contrato, valor, vencimento, terceiro, motivo)`** gera o título da liberação, para o próprio fornecedor ou para um terceiro.
- **`registrar_movimento_societario(tipo, pagadora, recebedora, valor, data)`** cria o par de títulos ligados.

### Pagamento parcial e adiantamento

Todo pagamento entra inteiro no livro em "Movimentações › Adiantamentos a fornecedores". Cada quitação tira o valor dali e o lança na natureza do título. Daí saem três casos:

- **Pagamento comum:** um pagamento quita uma parcela inteira e o adiantamento volta a zero no mesmo dia.
- **Pagamento parcial:** uma parcela recebe duas quitações.
- **Adiantamento:** é um pagamento ainda sem quitação. O saldo fica em Adiantamentos e é abatido aos poucos, por quitações em uma ou mais parcelas e títulos do mesmo fornecedor.

O realizado do livro sempre bate com o dinheiro que saiu do banco, e a DRE só enxerga a natureza do título.

## 4. Orçamento e livro

| Tabela | O que guarda | Regras principais |
|---|---|---|
| `orcamento_versoes` | As versões datadas: viabilidade, aprovado e reprojeções | Publicada, a versão não muda. Publicar uma viabilidade ou um aprovado substitui a versão vigente do mesmo tipo |
| `orcamento_linhas` | Os valores por centro, natureza e mês | O custo de capital ("só no orçado") só entra aqui |
| `lancamentos` | **O livro:** estágio (orçado, previsto, comprometido, realizado), empresa, centro, natureza, fase, departamento, competência, data de caixa, valor e a origem (previsão, título, parcela, quitação, pagamento, caução ou linha de orçamento) | Não se apaga nem se edita. A natureza só muda pela reclassificação |

O livro é escrito sozinho, a cada passo:

| Acontecimento | O que entra no livro |
|---|---|
| Previsão criada | Previsto, na data prevista |
| Título consome a previsão | Estorno do previsto |
| Título confirmado | Comprometido, no vencimento de cada parcela, rateado |
| Quitação | Realizado na natureza do título, estorno do comprometido, juros e multa ou desconto nas naturezas do sistema, e a saída de Adiantamentos |
| Caução retida | Comprometido sem data de caixa |
| Caução liberada | Sai do "sem data" e passa para o título, com vencimento |
| Orçamento publicado | Orçado |

### Visões

- **`v_fluxo_caixa`:** previsto em aberto, comprometido em aberto e realizado, por empresa e por dia. É uma soma do livro, não uma tabela.
- **`v_lancamentos_bi`:** o livro com os nomes, os níveis da árvore, as características da natureza e os atributos do empreendimento vigentes na competência de cada linha. É a visão para BI e para os agentes.
- **`v_parcelas`, `v_adiantamentos`, `v_caucao`, `v_previsoes`:** saldos e previsto × realizado.

## 5. Fechamento e reclassificação

| Tabela | O que guarda |
|---|---|
| `meses_fechados` | Os meses fechados de cada empresa. Só a diretoria fecha e reabre, sempre em ordem |
| `niveis_aprovacao` | Gestor, Diretoria, e Diretoria e contador |
| `alcadas_reclassificacao` | A alçada pela idade do lançamento (mês aberto, mês fechado com o trimestre aberto, trimestre fechado), pelo valor e pelo acumulado da pessoa no mês. Só o administrador mexe |
| `reclassificacoes` | O pedido: origem, destino, filtro, motivo, valor, acumulado, faixa, nível exigido e situação |
| `reclassificacao_itens` | Cada linha do livro movida, com a natureza de antes e a de depois |
| `reclassificacao_votos` | Os votos, com quem votou, em que papel e a justificativa |

Regras (decididas em 7/nov/2026):

1. Toda reclassificação precisa de aval. O padrão é a diretoria em qualquer valor; no trimestre fechado, a diretoria e o contador.
2. O trimestre é o do calendário. Ele fecha quando o último mês dele é fechado.
3. Vale a mais alta de três alçadas: a da idade, a do valor e a do valor acumulado pela pessoa no mês. Por isso, picar um pedido grande não escapa da alçada.
4. O valor do pedido é o maior valor movido num estágio. Os estornos e os estágios repetidos não se somam.
5. Linhas do mesmo título ou da mesma previsão vão juntas, para o título não ficar com parte numa natureza e parte noutra.
6. Quem pediu não aprova. Recusar exige justificativa e encerra o pedido.
7. Aprovado o pedido, mudam a natureza das linhas e também o rateio dos títulos e das previsões, para que os próximos pagamentos já caiam no destino. Na reclassificação da natureza inteira, mudam também os contratos, as notas e os orçamentos em rascunho.
8. "Apagar a origem" só vale para a natureza inteira. A natureza é apagada depois de esvaziada, e o pedido guarda o nome dela.
9. `previa_reclassificacao` mostra, antes da aprovação, quantas linhas o pedido move, o valor, os meses e se a linha da DRE ou o tipo mudam.

Exemplo de alçada configurada pelo administrador: "gestor aprova até R$ 11 mil no mês aberto, desde que o acumulado da pessoa no mês não passe de R$ 35 mil".

## O que ficou de fora desta versão (de propósito)

- **Permissões por linha (RLS) e telas.** Por enquanto, as regras de papel estão nas funções.
- **Contas a receber.** Por isso a quitação só aceita título a pagar. O título a receber já existe para o dinheiro entre sócios.
- **Módulo de aprovação geral.** Ficam para ele as alçadas de pagamento, a liberação de caução e as avaliações do gestor do contrato.
- **Estorno de pagamento, conciliação e remessa.** Ficam para o módulo de bancos.
- **Lançamento em mês fechado.** Hoje o fechamento só pesa na reclassificação. Falta decidir o que fazer com um pagamento atrasado de uma competência já fechada: travar, ou lançar no primeiro mês aberto.
- **A carga do Sienge para o núcleo.** Ela vem depois das camadas `sienge_bruto` e `sienge`.
