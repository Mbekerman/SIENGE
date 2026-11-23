#!/usr/bin/env bash
# ERP BKM, busca das notas recebidas (Moises, 23/11/2026): Cloud Run Job erp-busca-notas no bkm-erp, de hora em hora.
# Guarda (a mesma do teste do ADN, escolhida pelo Moises em 21/11/2026): certificados e a senha do banco só no Secret
# Manager, lidos só pela conta erp-busca-notas, que não tem papel nenhum no projeto. O banco: login erp_busca_notas, que
# só alcança a caixa de notas (cartão do Moises, 23/11/2026).
# Rodar no Cloud Shell do projeto bkm-erp, pelo Moises, nesta ordem:
#   1. bash publicar.sh --certificado ~/arquivo.pfx    (uma vez por empresa: pede o id da empresa no ERP e a senha do
#                                                      certificado; guarda chave + certificado em PEM; apaga o .pfx)
#   2. bash publicar.sh --banco ~/prod-ca-2021.crt     (o certificado raiz do Supabase, de Database > Settings > SSL: o
#                                                      serviço confere o servidor do banco com ele; gera a senha do login,
#                                                      guarda a URL e mostra o SQL para colar no SQL Editor do Supabase,
#                                                      que só liga o login com a rede do banco, o pg_net, fechada; S-143)
#   3. bash publicar.sh --publicar                     (publica o job com o código da develop e roda uma vez)
#   4. bash publicar.sh --agendar                      (de hora em hora, pelo Cloud Scheduler)
#   bash publicar.sh --rodar     roda de novo e mostra o log
#   bash publicar.sh --parar     tira o agendamento (o job e os segredos ficam)
# Nunca dar à conta erp-busca-notas papel de deploy; a conta compute do build não pode ler os segredos (o script confere).
set -euo pipefail
P=bkm-erp-515119
R=southamerica-east1
NOME=erp-busca-notas
SA=$NOME@$P.iam.gserviceaccount.com
SA_AGENDA=erp-busca-notas-agenda@$P.iam.gserviceaccount.com
S_DB=notas-db-url
S_CA=notas-ca-icp
S_DBCA=notas-db-ca
gcloud config set project "$P" >/dev/null
[ -n "$(gcloud config get-value account 2>/dev/null)" ] || { echo "Entre antes: gcloud auth login" >&2; exit 1; }

