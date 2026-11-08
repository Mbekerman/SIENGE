# Aprovações e alçadas

[← Sumário](../README.md)

⏳ **Sessão em andamento** (começou em 7/nov/2026). O Moises pediu que a aprovação seja "amplamente discutida", com várias camadas, alçadas e regras. Nada disso tem tela ainda.

## O que entra agora

✅ **Decidido** (Moises, 7/nov/2026): por ora a aprovação cobre **só o financeiro**:

- a nota ou o título, antes de virar dívida;
- o pagamento ou o lote que vai ao banco;
- o adiantamento e a liberação de caução;
- o orçamento (versão aprovada e reprojeções).

Compras (requisição, cotação, pedido e contrato) fica para depois, no mesmo mecanismo, sem um segundo sistema de aprovação.

## Os cinco momentos de aprovação

✅ **Decidido** (Moises, 7/nov/2026):

| Momento | Quem aprova |
| --- | --- |
| 1. **Título** (nota lançada) | As regras de aprovação (ver abaixo). É a aprovação principal |
| 2. **Adiantamento sem nota** | O mesmo caminho do título, mais o gestor do contrato |
| 3. **Lote, antes de ir ao Nexxera** | Uma conferência final por uma pessoa diferente de quem montou o lote. Ela não reaprova cada título; confere banco, valores e datas |
| 4. **Liberação de caução** | O gestor do contrato e, acima de certo valor, também as regras gerais |
| 5. **Publicação de versão do orçamento** | Diretoria |

✅ **Quem lança não aprova o próprio lançamento** (Moises, 7/nov/2026). Só a AD pode lançar e aprovar, e isso se configura **pessoa a pessoa**: para cada um da AD, diz-se se pode aprovar o próprio lançamento e se deve sair um aviso quando lançar e aprovar o mesmo item (Moises, 7/nov/2026). O lançamento de quem está na AF ou na AO é aprovado, por padrão, pela AD; é configurável trocar por "a AF aprova o da AO e a AO aprova o da AF" ou por uma terceira pessoa que aprova os dois. ✅ Quem inclui ou tira pessoas da AD é o master, ou um administrador com a aprovação do master (Moises, 7/nov/2026).

⏳ Em aberto: o valor a partir do qual a liberação de caução também passa pelas regras gerais.

## Como uma regra de aprovação funciona

✅ **Decidido** (Moises, 7/nov/2026):

- As regras são **editáveis pela tela**, sem programador, e podem ser dadas por centro de custo, por natureza e por quem paga. Exemplo do Moises: uma regra para marketing, outra para obra, outra para comercial.
- **Hierarquia de regras** (Moises, 7/nov/2026). Cada regra tem um nível:
  1. Regras do **mesmo nível** que se encaixam no lançamento **se somam**, e a mesma pessoa não aprova duas vezes.
  2. Uma regra de **nível superior se sobrepõe** às de nível inferior.
  3. Uma regra **supertrunfo** substitui qualquer outra.
  Qualquer regra, inclusive a superior e a supertrunfo, pode ter quantas camadas se quiser, até menos que as gerais. ✅ Os níveis são configurados pelo master ou por um administrador; a regra **supertrunfo** só é criada e alterada pelo master ou por quem ele der esse poder (Moises, 7/nov/2026).
- **Os aprovadores são pessoas, escolhidas pelo nome** em cada regra, e não um papel ("gestor", "diretor"). Decisão do Moises de 7/nov/2026.
- ✅ As pessoas ficam em **listas nomeadas** (por exemplo, "Aprovador Obras SP", com o João), e cada regra aponta para uma lista. Quando a pessoa sai ou tira férias, edita-se só a lista (Moises, 7/nov/2026). 🟡 Proposto também: um substituto nomeado em cada camada. ✅ **Nomear um substituto é um ato que precisa ser aprovado** (Moises, 7/nov/2026).
- ✅ **Todo aprovador, inclusive os substitutos, é nomeado pelo master ou por um usuário com poder de administrador** (Moises, 7/nov/2026).
- **Título rateado:** cada parte do rateio puxa as suas regras, e o título só fica aprovado quando todas forem cumpridas. Exemplo: um título metade Marketing, metade Obra passa pela regra de marketing e pela de obra. A faixa de valor é conferida também pelo total do lançamento, para o rateio não servir para fugir dela.
- **Cada conta é uma pessoa**, inclusive as duas do Moises (a normal e a master) (Moises, 7/nov/2026).

