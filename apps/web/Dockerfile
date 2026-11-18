# Front do ERP servido por Caddy no Cloud Run (mesmo padrão do BKM Terrenos, Dockerfile da raiz de lá).
# Contexto do build: apps/web. O endereço e a chave publicável do Supabase não entram no build:
# o Caddy os põe na página a partir das variáveis SUPABASE_URL, SUPABASE_KEY e AMBIENTE do serviço.
FROM node:22-alpine AS build
WORKDIR /web
COPY package*.json ./
RUN npm ci --no-audit --no-fund
COPY . ./
RUN npm run build

FROM caddy:2-alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=build /web/dist /srv
