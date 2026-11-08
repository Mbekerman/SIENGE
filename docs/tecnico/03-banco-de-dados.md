# 3. Banco de dados

O banco é um Postgres do Supabase, num projeto próprio do ERP (decisão de 7/nov/2026; o BKM Terrenos e o monitor ficam no BKM_Desenvolvimento_Imobiliario), organizado em esquemas por camada. Cada camada tem uma situação diferente:

| Esquema | Papel | Situação |
| --- | --- | --- |
| `nucleo` | Modelo da BKM, neutro em relação ao ERP | **[Construído em branch]** v0, 7/nov/2026, ainda não integrado na `develop` nem aplicado em nenhum banco |
| `sienge` | Espelho do Sienge: uma tabela por entidade da API | **[Desenhado]**, aprovado pelo Moises em 7/nov/2026 |
| `sienge_bruto` | Resposta inteira de cada chamada à API, nunca alterada | **[Desenhado]**, aprovado em 7/nov/2026 |
| `crm`, `crm_bruto` | Mesma lógica para o CRM | **[Desenhado]**; CRM ainda não identificado |
| esquema pessoal dos PJ (nome a definir) | Cadastro e remuneração dos PJ, fora do `nucleo` | **[Desenhado]**, aceito pelo Moises em 7/nov/2026; **adiado até o Sienge sair** (ver 3.3) |
| `app`, `fluxo` | BKM Terrenos e tarefas | Em outro projeto Supabase (BKM_Desenvolvimento_Imobiliario); ver `docs/modelo.md` do BKM Terrenos |

## 3.1 Esquema `nucleo` [Construído em branch, 7/nov/2026]

Onde está: branch `claude/project-thread-dknc98` deste repositório (commits `649ae60` "Núcleo do ERP BKM v0", `5c71b57`, `89c1202`, `ae75175` e `f659cfe`, que fecham o esquema à API). Quando o PR desse branch entrar na `develop`, esta seção passa a valer para a `develop`.

| Arquivo | Conteúdo |
| --- | --- |
| `supabase/migrations/20261107000100_nucleo_cadastros.sql` | Esquema, usuários e papéis, auditoria, pessoas, empresas, participações, empreendimentos, atributos de BI, centros de custo, departamentos, fases, `codigos_externos`, árvore de naturezas (17 tabelas) |
| `supabase/migrations/20261107000200_nucleo_pagar_livro.sql` | Compromissos, previsões, documentos fiscais e retenções, títulos, parcelas, pagamentos, quitações, caução, movimentos societários, contas e lotes bancários, orçamento, livro de lançamentos e visões (19 tabelas) |
| `supabase/migrations/20261107000300_nucleo_reclassificacao.sql` | Fechamento de mês, níveis de aprovação, alçadas, pedidos de reclassificação, itens e votos (6 tabelas) |
| `supabase/migrations/20261107000400_nucleo_carga.sql` | Carga inicial: árvore de naturezas v0 (11 grupos), linhas da DRE, naturezas do sistema, níveis e alçada padrão |
| `supabase/tests/nucleo.sql` | 112 testes de regra (os de acesso incluem função `security definer` e catálogo de privilégios) |
| `supabase/tests/run.sh` | Sobe um Postgres 16 temporário, aplica `shim_supabase.sql` + migrations e roda os testes |
| `supabase/tests/shim_supabase.sql` | Imita o mínimo do Supabase (`auth.uid()` lido de `request.jwt.claim.sub`) |
| `docs/nucleo.md` | Dicionário das tabelas e regras, em português (fonte principal para o detalhe de cada tabela) |

Conferido nesta documentação em 7/nov/2026: `bash supabase/tests/run.sh` aplica as 4 migrations e passa os 112 testes.

### Como rodar os testes

```bash
bash supabase/tests/run.sh   # precisa de Postgres 16 em /usr/lib/postgresql/16/bin (ou PGBIN=...)
```