✅ **Tudo configurável ponto a ponto, regra a regra, pela tela** (Moises, 7/nov/2026): quem aprova, as faixas de valor, a ordem das camadas e se basta um ou precisam todos. Os valores iniciais são definidos na [implantação](https://claude.ai/artifact/2U1u689a7Qi3WAvbZAT6n6). O formato de cada regra:

- Além de centro de custo, natureza e empresa pagadora, a regra pode filtrar por fornecedor, tipo de compromisso e faixa de valor.
- Cada regra tem **camadas de aprovadores em sequência**, e cada camada diz se basta um aprovador ou se precisam todos.
- Exemplos (ilustrativos): "Marketing acima de R$ 10 mil: Fulana (marketing), depois Moises"; "Obra: engenheiro da obra, depois gestor de obras"; "qualquer pagamento acima de R$ 200 mil: mais o diretor financeiro".

### Regra inicial e papéis de exceção

✅ **Ponto de partida de todas as regras** (Moises, 7/nov/2026): aprovam **juntos o gestor da área e o diretor financeiro ou o COO**; ou então **o CEO aprova sozinho**. Hoje o CEO é o Moises. Depois, cada regra pode ser mudada pela tela.

✅ **Gestor da área em níveis** (Moises, 8/nov/2026): as áreas têm até 3 níveis, e cada nível tem de 1 a 3 aprovadores (ver [três eixos](../financeiro/classificacao.md#três-eixos-separados-centro-de-custo-área-e-natureza)). 🟡 Proposta: isso se soma à AF, à AO e à AD, sem substituí-las. ⏳ Em aberto: se o número é de pessoas que **precisam** aprovar ou de pessoas na lista para **qualquer uma** aprovar.

✅ **Diretor financeiro (CFO), COO e CEO são posições no sistema, não cargos** (Moises, 7/nov/2026). Cada posição é uma **lista nomeada**, porque quem ocupa a posição no sistema pode não ter o cargo na empresa:

| Lista | Posição | Para que serve |
| --- | --- | --- |
| **AF** (Aprovação financeira) | a do diretor financeiro (CFO) | Aprova junto com o gestor da área; recebe exceções |
| **AO** (Aprovação operacional) | a do COO | Aprova junto com o gestor da área; recebe exceções |
| **AD** (Aprovação definitiva) | a do CEO, hoje o Moises; pode ter mais de uma pessoa | Aprova sozinho; última instância |

Essas listas cuidam das **exceções**: férias sem substituto, demora na aprovação e casos parecidos.

✅ **Pedido parado** (Moises, 7/nov/2026):

- Os **lembretes são automações configuráveis**: notificação, e-mail, aviso a outras pessoas. O primeiro sai, por padrão, no **3º dia** sem resposta.
- Depois de **7 dias corridos** (prazo configurável), **só a camada parada** pode ser decidida por alguém da AF, da AO ou da AD. Esperar não serve para pular as outras camadas, e quem lançou nunca decide.
- O aprovador original continua podendo aprovar até alguém decidir.
- **A AD pode aprovar sozinha a qualquer momento**, sem esperar o prazo.
- O prazo pode ser diferente em cada camada; a exceção pede justificativa; o aprovador que foi passado para trás recebe aviso.

✅ **Camadas com quantos aprovadores quiser** (Moises, 7/nov/2026): uma camada pode ter 2 aprovadores ou mais, e a regra diz se eles precisam seguir uma ordem ou não. A AD pode entrar na sequência como última instância.

✅ **Quando o gestor da área também está na AF** (Moises, 7/nov/2026): ao colocar a pessoa na AF, o sistema percebe o conflito e pergunta se ela aprova sozinha nesses casos ou se outra pessoa aprova junto, e quem.

✅ **Pagamento que não se encaixa em nenhuma regra** (Moises, 7/nov/2026):

- Vai para a posição do COO sozinha, para a do CFO sozinha ou para as duas juntas. A escolha é uma configuração.
- Se uma das duas listas estiver vazia, vai só para a outra. Se as duas estiverem vazias, vai para o CEO.
- Chega com o aviso **"sem regra"**, para quem recebe analisar e, se for o caso, transformar o caso em regra e atribuir o aprovador.
- Nenhum pagamento sai sem aprovação por falta de regra.

✅ **Substitutos: tudo configurável** (Moises, 7/nov/2026):

- A vigência (início e fim), o que acontece quando o aprovador sai da empresa, se a troca vale só para pedidos novos e quem cobre a vez enquanto a nomeação espera aprovação.
- Quem aprova a nomeação e quem cobre a vez: AF, AO, AD, o master ou alguém que o master designar, combinados como se quiser (por exemplo, AF e AO juntos ou separados).
- O substituto nunca é quem lançou o item (trava fixa).

### Tarefa: criar uma regra de aprovação

> ⏳ As telas ainda não existem. A configuração é do master e dos administradores; a supertrunfo, só do master ou de quem ele autorizar.

1. Abra **Configurações › Aprovação › Regras** e clique em **Nova regra**.
2. Escolha o **momento**: título, adiantamento sem nota, lote, liberação de caução ou orçamento.
3. Dê um nome (por exemplo, "Marketing acima de R$ 10 mil").
4. Em **Condições**, escolha o que a regra pega. Todas são opcionais: empresa pagadora, centro de custo, galho da natureza (vale para tudo abaixo dele), fornecedor, tipo de compromisso e faixa de valor.
5. Em **Camadas**, inclua a primeira camada: escolha a lista de aprovadores e se basta um ou precisam todos.
6. Se houver mais camadas, inclua na ordem em que devem aprovar.
7. Escolha o **nível**: comum (soma com as do mesmo nível), superior (se sobrepõe às de nível inferior) ou supertrunfo (substitui qualquer outra).
8. Salve. A regra vale para os pedidos novos.

**O que o sistema confere:** a regra precisa ter pelo menos uma camada; quem lança não aprova o próprio lançamento, salvo a AD.

**Se nenhuma regra pegar o item:** ele vai para as posições de exceção com o aviso "sem regra" (ver [Regra inicial e papéis de exceção](#regra-inicial-e-papéis-de-exceção)).

### Limites do administrador

✅ **Decidido** (Moises, 7/nov/2026):

1. O administrador **não pode se colocar** numa lista de aprovadores nem se nomear substituto.
2. O administrador **não pode mudar uma lista da qual faz parte**.
3. **Só o master dá e tira** o poder de administrador.
4. **A cada trimestre, o master revisa** as listas de aprovadores e quem é administrador (Moises, 7/nov/2026; antes era mensal).

### Tarefa: trocar o aprovador de uma lista

> ⏳ As telas ainda não existem.

1. Abra **Configurações › Aprovação › Listas de aprovadores**.
2. Abra a lista (por exemplo, "Aprovador Obras SP").
3. Tire a pessoa que sai e inclua a nova. Só o master ou um administrador pode fazer isso.
4. Salve. Todas as regras que apontam para essa lista passam a usar a pessoa nova.

### Exemplo de soma

Um gasto de marketing de R$ 300 mil, com as regras acima, passa pelo gestor de marketing, pela diretoria e pelo diretor financeiro. Se o diretor financeiro também estiver na diretoria, ele aprova uma vez só.

## Pagamento de funcionários PJ

✅ **Já vale agora, com o Sienge** (Moises, 7/nov/2026): os títulos dos fornecedores PJ copiados do Sienge ficam numa **área restrita** do ERP BKM. Relatórios e BI mostram só a soma por centro de custo e mês, sem valor por pessoa. Os centros de custo pequenos **não** são juntados (Moises, 7/nov/2026). Consequência: num centro de custo com um PJ só, a soma do mês é o valor dele. No próprio Sienge, nome e valor continuam visíveis.

✅ O pagamento dos PJ **não tem aprovação própria**: a aprovação são os dois "ok" do mês sobre as tabelas (Moises, 7/nov/2026).

> 🔜 **Futuro.** Os pagamentos PJ ainda passam pelo Sienge, e a remessa e o extrato vão pelo Nexxera (Moises, 7/nov/2026). Enquanto for assim, o nome e o valor de cada PJ continuam visíveis no Sienge, e **todo o fluxo abaixo (anonimização, conferência com dois "ok", portal de notas e portal do contador) fica para quando o Sienge sair desse fluxo**. Ver [O que ainda é feito à mão no Sienge](passos-manuais-no-sienge.md). A conciliação automática depende do módulo de Bancos, que não foi desenhado.

**Para que serve:** pagar os funcionários contratados como PJ mantendo o valor de cada um o mais anônimo possível.

✅ **Pedido e decisões do Moises** (7/nov/2026):

- O **RH** mantém, no portal dele, quem está ativo, o controle dos benefícios e **qual SPE paga cada funcionário em cada mês**.
- Uma **tabela de remuneração**, à parte, guarda o valor de cada um "a 7 chaves".
- O **financeiro** vê só um pseudônimo (por exemplo, "PJ-017") e o valor a pagar, nunca o nome.
- O funcionário sobe a nota num **portal**; se tudo bate com as duas tabelas, ela segue direto para pagamento.
- O RH pode **dividir o pagamento de um funcionário entre SPEs ou centros de custo**, em percentuais, no mês (Moises, 7/nov/2026). O PJ emite uma nota para cada SPE. Ao receber cada nota, o sistema confere o CNPJ da SPE, o percentual e o valor contra o cadastro do RH daquele mês, e **trava o pagamento** se algo divergir.
- **Todo mês, as duas tabelas são conferidas.** Se um dos dois responsáveis não der o "ok" do mês, **ninguém recebe**.
- Os dois responsáveis e os **substitutos temporários** de cada um são definidos na própria plataforma.
- Existe **um único usuário master, o Moises** (com uma conta própria de master, separada da conta do dia a dia). Ele vê tudo, pode trocar o aprovador e pode aprovar tudo, inclusive os dois "ok" do mês.
- **Qualquer mudança de remuneração** de um PJ passa por aprovadores definidos (Moises, 7/nov/2026).
- A folha PJ entra no financeiro, nos relatórios e no BI **somada por centro de custo e por mês**, sem valor por pessoa. O detalhe fica só na área restrita.
- As **notas dos PJ ficam guardadas na área restrita** ("a 7 chaves") e vão direto ao contador. O contador também tem um **portal** para baixá-las. ✅ O contador entra nesse portal com um login próprio, fora do Google (Moises, 7/nov/2026).

🟡 **Propostas** ainda sem resposta (7/nov/2026):

- Conciliação automática: o extrato vem direto do banco e, antes de qualquer pessoa ver, os dados do PJ são trocados pelo pseudônimo. O Moises sugeriu a ideia; o desenho depende do módulo de Bancos.
- O pseudônimo é um código aleatório, e não um "hash" do CPF, que se descobre testando todos os CPFs.
- Ninguém do financeiro digita o Pix nem entra no internet banking da conta usada para os PJ, que seria uma conta separada; o lote vai ao banco pela integração.
- Toda leitura do master fica registrada. (A sugestão de dois masters foi recusada: o master é só o Moises.)
- Aviso aos responsáveis alguns dias antes do vencimento.
- A chave Pix não aparece para o financeiro: ela só é buscada na hora de mandar o pagamento ao banco.
- O portal do contador tem login próprio, mostra só as notas e registra cada download.

**O que não dá para garantir:** o anonimato total. A chave Pix, o extrato e o comprovante do banco e a nota que vai ao contador identificam a pessoa. O que o sistema garante é que quase ninguém veja, e que toda leitura fique registrada.

⚠️ **Ponto levantado e sem resposta:** registrar benefícios de PJ no sistema pode servir de prova de vínculo empregatício. A sugestão é passar o desenho pelo jurídico antes.

### Tarefa: conferir e liberar o pagamento dos PJ do mês

> ⏳ As telas ainda não existem.

1. **Responsável do RH:** abra **Pessoal › Conferência do mês**, confira quem está ativo, os benefícios e qual SPE paga cada um neste mês, e clique em **Dar ok**.
2. **Responsável pela remuneração:** abra a mesma tela, confira os valores e clique em **Dar ok**.
3. Com os dois "ok", as notas que os PJ subiram no portal e que batem com as tabelas seguem para pagamento.
4. **Financeiro:** vê os pagamentos só pelo pseudônimo e o valor.
5. **Contador:** recebe as notas e, se precisar, baixa pelo portal dele.

**Se der errado:** se um responsável estiver ausente, o substituto temporário dá o "ok". Se nenhum dos dois puder, o master pode aprovar ou trocar o aprovador.

## Outras regras já decididas

- ✅ A aprovação será um **módulo único**, usado por todos os outros (contrato, medição, nota, pagamento, caução, reclassificação), e não uma regra espalhada em cada tela (7/nov/2026).
- ✅ As regras podem ser dadas sobre **qualquer combinação de classificações**, e a regra num galho vale para tudo abaixo dele. Exemplos (7/nov/2026):
  - "Comerciais › Marketing, em qualquer empreendimento, acima de R$ 20 mil: aprova o diretor comercial."
  - "Empreendimento Vila Maria, qualquer natureza: aprova o gestor da obra."
- ✅ O mesmo mecanismo serve para **restringir quem vê**: "Gerais › Pessoal › Folha: só RH e diretoria"; "o sócio externo da SPE X só vê a SPE X".
- ✅ A medição continua com a aprovação de **2 gestores**, que passa a ser feita no ERP BKM (processo atual da BKM, 6/nov/2026).
- ✅ Alçadas de reclassificação: idade × valor × acumulado no mês, vale a mais alta (ver [Reclassificação](../financeiro/reclassificacao-e-fechamento.md)).
- 🟡 A autorização de pagamento no Sienge continua como o último clique do financeiro, porque não tem API; a aprovação de verdade acontece no ERP BKM.

## Papéis previstos

✅ **Usuário master** (Moises, 7/nov/2026): existe um só, o Moises, que pode ver e aprovar tudo. Ele terá **duas contas**: uma normal, para o dia a dia, e uma de master, usada só quando precisar desse poder.

🟡 Pelo banco de dados de 7/nov/2026: diretor, gestor, analista e leitura; à parte, administrador (configuração) e contador (vota nas alçadas que pedem o contador). Segue o modelo do BKM Terrenos, com hierarquia analista → gestor → diretor.

## Pagamento com multa ou juros

✅ **Decidido** (Moises, 7/nov/2026): pagar com multa ou juros é "falha grave, desperdício por desorganização". Por isso, **o título com multa ou juros precisa de uma aprovação específica**, somada às regras normais, de uma pessoa definida pelo administrador. Por padrão, essa pessoa é a AD.

✅ Também confirmados (Moises, 8/nov/2026, "Concordo"):

- Tolerância zero: um centavo de multa ou juros já pede essa aprovação.
- Vale também para o título já vencido, mesmo quando a multa só aparece no banco; sem isso, o boleto vencido passaria pelo lote sem a aprovação extra.
- O motivo do atraso é obrigatório.
- Um relatório mensal mostra a multa e os juros pagos por área e por responsável.

## Travas fixas

✅ **Confirmadas pelo Moises** no [documento de desenho das aprovações](https://claude.ai/artifact/FvkBaLmYig68zstJzTKFwP) (7/nov/2026). Ficam no banco de dados, e **nenhuma tela as desliga**, nem a do master:

1. Quem lança não aprova, salvo a pessoa da AD que o master autorizou.
2. Nas camadas em conjunto, cada camada tem uma pessoa diferente, salvo a exceção "gestor da área também na AF ou na AO" escolhida na configuração.
3. O administrador não se nomeia aprovador nem substituto.
4. O substituto não é quem lançou.
5. A aprovação vale só para o que foi aprovado, **inclusive a conta bancária e o PIX do fornecedor**. Se o título, os dados bancários ou o arquivo do lote mudarem depois, é preciso aprovar de novo.
6. **Trocar os dados bancários de um fornecedor** é um ato que outra pessoa aprova. O fornecedor é avisado pelo contato que já estava cadastrado, e os títulos abertos dele voltam para aprovação. (É o golpe mais comum: um e-mail falso pedindo a troca da conta.)
7. O lote só aceita título aprovado e sem nenhuma mudança depois da aprovação.
8. Todo pagamento tem pelo menos uma aprovação. No PJ, a aprovação são os dois "ok" do mês.
9. Toda mudança de configuração fica registrada.

## Quem muda a configuração

- ✅ **Listas AF e AO:** qualquer pessoa da AD pode mexer, menos numa lista da qual ela mesma faça parte. Toda mudança avisa o master e as outras pessoas da AD (Moises, 7/nov/2026).
- ✅ **Prazos e opções** (demora, lembretes, destino do "sem regra", prazo da nota do adiantamento): o master ou um administrador (Moises, 7/nov/2026).
- ✅ **Lista AD:** o master, ou um administrador com a aprovação do master.
- ✅ **Mudanças de configuração** valem só para os pedidos novos e avisam o master. As que afrouxam o controle (menos camadas, faixa maior, tirar uma natureza da aprovação) precisam do master. A tela mostra o efeito antes de salvar (Moises, 7/nov/2026).
- ✅ **Duas alçadas de valor**, ambas configuráveis: o valor da operação e o acumulado no mês (Moises, 7/nov/2026).

✅ Também confirmados no documento de desenho (7/nov/2026): as duas opções de cada pessoa da AD só o master muda, e todo lançamento aprovado por quem o lançou fica marcado e entra na revisão do master; um relatório mostra os pagamentos que caíram em "sem regra"; no lote, a conferência grava a "impressão digital" do arquivo, para saber se ele mudou.

## Remuneração variável (comissões, prêmios, sorteios)

✅ **Decidido** (Moises, 7/nov/2026, no documento de desenho). O caminho do pagamento depende de **quem recebe**:

| Quem recebe | Como se paga |
| --- | --- |
| Funcionário CLT | Pela folha, com imposto retido. Nunca por PIX direto da conta da empresa |
| PJ | Entra no valor do mês, coberto pela nota |
| Corretor autônomo | Por RPA, com as retenções |
| Imobiliária | Com nota fiscal |

- Cada **campanha** (de meta, de vendas, de evento) é cadastrada antes, com o orçamento aprovado pelas regras.
- Paga-se **só a pessoas cadastradas**, nunca a uma chave PIX solta. Pelo vínculo da pessoa, o sistema escolhe o caminho da tabela.
- Um relatório mostra quanto cada pessoa recebeu no mês.
- 🟡 Para prêmio pequeno em evento, uma alternativa é vale-presente comprado com nota. A forma de cada caso, e as regras de sorteio, o contador confirma.

## O que falta decidir

- Se o Nexxera ou o banco exigem assinatura eletrônica da remessa, de quem e quantas (pergunta ao financeiro).
- As faixas de valor de cada regra ficam para a [implantação](https://claude.ai/artifact/2U1u689a7Qi3WAvbZAT6n6).
- As avaliações e a aprovação para liberar caução.
- Alçadas de pagamento.
