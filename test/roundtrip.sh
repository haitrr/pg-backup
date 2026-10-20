#!/bin/bash
# End-to-end test: dump, check the tiers and encryption, change the data, then
# restore and check it came back. Builds pg-backup:test unless IMAGE is set.
#
#   PG_MAJOR=17 test/roundtrip.sh
set -euo pipefail

cd "$(dirname "$0")"
export PG_MAJOR=${PG_MAJOR:-17}
export IMAGE=${IMAGE:-pg-backup:test}
export COMPOSE_PROJECT_NAME=pg-backup-test
COMPOSE="docker compose"

[ "$IMAGE" != pg-backup:test ] || docker build -q --build-arg PG_MAJOR="$PG_MAJOR" -t "$IMAGE" .. >/dev/null

TMP=$(mktemp -d)
down() { $COMPOSE down -v -t 1 >/dev/null 2>&1 || true; }
cleanup() { down; rm -rf "$TMP"; }
trap cleanup EXIT

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }
sql() { $COMPOSE exec -T postgres psql -qtA -U app -d app -c "$1" </dev/null; }
backup() { $COMPOSE exec -T postgres-backup "$@" </dev/null; }
restore() { $COMPOSE run --rm -T -v "$1":/run/age.key:ro "${@:3}" postgres-backup pg-backup restore "$2"; }

docker run --rm "$IMAGE" age-keygen >"$TMP/key" 2>/dev/null
docker run --rm "$IMAGE" age-keygen >"$TMP/wrong.key" 2>/dev/null
export BACKUP_AGE_RECIPIENT=
down
$COMPOSE up -d --wait postgres >/dev/null 2>&1

# No recipient: the sidecar must exit rather than run.
$COMPOSE up -d postgres-backup >/dev/null 2>&1
sleep 2
[ "$($COMPOSE ps -a --format '{{.State}}' postgres-backup)" = exited ] || fail "sidecar runs without a recipient"
$COMPOSE logs postgres-backup 2>&1 | grep -q 'BACKUP_AGE_RECIPIENT is unset' || fail "no message about the recipient"
pass "refuses to start without BACKUP_AGE_RECIPIENT"

sql "create table t (v text); insert into t values ('before');"
export BACKUP_AGE_RECIPIENT=$(grep -o 'age1[a-z0-9]*' "$TMP/key")
$COMPOSE up -d postgres-backup >/dev/null 2>&1
for _ in $(seq 30); do
  backup sh -c 'ls /backups/monthly/*.sql.gz.age' >/dev/null 2>&1 && break
  sleep 1
done
for tier in hourly daily weekly monthly; do
  backup sh -c "ls /backups/$tier/*.sql.gz.age" >/dev/null 2>&1 || fail "no $tier dump"
done
pass "hourly dump promoted to daily, weekly, monthly"

HOURLY=$(backup pg-backup list | grep /hourly/ | head -1 | tr -d '\r')
backup head -c 21 "$HOURLY" | grep -q '^age-encryption.org/v1' || fail "dump is not age ciphertext"
backup sh -c "! ls /backups/*/*.part" >/dev/null 2>&1 || fail ".part file left behind"
pass "dump is encrypted: $HOURLY"

DEPLOY=$(backup pg-backup now | tr -d '\r')
[[ $DEPLOY == /backups/deployments/app-deploy-*.sql.gz.age ]] || fail "unexpected now path: $DEPLOY"
pass "now writes $DEPLOY"

sql "update t set v = 'after'; create table extra (x int);"

if restore "$TMP/wrong.key" "$HOURLY" -e RESTORE_ASSUME_YES=1 >/dev/null 2>&1; then fail "restored with the wrong key"; fi
[ "$(sql 'select v from t')" = after ] || fail "failed restore changed the database"
pass "wrong key fails and leaves the database alone"

echo nope | restore "$TMP/key" "$HOURLY" >/dev/null 2>&1 && fail "restored without confirmation"
[ "$(sql 'select v from t')" = after ] || fail "aborted restore changed the database"
pass "wrong confirmation aborts"

echo app | restore "$TMP/key" "$HOURLY" >/dev/null || fail "restore with confirmation failed"
[ "$(sql 'select v from t')" = before ] || fail "restore did not bring the row back"
pass "restore over the live database brings the data back"

# A dump on the host, mounted in the way an app's restore.sh does it.
sql "update t set v = 'after';"
backup cat "$DEPLOY" >"$TMP/host.sql.gz.age"
restore "$TMP/key" /run/dump.sql.gz.age -v "$TMP/host.sql.gz.age":/run/dump.sql.gz.age:ro -e RESTORE_ASSUME_YES=1 >/dev/null
[ "$(sql 'select v from t')" = before ] || fail "restore from a host file did not bring the row back"
pass "restore from a host file"

echo "all passed (postgres $PG_MAJOR)"
