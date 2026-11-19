# Front do ERP servido por Caddy no Cloud Run (mesmo padrão do BKM Terrenos, Dockerfile da raiz de lá).
# Contexto do build: apps/web. O endereço e a chave publicável do Supabase não entram no build:
# o Caddy os põe na página a partir das variáveis SUPABASE_URL, SUPABASE_KEY e AMBIENTE do serviço.
# Imagens fixadas pelo digest (18/11/2026): node:22-alpine e caddy:2-alpine.
FROM node:22-alpine@sha256:1314fb30ec37592d5845e5a160d522c0e680972aa534549940b8d73bde88481a AS build
WORKDIR /web
COPY package*.json ./
RUN npm ci --no-audit --no-fund
COPY . ./
RUN npm run build

FROM caddy:2-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh
COPY --from=build /web/dist /srv
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
