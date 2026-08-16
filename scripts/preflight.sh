#!/usr/bin/env bash
# Everything that has to be true before a dump is worth starting. Run it while
# connected to the source; it answers in seconds instead of failing an hour in.

set -uo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

: "${SRC_DB_URL:?SRC_DB_URL is required}"
SRC="$(sanitize_url "$SRC_DB_URL")"
export PGCONNECT_TIMEOUT=10

fail=0
info "source: $(redact "$SRC")"
echo

# 1 -- can the container speak to the source at all
if out=$(psql "$SRC" -Atqc "select 1" 2>&1); then
  ok "connected to the source"
else
  err "cannot connect to the source"
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  echo
  err "things to check, in order:"
  err "  1. is your link to the source up (VPN, SSH tunnel, IP allowlist)?"
  err "  2. does 'psql \"\$SRC_DB_URL\" -c \"select 1\"' work on the host?"
  err "     if yes, Docker is not inheriting the host route -- see README,"
  err "     'Preflight cannot connect, but psql works on the host'"
  err "  3. is the password percent-encoded? @ must be %40, # must be %23"
  exit 1
fi

# 2 -- version compatibility; pg_dump refuses to read a newer server
srv=$(psql "$SRC" -Atqc "select current_setting('server_version')")
cli=$(pg_dump --version | awk '{print $3}')
if [ "${srv%%.*}" -gt "${cli%%.*}" ]; then
  err "server is pg ${srv} but pg_dump is ${cli} -- pg_dump cannot read a newer server"
  err "  fix: set PG_MAJOR=${srv%%.*} in .env, then ./pgshuttle prepare (needs internet)"
  fail=1
else
  ok "server pg $srv / client pg_dump $cli -- compatible"
fi

# 3 -- how much are we about to pull
IFS=$'\t' read -r dbname dbsize tables <<< "$(psql "$SRC" -At -F $'\t' -c "
  select current_database(),
         pg_size_pretty(pg_database_size(current_database())),
         (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
          where c.relkind='r' and n.nspname not in ('pg_catalog','information_schema')
            and n.nspname not like 'pg\_%')")"
ok "database $dbname -- $dbsize, $tables tables"

# 4 -- extensions the local target will need to provide
exts=$(psql "$SRC" -Atqc "select string_agg(extname, ', ' order by extname) from pg_extension where extname <> 'plpgsql'")
if [ -n "$exts" ]; then
  info "extensions in use: $exts"
  info "  plain postgres provides most of these; if one is missing the restore"
  info "  will say so, and you can switch PG_IMAGE then -- restore runs offline"
else
  ok "no extensions beyond plpgsql"
fi

# 5 -- large objects live outside any table and this tool does not carry them
los=$(psql "$SRC" -Atqc "select count(*) from pg_largeobject_metadata" 2>/dev/null || echo 0)
if [ "${los:-0}" != "0" ]; then
  warn "$los large objects (lo_* / oid columns) exist and are NOT copied by this tool"
  warn "  if your app uses them, add a separate: pg_dump --blobs --section=data"
else
  ok "no large objects to worry about"
fi

# 6 -- largest tables, i.e. the ones a dropped connection will cost you
echo
info "largest tables:"
psql "$SRC" -At -F $'\t' -c "
  select n.nspname||'.'||c.relname, pg_size_pretty(pg_total_relation_size(c.oid))
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind='r' and n.nspname not in ('pg_catalog','information_schema')
  order by pg_total_relation_size(c.oid) desc limit 10" \
  | awk -F'\t' '{printf "    %-56s %s\n", $1, $2}'

echo
if [ "$fail" = 0 ]; then
  ok "preflight passed -- run ./pgshuttle dump"
else
  err "preflight failed"
  exit 1
fi
