#!/bin/sh
# Sauvegarde logique quotidienne de la base ATLAS (Railway, plan Hobby : pas de PITR).
# Exécuté par le service Railway « pg-backup » (image postgres:18-alpine, cron).
# Variables requises : DATABASE_URL, BUCKET, ENDPOINT, AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION. Optionnelle : RETENTION_COUNT (défaut 30).
set -eu

KEEP="${RETENTION_COUNT:-30}"
PREFIX="daily/"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
FILE="atlas-${STAMP}.dump"

apk add --no-cache aws-cli >/dev/null

echo "[backup] pg_dump -> /tmp/${FILE}"
pg_dump "$DATABASE_URL" --format=custom --no-owner --no-acl --file="/tmp/${FILE}"

# Un dump illisible ne doit jamais partir dans le bucket comme s'il était valide.
TOC_ENTRIES="$(pg_restore --list "/tmp/${FILE}" | grep -vc '^;')"
SIZE="$(wc -c < "/tmp/${FILE}")"
echo "[backup] dump OK : ${SIZE} octets, ${TOC_ENTRIES} entrées"

aws s3 cp "/tmp/${FILE}" "s3://${BUCKET}/${PREFIX}${FILE}" --endpoint-url "$ENDPOINT" --only-show-errors
echo "[backup] envoyé : s3://${BUCKET}/${PREFIX}${FILE}"

# Rétention : on garde les KEEP dumps les plus récents (les noms sont triables par date).
aws s3 ls "s3://${BUCKET}/${PREFIX}" --endpoint-url "$ENDPOINT" \
  | awk '{print $4}' | grep '\.dump$' | sort > /tmp/dumps.txt
TOTAL="$(wc -l < /tmp/dumps.txt)"
if [ "$TOTAL" -gt "$KEEP" ]; then
  head -n "$((TOTAL - KEEP))" /tmp/dumps.txt | while read -r old; do
    aws s3 rm "s3://${BUCKET}/${PREFIX}${old}" --endpoint-url "$ENDPOINT" --only-show-errors
    echo "[backup] rétention : supprimé ${old}"
  done
fi
echo "[backup] terminé (${TOTAL} dumps avant rétention, ${KEEP} conservés au plus)"
