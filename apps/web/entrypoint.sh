#!/bin/sh
# Recusa subir com chave que não seja a publicável nova do Supabase: o Caddy escreve SUPABASE_KEY no HTML
# público, então uma service_role ou sb_secret_ posta ali por engano vazaria para qualquer um (revisão do
# PR #89). O deploy falha antes de servir a página. O projeto do ERP só usa a chave nova (sb_publishable_).
# `case` olha o valor inteiro (grep olharia linha por linha e deixaria passar um valor com quebra de linha).
falha() { echo "$1 O serviço não sobe." >&2; exit 1; }

case "$SUPABASE_KEY" in
  sb_publishable_*[!A-Za-z0-9_-]*) falha "SUPABASE_KEY não é a chave publicável (sb_publishable_...)." ;;
  sb_publishable_?*) ;;
  *) falha "SUPABASE_KEY ausente ou não é a chave publicável (sb_publishable_...)." ;;
esac

proj=${SUPABASE_URL#https://}
proj=${proj%.supabase.co}
case "$SUPABASE_URL" in
  https://?*.supabase.co) ;;
  *) falha "SUPABASE_URL fora do formato https://<projeto>.supabase.co." ;;
esac
case "$proj" in
  ""|*[!a-z0-9]*) falha "SUPABASE_URL fora do formato https://<projeto>.supabase.co." ;;
esac

case "$AMBIENTE" in
  ""|dev) ;;
  *) falha "AMBIENTE só pode ser vazio (produção) ou dev." ;;
esac

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
