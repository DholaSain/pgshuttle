#!/usr/bin/env bash
# Produce ONE shareable file from the already-restored local copy.
#
# The slow part -- pulling the data across the network -- has already happened.
# This reads the local container, so it runs at disk speed and offline. The
# output is a plain `pg_dump -Fc` archive: anyone with pg_restore or pgAdmin can
# load it, with or without this tool.

set -uo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

: "${TGT_DB_URL:?TGT_DB_URL is required}"
OUT="${OUT:?OUT is required}"
ZLEVEL="${EXPORT_ZLEVEL:-6}"
EXCLUDES="${EXPORT_EXCLUDES:-}"   # newline-separated table patterns, data dropped

SRC="$(PGSSLMODE_DEFAULT=prefer sanitize_url "$TGT_DB_URL")"
export PGCONNECT_TIMEOUT=15

mkdir -p "$(dirname "$OUT")"

# ---------------------------------------------------------------- preflight --
psql "$SRC" -Atqc "select 1" >/dev/null 2>&1 \
  || die "the local copy is not reachable -- run ./pgshuttle up (and ./pgshuttle restore if you have not yet)"

ntables=$(psql "$SRC" -Atqc "
  select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind='r' and n.nspname not in ('pg_catalog','information_schema')")
[ "${ntables:-0}" -gt 0 ] || die "the local copy has no tables -- run ./pgshuttle restore first"

dbname=$(psql "$SRC" -Atqc "select current_database()")
dbsize=$(psql "$SRC" -Atqc "select pg_size_pretty(pg_database_size(current_database()))")
info "exporting $dbname -- $ntables tables, $dbsize on disk"

# ------------------------------------------------------------------ excludes --
declare -a XARGS=()
if [ -n "$EXCLUDES" ]; then
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    XARGS+=(--exclude-table-data "$pat")
    info "  excluding data from: $pat (schema still included)"
  done <<< "$EXCLUDES"
fi

# --------------------------------------------------------------------- dump --
info "writing $OUT ..."
started=$(date +%s)

pg_dump "$SRC" -Fc -Z "$ZLEVEL" --no-owner --no-acl \
  ${XARGS[@]+"${XARGS[@]}"} -f "$OUT.part" 2>"$OUT.err" &
pid=$!

# Same idea as `./pgshuttle watch`: show bytes so a long run is never ambiguous.
while kill -0 "$pid" 2>/dev/null; do
  sleep 5
  [ -f "$OUT.part" ] && printf '\r  %s so far...        ' "$(du -h "$OUT.part" 2>/dev/null | awk '{print $1}')"
done
wait "$pid"; rc=$?
printf '\r%*s\r' 40 ''

if [ "$rc" != 0 ]; then
  sed 's/^/    /' "$OUT.err" >&2
  rm -f "$OUT.part"
  die "export failed"
fi
rm -f "$OUT.err"
mv "$OUT.part" "$OUT"
elapsed=$(( $(date +%s) - started ))

# ------------------------------------------------------------------- verify --
# Reading the table of contents back proves the archive is not truncated.
objects=$(pg_restore -l "$OUT" 2>/dev/null | grep -c '^[0-9]')
[ "${objects:-0}" -gt 0 ] || die "the archive is unreadable -- do not share it, re-run the export"

# Relative path inside the checksum file so `sha256sum -c` works wherever it lands.
( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
size=$(du -h "$OUT" | awk '{print $1}')
ok "export complete -- $size, $objects objects, ${elapsed}s"

# ------------------------------------------------------- instructions to ship --
HOWTO="$OUT.HOW-TO-RESTORE.txt"
cat > "$HOWTO" <<EOF
$(basename "$OUT")
$(date -u +%Y-%m-%d) -- copy of $dbname ($ntables tables, $dbsize restored size)

This is a standard PostgreSQL custom-format archive. You do not need any special
tooling to load it -- pg_restore or pgAdmin 4 is enough.

Requirements
  PostgreSQL client tools version 16 or newer (pg_restore refuses archives from
  a newer version than itself). Check with:  pg_restore --version

Command line
  createdb -h localhost -U postgres $dbname
  pg_restore -h localhost -U postgres -d $dbname -j 4 --no-owner --no-acl \\
    $(basename "$OUT")

pgAdmin 4
  1. Create an empty database named $dbname
  2. Right-click it -> Restore
  3. Format: Custom or tar
  4. Filename: $(basename "$OUT")
  5. Restore Options -> turn ON "Do not save Owner" and "Do not save Privileges"
  6. Restore

Notes
  - Ownership and grants are stripped, so it loads under whatever role you use.
  - Restoring takes longer than the file suggests; rebuilding indexes dominates.
  - Verify the download first:  shasum -a 256 -c $(basename "$OUT").sha256
EOF

echo
info "share these files:"
printf '    %s\n' "$OUT"
printf '    %s\n' "$OUT.sha256"
printf '    %s\n' "$HOWTO"