conta() {
  gcloud iam service-accounts describe "$SA" >/dev/null 2>&1 || \
    gcloud iam service-accounts create "$NOME" --display-name "Busca das notas recebidas (sem papel no projeto)"
}
segredo() {   # nome arquivo: cria ou acrescenta versão e dá leitura só à conta do job
  if gcloud secrets describe "$1" >/dev/null 2>&1; then gcloud secrets versions add "$1" --data-file="$2" >/dev/null
  else gcloud secrets create "$1" --replication-policy=user-managed --locations="$R" --data-file="$2" >/dev/null; fi
  gcloud secrets add-iam-policy-binding "$1" --member "serviceAccount:$SA" --role roles/secretmanager.secretAccessor >/dev/null
}
conferir_compute() {
  local num compute amplos
  num=$(gcloud projects describe "$P" --format='value(projectNumber)')
  compute="serviceAccount:$num-compute@developer.gserviceaccount.com"
  amplos=$(gcloud projects get-iam-policy "$P" --format=json | python3 -c "import json,sys
for b in json.load(sys.stdin).get('bindings',[]):
  if b['role'] in ('roles/secretmanager.secretAccessor','roles/secretmanager.admin','roles/owner','roles/editor'):
    print(b['role'], ' '.join(b['members']))")
  echo "Papéis no projeto que leem qualquer segredo:"; echo "$amplos" | sed 's/^/  /'
  if echo "$amplos" | grep -q "$compute"; then echo "A conta compute tem papel que lê todos os segredos. Tire antes." >&2; exit 1; fi
}
certs_montados() {   # /certs/<empresa>/pem=notas-cert-<8 primeiros>:latest, para cada segredo de certificado
  gcloud secrets list --filter='labels.busca-notas=certificado' --format='value(name,labels.empresa)' | \
    while read -r s e; do [ -n "$e" ] && printf '/certs/%s/pem=%s:latest,' "$(echo "$e" | tr '_' '-')" "$s"; done
}

case "${1:-}" in
--certificado)
  PFX=${2:?"informe o .pfx: bash publicar.sh --certificado ~/arquivo.pfx"}
  [ -f "$PFX" ] || { echo "Não achei $PFX" >&2; exit 1; }
  read -r -p "Id da empresa no ERP (uuid; select id, apelido from erp.empresas): " EMP
  [[ "$EMP" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "Id inválido." >&2; exit 1; }
  conta; conferir_compute
  umask 077; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  read -r -s -p "Senha do certificado: " SENHA; echo; printf '%s' "$SENHA" > "$T/senha"; unset SENHA
  # PFX antigo (RC2/3DES) só abre com -legacy no OpenSSL 3; a saída é PEM sem senha, que só vai para o Secret Manager
  openssl pkcs12 -in "$PFX" -nodes -passin "file:$T/senha" -out "$T/pem" 2>/dev/null || \
    openssl pkcs12 -legacy -in "$PFX" -nodes -passin "file:$T/senha" -out "$T/pem"
  grep -q 'PRIVATE KEY' "$T/pem" && grep -q 'BEGIN CERTIFICATE' "$T/pem" || { echo "O .pfx não tem chave e certificado." >&2; exit 1; }
  openssl x509 -in "$T/pem" -noout -subject -enddate | sed 's/^/  /'
  S="notas-cert-${EMP:0:8}"
  segredo "$S" "$T/pem"
  gcloud secrets update "$S" --update-labels "busca-notas=certificado,empresa=${EMP//-/_}" >/dev/null
  rm -rf "$T"; rm -f "$PFX"
  echo "Certificado guardado em $S e o .pfx apagado do Cloud Shell. Depois: bash publicar.sh --publicar" ;;
--banco)
  DBCA=${2:?"informe o certificado do Supabase: bash publicar.sh --banco ~/prod-ca-2021.crt"}
  [ -f "$DBCA" ] || { echo "Não achei $DBCA" >&2; exit 1; }
  openssl x509 -in "$DBCA" -noout -text 2>/dev/null | grep -q 'CA:TRUE' || { echo "$DBCA não é um certificado de autoridade (CA)." >&2; exit 1; }
  openssl x509 -in "$DBCA" -noout -subject -enddate -fingerprint -sha256 | sed 's/^/  /'
  conta
  segredo "$S_DBCA" "$DBCA"
  read -r -p "Ref do projeto Supabase (Settings > General): " REF
  read -r -p "Host do pooler de sessão (Connect > Session pooler, ex.: aws-0-sa-east-1.pooler.supabase.com): " HOST
  [[ "$REF" =~ ^[a-z0-9]{20}$ && "$HOST" =~ ^[a-z0-9.-]+\.supabase\.com$ ]] || { echo "Ref ou host inválidos." >&2; exit 1; }
  umask 077; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  openssl rand -hex 24 > "$T/senha"
  printf 'postgresql://erp_busca_notas.%s:%s@%s:5432/postgres?sslmode=verify-full' "$REF" "$(cat "$T/senha")" > "$T/url"
  segredo "$S_DB" "$T/url"
  # o banco guarda só o verificador SCRAM: a senha não passa pelo SQL Editor
  VERIF=$(python3 - "$T/senha" <<'PY'
import base64, hashlib, hmac, os, sys
pw = open(sys.argv[1]).read().strip().encode(); salt = os.urandom(16); it = 4096
s = hashlib.pbkdf2_hmac('sha256', pw, salt, it)
ck = hmac.new(s, b'Client Key', 'sha256').digest(); sk = hmac.new(s, b'Server Key', 'sha256').digest()
b = lambda x: base64.b64encode(x).decode()
print(f"SCRAM-SHA-256${it}:{b(salt)}${b(hashlib.sha256(ck).digest())}:{b(sk)}")
PY
)
  rm -rf "$T"
  echo; echo "Cole no SQL Editor do Supabase (projeto $REF). Só liga o login se o pg_net estiver fechado (S-143):"; echo
  cat <<SQL
do \$\$ begin
  if exists (select 1 from pg_namespace where nspname = 'net')
     and (has_schema_privilege('erp_busca_notas', 'net', 'usage')
          or exists (select 1 from pg_class c where c.relnamespace = 'net'::regnamespace
                      and has_table_privilege('erp_busca_notas', c.oid, 'select'))) then
    raise exception 'S-143: o pg_net continua aberto a todos os logins; o login do serviço não foi ligado';
  end if;
  alter role erp_busca_notas login password '$VERIF';
end \$\$;
SQL
  echo; echo "Depois: bash publicar.sh --publicar" ;;
