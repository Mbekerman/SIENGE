#!/usr/bin/env bash
# Sobe um Postgres 16 temporário, aplica o shim + migrations e roda os testes.
# Uso: bash supabase/tests/run.sh   (precisa de postgres 16 em /usr/lib/postgresql/16/bin ou PGBIN)
set -euo pipefail
cd "$(dirname "$0")/../.."
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
export PATH="$PGBIN:$PATH"
DIR="$(mktemp -d)"
PORT="${PORT:-54331}"
if [ "$(id -u)" = "0" ]; then RUN="runuser -u postgres --"; chown postgres "$DIR"; else RUN=""; fi
cleanup() { $RUN pg_ctl -D "$DIR" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$DIR"; }
trap cleanup EXIT
# Como no Supabase, o superusuário de verdade é o supabase_admin. O postgres é superusuário enquanto as migrations
# rodam (como no CI de sempre) e deixa de ser só para rodar os scripts do bkm_dev (supabase/dev/), onde ele não é.
$RUN initdb -D "$DIR" -U supabase_admin -A trust -E UTF8 --locale=C >/dev/null
$RUN pg_ctl -D "$DIR" -o "-p $PORT -k /tmp" -l "$DIR/log" start -w >/dev/null
ADMIN="psql -h /tmp -p $PORT -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q"
$ADMIN -c "create role postgres login superuser createrole createdb bypassrls"
PSQL="psql -h /tmp -p $PORT -U postgres -d postgres -v ON_ERROR_STOP=1 -q"
$PSQL -f supabase/tests/shim_supabase.sql
# Migrations do espelho do Sienge rodam no pior caso dos privilégios padrão do Supabase (tudo o que o
# postgres cria nasce aberto aos papéis da API), para o teste provar que a migration fecha o que cria.
PADRAO_ABERTO="alter default privileges for role postgres grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres grant all on functions to anon, authenticated, service_role;"
PADRAO_FECHADO="alter default privileges for role postgres revoke all on tables from anon, authenticated, service_role;
alter default privileges for role postgres revoke all on sequences from anon, authenticated, service_role;
alter default privileges for role postgres revoke all on functions from anon, authenticated, service_role;"
# Migration com script do bkm_dev (supabase/dev/ com o mesmo nome): roda o script no lugar dela, com o postgres sem
# superusuário, como o Moises roda no SQL Editor. Erro de permissão no script aparece aqui, não no bkm_dev.
for f in supabase/migrations/*.sql; do
  dev="supabase/dev/$(basename "$f")"
  if [ -f "$dev" ]; then
    echo "bkm_dev: $(basename "$f") (postgres sem superusuário)"
    # No bkm_dev os papéis erp_* foram criados pelo postgres já sem superusuário, e por isso ele tem ADMIN sobre eles
    # (sem herdar nem assumir: o script se dá o set quando precisa).
    # Depois o ADMIN sai, porque o teste do catálogo confere que os papéis erp_* não têm membros.
    $ADMIN -c "set client_min_messages = warning; do \$\$ declare r text; begin for r in select rolname from pg_roles where rolname like 'erp\\_%' loop
      execute format('grant %I to postgres with admin true, inherit false, set false', r); end loop; end \$\$"
    $ADMIN -c "alter role postgres nosuperuser"
    $PSQL -f "$dev" >/dev/null
    $ADMIN -c "alter role postgres superuser"
    $ADMIN -c "set client_min_messages = warning; do \$\$ declare r text; begin for r in select rolname from pg_roles where rolname like 'erp\\_%' loop
      execute format('revoke %I from postgres cascade', r); end loop; end \$\$"
    continue
  fi
  echo "migration: $(basename "$f")"
  case "$f" in
    *sienge*) $PSQL -c "$PADRAO_ABERTO"; $PSQL -f "$f"; $PSQL -c "$PADRAO_FECHADO" ;;
    *) $PSQL -f "$f" ;;
  esac
done
$PSQL -f supabase/tests/sienge.sql 2>&1 | sed "s/^psql:[^ ]* NOTICE:  //" | grep -E "^(ok |# |FALHOU|TODOS)|ERROR"
$PSQL -f supabase/tests/erp.sql 2>&1 | sed "s/^psql:[^ ]* NOTICE:  //" | grep -E "^(ok |# |FALHOU|TODOS)|ERROR"
