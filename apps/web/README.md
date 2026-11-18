# ERP BKM, front (apps/web)

React 18 + TypeScript + Vite, TanStack Query, react-router e supabase-js, sem biblioteca de UI (a mesma base do BKM Terrenos).
O desenho é o do protótipo aprovado pelo Moises em 15/11/2026 (linha F, versão 35); `src/styles.css` é o `tpl.css` dele.
Revisão de design de 18/11/2026 (pedido do Moises: cards baixos, título grande, muito vazio ao lado do menu), no fim de `src/app.css`: abas no lugar do título, página a 24 px do menu, contadores com o total em R$, uma cor por situação, cabeçalho das colunas fixo, grupos em quadros, gaveta que empurra a lista em vez de cobrir (tela cheia no celular). Imagens em `imagens/`.

## Rodar

```bash
cp .env.example .env.local   # VITE_SUPABASE_URL e VITE_SUPABASE_KEY (chave publicável) do bkm_dev
npm install
npm run dev                   # http://localhost:5174
npm run typecheck && npm run build
```

Publicado, o servidor web põe `SUPABASE_URL`, `SUPABASE_KEY` e `AMBIENTE` nas metas da página (`index.html`), como no BKM Terrenos.

## Como fala com o banco

Só pelo esquema `api` (ver `docs/tecnico/03-banco-de-dados.md`, seção 3.4): funções que rodam com o login e o RLS de quem chama.
No Supabase, `api` precisa estar em Settings › API › Exposed schemas. O `erp` nunca é exposto.

## Telas

- `/titulos`, `/titulos/:id`: títulos por etapa (Rascunhos, Em aprovação, No Sienge, Pagos), com a gaveta do título.
- `/previsoes`, `/previsoes/:id`: previsões por situação.
- `/contratos`, `/contratos/:id`: contratos de serviço e assinaturas.

O contador ligado e a busca ficam no endereço (`?f=` e `?q=`), então o link abre a mesma tela.
