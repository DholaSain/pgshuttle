#!/usr/bin/env bash
# Load a shared export file into the local target container. Convenience for
# whoever receives the file and happens to have this repo -- plain pg_restore
# works just as well, which is the point of exporting a standard archive.

set -uo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

: "${TGT_DB_URL:?TGT_DB_URL is required}"
: "${IMPORT_FILE:?IMPORT_FILE is required}"
JOBS="${JOBS:-4}"

TGT="$(PGSSLMODE_DEFAULT=prefer sanitize_url "$TGT_DB_URL")"
export PGOPTIONS="-c synchronous_commit=off -c maintenance_work_mem=512MB -c statement_timeout=0"
export PGCONNECT_TIMEOUT=15

[ -f "$IMPORT_FILE" ] || die "no such file: $IMPORT_FILE"

objects=$(pg_restore -l "$IMPORT_FILE" 2>/dev/null | grep -c '^[0-9]')
[ "${objects:-0}" -gt 0 ] || die "$IMPORT_FILE is not a readable pg_dump custom archive (truncated download?)"
info "$(basename "$IMPORT_FILE") -- $objects objects"

if [ -f "$IMPORT_FILE.sha256" ]; then
  if (cd "$(dirname "$IMPORT_FILE")" && sha256sum -c "$(basename "$IMPORT_FILE").sha256" >/dev/null 2>&1); then
    ok "checksum matches"
  else
    die "checksum does NOT match -- the file is corrupt, download it again"
  fi
fi

psql "$TGT" -Atqc "select 1" >/dev/null 2>&1 || die "the local target is not running -- ./pgshuttle up"

info "wiping the target and loading..."
psql "$TGT" -v ON_ERROR_STOP=1 -q <<'SQL'
DO $$
DECLARE s text;
BEGIN
  FOR s IN SELECT nspname FROM pg_namespace
           WHERE nspname NOT IN ('pg_catalog','information_schema','public')
             AND nspname NOT LIKE 'pg_%'
  LOOP
    EXECUTE format('DROP SCHEMA %I CASCADE', s);
  END LOOP;
  EXECUTE 'DROP SCHEMA IF EXISTS public CASCADE';
  EXECUTE 'CREATE SCHEMA public';
END $$;
SQL

pg_restore -d "$TGT" -j "$JOBS" --no-owner --no-acl "$IMPORT_FILE" > /tmp/import.log 2>&1
perr=$(grep -c '^pg_restore: error' /tmp/import.log 2>/dev/null); perr=${perr:-0}
[ "$perr" -gt 0 ] && warn "$perr error(s) during restore:" && grep '^pg_restore: error' /tmp/import.log | head -5 >&2

psql "$TGT" -qc "ANALYZE" >/dev/null 2>&1
n=$(psql "$TGT" -Atqc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='r' and n.nspname not in ('pg_catalog','information_schema')")
size=$(psql "$TGT" -Atqc "select pg_size_pretty(pg_database_size(current_database()))")
ok "imported -- $n tables, $size"
