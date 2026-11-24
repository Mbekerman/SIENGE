# Lançar uma nota fiscal para pagamento

[← Sumário](../README.md)

## Como o Moises quer que seja

✅ **Pedido do Moises** (6/nov/2026): a pessoa recebe a nota, entra no sistema, clica em **Lançar nota fiscal** e sobe o PDF. O sistema lê a nota, descobre sozinho a qual contrato ela se refere e abre o formulário já preenchido: valores, número, impostos retidos e a forma de pagamento padrão do fornecedor. A pessoa confere, ajusta o que precisar e confirma. Daí a nota vai para o financeiro conferir e mandar pagar.

## O que acontece quando você lança uma nota

✅ **Decidido** (7/nov/2026). Uma nota lançada gera três coisas de uma vez:

1. **O título do fornecedor**, pelo valor líquido: valor da nota menos impostos retidos, caução e adiantamento abatido.
2. **Um título por imposto retido**, contra o órgão que recebe (ISS para a prefeitura, INSS, IR, PIS/COFINS/CSLL para a Receita).
   - ✅ **A retenção não é natureza** (Moises, 16/nov/2026). Ela fica registrada no título da nota, com tipo, base, alíquota, valor e a guia que a recolheu. A despesa entra pelo valor cheio: uma consultoria de R$ 10 mil com R$ 1,5 mil retidos custa R$ 10 mil. Saem do plano as contas "(-) Retenção" (2080101 a 2080105 e 1020301 a 1020305), que não tiveram lançamento no último ano.
   - ✅ **A guia de recolhimento continua como natureza**, no grupo Movimentações: IRRF, INSS, ISS e PIS/COFINS/CSLL de terceiros.
   - ✅ **Conferência:** o sistema mostra três coisas:
     - o retido contra o recolhido por mês, imposto e centro, com a diferença em destaque;
     - para cada fornecedor, as notas com o valor retido e a guia que pagou cada uma;
     - um aviso para guia sem nota e para nota retida sem guia.
3. **Uma entrada no extrato de caução** do contrato, se houver caução (ver [Caução](caucao.md)).

E ainda **consome as previsões** do contrato ou da assinatura, da mais antiga para a mais nova, até o valor da nota.

### Exemplo

Nota de serviço de R$ 10.000,00, com ISS de 5% retido e caução de 5% do contrato:

| Item | Valor |
| --- | --- |
| Valor da nota | R$ 10.000,00 |
| ISS retido (5%) | − R$ 500,00 → título para a prefeitura |
| Caução (5%) | − R$ 500,00 → extrato de caução do contrato |
| **Título do fornecedor** | **R$ 9.000,00** |

---

## Competência da nota

- ✅ A competência da nota (e do título avulso) fica **no máximo no mês seguinte ao da emissão**. O administrador pode mudar essa janela (Moises, 14/nov/2026).
- 🟡 A conferir com o Moises: o código também aceita até **1 mês antes** da emissão. Ele falou só do mês seguinte.
- ✅ Fora da janela, só com uma **exceção aprovada por alguém da AF ou da AD**, com justificativa. Quem lançou não aprova. Se a competência mudar depois, a exceção deixa de valer e é preciso outra.

## Tarefa: lançar uma nota fiscal

> 🟡 **Primeira tela de lançamento, no PR #93** (ainda não juntado). Ela é mais simples que o desenho de 6/nov/2026, que segue abaixo como o destino.

### O que a tela do PR #93 já faz

O botão **Lançar título** fica na página Títulos e abre uma janela com estas seções, nesta ordem:

