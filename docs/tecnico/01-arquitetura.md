# 1. Visão geral e arquitetura

## Objetivo

A BKM usa o Sienge como ERP em todos os módulos. O objetivo do projeto é reduzir o Sienge a um **núcleo de transações** (financeiro, fiscal, contábil, banco e segurança) e construir em volta dele os sistemas da BKM, com banco de dados próprio. A meta de longo prazo é que trocar o Sienge por outro ERP seja trocar uma peça (o adaptador), sem refazer os sistemas.

Ressalva registrada desde o início: isso torna o **código** trocável. Trocar de ERP continua exigindo migrar histórico, refazer plano de contas e parâmetros fiscais e treinar o financeiro.

## Sistemas envolvidos

| Sistema | Situação | Relação com este projeto |
| --- | --- | --- |
| Sienge (ERP) | Em produção na BKM, subdomínio `bkmincorporadora` | Núcleo de transações; fonte da verdade do fato financeiro, fiscal e contábil |
| ERP BKM (este repositório) | **[Desenhado]** | Banco próprio, adaptador do Sienge, contas a pagar e, depois, os outros módulos |
| BKM Terrenos (`Mbekerman/bkm_terrenos-claude`) | Em desenvolvimento, sem banco criado | Mesmo projeto Supabase, mesmo login; o terreno comprado vira empreendimento; a viabilidade dá o topo da árvore de naturezas |
| CRM de vendas | Em uso, software paralelo (nome ainda não informado) | Já manda as vendas ao Sienge por API; vai alimentar o mesmo núcleo |
| Monitor de mercado (`Mbekerman/bkm-monitor-mercado`) | Em uso | Já tem tabelas `public.im_*` no mesmo projeto Supabase |

## Arquitetura proposta [Desenhado]

```
 Sistemas BKM (contas a pagar, BKM Terrenos, CRM, suprimentos, obra)
                 │  só falam com o núcleo, em português
                 ▼
 ┌──────────────────────────── Supabase, projeto próprio do ERP ───────────┐
 │  nucleo        modelo neutro da BKM + nucleo.codigos_externos             │
 │  pagar*        documentos a pagar, conferência, aprovação                 │
 │  sienge        espelho do Sienge (uma tabela por entidade da API)         │
 │  sienge_bruto  resposta inteira de cada chamada, nunca alterada           │
 │  crm, crm_bruto  mesma lógica para o CRM                                  │
 └───────────────────────────────────────────────────────────────────────────┘
 ┌──────────── Supabase BKM_Desenvolvimento_Imobiliario (outro projeto) ─────┐
 │  app, fluxo    BKM Terrenos e tarefas;  public.im_*  monitor de mercado   │
 └───────────────────────────────────────────────────────────────────────────┘
   Portal único: um login pelo Google, uma sessão em cada projeto
                 ▲                                   │
   avisos (webhooks) + leitura periódica     fila de envio
                 │                                   ▼
            ┌──────────── adaptador do Sienge (servidor) ────────────┐
            └─────────────────────── API do Sienge ──────────────────┘
```

\* O esquema `pagar` aparece no plano de 6/nov/2026. No modelo v1 do núcleo (7/nov/2026) compromisso, documento, título e pagamento passaram a ser tabelas do `nucleo`. Qual esquema guarda o fluxo de aprovação do contas a pagar ainda não foi fechado; ver [07-pendencias.md](07-pendencias.md).

### Regras que mantêm o ERP trocável [Desenhado, aprovado em 6 e 7/nov/2026]

1. **Só o adaptador conhece o Sienge.** Nenhuma tabela fora de `sienge`/`sienge_bruto` guarda código do Sienge; a ligação "nosso id ↔ id do Sienge" mora em `nucleo.codigos_externos` (sistema, entidade, código lá, código nosso). Trocar de ERP = criar outras camadas bruto/espelho e preencher outra correspondência.
2. **Cada dado tem um dono.** O Sienge é dono do fato financeiro (título, parcela, baixa, contábil, fiscal); a nossa cópia é só leitura. O nosso banco é dono do caminho até lá (o que chegou, quem conferiu, quem aprovou, a que terreno se liga). Nunca os dois escrevem o mesmo campo.
3. **Envio por fila.** Aprovar no nosso sistema grava um pedido de envio; um processo no servidor manda ao Sienge, respeita os limites por minuto, tenta de novo e registra o número devolvido. A pessoa nunca espera o Sienge na tela.
4. **Recebimento em duas etapas.** O aviso do Sienge é gravado como chegou e respondido na hora (o Sienge espera 2,5 s); o processamento vem depois.
5. **Aviso não é dado.** O webhook só diz "o registro X mudou"; o sistema sempre relê o registro pela API.
6. **Credenciais só no servidor**, no cofre do Supabase (Vault), nunca no navegador.

## Stack [Desenhado]

Mesma do BKM Terrenos, por decisão do Moises (instruções do projeto):

- Front: React 18 + TypeScript + Vite, TanStack Query, react-router, supabase-js, sem biblioteca de UI. Visual Material 3 sobre a marca BKM, reaproveitando componentes do BKM Terrenos.
- Banco: Supabase (Postgres + Auth + Storage), num **projeto próprio do ERP**, separado do BKM_Desenvolvimento_Imobiliario do Terrenos e do monitor (decisão do Moises, 7/nov/2026, 21h56; motivo na S-015 do [08](08-seguranca.md)). O projeto só é criado quando as tabelas forem para um banco. Estudo Supabase × AWS de 7/nov/2026: https://claude.ai/artifact/Rmq8G8PR7hcg1Fo6RFjG7P (projeto próprio no Supabase estimado em US$ 115–165/mês; RDS Multi-AZ da AWS em sa-east-1, US$ 335–400/mês mais operação; preços de trechos de busca).
- **Portal único** (requisito do Moises, 7/nov/2026): ERP, CRM, Terrenos, obras e o resto num portal só, com um login pelo Google e uma sessão em cada projeto, aberta sem nova tela (a validar em protótipo; requisitos na S-018).
- Portabilidade (estudo de 7/nov/2026): o que hoje prende o `nucleo` ao Supabase é só `auth.uid()` em `nucleo.eu()`, os papéis do PostgREST e `request.jwt.claim.sub` em `nucleo.sistema()`; o `shim_supabase.sql` dos testes já roda tudo num Postgres comum. Regras propostas, à espera do Moises: usuário só por `nucleo.eu()`; adaptador do Sienge em contêiner (Cloud Run), não em Edge Function; arquivo acessado só por função nossa; segredo lido num ponto só; cópia diária do banco e dos arquivos fora do Supabase, com teste de restauração a cada trimestre.
- Regra de negócio no banco (funções Postgres chamadas por RPC), sempre com teste.
- Adaptador do Sienge: servidor ainda não escolhido (funções do Supabase, serviço no Cloud Run ou outro). **[A decidir]**
- Deploy do front: provavelmente o mesmo padrão do BKM Terrenos (Google Cloud Run, projeto `bkm-terrenos`, região `southamerica-east1`). **[A decidir]**

## Ordem de migração [Desenhado, discutida com o Moises em 6/nov/2026]

1. Nosso banco copiando Sienge e CRM (só leitura).
2. Contas a pagar e medições.
3. Suprimentos, orçamento e obra.
4. Contas a receber e banco (Open Finance para ler; Nexxera ou o banco para pagar).
5. Fiscal e contábil por último, rodando em paralelo antes de desligar o Sienge.

Escopo do primeiro módulo (Moises, 6/nov/2026): lançar medições mensais sobre contratos já criados à mão no Sienge, inclusive os pagamentos do dia a dia da empresa.
