# Registro de decisões

[← Sumário](README.md)

Decisões do Moises que valem como regra do sistema, da mais recente para a mais antiga. Propostas ainda não confirmadas não entram aqui; ficam marcadas 🟡 nas páginas.

| Data | Decisão | Página |
| --- | --- | --- |
| 8/nov/2026 | Telas v18 do contas a pagar (protótipo): Pedidos com as abas Pedidos, Contas recorrentes, No Sienge e Campanhas; Novo pedido com retenções e líquido, centro, área e natureza separados, rateio e trava do PIX importado não conferido; Adiantamento sem nota; ficha do pedido; Nova conta recorrente. Justificativa para trocar área ou natureza e a aba Campanhas ainda são propostas | [Contas a pagar](financeiro/contas-a-pagar.md#as-telas-do-pedido-de-pagamento) |
| 8/nov/2026 | Três classificações: centro de custo (a obra ou Corporativo, em árvore estado › cidade › região › obra, cada obra num lugar só), área (quem gasta; árvore livre, cada nó com aprovadores nominais e quantos precisam aprovar) e natureza (só o tipo de gasto). Fase calculada sozinha, só para relatório. Acesso = Área × Centro, com herança para baixo. Mover obra ou área na árvore exige aprovação | [Classificação](financeiro/classificacao.md#três-classificações-centro-de-custo-área-e-natureza) |
| 8/nov/2026 | ~~Três eixos com áreas em até 3 níveis e acesso Área × Centro × Fase~~ (substituído às 21h21). Power BI não fica nem como ponte | [Relatórios](transversais/relatorios-e-bi.md#relatórios-dentro-do-sistema) |
| 8/nov/2026 | Contas recorrentes entram já na primeira etapa: contrato de serviço e conta de consumo, cada uma com caixa no Início; o sistema confere emitente, tomador, vigência, mês sem nota e valor, e o que não bate vira exceção com justificativa; cadastro aprovado pelo gestor e por AF ou AO, com nova aprovação ao trocar PIX, conta, valor ou faixa; quem arrastou a nota e quem mexeu por último no cadastro não aprovam; contratos de obra ficam para Suprimentos | [Contas a pagar](financeiro/contas-a-pagar.md#contas-recorrentes-os-dois-tipos) |
| 8/nov/2026 | Caixa única "Solte aqui as notas do mês" no Início: várias notas de uma vez, contrato achado pelo CNPJ do emitente e do tomador (desempate por serviço, texto e valor); "Enviar as N" manda só as prontas; sem contrato vira rascunho de Novo pedido. Recebimento por WhatsApp ainda é proposta | [Contas a pagar](financeiro/contas-a-pagar.md#tarefa-enviar-várias-notas-do-mês-de-uma-vez) |
| 8/nov/2026 | Início com "Contratos recorrentes": arrastar a nota do mês para a caixa do contrato abre "Conferir e enviar" já preenchido | [Contas a pagar](financeiro/contas-a-pagar.md#tarefa-enviar-a-nota-de-um-contrato-recorrente) |
| 8/nov/2026 | Conversa do título: linha do tempo com perguntas e respostas, "Perguntar sobre isto" em cada nível, @ para quem responde | [Contas a pagar](financeiro/contas-a-pagar.md#conversar-sobre-o-título) |
| 8/nov/2026 | O aprovador navega do título até a origem (nota, contrato, previsão, orçamento, adiantamento, aprovações) só com cliques; agente de recomendação por título é futuro | [Contas a pagar](financeiro/contas-a-pagar.md#ver-o-que-está-por-trás-do-título) |
| 8/nov/2026 | Linha de telas F para o ERP; todas as telas com bastante área branca e respiro | [Contas a pagar](financeiro/contas-a-pagar.md#as-telas-do-pedido-de-pagamento) |
| 8/nov/2026 | Relatórios e gráficos no próprio sistema, sem Power BI; acesso liberado por pessoa ou grupo; folha PJ só por centro de custo; datas e horas no horário de São Paulo | [Relatórios](transversais/relatorios-e-bi.md#relatórios-dentro-do-sistema) |
| 8/nov/2026 | Controle de prazos (SLA) do pagamento: antecedência da postagem e tempo de cada etapa | [Relatórios](transversais/relatorios-e-bi.md#controle-de-prazos-do-pagamento-sla) |
| 8/nov/2026 | Atributos do empreendimento: visão padrão a de hoje, mais a foto de cada mês para comparar | [Relatórios](transversais/relatorios-e-bi.md#atributos-dos-empreendimentos-nos-relatórios) |
| 8/nov/2026 | Pedido de pagamento só se conclui com os dados de pagamento completos e aprovados; título vai ao Sienge pela API, completo; conferência nos dois sentidos | [Contas a pagar](financeiro/contas-a-pagar.md#primeira-etapa-da-implantação-o-pedido-de-pagamento) |
| 8/nov/2026 | Medições de obra paradas até a fase de suprimentos (substitui o escopo inicial de 6/nov) | [Contratos e medições](suprimentos/contratos-e-medicoes.md) |
| 8/nov/2026 | Primeira etapa da implantação: obra fora; demais departamentos no ERP até a nota; pedido de pagamento cria o título no Sienge; pagamento segue no Sienge; ERP lê de volta; conferência automática e manual; relatório para cada pessoa | [Contas a pagar](financeiro/contas-a-pagar.md#primeira-etapa-da-implantação-o-pedido-de-pagamento) |
| 8/nov/2026 | Multa e juros: tolerância zero, vale para título vencido, motivo obrigatório, relatório mensal por área e responsável | [Aprovações](transversais/aprovacoes.md#pagamento-com-multa-ou-juros) |
| 7/nov/2026 | Título com multa ou juros precisa de aprovação específica, somada às normais, de pessoa definida pelo admin (padrão: a AD) | [Aprovações](transversais/aprovacoes.md#pagamento-com-multa-ou-juros) |
| 7/nov/2026 | Níveis das regras configurados pelo master ou admin; supertrunfo só pelo master ou por quem ele autorizar | [Aprovações](transversais/aprovacoes.md#como-uma-regra-de-aprovação-funciona) |
| 7/nov/2026 | Hierarquia de regras: mesmo nível soma, nível superior se sobrepõe, supertrunfo substitui; qualquer número de camadas | [Aprovações](transversais/aprovacoes.md#como-uma-regra-de-aprovação-funciona) |
| 7/nov/2026 | Cada conta conta como uma pessoa, inclusive as duas do Moises | [Aprovações](transversais/aprovacoes.md#como-uma-regra-de-aprovação-funciona) |
| 7/nov/2026 | Substitutos: vigência, saída da empresa, quem aprova a nomeação e quem cobre a vez, tudo configurável | [Aprovações](transversais/aprovacoes.md#regra-inicial-e-papéis-de-exceção) |
| 7/nov/2026 | AD não edita lista AF ou AO de que faz parte; toda mudança avisa o master e a AD; prazos e opções pelo master ou admin | [Aprovações](transversais/aprovacoes.md#quem-muda-a-configuração) |
| 7/nov/2026 | Remuneração variável pelo caminho de quem recebe (CLT folha, PJ nota, autônomo RPA, imobiliária nota); campanha cadastrada antes; só pessoas cadastradas | [Aprovações](transversais/aprovacoes.md#remuneração-variável-comissões-prêmios-sorteios) |
| 7/nov/2026 | PJ (futuro): toda mudança de remuneração passa por aprovadores definidos | [Aprovações](transversais/aprovacoes.md#pagamento-de-funcionários-pj) |
| 7/nov/2026 | Faixas iniciais e configuração inicial ficam num documento de implantação separado do manual | [Como atualizar](COMO-ATUALIZAR.md) |
| 7/nov/2026 | AF = Aprovação financeira, AO = Aprovação operacional; contador entra no portal com login fora do Google | [Aprovações](transversais/aprovacoes.md#regra-inicial-e-papéis-de-exceção) |
| 7/nov/2026 | Travas fixas confirmadas, sem tela que as desligue; dados bancários e PIX do fornecedor fazem parte do aprovado, e a troca deles precisa de aprovação | [Aprovações](transversais/aprovacoes.md#travas-fixas) |
| 7/nov/2026 | Lembretes por automações configuráveis; escalada depois de 7 dias corridos, só da camada parada; a AD aprova sozinha a qualquer momento | [Aprovações](transversais/aprovacoes.md#regra-inicial-e-papéis-de-exceção) |
| 7/nov/2026 | Qualquer pessoa da AD edita as listas AF e AO; revisão das listas e dos admins passa a ser trimestral | [Aprovações](transversais/aprovacoes.md#quem-muda-a-configuração) |
| 7/nov/2026 | Mudança de configuração vale para pedidos novos; a que afrouxa o controle precisa do master | [Aprovações](transversais/aprovacoes.md#quem-muda-a-configuração) |
| 7/nov/2026 | Duas alçadas de valor configuráveis: valor da operação e acumulado no mês | [Aprovações](transversais/aprovacoes.md#quem-muda-a-configuração) |
| 7/nov/2026 | Adiantamento sem nota: novo adiantamento só com aprovação da AD; título do fornecedor só é pago deduzindo o adiantamento em aberto, salvo AD; aviso no vencimento do prazo | [Contas a pagar](financeiro/contas-a-pagar.md#adiantamento-sem-nota-prazo-e-travas) |
| 7/nov/2026 | PJ (futuro): o pagamento pode ser dividido por SPE ou por centro de custo | [Aprovações](transversais/aprovacoes.md#pagamento-de-funcionários-pj) |
| 7/nov/2026 | PJ (futuro): se mudar a remuneração exige aval de outra pessoa é configurável | [Aprovações](transversais/aprovacoes.md#pagamento-de-funcionários-pj) |
| 7/nov/2026 | AD: cada pessoa configurada se pode aprovar o próprio lançamento e se gera aviso; a lista AD só muda pelo master, ou por admin com aprovação do master | [Aprovações](transversais/aprovacoes.md#os-cinco-momentos-de-aprovação) |
| 7/nov/2026 | Listas de exceção chamam-se AF, AO e AD (Aprovação definitiva) | [Aprovações](transversais/aprovacoes.md#regra-inicial-e-papéis-de-exceção) |
| 7/nov/2026 | Pedido parado: prazo configurável, 7 dias de início; e-mail e notificação no 3º dia | [Aprovações](transversais/aprovacoes.md#regra-inicial-e-papéis-de-exceção) |
| 7/nov/2026 | Só a AD lança e aprova; o lançamento da AF e da AO é aprovado pela AD por padrão (configurável: uma aprova a outra, ou um terceiro); a AD pode ter mais de uma pessoa | [Aprovações](transversais/aprovacoes.md#os-cinco-momentos-de-aprovação) |
| 7/nov/2026 | Camadas com 2 ou mais aprovadores, em sequência ou não; AD pode ser a última instância | [Aprovações](transversais/aprovacoes.md#regra-inicial-e-papéis-de-exceção) |
| 7/nov/2026 | Gestor da área que está na AF: o sistema avisa e pergunta se aprova sozinho ou com outra pessoa | [Aprovações](transversais/aprovacoes.md#regra-inicial-e-papéis-de-exceção) |
| 7/nov/2026 | Pagamento sem regra vai para COO, CFO ou os dois (configurável); lista vazia passa para a outra; nenhuma, para o CEO; chega com aviso "sem regra" | [Aprovações](transversais/aprovacoes.md#regra-inicial-e-papéis-de-exceção) |
| 7/nov/2026 | CFO, COO e CEO são posições do sistema em listas nomeadas, com nomes neutros, para exceções (férias sem substituto, demora) | [Aprovações](transversais/aprovacoes.md#regra-inicial-e-papéis-de-exceção) |
| 7/nov/2026 | Regra inicial: gestor da área junto com CFO ou COO, ou o CEO sozinho | [Aprovações](transversais/aprovacoes.md#regra-inicial-e-papéis-de-exceção) |
| 7/nov/2026 | Aprovadores, faixas de valor, ordem das camadas e "um ou todos" configuráveis ponto a ponto, regra a regra | [Aprovações](transversais/aprovacoes.md#tarefa-criar-uma-regra-de-aprovação) |
| 7/nov/2026 | Limites do administrador: não se põe em lista nem como substituto, não muda lista de que faz parte; só o master dá e tira o poder de admin; revisão pelo master (hoje trimestral) | [Aprovações](transversais/aprovacoes.md#limites-do-administrador) |
| 7/nov/2026 | Fornecedor com adiantamento sem nota não recebe nenhum adiantamento novo (substituída: agora só com aprovação da AD) | [Contas a pagar](financeiro/contas-a-pagar.md#adiantamento-sem-nota-prazo-e-travas) |
| 7/nov/2026 | Prazo para a nota do adiantamento chegar: 30 dias por padrão, configurável pelo master ou administrador | [Contas a pagar](financeiro/contas-a-pagar.md#adiantamento-sem-nota-prazo-e-travas) |
| 7/nov/2026 | Todo aprovador e substituto é nomeado pelo master ou por um administrador | [Aprovações](transversais/aprovacoes.md) |
| 7/nov/2026 | Nomear substituto de aprovador precisa de aprovação | [Aprovações](transversais/aprovacoes.md) |
| 7/nov/2026 | Aprovadores em listas nomeadas; a regra aponta para a lista | [Aprovações](transversais/aprovacoes.md) |
| 7/nov/2026 | Cinco momentos de aprovação no financeiro (título, adiantamento sem nota, lote antes do Nexxera, liberação de caução, versão do orçamento); quem lança nunca aprova o próprio lançamento | [Aprovações](transversais/aprovacoes.md#os-cinco-momentos-de-aprovação) |
| 7/nov/2026 | Cada regra de aprovação define os aprovadores pelo nome da pessoa, não por papel | [Aprovações](transversais/aprovacoes.md) |
| 7/nov/2026 | O Moises terá duas contas: uma normal e uma de master | [Aprovações](transversais/aprovacoes.md#papéis-previstos) |
| 7/nov/2026 | Um único usuário master, o Moises, que pode aprovar tudo, inclusive os dois "ok" da folha PJ | [Aprovações](transversais/aprovacoes.md#pagamento-de-funcionários-pj) |
| 7/nov/2026 | PJ (futuro): ao receber a nota, o sistema confere SPE, percentual e valor contra o cadastro mensal do RH; títulos PJ em área restrita | [Aprovações](transversais/aprovacoes.md#pagamento-de-funcionários-pj) |
| 7/nov/2026 | PJ (futuro): o portal do RH guarda também qual SPE paga cada funcionário em cada mês | [Aprovações](transversais/aprovacoes.md#pagamento-de-funcionários-pj) |
| 7/nov/2026 | Pagamentos PJ seguem pelo Sienge e pelo Nexxera; a anonimização só vale depois de tirar o Sienge desse fluxo | [Aprovações](transversais/aprovacoes.md#pagamento-de-funcionários-pj) |
| 7/nov/2026 | PJ: folha somada por centro de custo e mês no financeiro e no BI; notas na área restrita, direto ao contador, com portal para ele baixar | [Aprovações](transversais/aprovacoes.md#pagamento-de-funcionários-pj) |
| 7/nov/2026 | PJ: RH controla ativos e benefícios, remuneração em tabela restrita, financeiro só vê pseudônimo, Pix e valor; sem os dois "ok" do mês ninguém recebe; responsáveis e substitutos definidos na plataforma; o master vê tudo, troca o aprovador e aprova | [Aprovações](transversais/aprovacoes.md#pagamento-de-funcionários-pj) |
| 7/nov/2026 | Aprovação por ora só no financeiro (nota/título, pagamento/lote, adiantamento, caução, orçamento); compras depois, no mesmo mecanismo | [Aprovações](transversais/aprovacoes.md) |
| 7/nov/2026 | Regras de aprovação editáveis pela tela, por centro de custo, natureza e quem paga; várias regras se somam (salvo "substitui as gerais"); no título rateado, cada parte puxa as suas | [Aprovações](transversais/aprovacoes.md) |
| 7/nov/2026 | Toda tela nova ou alterada avisa a manutenção do manual, para o passo a passo e as imagens serem atualizados | [Como atualizar](COMO-ATUALIZAR.md) |
| 7/nov/2026 | O manual é passo a passo, com o que dá e o que não dá para fazer, e serve de roteiro para vídeos | [Sumário](README.md) |
| 7/nov/2026 | Pessoa única com vários papéis (fornecedor, cliente, sócio, corretor, funcionário) | [Pessoas](cadastros/pessoas.md) |
| 7/nov/2026 | Estágios do livro: orçado, previsto, comprometido e realizado | [Orçamento](financeiro/orcamento-e-fluxo-de-caixa.md) |
| 7/nov/2026 | Topo da árvore de naturezas igual ao da viabilidade, e também editável | [Classificação](financeiro/classificacao.md) |
| 7/nov/2026 | Gasto anterior à SPE pode virar aporte, integralização ou mútuo | [Dinheiro entre sócios](financeiro/dinheiro-entre-socios.md) |
| 7/nov/2026 | Alçadas de reclassificação: idade (mês, trimestre do calendário, depois), valor e acumulado da pessoa no mês (soma absoluta); vale a mais alta | [Reclassificação](financeiro/reclassificacao-e-fechamento.md) |
| 7/nov/2026 | Toda reclassificação tem aval; o sistema terá fechamento de mês | [Reclassificação](financeiro/reclassificacao-e-fechamento.md) |
| 7/nov/2026 | Página de reclassificação em lote, com prévia do impacto, orçado junto e histórico; natureza vazia pode ser apagada | [Reclassificação](financeiro/reclassificacao-e-fechamento.md) |
| 7/nov/2026 | Árvore de naturezas dinâmica, criada do zero, novas naturezas pela tela | [Classificação](financeiro/classificacao.md) |
| 7/nov/2026 | Tipo (operacional, não operacional, movimentação), linha da DRE e do fluxo de caixa são características da natureza | [Classificação](financeiro/classificacao.md) |
| 7/nov/2026 | Atributos de BI (cidade, praça, faixa MCMV...) no cadastro do empreendimento, com histórico, mostrados por visão (em 8/nov: padrão a visão de hoje, mais a foto de cada mês) | [Relatórios](transversais/relatorios-e-bi.md) |
| 7/nov/2026 | Classificação por dimensões independentes (empresa/centro de custo, natureza, datas, fase, departamento) e livro único, com rateio | [Classificação](financeiro/classificacao.md) |
| 7/nov/2026 | O sistema cuida do dinheiro entre sócios, em pares ligados | [Dinheiro entre sócios](financeiro/dinheiro-entre-socios.md) |
| 7/nov/2026 | 1 empreendimento = 1 SPE; uma lista de empresas com participações; SPE e empreendimento separados | [Empresas](cadastros/empresas-e-empreendimentos.md) |
| 7/nov/2026 | Compromisso, previsão, título e fluxo de caixa separados; assinatura recorrente no lugar do contrato fictício | [Contas a pagar](financeiro/contas-a-pagar.md) |
| 7/nov/2026 | Caução em extrato por contrato; padrão do contrato, alterável na nota; liberação parcial pelo gestor; pode pagar terceiro | [Caução](financeiro/caucao.md) |
| 7/nov/2026 | Juros, multa e desconto na quitação; retenções e caução na nota | [Contas a pagar](financeiro/contas-a-pagar.md) |
| 7/nov/2026 | Pagamento parcial e adiantamento abatido aos poucos; pagamento separado de quitação | [Contas a pagar](financeiro/contas-a-pagar.md) |
| 6/nov/2026 | Previsões ficam no ERP BKM; título no Sienge só nasce completo (resultado de teste) | [Contas a pagar](financeiro/contas-a-pagar.md) |
| 6/nov/2026 | Contratos novos do dia a dia com item a R$ 1,00 por unidade | [Contratos e medições](suprimentos/contratos-e-medicoes.md) |
| 6/nov/2026 | Escopo inicial: medições mensais sobre contratos criados à mão no Sienge (substituída em 8/nov) | [Contratos e medições](suprimentos/contratos-e-medicoes.md) |
| 6/nov/2026 | Sienge vira o núcleo (financeiro, fiscal, contábil, banco, segurança); banco próprio para todos os sistemas BKM | [Visão geral](00-visao-geral.md) |
