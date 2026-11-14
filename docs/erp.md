# ERP BKM: dicionário das tabelas (v0)

Versão 0, de 7/nov/2026. Ela traduz em tabelas o desenho da sabatina, que está no doc [Núcleo do ERP BKM: modelo v1](https://claude.ai/artifact/YXuHgVNLaMPRtpxJ8YWCPt). Todas as tabelas ficam no esquema `erp`, no mesmo Supabase do BKM Terrenos, acima do espelho do Sienge (`sienge_bruto` e `sienge`).

O SQL está em `supabase/migrations/` e os testes em `supabase/tests/erp.sql` (564 testes). Para rodar: `bash supabase/tests/run.sh`.

Este documento cobre o contas a pagar, a raiz (empresas e sócios), a árvore de naturezas, o livro de lançamentos e a reclassificação. Contas a receber, bancos, aprovação geral e engenharia ficam para as próximas sessões.

## Como ler

- **Regra no banco.** O que tem regra (confirmar título, quitar, reclassificar, fechar mês) só acontece por função do banco, com teste. A tela só chama a função.
- **O livro só cresce.** Nenhuma linha do livro é apagada ou editada. Desfazer é lançar uma linha de sinal contrário. A única exceção é a natureza, que muda pela reclassificação aprovada e guarda a natureza antiga.
- **Sinal.** No livro, entrada é positiva e saída é negativa. Nas tabelas de origem (título, pagamento, nota), os valores são sempre positivos.

## 1. Raiz

| Tabela | O que guarda | Regras principais |
|---|---|---|
| `usuarios` | Quem usa o ERP: id nosso, `login_id` (o `sub` que o provedor de login dá), papel (diretor, gestor, analista, leitura), se é contador, se é administrador | Administrador mexe na configuração. Contador vota nas alçadas que pedem o contador. Sem chave estrangeira para `auth.users`: `erp.eu()` acha o usuário pelo `login_id` lido em `erp.login_atual()`, o único ponto que conhece o provedor. Só o administrador cadastra e muda usuário, com auditoria; ninguém muda o próprio papel, acesso ou login. Só o master cria administrador, tira administrador ou mexe no cadastro de um. `so_sucessao` marca o usuário que existe só para o grupo de sucessão do master (pode ser de fora da empresa): papel leitura, sem nenhum outro acesso |
| `pessoas` | Uma tabela só para todo mundo: fornecedor, cliente, sócio, corretor, funcionário, órgão público, banco | CPF ou CNPJ único, só dígitos, com o tamanho certo |
| `pessoa_papeis` | Os papéis de cada pessoa | A mesma pessoa pode ser fornecedora e cliente sem cadastro duplicado |
| `empresas` | Empresas do grupo: holding, incorporadora, construtora, SPE | Cada empresa é uma pessoa (o CNPJ fica em `pessoas`) |
| `participacoes` | Quem é sócio de quem, com quanto e desde quando até quando | Em nenhum dia a soma passa de 100%. O mesmo sócio não tem duas participações no mesmo período. A empresa não é sócia de si mesma |
| `empreendimentos` | O empreendimento, ligado à sua SPE (1 para 1) | Só em empresa do tipo SPE, e uma SPE tem um empreendimento só. Guarda o código do terreno no BKM Terrenos |
| `atributos`, `atributo_opcoes` | Lista extensível de atributos de BI (praça, regional, linha de produto, faixa MCMV...) | O administrador cria atributos novos. Atributo de lista só aceita as opções cadastradas |
| `empreendimento_atributos` | O valor de cada atributo em cada empreendimento, com vigência | Não há dois valores do mesmo atributo no mesmo período. Os relatórios pegam o valor da data do lançamento |
| `tipos_nucleo` | Tipos de núcleo (Empreendimento, Corporativo, Loja, Outro, e os que vierem) | Lista editável pelo pedido de mudança de acesso aprovado, com auditoria; não se apaga, desativa. O tipo que exige empreendimento liga o núcleo a um. Tipo com núcleos não muda essa exigência; tipo desativado não recebe núcleo novo |
| `nucleos_economicos` | Onde a despesa mora: a SPE ou obra (empreendimento), o Corporativo, uma loja | O tipo vem de `tipos_nucleo`. O núcleo do empreendimento fica na SPE dele. Área não é núcleo. A data de criação é sempre a do cadastro e não muda (é o que decide se um núcleo é "futuro" para uma atribuição) |
| `centros_custo` | Área de apropriação (Novos negócios, Terreno, Incorporação, Projetos, Obra, Assistência técnica, Comercial, Marketing, Financeiro, Administrativo, Jurídico, Diretoria). Lista raiz única | Editável pelo administrador |
| `nucleo_centros` | Quais centros de custo estão ligados em cada núcleo (o Corporativo não tem Obra; uma loja não tem Incorporação) | Só o administrador liga ou desliga, com auditoria; não se apaga. Sem linha = desligado. Lançamento só em centro ligado no núcleo |
| `fases` | Momento do projeto, só para relatório | Editável |
| `perfis_modelo`, `perfil_centros`, `perfil_naturezas` | Perfil de acesso salvo (Analista de Marketing, Coordenador de Marketing...): nível em cada centro de custo (Leitor, Lançador restrito, Lançador) e as naturezas restritas que ele libera. Sem núcleo | Só muda pelo pedido de mudança de acesso aprovado, com auditoria. Mudar o modelo muda todos que estão ligados a ele. Leitor vê tudo do centro; Lançador restrito lança e vê só o que lançou; Lançador lança e vê tudo. Comentar é ação de quem vê |
| `atribuicoes`, `atribuicao_nucleos`, `atribuicao_tipos` | A pessoa ligada a um modelo, com o escopo de núcleos e a validade (início e fim). Uma pessoa tem várias | Escopos: lista (os núcleos marcados na hora e, se escolhidos, os núcleos criados depois nos tipos marcados); todos, inclusive os futuros; todos dos tipos marcados, inclusive os futuros. Em qualquer escopo, os núcleos excluídos ficam de fora. Atribuições que se sobrepõem valem pelo maior (Leitor + Lançador restrito = Lançador). Fora da validade ou com o modelo desativado, não vale. A atribuição não muda de pessoa e a data dela (a foto) é sempre a de quando ela passa a valer. Só muda pelo pedido de mudança de acesso aprovado |
| `excecoes_centro`, `excecoes_natureza` | Exceção da pessoa: nível próprio num núcleo × centro (inclusive nenhum) e liberação ou bloqueio de uma natureza (num centro ou em todos) | Vence o modelo. O bloqueio vale para o galho inteiro e vence qualquer liberação. Com fim opcional |
| `centro_diretores` | Diretor da área, por centro de custo | Papel nominal, fora dos modelos, como o gestor da área (`centro_aprovadores`) e AF, AO e AD (`listas_financeiro`). Ainda fora da alçada. Os quatro papéis só mudam pelo pedido de mudança de acesso aprovado |
| `aprovadores_acesso`, `regra_acesso` | Quem aprova as mudanças de acesso e quantos precisam aprovar; o prazo de veto da sucessão do master | Os aprovadores não precisam ser administradores. O master muda a lista e as regras sozinho; os outros, só com a unanimidade da lista. A primeira lista entra pelo sistema |
| `mudancas_acesso`, `mudanca_acesso_votos` | Pedido de mudança de acesso e os votos: modelos, atribuições, exceções, gestor e diretor da área, AF, AO e AD, tipos de núcleo, marca de natureza restrita e mudança de galho restrito, tipo de um núcleo existente | Ninguém grava direto nas tabelas de acesso, nem o administrador. Só o administrador pede (`erp.pedir_mudanca_acesso`); vale quando o mínimo de aprovadores aprova (`erp.decidir_mudanca_acesso`). Quem pediu e quem ganha acesso com a mudança não aprovam (no modelo, quem está ligado a ele). Recusa precisa de justificativa e encerra o pedido. O pedido sem aprovadores suficientes nem abre. Se o registro mudou depois do pedido, a aprovação não aplica a versão velha (fica obsoleta). Quem pediu cancela. Histórico não se apaga |
| `master`, `grupo_sucessao`, `sucessoes_master`, `sucessao_votos`, `avisos_sucessao` | O master (um usuário só), o grupo que aprova a sucessão dele, os pedidos de sucessão, os votos e os avisos ao master | O master muda a lista de aprovadores de acesso sozinho, é o único que cria e administra administradores e o único que define o grupo de sucessão; passa o papel na hora (`erp.passar_master`). Sucessão: alguém do grupo pede, já apontando o novo master; todo o grupo aprova (menos o master e o novo master), sem prazo; da unanimidade, o master tem 7 dias para vetar e recebe 2 avisos por dia, por e-mail e WhatsApp, cada um com um link de veto único (a página do link tem o botão Interromper, porque antivírus e prévias abrem links sozinhos; `erp.vetar_sucessao_por_link`); sem veto, o novo master assume (`erp.efetivar_sucessao_master`). O envio dos avisos é do servidor |
| `codigos_externos` | O código de cada registro no Sienge, no CRM ou no BKM Terrenos | Para trocar de ERP, troca-se esta tabela e não o modelo |

## 2. Árvore de naturezas

| Tabela | O que guarda | Regras principais |
|---|---|---|
| `linhas_dre` | As linhas da DRE (receita bruta, deduções, custo do terreno...) | Editáveis |
| `naturezas` | A árvore, com quantos níveis forem precisos. Cada natureza aponta para a mãe e tem tipo (operacional, não operacional, movimentação), linha da DRE, linha do fluxo de caixa, "só no orçado", "redutora" e "restrita" (pró-labore, folha PJ: fechada a todos, mesmo dentro do centro, até liberação do modelo ou da pessoa; marcada pelo administrador) | Veja as regras abaixo |
| `naturezas_sistema` | As naturezas que o próprio sistema usa: adiantamentos, juros e multas pagos, descontos obtidos e movimentos entre sócios | O administrador pode trocar o galho, mas a chave continua existindo |
| `v_naturezas` | Visão com o caminho legível ("Comerciais › Marketing › Online") e os níveis 1 a 4 | |

Regras da árvore. O Moises decidiu em 7/nov/2026 que a árvore é dinâmica e que o topo também se edita; as regras marcadas como *proposta* ainda precisam ser confirmadas por ele:

1. *Proposta:* só o administrador cria, renomeia, move e desativa naturezas, incluindo as do topo. Tudo fica na auditoria.
2. *Proposta:* Uma natureza nova nasce com as características da mãe. Elas podem ser trocadas depois.
3. *Proposta:* Só se lança no último nível. Uma natureza que já tem lançamentos não pode ganhar galhos abaixo dela: antes, os lançamentos precisam ser reclassificados.
4. *Proposta:* Uma natureza desativada não recebe lançamentos novos, e os antigos continuam onde estão.
5. Uma natureza com lançamentos não se apaga direto. Ela é esvaziada pela reclassificação, que a apaga no fim. (pedido do Moises: página de reclassificação.)
6. *Proposta:* Quando a natureza tem lançamentos, mudar o lugar dela na árvore, o tipo, a linha da DRE ou o fluxo de caixa mexe nos relatórios do passado. Por isso só a diretoria pode fazer essas mudanças.

A carga inicial é o rascunho v0 do doc, com 11 grupos e 4 níveis em Marketing. As 4 divergências em relação à viabilidade ainda esperam a sua decisão. A carga já usa a minha proposta para cada uma: impostos sobre a receita em Deduções, custo de capital só no orçado, taxas de gestão como grupo próprio e ITBI e registro das unidades vendidas em Comerciais.

## 3. Do compromisso ao pagamento

| Tabela | O que guarda | Regras principais |
|---|---|---|
| `compromissos` | O acordo que gera gasto: contrato, pedido, assinatura recorrente, avulsa, guia ou folha | A assinatura exige periodicidade e valor por período, e substitui o contrato fictício. O contrato traz o percentual de caução |
| `compromisso_rateios` | O rateio do compromisso por núcleo econômico, centro de custo, natureza e fase | Natureza do último nível e ativa. Despesa exige núcleo e centro de custo, e o centro precisa estar ligado no núcleo |
| `previsoes` | O gasto esperado que ainda não é dívida | Não se edita: cancela-se e cria-se outra. É consumida pelos títulos e substitui o título de previsão |
| `documentos_fiscais` | A nota, o boleto ou a guia que chegou, com o valor bruto e a caução retida | Não aceita nota repetida do mesmo emitente (mesmo tipo, número e série), uma trava que o Sienge não tem. Depois de lançada, não se edita |
| `documento_retencoes` | Os impostos retidos na nota (ISS, INSS, IR, PIS, COFINS, CSLL) e o órgão que recebe cada um | |
| `documento_rateios` | O rateio da nota | |
| `titulos` | A dívida real (ou o direito a receber), em rascunho até ser confirmada | Confirmado, o título não se edita e só muda de situação pelas quitações. Quem criou e quando (`criado_por`, `criado_em`) o banco grava sozinho e não se mudam. O tipo `adiantamento` é o pedido de adiantamento: um núcleo e um centro só, passa pela alçada como os outros e não compromete o livro (quem lança é o pagamento) |
| `titulo_rateios` | O rateio do título | Muda só com o título em rascunho, ou pela reclassificação |
| `parcelas` | Os vencimentos do título | Precisam somar o valor do título |
| `titulo_previsoes` | Quanto de cada previsão o título consumiu | Não passa do saldo da previsão. A previsão zerada fica "consumida" |
| `pagamentos` | O dinheiro que saiu do banco, numa operação, carimbado com núcleo econômico e centro de custo desde a saída | Não se altera; o estorno virá com o módulo de bancos. Sem núcleo e centro (ligado no núcleo, da mesma empresa) não sai; só a transferência entre contas próprias dispensa. O atalho de pagar parcela carimba com o núcleo e o centro de maior peso do título. Quem criou e quando o banco grava sozinho e não se mudam. O que sobra do pagamento depois das quitações da mesma transação é adiantamento e só sai ligado a um pedido de adiantamento aprovado (`adiantamento_id`), com o favorecido e o carimbo do pedido e sem passar do valor dele; conferido no fim da transação |
| `regra_adiantamento` | A regra do adiantamento em aberto, configurável: se a trava vale, quais listas aprovam o abatimento em outro núcleo ou centro (padrão AF, AO, AD) e quais liberam pagar sem abater (padrão AD) | Uma linha só; só o administrador muda, com auditoria |
| `listas_financeiro` | Quem está em cada lista de aprovação do financeiro (AF, AO, AD) | Só o administrador mexe, com auditoria |
| `centro_aprovadores` | O gestor da área de cada centro de custo, que aprova a primeira etapa da alçada de pagamento | Só o administrador mexe, com auditoria. Centro sem gestor aprovador fica fora da alçada (piloto: Marketing) |
| `alcadas_pagamento`, `regra_alcada_pagamento` | Faixas da alçada de pagamento pelo acumulado do mês do centro de custo (padrão: até 50 mil, gestor da área e AF; acima, gestor da área, AF e AD) e como se soma o acumulado (padrão: o centro no grupo todo; ou por empresa; ou por núcleo; e, por padrão, somando também o que o mesmo fornecedor tem no mês em outros centros). Também a janela da competência: a da nota e a do título avulso ficam no máximo 1 mês antes ou depois do mês da emissão (configurável) | Só o administrador muda, com auditoria |
| `titulo_coberturas` | Quanto de cada linha do rateio de um título foi coberto por adiantamento já pago ao mesmo fornecedor, no mesmo núcleo e centro | Só pela confirmação do título; não se altera. O adiantamento conta uma vez no acumulado: a linha soma só o que passa da cobertura. Cada adiantamento cobre até o que já foi pago dele e ainda não foi usado (cobertura ou abatimento em outro título, o maior dos dois), do mais antigo para o mais novo, e nunca mais que a parte da linha |
| `excecoes_competencia` | Exceção aprovada para a nota ou o título avulso com competência fora da janela da emissão | Só insere; aprova quem está nas listas configuradas (padrão AF e AD), com papel de edição e justificativa; quem lançou não aprova. Vale só para a competência aprovada: se ela muda, precisa de outra exceção |
| `titulo_alcadas`, `titulo_aprovacoes` | A alçada fixada quando o título a pagar é confirmado (etapas, centro e acumulado) e a decisão de cada etapa, por volta (`titulos.rodada`) | Só pelas operações do banco; não se alteram. As etapas são em sequência, quem lançou não aprova, cada pessoa aprova uma etapa só por volta. Cada etapa aprova, recusa ou pede revisão. Recusar exige justificativa e cancela: o título (ou a nota inteira, com os títulos de imposto) vai para `cancelado`, o livro estorna o comprometido e o consumo das previsões, a previsão volta a aberta, a caução retida é estornada e o número da nota fica livre. Pedir revisão exige o motivo, e o título continua aberto e no livro. O título não é quitado sem a alçada completa. Quem aprova consulta exatamente os títulos que formaram o acumulado (`titulos_do_acumulado`). Títulos do mesmo centro confirmados ao mesmo tempo se enxergam na soma. O último gestor do centro não sai enquanto houver título esperando por ele |
| `titulo_revisoes` | Pedido de revisão de um título (volta, etapa, motivo, quem pediu) e o reenvio (resposta, quem reenviou) | Só pela aprovação e pelo `reenviar_titulo`; não se apaga e se responde uma vez. Há no máximo um pedido aberto por título. Em revisão, ninguém aprova nem paga. Quem ajusta é quem lançou, o gestor de um centro do rateio ou o AF, dentro de `regras_ajuste`. Título avulso ou pedido: ajusta-se o título, as parcelas e o rateio. Título de nota: ajusta-se a nota, o rateio e as retenções. O reenvio confere de novo o que a confirmação confere e abre uma volta nova, com a alçada recalculada do zero. A nota é relançada e os títulos refeitos (`substitui_id`), consumindo as mesmas previsões quando ainda casam. Cada pessoa que ajustou ou reenviou já aprova a própria etapa na volta nova (a gestora da área a da área, o AF a do AF; `titulo_aprovacoes.origem = 'ajuste'`), uma etapa por pessoa, e não aprova nenhuma outra; quem lançou o primeiro título da cadeia continua o autor e nunca aprova. A cadeia de substituições conta inteira |
| `titulo_ajustes` | Cada linha mudada no ajuste de uma revisão: tabela, antes, depois, quem e quando | Só cresce, e só pelas travas do ajuste. É a trilha do ajuste e diz quem ajustou |
| `regras_ajuste` | O que cada um (AF, gestor da área, quem lançou) pode mudar no ajuste da revisão, campo a campo; em número e data, também se só para mais, só para menos ou os dois | Linhas fixas, uma por campo e papel; só o administrador muda `permitido` e `direcao`, com auditoria. Começa tudo liberado, para os dois lados. Quem tem mais de um papel pode o que algum deles pode. Coluna que não está na lista não muda no ajuste. Linha incluída passa pela regra de cada campo dela; campo que só muda para um lado não entra em linha nova |
| `abatimentos_cruzados`, `liberacoes_sem_abater` | Aprovações do abatimento de adiantamento em título de outro núcleo ou centro, e da liberação para pagar o título sem abater o adiantamento em aberto | Com justificativa; quem está na lista aprova; quem lançou o pagamento não aprova o abatimento dele e quem lançou o título não libera; a liberação cobre só os adiantamentos que já existiam quando foi aprovada (adiantamento novo pede outra); não se alteram nem se apagam. Com a trava ligada, sem elas a quitação é recusada |
| `quitacoes` | Quanto de um pagamento quitou cada parcela, mais juros, multa e desconto | Não passa do saldo da parcela nem do saldo do pagamento. Só vale para a mesma empresa e a mesma pessoa. Não se apaga |
| `caucao_movimentos` | O extrato da caução por contrato: retenção, liberação e uso para pagar terceiro | O saldo nunca fica negativo. O uso para pagar terceiro exige motivo |
| `movimentos_societarios` | Aporte, integralização, distribuição, mútuo e devolução de mútuo | Cada movimento é um par ligado: título a pagar numa empresa e a receber na outra |
| `contas_bancarias`, `lotes_bancarios` | Contas e lotes de envio ao banco | Só o administrador cadastra e muda conta, com auditoria. O lote é só um agrupamento |

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
| `orcamento_linhas` | Os valores por núcleo, centro de custo, natureza e mês | O custo de capital ("só no orçado") só entra aqui |
| `lancamentos` | **O livro:** estágio (orçado, previsto, comprometido, realizado), empresa, núcleo econômico, centro de custo, natureza, fase, competência, data de caixa, valor e a origem (previsão, título, parcela, quitação, pagamento, caução ou linha de orçamento) | Não se apaga nem se edita. A natureza só muda pela reclassificação |

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
| `meses_fechados` | Os meses fechados de cada empresa (o fechamento mensal foi aceito pelo Moises). *Proposta:* só a diretoria fecha e reabre, sempre em ordem |
| `niveis_aprovacao` | Gestor, Diretoria, e Diretoria e contador |
| `alcadas_reclassificacao` | A alçada pela idade do lançamento (mês aberto, mês fechado com o trimestre aberto, trimestre fechado), pelo valor e pelo acumulado da pessoa no mês. Só o administrador mexe |
| `reclassificacoes` | O pedido: origem, destino, filtro, motivo, valor, acumulado, faixa, nível exigido e situação |
| `reclassificacao_itens` | Cada linha do livro movida, com a natureza de antes e a de depois |
| `reclassificacao_votos` | Os votos, com quem votou, em que papel e a justificativa |

Regras decididas em 7/nov/2026 (o Moises disse que mesmo a reclassificação simples precisa do aval da diretoria; a exceção que propus, para corrigir um lançamento só num mês aberto, ficou sem resposta e não foi implementada):

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

- **Permissões por linha (RLS) e telas.** O esquema fica fechado à API (anon, authenticated e service_role sem nenhum acesso; o teste de catálogo só admite privilégio do dono e de papéis `erp_*`). Toda tabela tem RLS ligado e forçado (S-003, migration `_erp_rls`), negando por padrão, com duas políticas: `sistema` (tudo, quando `erp.sistema()`) e `conferencia` (só leitura, para o papel `erp_conferencia`). Sistema é só a chamada sem login do papel nosso `erp_sistema` ou da sessão do dono do esquema sem SET ROLE (migration e cron); a chave de serviço do Supabase e qualquer outro papel não são (S-033). As conferências das travas (`eu`, `meu_usuario`, `meu_papel`, `exigir_*`, `estou_nas_listas`, `regra_adiantamento_atual`, `autor_lancamento`, `abatimento_aprovado`, `adiantamento_anterior_em_aberto`, os saldos de previsão, parcela e pagamento e `centro_ligado`) são security definer, donas `erp_conferencia`, com `search_path` fixo, e recebem só ids: a trava enxerga o que quem lança não vê (S-034, testado com um usuário comum que só vê um centro). As políticas por perfil (núcleo econômico × centro de custo × natureza, com PJ isolado) entram com o primeiro grant a `authenticated`, no mesmo PR. Também são definer de `erp_conferencia` `checar_natureza`, `checar_centro` e o gatilho `tg_nucleo_economico`. As operações que mudam o que o cliente não muda direto (S-035) são definer de papéis próprios, sem login nem membros: `erp_situacao` (`confirmar_titulo`, os gatilhos da quitação e do consumo da previsão) e `erp_reclassificacao` (`decidir_reclassificacao`, que aplica a reclassificação aprovada); as travas conferem `erp.agindo_como(papel)`, e essas funções têm a política `operacao`. Não há mais variável de sessão (`erp.sistema`, `erp.reclassificando`, `erp.sistema_apaga`) servindo de passe: o teste de catálogo recusa função que leia ou ponha `erp.*` na sessão. A situação do título, inclusive de rascunho para aberto, e a da nota fiscal só mudam por essas operações (`lancar_documento` também é de `erp_situacao`, S-036): nota lançada não volta a rascunho, e título, nota e previsão nascem no estado inicial. O pedido de reclassificação, suas linhas e os votos (S-038) só se gravam, mudam ou apagam por `pedir_reclassificacao`, `decidir_reclassificacao` e `cancelar_reclassificacao`, todas de `erp_reclassificacao` (S-037); de fora, só a chave estrangeira limpa a natureza que foi apagada. O livro, o extrato da caução e a auditoria só crescem, e só pelas operações do banco: as linhas do livro entram pelas operações de `erp_situacao` (nota, título, pagamento, quitação, previsão, caução e orçamento), a caução só se movimenta pelo lançamento da nota e pela liberação, e a auditoria só é escrita pelo `erp.tg_auditoria`, definer do papel `erp_auditoria`, que só insere nela; nada disso se altera ou se apaga, nem pelo sistema, e quem fez e quando o banco grava. O mês só fecha e reabre por `fechar_mes` e `reabrir_mes`, da diretoria (definer de `erp_situacao`, S-053), e quem fechou o banco grava. A previsão só é consumida pelo lançamento da nota, e só a que casa com a nota do título (S-054). Usuários, as naturezas do sistema, os níveis de aprovação, as contas bancárias da empresa e os códigos externos só o administrador (ou o sistema) grava, com auditoria; ninguém muda o próprio papel, acesso ou login, nem se apaga. A versão do orçamento nasce em rascunho e só a publicação muda a situação dela; publicada, não se edita nem se apaga (S-055). O núcleo econômico do rateio, do livro e do pagamento é sempre da empresa do registro, e a empresa de contrato, nota, título, orçamento, pagamento e conta não muda depois de criado (S-056). De fora das operações só nasce título avulso, sem nota nem contrato, e ele não passa a apontar para um; o rateio e as retenções da nota lançada não mudam, o rateio do contrato com caução retida também não, e o movimento entre sócios só se registra pela função dele e não se altera (S-057). Pedir e cancelar reclassificação exigem cadastro no ERP, e só quem pediu cancela (S-058). Nenhuma tabela do esquema se apaga por TRUNCATE. O `search_path` das funções definer termina em `pg_temp`, para tabela temporária nunca ser achada antes das do esquema. Quando entrarem as políticas por perfil, essas operações conferem por conta própria se quem chama vê o registro, porque por dentro enxergam tudo.
- **Contas a receber.** Por isso a quitação só aceita título a pagar. O título a receber já existe para o dinheiro entre sócios.
- **Módulo de aprovação geral.** Ficam para ele as alçadas de pagamento, a liberação de caução e as avaliações do gestor do contrato.
- **Estorno de pagamento, conciliação e remessa.** Ficam para o módulo de bancos.
- **Lançamento em mês fechado.** Hoje o fechamento só pesa na reclassificação. Falta decidir o que fazer com um pagamento atrasado de uma competência já fechada: travar, ou lançar no primeiro mês aberto.
- **A carga do Sienge para o núcleo.** Ela vem depois das camadas `sienge_bruto` e `sienge`.

## Próxima versão: decidido, ainda sem código

Decisões do Moises de 08/11/2026, à espera do sinal verde para o código:

- **Contas recorrentes no compromisso.** O `compromissos` ganha o subtipo da assinatura: `servico` (valor mensal, vigência, reajuste, dia de vencimento) ou `consumo` (faixa máxima por mês, teto no ano, número da instalação ou do cliente). Ganha também `gestor_id`, a conta de pagamento padrão (das contas aprovadas do fornecedor), o tipo de documento esperado, as retenções esperadas e o PDF do contrato (em `arquivos`). O modelo tem versão: o cadastro e toda mudança de valor, faixa, conta, retenções ou gestor são aprovados pelo gestor e por AF ou AO, e cada pedido guarda a versão que o montou. Quem mexeu por último no modelo e quem enviou a nota não aprovam aquele pedido.
- **Conferência da nota contra a conta recorrente.** Emitente = fornecedor; tomador = empresa pagadora (de outra SPE, recusa); vigência; mês sem nota; duplicidade pela chave de acesso em todas as empresas; valor: serviço com 0% sobre o valor com reajustes aprovados, consumo dentro da faixa do mês e do teto do ano. Fora disso, exceção com justificativa. A autenticidade da nota (assinatura do XML ou chave conferida na SEFAZ ou na prefeitura) vira um campo; sem ela, conferência humana. A conta de consumo se identifica pelo número da instalação quando a concessionária usa um CNPJ só.
- **Entrada única de notas** (`notas_recebidas`): canal, remetente, arquivo, hash, chave de acesso e situação. O sistema acha a conta recorrente pelo CNPJ do emitente e do tomador (e pela instalação); ambígua vai para o gestor escolher. O rascunho vindo de canal externo fica marcado com o canal e o remetente, quem o envia à aprovação conta como lançador, e o id da mensagem é único (contra repetição).
- **Dados de pagamento da parcela e contas do fornecedor com histórico.** Enquanto os títulos passarem pelo Sienge, o pedido só se conclui com os dados de pagamento aprovados. Trocar a conta do fornecedor é ato aprovado e devolve os títulos abertos dele para aprovação (S-017).
- **Arquivos** (nota, contrato, boleto, comprovante): versão e hash, nunca sobrescritos, com o caminho começando pela empresa e entregues por link assinado de poucos minutos (S-024).
- **Conversas do objeto** (perguntas, respostas, comentários, justificativas), append-only: autor sempre `erp.eu()`, tipo "sistema" só gravado por função, ocultar conteúdo só por exceção com log, e a justificativa de uma decisão fica gravada na própria decisão (S-025).
- **Fica para Suprimentos:** contratos de obra, medições e o casamento da nota com o pedido de compra (itens com saldo, recebimento, conferência de três vias).
- **Plano financeiro em três dimensões** (Moises, 08/11/2026; nomes trocados em 14/11/2026). Cada lançamento leva:
  - **Núcleo econômico** = a SPE ou obra, o Corporativo, uma loja (o que no Sienge é o centro de custo). Já está nas tabelas (`nucleos_economicos`). Falta: a árvore de grupos (estado › cidade › região › obra), com cada núcleo num nó só, para liberar acesso e para relatórios; o tipo de produto é coluna de filtro, não grupo.
  - **Centro de custo** = a área de apropriação (Marketing, Terreno, Incorporação, Obra, Assistência técnica...). Já está nas tabelas: lista raiz única, ligada ou desligada em cada núcleo (`centros_custo`, `nucleo_centros`). Falta: a hierarquia sem limite fixo de níveis (até a menor unidade com orçamento próprio, não o organograma), com lista nominal de aprovadores por nó e quantos dela precisam aprovar (de 1 ao tamanho da lista); a mesma pessoa não conta em dois níveis do mesmo pedido.
  - **Natureza** = só o tipo do gasto (pessoal, malote, assinatura, consultoria...), um plano único que não se repete por centro de custo.
  - **Fase** = coluna de relatório tirada do núcleo e da data; não entra no acesso nem na aprovação e ninguém a escolhe.
  - Travas, alçadas, aprovações e permissão de lançamento nas três dimensões: núcleo, centro de custo e natureza (a permissão por natureza é nova, de 14/11). Herança para baixo nas árvores e "todos" (que inclui itens futuros, avisado na tela e na revisão trimestral). A natureza PJ fica fora de qualquer combinação; checagem única na função de acesso, com teste. Total soma só o que a pessoa vê. Ainda sem código: entra com o motor de aprovação.
  - Sem ciclo nas árvores (constraint + teste); mover núcleo ou centro na árvore, ligar ou desligar centro num núcleo e mudar atributo que define grupo são atos aprovados e registrados (S-028).
