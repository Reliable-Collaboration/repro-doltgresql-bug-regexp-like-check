#!/bin/sh
# Runs repro.sql on PostgreSQL 18.6 and on DoltgreSQL 1.3.1, each in a throwaway container, and prints
# the two outputs side by side. Exits 0 when DoltgreSQL's output is identical to PostgreSQL's, and 1
# when it differs.
#
# Other images: DOLTGRESQL_IMAGE=dolthub/doltgresql:latest ./repro.sh
set -eu
cd "$(dirname "$0")"

POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18.6-bookworm@sha256:1c59e2c3c818eaa0f0628f695b36e7c9e362d6b219b36a54a32df645cbd7e1af}"
DOLTGRESQL_IMAGE="${DOLTGRESQL_IMAGE:-dolthub/doltgresql:1.3.1@sha256:6c85cb1f35beabf47f094336a420255130b841b1645f36d79ef046276af36851}"
PG=repro-doltgresql-bug-regexp-like-check-postgres
DG=repro-doltgresql-bug-regexp-like-check-doltgresql
OUT=$(mktemp -d)

cleanup() {
  docker rm -f "$PG" "$DG" >/dev/null 2>&1 || true
  rm -rf "$OUT"
}
trap cleanup EXIT

start() { # container, image, password variable
  docker rm -f "$1" >/dev/null 2>&1 || true
  echo "Starting $2"
  docker run -d --name "$1" -e "$3=password" "$2" >/dev/null
}

wait_until_ready() { # container: answers over TCP twice in a row
  ok=0
  tries=0
  while [ "$ok" -lt 2 ]; do
    if docker exec -e PGPASSWORD=password "$1" psql -X -h 127.0.0.1 -U postgres -d postgres -tAc 'SELECT 1' >/dev/null 2>&1; then
      ok=$((ok + 1))
    else
      ok=0
    fi
    tries=$((tries + 1))
    if [ "$tries" -gt 120 ]; then
      echo "$1 did not start. Its log:" >&2
      docker logs "$1" >&2
      exit 2
    fi
    sleep 1
  done
}

run() { # container, output file
  docker cp repro.sql "$1:/tmp/repro.sql" >/dev/null 2>&1 || { echo "Could not copy repro.sql into $1" >&2; exit 2; }
  # -t gives psql a terminal, so each error is printed right after the statement that caused it.
  docker exec -t -e PGPASSWORD=password "$1" \
    psql -X -P pager=off -h 127.0.0.1 -U postgres -d postgres --echo-all -f /tmp/repro.sql | tr -d '\r' > "$2"
}

start "$PG" "$POSTGRES_IMAGE" POSTGRES_PASSWORD
start "$DG" "$DOLTGRESQL_IMAGE" DOLTGRES_PASSWORD
wait_until_ready "$PG"
wait_until_ready "$DG"
run "$PG" "$OUT/postgres.txt"
run "$DG" "$OUT/doltgresql.txt"

echo
echo "Left: PostgreSQL. Right: DoltgreSQL. Lines that differ are marked with |."
echo
diff -y -t -W 121 "$OUT/postgres.txt" "$OUT/doltgresql.txt" || true
echo

if cmp -s "$OUT/postgres.txt" "$OUT/doltgresql.txt"; then
  echo "Result: DoltgreSQL's output is identical to PostgreSQL's."
  exit 0
fi
echo "Result: DoltgreSQL's output differs from PostgreSQL's on $(diff "$OUT/postgres.txt" "$OUT/doltgresql.txt" | grep -c '^>') line(s), marked with |."
exit 1
