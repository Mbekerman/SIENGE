#!/bin/sh
# Recusa subir com chave que não seja a publicável nova do Supabase: o Caddy escreve SUPABASE_KEY no HTML
# público, então uma service_role ou sb_secret_ posta ali por engano vazaria para qualquer um (revisão do
# PR #89). O deploy falha antes de servir a página. O projeto do ERP só usa a chave nova (sb_publishable_).
if ! printf '%s' "$SUPABASE_KEY" | grep -Eq '^sb_publishable_[A-Za-z0-9_-]+$'; then
  echo "SUPABASE_KEY ausente ou não é a chave publicável (sb_publishable_...). O serviço não sobe." >&2
  exit 1
fi
if ! printf '%s' "$SUPABASE_URL" | grep -Eq '^https://[a-z0-9]+\.supabase\.co$'; then
  echo "SUPABASE_URL ausente ou fora do formato https://<projeto>.supabase.co. O serviço não sobe." >&2
  exit 1
fi
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