1. **Documento:** empresa, fornecedor (busca por nome, nome fantasia ou CNPJ), tipo (NFS-e, NF-e, Fatura, Boleto, Recibo ou Outro; o PR #112, ainda não juntado, acrescenta as guias IPTU, ITBI, DARF, DARM e DARE, que vão ao Sienge com o documento de mesmo nome e, quando a guia não mostra o CNPJ do órgão, o completam pelo código da linha digitável, com aviso para conferir), número, série, emissão, competência e valor.
2. **Onde entra:** núcleo, centro, divisão do último nível e natureza. A lista de naturezas traz só as que a pessoa pode lançar ali. O botão "Ratear" acrescenta linhas, cada uma com o seu percentual.
3. **Previsões que a nota consome:** as previsões abertas do fornecedor com o mesmo núcleo, centro e natureza. Cada uma mostra o número PRV no Sienge, a data e o saldo, e aparece "Esperando aprovação" quando for o caso. A pessoa marca quais a nota consome.
4. **Pagamento:** a nota se divide em parcelas iguais, e cada parcela é PIX ou boleto. A chave PIX sugerida é o CNPJ do fornecedor; outra chave de CPF ou CNPJ pede justificativa. O centavo que sobra vai na primeira parcela, como no Sienge (por exemplo, R$ 900,01 em 2 parcelas fica R$ 450,01 + R$ 450,00). 🟡 No PR #102 (ainda não juntado), cada parcela ganha o seu campo de valor. Ou se preenchem todas, ou nenhuma: sem valor, as parcelas saem iguais. A soma tem de dar o valor da nota; se não der, a tela avisa "As parcelas somam X; o valor é Y". O leitor já preenche o valor de cada parcela ou boleto quando o encontra.
5. **Etiquetas.**

✅ **Número do título** (Moises, 24/nov/2026): quando o arquivo não é uma nota fiscal (boleto, fatura, guia, IPTU, DARF), o número do título é o número do documento impresso nele. Não vale um rótulo nosso, como os que se usam hoje no Sienge ("LOTE6 3/10" no IPTU, o período no DARF). É por esse número que se confere o papel e se acha um documento lançado duas vezes. O leitor já preenche assim.

Ao clicar em **Lançar**, o título vai para a aprovação e abre na gaveta. Se faltar alguma coisa, o pé da janela diz o quê.

🟡 **Ler a nota pelo arquivo, no PR #98** (ainda não juntado). O Lançar título ganha no topo o bloco **Arquivo da nota**:
- **Preenchimento:** a pessoa arrasta ou escolhe o PDF, o XML ou a foto da nota, com até 20 MB. A tela se preenche com empresa, fornecedor, documento, datas, valor e parcelas (boleto ou PIX).
- **Avisos do bloco:**
  - nota já lançada;
  - nota lida pela IA, que precisa de conferência;
  - tomador que não é empresa da pessoa;
  - emitente sem cadastro;
  - boleto que o banco não confirmou;
  - valor ou beneficiário diferentes do boleto.
  - 🟡 CPF ou CNPJ lido com dígito verificador errado, do emitente ou do tomador (PR #127, ainda não juntado): o campo vem vazio, com o aviso "CNPJ do emitente lido com dígito verificador errado: confira no documento", e a pessoa digita o número olhando a nota. É o mesmo que já acontece com a chave de acesso.
- **Nota com retenção trava o Lançar.** Quando a leitura acha tributo retido, ou um líquido abaixo do bruto, aparece um aviso vermelho: "Nota com retenção ainda não se lança… espere a tela de retenções". O Lançar só destrava se a pessoa marcar "Conferi o documento: a nota não tem retenção (a leitura errou)". ⚠️ Quem lança à mão, sem arquivo, uma nota com retenção ainda lança pelo valor bruto; isso vai ao Moises.
- **De onde a nota vem:** o bloco lista as origens possíveis (previsão, contrato, assinatura, conta de consumo ou pedido de compra), com a mais provável já marcada. Escolher uma origem preenche o rateio e a previsão; "Nenhum destes" limpa os dois.
- **Depois de lido:** tudo continua editável, e o arquivo fica ligado à nota.
- **Limite de envio** (Moises, 20/nov/2026; PR #101, ainda não juntado): cada pessoa sobe até 30 arquivos ao leitor a cada 10 minutos. Quem passa do limite vê o aviso "Muitos arquivos em pouco tempo; espere alguns minutos". O administrador ou o master podem mudar o número de cada pessoa, de 1 a 1.000, e ninguém muda o próprio. Ainda não há tela para isso; a mudança é feita direto no banco.
- **No rastro do título**, o botão Anexos passa a baixar o arquivo.

**Ainda não dá para fazer:**
- reter impostos ou caução;
- adiantar sem nota;
- salvar rascunho;
- escrever uma descrição.

### O desenho completo (6/nov/2026)

Alguns pontos dependem de decisões em aberto, indicadas abaixo.

**Quem faz:** 🟡 alguém da BKM, normalmente o responsável pelo contrato. Abrir para o próprio fornecedor subir a nota fica para depois (proposta de 6/nov/2026, sem confirmação).

**Antes de começar:** o PDF da nota (e o XML, se o fornecedor mandou); o contrato ou a assinatura já cadastrados.

**Passo a passo:**

1. Clique em **Lançar nota fiscal**.
2. Arraste o PDF da nota. Se tiver o XML, suba junto: ele é exato, enquanto o PDF depende da leitura automática.
3. Espere a leitura. O sistema extrai emitente, tomador, número, data, valores, impostos retidos e descrição.
4. Veja o contrato que o sistema encontrou. Ele procura pelo par **CNPJ de quem emitiu + CNPJ de quem foi cobrado** (o tomador diz qual empresa ou SPE da BKM, ou seja, qual obra).
   - Se ele não encontrar, ou se houver mais de um contrato possível, escolha na lista. A lista mostra só os contratos ligados ao seu perfil.
5. Confira o formulário: número, data, valor, impostos retidos, caução (vem a do contrato, e você pode mudar nesta nota) e vencimento.
6. Confira a forma de pagamento. Vem a padrão do fornecedor (Pix ou conta). Se for boleto, suba o boleto ou digite o código de barras.
7. Confira a classificação (núcleo econômico, centro de custo e natureza), que vem do contrato.
8. Clique em **Confirmar**.

**O que o sistema confere:**

| Situação | O que acontece |
| --- | --- |
| Nota já lançada (mesmo emitente, tipo, número e série) | Recusa |
| Tomador não é empresa da BKM | Recusa |
| Valor acima do saldo do contrato | 🟡 Bloqueia, porque o aditivo só se faz no Sienge |
| Imposto retido na nota diferente do esperado | 🟡 Segue com alerta e o financeiro decide (proposta de 6/nov/2026) |
| Valor que não fecha no centavo ao converter para a medição | Avisa antes de lançar (ver [Medições](../suprimentos/contratos-e-medicoes.md)) |

**Não dá para detectar:** nota falsa ou adulterada em PDF. Conferir na prefeitura ou na SEFAZ é um passo a avaliar.

**E depois?** A nota segue para aprovação e para o financeiro. O caminho até o Sienge depende de uma decisão em aberto:

## Caixa das notas recebidas

✅ **Decidido** (Moises, 23/nov/2026). O sistema mostra numa caixa as notas que os fornecedores emitem contra os CNPJs do grupo, antes mesmo de alguém lançar.

> ✅ O banco e o serviço da busca estão no sistema (PR #126, juntado em 23/nov/2026). A busca já pode ser ligada (Moises aceitou o risco que faltava, 23/nov/2026). ⏳ A tela ainda não existe.

- **Como as notas chegam:** o sistema busca sozinho, várias vezes ao dia, as NF-e (material) na SEFAZ e as NFS-e (serviço) no ambiente nacional da nota de serviço. ✅ A NF-e recebe a ciência da operação automaticamente, para o sistema baixar a nota completa. A SEFAZ só aceita a ciência até 10 dias depois da emissão, então ela é pedida só para as notas desse prazo, das mais novas para as mais antigas (PR #131). Nota mais antiga fica só com o resumo, sem o arquivo completo.
- ✅ **Agrupada por empresa**, não por núcleo, porque a nota só traz o CNPJ da empresa.
- ✅ **Quem vê:** AF, AO, AD, diretor e master veem a caixa inteira. O master e o AD liberam outras pessoas por empresa e por tipo (material ou serviço), sempre com o motivo, e podem tirar a liberação.
- ✅ **Quem lança sem acesso à caixa** acha a própria nota pela chave de acesso ou pelo CNPJ do emitente e o número. 🟡 Sem a chave, o sistema pede também o valor exato da nota, para ninguém percorrer a sequência de números de um fornecedor. Falta o Moises confirmar.
- ✅ **Nota de PJ:** só o master e os designados veem.
- 🟡 **Situação da nota:** nova, vinculada ou ignorada. Fica vinculada sozinha quando a nota é lançada no ERP. Ignorar exige o motivo, e só o financeiro ou o master ignora.
- 🟡 A nota cancelada pelo emitente fica marcada como cancelada.
- 🟡 **No Sienge,** a importação de NF-e fica parada, porque a nossa busca substitui e as duas dividiriam o limite de consultas da SEFAZ. É a recomendação, e o Moises não se opôs.

## ⏳ Em aberto: como a nota chega ao Sienge

| Caminho | Como funciona | Custo |
| --- | --- | --- |
| **Medição do contrato** | O sistema cria a medição no Sienge, os 2 gestores aprovam no ERP BKM, o sistema autoriza no Sienge, o analista **libera à mão no Sienge** (com a ficha pronta), e o sistema completa o título depois | Sobra um passo manual, a liberação. O Sienge controla o saldo do contrato |
| **Título avulso** | O sistema cria o título completo no Sienge, já com os impostos | Tudo automático, mas o saldo do contrato passa a ser controlado só pelo ERP BKM |

✅ **Na primeira etapa da implantação, fora a obra, vale o título avulso** (Moises, 8/nov/2026): o fluxo roda no ERP BKM até a nota, e o título é criado completo no Sienge pela API. Ver [Contas a pagar › Primeira etapa](contas-a-pagar.md#primeira-etapa-da-implantação-o-pedido-de-pagamento). ⏳ Para a obra (medições), o caminho continua em aberto. Foi sugerido também perguntar ao suporte do Sienge se existe liberação automática ou API de liberação.