Roda como root (usa `runuser -u postgres`) ou como usuário comum; porta padrão 54331 (`PORT=...`).

### Princípios do esquema

- **Regra no banco.** Confirmar título, lançar documento, quitar, liberar caução, fechar mês e reclassificar só acontecem por função (`nucleo.lancar_documento`, `confirmar_titulo`, `pagar_parcela`, `liberar_caucao`, `registrar_movimento_societario`, `gerar_previsoes_assinatura`, `publicar_orcamento`, `fechar_mes`, `reabrir_mes`, `pedir_reclassificacao`, `previa_reclassificacao`, `decidir_reclassificacao`, `cancelar_reclassificacao`). Triggers barram as alterações diretas (`tg_titulo`, `tg_documento`, `tg_imutavel` em quitações e consumo de previsão, `tg_lancamento` no livro).
- **O livro só cresce.** `nucleo.lancamentos` não aceita update nem delete; desfazer é lançar o oposto. Única exceção: a natureza da linha, que muda pela reclassificação aprovada e guarda a anterior em `reclassificacao_itens`.
- **Sinal.** No livro, entrada positiva e saída negativa; nas tabelas de origem, valores sempre positivos (`nucleo.sinal`).
- **Estágios do livro:** orçado, previsto, comprometido, realizado. O livro é escrito pelos triggers e funções; a tabela de eventos que geram cada linha está em `docs/nucleo.md`, seção 4.
- **Todo pagamento passa por Adiantamentos.** O pagamento entra inteiro no realizado na natureza de sistema "Adiantamentos a fornecedores"; cada quitação tira dali e lança na natureza do título. Assim o realizado do livro bate sempre com o banco, e pagamento parcial e adiantamento são o mesmo mecanismo.
- **Auditoria** em `nucleo.auditoria` (trigger `tg_auditoria`) nas tabelas de configuração e estrutura (participações, naturezas e outras).
- **Visões** com `security_invoker`: `v_naturezas`, `v_parcelas`, `v_adiantamentos`, `v_caucao`, `v_previsoes`, `v_fluxo_caixa`, `v_lancamentos_bi` (a de BI e agentes).
- **Trava de duplicidade** de nota: `documentos_fiscais` recusa o mesmo emitente + tipo + número + série. O Sienge não tem essa trava no documento NFSE da BKM (ver [04](04-integracao-sienge.md)).

### Identidade e permissões no `nucleo`

- `nucleo.usuarios` (`user_id` = `auth.users.id`) guarda papel (`diretor`, `gestor`, `analista`, `leitura`), `contador` e `administrador`.
- `nucleo.eu()` = `auth.uid()`. `nucleo.sistema()` é verdadeiro só quando não há usuário, o `session_user` não é `authenticator`, `anon` nem `authenticated`, e o papel da sessão não é `anon` nem `authenticated`: migration, pg_cron, conexão direta ao Postgres ou a chave de serviço (`service_role`, commit `f659cfe`). Chamadas como `anon` ou `authenticated` sem login nunca contam. As checagens `exigir_admin`, `exigir_editor` e `exigir_diretor` deixam passar só nesse caso.
- Acesso fechado à API do Supabase (migration `..._nucleo_carga.sql`, fim): o esquema, as tabelas e o `execute` das funções são revogados de `public`, `anon` e `authenticated`, inclusive nos privilégios padrão. Hoje **só o servidor** usa o `nucleo`.

Corrigido em 7/nov/2026: na v0 inicial, `eu()` nulo passava nas checagens, e uma chamada anônima pela API também tem `auth.uid()` nulo. Em seguida (S-002), a decisão deixou de usar `current_user`, que dentro de `security definer` é o dono. Os testes de acesso cobrem os dois casos e um teste de catálogo barra qualquer privilégio de `public`, `anon` ou `authenticated`.

O que falta antes de abrir o `nucleo` às telas (ver [07-pendencias.md](07-pendencias.md)):

