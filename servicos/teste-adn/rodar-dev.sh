#!/usr/bin/env bash
# ERP BKM, teste único do ambiente nacional da NFS-e (ADN), pedido do Moises em 20/11/2026; guarda escolhida por ele
# em 21/11/2026: certificado no Secret Manager do bkm-erp, lido só por uma conta de serviço própria, e tudo apagado no fim.
# Rodar no Cloud Shell do projeto bkm-erp, pelo Moises (dono do projeto):
#   1. Suba o .pfx da BKM 03 para o Cloud Shell (menu ⋮ › Fazer upload).
#   2. bash ~/SIENGE/servicos/teste-adn/rodar-dev.sh ~/arquivo.pfx      (pede o CNPJ e a senha; apaga o .pfx no fim)
#   3. O resumo sai no fim (contagens por mês e por município, sem XML e sem CNPJ de terceiros).
#   4. bash ~/SIENGE/servicos/teste-adn/rodar-dev.sh --rodar             (roda de novo com os segredos já criados)
#   5. bash ~/SIENGE/servicos/teste-adn/rodar-dev.sh --apagar            (apaga job, segredos e conta)
# Regras (revisão do #117): a conta erp-teste-adn não tem papel nenhum no projeto, só secretAccessor nos dois segredos;
# nunca dar a ela papel de deploy; a conta compute do build não pode ler esses segredos (o script confere e para).
# Durante o teste, só o Moises tem run.admin e serviceAccountUser nessa conta (quem tem os dois publica outro código
# com ela e lê o certificado); papel herdado da pasta ou da organização não aparece na checagem do script.
set -euo pipefail
P=bkm-erp-515119
R=southamerica-east1
NOME=erp-teste-adn
SA=$NOME@$P.iam.gserviceaccount.com
S_PFX=adn-cert-pfx
S_SENHA=adn-cert-senha
gcloud config set project "$P" >/dev/null

if [ "${1:-}" = "--apagar" ]; then
  gcloud run jobs delete "$NOME" --region "$R" --quiet || true
  gcloud secrets delete "$S_PFX" --quiet || true
  gcloud secrets delete "$S_SENHA" --quiet || true
  gcloud iam service-accounts delete "$SA" --quiet || true
  echo "Apagados: job, os dois segredos e a conta $SA."; exit 0
fi

RODAR_SO=0; [ "${1:-}" = "--rodar" ] && RODAR_SO=1   # segredos já criados: só publica e roda o job
PFX=${1:?"informe o caminho do .pfx: bash rodar-dev.sh ~/arquivo.pfx (ou --rodar)"}
CNPJ=${ADN_CNPJ:-}
[ -n "$CNPJ" ] || read -r -p "CNPJ da empresa do certificado (só números): " CNPJ
CNPJ=${CNPJ//[^0-9]/}; [ ${#CNPJ} -eq 14 ] || { echo "CNPJ precisa ter 14 dígitos." >&2; exit 1; }
[ "$RODAR_SO" = 1 ] || [ -f "$PFX" ] || { echo "Não achei $PFX" >&2; exit 1; }

# Quem já lê todos os segredos do projeto (papel no projeto inteiro): avisar e parar se for a conta compute
NUM=$(gcloud projects describe "$P" --format='value(projectNumber)')
COMPUTE="serviceAccount:$NUM-compute@developer.gserviceaccount.com"
AMPLOS=$(gcloud projects get-iam-policy "$P" --format=json | python3 -c "import json,sys
for b in json.load(sys.stdin).get('bindings',[]):
  if b['role'] in ('roles/secretmanager.secretAccessor','roles/secretmanager.admin','roles/owner','roles/editor'):
    print(b['role'], ' '.join(b['members']))")
echo "Papéis no projeto que leem qualquer segredo:"; echo "$AMPLOS" | sed 's/^/  /'
if echo "$AMPLOS" | grep -q "$COMPUTE"; then
  echo "A conta compute ($COMPUTE) tem papel que lê todos os segredos. Tire antes (o build roda com ela)." >&2; exit 1
fi

if [ "$RODAR_SO" = 0 ]; then
gcloud iam service-accounts describe "$SA" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$NOME" --display-name "Teste único do ADN (apagar no fim)"

# Segredos sem o valor na linha de comando: arquivos temporários só do usuário, apagados logo depois
umask 077; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
base64 -w0 "$PFX" > "$T/pfx"
read -r -s -p "Senha do certificado: " SENHA; echo; printf '%s' "$SENHA" > "$T/senha"; unset SENHA
for par in "$S_PFX:$T/pfx" "$S_SENHA:$T/senha"; do
  s=${par%%:*}; f=${par#*:}
  if gcloud secrets describe "$s" >/dev/null 2>&1; then gcloud secrets versions add "$s" --data-file="$f"
  else gcloud secrets create "$s" --replication-policy=user-managed --locations="$R" --data-file="$f"; fi
  gcloud secrets add-iam-policy-binding "$s" --member "serviceAccount:$SA" --role roles/secretmanager.secretAccessor >/dev/null
done
rm -rf "$T"; rm -f "$PFX"; echo "Segredos criados e o .pfx apagado do Cloud Shell."

fi
# O umask 077 acima vale só para os arquivos do segredo: o código clonado precisa ser legível dentro da imagem
# (com 077, o COPY leva os arquivos sem leitura para o usuário node e o job falha ao abrir job.ts; 23/nov/2026).
umask 022
DIR=$(mktemp -d); git clone --depth 1 --branch "${ADN_BRANCH:-develop}" https://github.com/Mbekerman/SIENGE.git "$DIR/SIENGE"
gcloud run jobs deploy "$NOME" --source "$DIR/SIENGE/servicos/teste-adn" --region "$R" \
  --service-account "$SA" --tasks 1 --max-retries 0 --task-timeout 2h --memory 512Mi --cpu 1 \
  --set-secrets "ADN_CERT_PFX_B64=$S_PFX:latest,ADN_CERT_SENHA=$S_SENHA:latest" \
  --set-env-vars "ADN_CNPJ=$CNPJ,ADN_LOTES=${ADN_LOTES:-200},ADN_NSU=${ADN_NSU:-0}"
gcloud run jobs execute "$NOME" --region "$R" --wait || true
echo "Resumo:"
gcloud logging read "resource.type=cloud_run_job AND resource.labels.job_name=$NOME" --freshness 3h --limit 5 --format='value(textPayload)'
echo "Mande o resumo acima na conversa. Para apagar tudo: bash $0 --apagar"
