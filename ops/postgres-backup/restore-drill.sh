#!/bin/sh
# Exercice de restauration : restaure le dernier dump dans un Postgres jetable,
# lancé DANS le conteneur (aucune autre base créée), puis compare le nombre de
# lignes table par table avec la production. La production n'est que lue.
# Exécuté par le service Railway « pg-restore-drill » (image postgres:18-alpine, cron).
# Mêmes variables que backup.sh. Code de sortie 1 si la restauration échoue ou si
# une table de production manque dans la copie restaurée.
set -eu

PREFIX="daily/"
apk add --no-cache aws-cli >/dev/null

LATEST="$(aws s3 ls "s3://${BUCKET}/${PREFIX}" --endpoint-url "$ENDPOINT" \
  | awk '{print $4}' | grep '\.dump$' | sort | tail -n 1)"
[ -n "$LATEST" ] || { echo "[drill] ÉCHEC : aucun dump dans s3://${BUCKET}/${PREFIX}"; exit 1; }
echo "[drill] dernier dump : ${LATEST}"
aws s3 cp "s3://${BUCKET}/${PREFIX}${LATEST}" /tmp/latest.dump --endpoint-url "$ENDPOINT" --only-show-errors

# Postgres jetable, socket Unix uniquement, dans /tmp.
PGTMP=/tmp/pgdrill
mkdir -p "$PGTMP" && chown postgres "$PGTMP"
gosu postgres initdb -D "$PGTMP/data" -U postgres --auth=trust --no-locale -E UTF8 >/dev/null 2>&1
gosu postgres pg_ctl -D "$PGTMP/data" -o "-c listen_addresses='' -k $PGTMP" -w start >/dev/null
LOCAL="host=$PGTMP user=postgres"
psql "$LOCAL dbname=postgres" -qc "CREATE DATABASE restored" >/dev/null

echo "[drill] pg_restore…"
pg_restore --no-owner --no-acl --exit-on-error -d "$LOCAL dbname=restored" /tmp/latest.dump

TABLES_SQL="SELECT quote_ident(schemaname)||'.'||quote_ident(tablename) FROM pg_tables
            WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1"
psql "$DATABASE_URL" -Atc "$TABLES_SQL" | LC_ALL=C sort > /tmp/prod_tables.txt
psql "$LOCAL dbname=restored" -Atc "$TABLES_SQL" | LC_ALL=C sort > /tmp/restored_tables.txt

MISSING="$(comm -23 /tmp/prod_tables.txt /tmp/restored_tables.txt)"
FAIL=0
if [ -n "$MISSING" ]; then
  echo "[drill] ÉCHEC : tables absentes de la restauration :"; echo "$MISSING"; FAIL=1
fi

# Comptages exacts. Un écart est normal pour les écritures faites depuis le dump ;
# il est affiché, pas bloquant. Une table vide côté restauration mais pleine en prod l'est.
printf '%-50s %12s %12s\n' "table" "prod" "restaurée"
TOTAL_P=0; TOTAL_R=0
while read -r t; do
  p="$(psql "$DATABASE_URL" -Atc "SELECT count(*) FROM $t")"
  r="$(psql "$LOCAL dbname=restored" -Atc "SELECT count(*) FROM $t" 2>/dev/null || echo "-")"
  flag=""
  if [ "$p" != "$r" ]; then flag=" ≠"; fi
  if [ "$r" = "0" ] && [ "$p" -gt 0 ]; then flag=" ÉCHEC (vide)"; FAIL=1; fi
  printf '%-50s %12s %12s%s\n' "$t" "$p" "$r" "$flag"
  TOTAL_P=$((TOTAL_P + p))
  if [ "$r" != "-" ]; then TOTAL_R=$((TOTAL_R + r)); fi
done < /tmp/prod_tables.txt
echo "[drill] total lignes : prod=${TOTAL_P} restaurée=${TOTAL_R}"

gosu postgres pg_ctl -D "$PGTMP/data" -m fast stop >/dev/null
if [ "$FAIL" -ne 0 ]; then echo "[drill] RÉSULTAT : ÉCHEC (${LATEST})"; exit 1; fi
echo "[drill] RÉSULTAT : OK — ${LATEST} restauré et vérifié"