--publicar|--rodar)
  conta; conferir_compute
  CERTS=$(certs_montados)
  [ -n "$CERTS" ] || { echo "Nenhum certificado guardado: bash publicar.sh --certificado ~/arquivo.pfx" >&2; exit 1; }
  gcloud secrets describe "$S_DB" >/dev/null 2>&1 && gcloud secrets describe "$S_DBCA" >/dev/null 2>&1 || \
    { echo "Falta o banco: bash publicar.sh --banco ~/prod-ca-2021.crt" >&2; exit 1; }
  if [ "$1" = --publicar ]; then
    # raízes da ICP-Brasil (a SEFAZ usa certificado de servidor dessa cadeia, que o Node não traz)
    umask 077; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
    for v in v5 v10 v11; do
      curl -fsS "https://acraiz.icpbrasil.gov.br/credenciadas/RAIZ/ICP-Brasil${v}.crt" -o "$T/$v.crt" || { echo "Não baixei a raiz $v" >&2; continue; }
      openssl x509 -inform DER -in "$T/$v.crt" -out "$T/$v.pem" 2>/dev/null || cp "$T/$v.crt" "$T/$v.pem"
      openssl x509 -in "$T/$v.pem" -noout -subject -fingerprint -sha256 | sed 's/^/  /'
      cat "$T/$v.pem" >> "$T/ca"
    done
    # confiança no primeiro uso: depois de guardadas, raízes diferentes das guardadas são recusadas (compare as
    # impressões digitais acima com as do site do ITI na primeira vez); para trocar de propósito, NOTAS_CA_NOVA=1
    if [ -s "$T/ca" ] && gcloud secrets describe "$S_CA" >/dev/null 2>&1; then
      gcloud secrets versions access latest --secret "$S_CA" > "$T/ca.guardada"
      if ! cmp -s "$T/ca" "$T/ca.guardada"; then
        [ "${NOTAS_CA_NOVA:-}" = 1 ] || { echo "As raízes da ICP-Brasil baixadas agora são diferentes das guardadas. Confira no site do ITI e, se for de propósito, rode com NOTAS_CA_NOVA=1." >&2; exit 1; }
        segredo "$S_CA" "$T/ca"
      fi
    elif [ -s "$T/ca" ]; then segredo "$S_CA" "$T/ca"; fi
    rm -rf "$T"
    umask 022   # o código clonado precisa ser legível dentro da imagem (lição do teste do ADN, 23/11/2026)
    DIR=$(mktemp -d); git clone --depth 1 --branch "${NOTAS_BRANCH:-develop}" https://github.com/Mbekerman/SIENGE.git "$DIR/SIENGE"
    CA=""; gcloud secrets describe "$S_CA" >/dev/null 2>&1 && CA="/ca/pem=$S_CA:latest,"
    gcloud run jobs deploy "$NOME" --source "$DIR/SIENGE/servicos/busca-notas" --region "$R" \
      --service-account "$SA" --tasks 1 --max-retries 0 --task-timeout 50m --memory 512Mi --cpu 1 \
      --set-secrets "${CERTS}${CA}/dbca/pem=$S_DBCA:latest,NOTAS_DB_URL=$S_DB:latest" \
      --set-env-vars "NOTAS_UF=${NOTAS_UF:-35},NOTAS_DB_CA=/dbca/pem$([ -n "$CA" ] && echo ',NOTAS_CA=/ca/pem')"
  fi
  gcloud run jobs execute "$NOME" --region "$R" --wait || true
  EXE=$(gcloud run jobs describe "$NOME" --region "$R" --format='value(status.latestCreatedExecution.name)')
  echo "Log da rodada (só contagens):"
  gcloud logging read "resource.type=cloud_run_job AND labels.\"run.googleapis.com/execution_name\"=\"$EXE\"" \
    --limit 50 --order asc --format='value(textPayload,jsonPayload)' ;;
--agendar)
  gcloud iam service-accounts describe "$SA_AGENDA" >/dev/null 2>&1 || \
    gcloud iam service-accounts create erp-busca-notas-agenda --display-name "Agenda da busca das notas (só executa o job)"
  gcloud run jobs add-iam-policy-binding "$NOME" --region "$R" --member "serviceAccount:$SA_AGENDA" --role roles/run.invoker >/dev/null
  URI="https://run.googleapis.com/v2/projects/$P/locations/$R/jobs/$NOME:run"
  if gcloud scheduler jobs describe "$NOME" --location "$R" >/dev/null 2>&1; then
    gcloud scheduler jobs update http "$NOME" --location "$R" --schedule "7 * * * *" --time-zone "America/Sao_Paulo" \
      --uri "$URI" --http-method POST --oauth-service-account-email "$SA_AGENDA"
  else
    gcloud scheduler jobs create http "$NOME" --location "$R" --schedule "7 * * * *" --time-zone "America/Sao_Paulo" \
      --uri "$URI" --http-method POST --oauth-service-account-email "$SA_AGENDA"
  fi
  echo "Agendado: todo minuto 7 de cada hora." ;;
--parar)
  gcloud scheduler jobs delete "$NOME" --location "$R" --quiet && echo "Agendamento tirado." ;;
*)
  sed -n '2,17p' "$0"; exit 1 ;;
esac