1. Dar `grant` a `authenticated` só no que as telas usam (funções e visões) e criar a RLS. Hoje não há RLS: com o esquema fechado não é necessária, mas passa a ser no primeiro `grant`.
2. O `nucleo` não tem `empresa_id` de isolamento como o BKM Terrenos (`app.minhas_empresas()`): as empresas do grupo são dados, não inquilinos. Quem vê o quê por empresa ou empreendimento fica para o módulo de aprovação e permissões.
3. `nucleo.usuarios` é um cadastro de papéis separado de `app.membros` do BKM Terrenos, no mesmo login. Falta decidir se os dois se unem.

### Regra de migrations

Enquanto nenhum banco de produção tiver recebido estas migrations, elas podem ser editadas no lugar (mesma regra do BKM Terrenos). Quando o `nucleo` for aplicado no banco de produção (o projeto próprio do ERP), toda mudança passa a ser migration nova. **[Construído]** CI em `.github/workflows/ci.yml` (commit `a252fbe`): em todo push e PR, instala o Postgres 16 num runner `ubuntu-24.04`, roda `bash supabase/tests/run.sh` e só fica verde se a saída trouxer "TODOS OS TESTES PASSARAM". Token só de leitura (`permissions: contents: read`). **Em 7/nov/2026 o CI ainda não tinha rodado nenhuma vez:** os minutos do GitHub Actions da conta acabaram em 6/nov/2026, às 15h11 UTC, e desde então todo job é recusado sem rodar (a anotação fala em "Billing & plans"). Enquanto isso, o check fica vermelho sem ter executado nada, e os testes são conferidos rodando `run.sh` à mão.

**Regra de CI de todo o projeto** (decisão do Moises, 7/nov/2026, para gastar menos minutos), aplicada aqui nos commits `556ca8c` e `73ab4b0`:

- roda só em `pull_request` para `develop` e `main` com mudança em `supabase/**` ou `.github/workflows/**`, ou à mão (`workflow_dispatch`); não roda em `push`. Um PR só de documentação não dispara o CI;
- `concurrency` com `cancel-in-progress`; `permissions: contents: read`;
- timeout de 15 minutos no job e de 8 no passo do Postgres;
- usa o Postgres 16 do runner e só recorre ao `apt-get` (com novas tentativas) se ele faltar. Sem cache, porque não há dependências.

