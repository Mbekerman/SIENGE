# Empresas, sócios e empreendimentos

[← Sumário](../README.md)

## Como o grupo está organizado

✅ **Decidido** (Moises, 7/nov/2026):

- Todo empreendimento tem a sua SPE, sempre um para um.
- Acima da SPE estão os sócios dela: a BKM e, às vezes, outro sócio que responde por uma parte.
- Acima das empresas está a holding (o grupo).

No sistema isso fica assim:

| Cadastro | O que guarda | Regra |
| --- | --- | --- |
| **Empresas** | Holding, BKM Incorporadora e cada SPE, cada uma com seu CNPJ | ✅ Uma lista só para todas. Não existe cadastro separado de "holding": a holding é a empresa que não tem dono dentro do grupo. |
| **Participações** | Quem é sócio de qual empresa, com o percentual, de quando até quando | ✅ A soma dos percentuais vigentes de uma empresa é 100%. Mudar o percentual encerra a linha antiga e abre uma nova, para guardar o histórico. |
| **Empreendimentos** | O produto: nome, SPE, praça, terreno de origem (BKM Terrenos), fase | ✅ Separado da SPE, mesmo sendo um para um. A SPE é o CNPJ; o empreendimento é o negócio. |
| **Praças e regionais** | Lista fixa | 🟡 Campo com lista, não etiqueta livre (ver abaixo). |
| **Centros de custo** | Um por empreendimento, mais as áreas (Sede etc.) | ✅ Nunca um centro de custo por tipo de gasto. Ver [Classificação](../financeiro/classificacao.md). |
| **Etiquetas (tags)** | Agrupamentos livres, como "lançamento 2027" | Para o que não precisa de garantia. |

### Praça e regional: lista, não etiqueta

O Moises sugeriu que praça e regional pudessem ser etiquetas (7/nov/2026). 🟡 A proposta do desenho é que sejam **campos com lista fixa**, porque etiqueta aceita erro de digitação e duplicidade ("SP" e "São Paulo"), e praça serve para relatório, orçamento consolidado e permissão de acesso. Etiquetas ficam para o resto. Falta confirmação explícita.

### Atributos do empreendimento para relatórios

✅ **Decidido** (7/nov/2026): cidade, estado, regional, praça, linha de produto, faixa MCMV e outros atributos ficam **no cadastro do empreendimento**, e não repetidos em cada lançamento. Os relatórios enxergam esses campos como se estivessem em cada linha. A lista de atributos pode crescer: o administrador cria novos. Quando um atributo muda (por exemplo, a faixa MCMV), o sistema guarda a data, para que um relatório do passado mostre o valor da época.

---

## Tarefa: cadastrar uma nova SPE e seu empreendimento

> ⏳ As telas ainda não existem. O roteiro abaixo segue as regras decididas.

**Para que serve:** criar a empresa e o produto de um novo negócio, normalmente quando um terreno é comprado no BKM Terrenos.

**Quem faz:** administrador do cadastro. ⏳ O papel exato será definido na sessão de aprovações.

**Antes de começar:** o CNPJ da SPE; os sócios e os percentuais; no Sienge, a empresa e a obra já criadas (a API do Sienge não cria empresa nem obra).

**Passo a passo:**

1. Abra **Cadastros › Empresas** e clique em **Nova empresa**.
2. Informe CNPJ, razão social e o tipo **SPE**.
3. Em **Sócios**, inclua cada sócio (empresa do grupo ou pessoa de fora) com o percentual e a data de início. O total precisa dar 100%.
4. Salve. Abra **Cadastros › Empreendimentos** e clique em **Novo empreendimento**.
5. Escolha a SPE que acabou de criar, dê o nome, escolha a praça e, se veio do BKM Terrenos, ligue o terreno de origem.
6. Preencha os atributos (cidade, linha de produto, faixa MCMV...).
7. Ligue a empresa e a obra correspondentes do Sienge (uma vez só).
8. Salve. O centro de custo do empreendimento é criado junto.

**O que o sistema confere:** CNPJ válido e não repetido; soma dos sócios igual a 100%; uma SPE com um empreendimento só.

**E depois?** O empreendimento já pode receber orçamento, compromissos e títulos. Se a viabilidade veio do BKM Terrenos, ela vira a primeira versão do orçamento.

## Tarefa: mudar a participação de um sócio

**Passo a passo:**

1. Abra a empresa e vá em **Sócios**.
2. Na linha do sócio, clique em **Alterar participação**.
3. Informe o novo percentual e a data a partir da qual vale.
4. Ajuste os outros sócios para que a soma continue 100% na mesma data.
5. Salve. A linha antiga fica encerrada na véspera e continua no histórico.

**O que o sistema confere:** a soma de 100% em qualquer data; datas sem buraco nem sobreposição para o mesmo sócio.