O mesmo modelo está nos PRs do BKM Terrenos (#243) e do monitor de mercado (#10).

## 3.2 Esquemas `sienge_bruto` e `sienge` [Desenhado, aprovado em 7/nov/2026]

Desenho completo: [Banco espelho do Sienge](https://claude.ai/artifact/EgDt6HJJREERJBsYKrvLsE). Resumo do que vale para quem for construir:

- `sienge_bruto`: a resposta de cada chamada, inteira, com data e hora. Nunca se altera; serve para reprocessar.
- `sienge`: cerca de 60 tabelas em 6 grupos (cadastros básicos, contas a pagar, suprimentos, engenharia, comercial e contas a receber, bancos e contabilidade). Cada tabela usa **os nomes da API** (minúsculas, com `_`), as chaves do Sienge e os campos principais (chaves, ligações, datas, valores, situação) em colunas; o resto num JSON da linha.
- Toda linha do espelho leva `lido_em`, uma impressão digital do conteúdo e `removido_em` (nada se apaga). Títulos e parcelas guardam cada versão que mudou.
- Controle da cópia: `sienge.sincronizacoes` (entidade, janela, lidos, novos, alterados, removidos, erros) e `sienge.sincronizacao_cursores` (onde parou).
- A tradução para português acontece uma vez só, do espelho para o `nucleo`, e a ligação de códigos fica em `nucleo.codigos_externos`.
- Ordem recomendada de construção: cadastros básicos + contas a pagar + suprimentos (contratos e medições).

Chaves que pegam desprevenido (da documentação e dos testes):

- Contrato de suprimentos: documento + número. Medição: documento + contrato + obra + número da medição.
- Obra: a API aceita o código de tela (`buildingId` 13 para o Escritório Central BKMSP); o código interno 14 dá 404. Guardar os dois (`buildingId`, `buildingIdView`), assim como `companyId` e `internalCompanyId`.
- Plano financeiro não tem hierarquia explícita: a árvore sai do código com máscara.
- Corretor não tem cadastro próprio: é credor com a marca de corretor.

Como o espelho fica em dia está em [04-integracao-sienge.md](04-integracao-sienge.md), seção "Sincronização".

## 3.3 Esquema pessoal dos PJ [Desenhado, 7/nov/2026; adiado até o Sienge sair]

Enquanto os pagamentos PJ passarem pelo Sienge, o esquema pessoal, a camada de pseudônimo no extrato e o portal do contador ficam adiados (Moises, 7/nov/2026). O desenho e os requisitos abaixo e em [08](08-seguranca.md) continuam valendo para quando forem feitos. **[A decidir]** quando o portal voltar: como o contador faz login, já que o login do projeto é só Google do Workspace.

Desenho aceito pelo Moises (thread "Desenhar o banco do ERP BKM"), sem código:

- Esquema separado com o cadastro dos PJ ativos e a remuneração. O valor fica criptografado; só os dois responsáveis e os masters leem.
- O `nucleo` recebe só o pseudônimo, a chave PIX e o valor.
- A conciliação lê o extrato por API ou Open Finance, liga cada linha ao pagamento pelo identificador do PIX e troca nome, documento e chave pelo pseudônimo antes de gravar na área do financeiro.

Ajustes aceitos pela thread do banco depois da revisão de segurança (7/nov/2026):

- A chave PIX não vai para o `nucleo`: ele guarda só o pseudônimo e a referência do pagamento, e a função de remessa busca a chave no esquema pessoal na hora do envio.
- Pseudônimo aleatório, com a tabela de ligação no esquema pessoal (sem HMAC).
- Extrato cru gravado só no esquema pessoal.
- Leitura só por função `security definer` que grava o log antes de devolver, sem `grant` nas tabelas; log que só cresce, revisado por quem não é master.
- Chave de criptografia no Vault.

Decidido pelo Moises (7/nov/2026):

- A folha PJ entra no livro **somada por centro de custo e mês**, sem linha por pessoa.
- O cadastro do RH guarda, além de quem está ativo e dos benefícios, **qual SPE paga cada PJ em cada mês** (vínculo mensal, com histórico; Moises, 7/nov/2026). Ele define a empresa pagadora do título e o centro na soma da folha PJ no livro. Um PJ pode ser dividido entre SPEs em % no mês, e cada SPE recebe a sua nota (Moises, 7/nov/2026; leitura do "Sim" dele, informada a ele). Ao receber cada nota, o sistema confere o CNPJ da SPE, o % e o valor (% × remuneração) contra o cadastro do mês e trava se algo divergir. Requisitos para quem construir: a soma dos % de um PJ no mês tem de dar exatamente 100% (restrição no banco, não só na tela) e os centavos do arredondamento vão para uma SPE definida (por exemplo, a de maior %), para que a soma das notas bata com a remuneração.
- Notas fiscais e retenções dos PJ ficam **só no esquema pessoal** e vão direto ao contador, por um **portal do contador** (acesso externo, login próprio, só leitura das notas, cada download no mesmo log que só cresce).

Também decidido (7/nov/2026): **os pagamentos PJ continuam passando pelo Sienge** até ele sair; a anonimização só vale depois disso. Remessa e extrato pela **Nexxera**.

**[A decidir]**: conta bancária separada para a folha PJ; dois masters. Limitação da transição em [08](08-seguranca.md), S-010.

O que a revisão de segurança pede antes de construir está em [08-seguranca.md](08-seguranca.md), S-007.
