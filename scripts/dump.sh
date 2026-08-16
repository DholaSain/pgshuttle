#!/usr/bin/env bash
# Resumable table-at-a-time dump of a Postgres database.
#
# Nothing here uses SysV IPC, forked worker pools, or shared snapshots, so it
# cannot segfault the way pgcopydb does on macOS, and it survives the connection
# dropping mid-run: every table lands in its own file, written to .part first and
# renamed on success. Re-running skips whatever is already on disk.

set -uo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

: "${SRC_DB_URL:?SRC_DB_URL is required}"
RUN_DIR="${RUN_DIR:?RUN_DIR is required}"
JOBS="${JOBS:-2}"
ZLEVEL="${ZLEVEL:-3}"
DUMP_ORDER="${DUMP_ORDER:-asc}"        # asc = small tables first (more progress per connected window)
EXACT_COUNTS="${EXACT_COUNTS:-0}"      # 1 = count(*) every table on the source (slower, exact verify)
REFRESH_TABLES="${REFRESH_TABLES:-0}"  # 1 = rebuild tables.tsv even if it exists

SRC="$(sanitize_url "$SRC_DB_URL")"

DATA_DIR="$RUN_DIR/data"
LOG_DIR="$RUN_DIR/logs"
FAIL_DIR="$LOG_DIR/failed"
mkdir -p "$DATA_DIR" "$LOG_DIR" "$FAIL_DIR"
rm -f "$FAIL_DIR"/*.err 2>/dev/null

export PGCONNECT_TIMEOUT=15

# ---------------------------------------------------------------- preflight --
info "source: $(redact "$SRC")"

if ! srv=$(psql "$SRC" -Atqc "select current_setting('server_version')" 2>"$LOG_DIR/preflight.err"); then
  err "cannot connect to the source database:"
  sed 's/^/    /' "$LOG_DIR/preflight.err" >&2
  die "is the source reachable? check with: psql \"\$SRC_DB_URL\" -c 'select 1'"
fi

cli=$(pg_dump --version | awk '{print $3}')
info "server pg $srv / client pg_dump $cli"
if [ "${srv%%.*}" -gt "${cli%%.*}" ]; then
  die "pg_dump ($cli) is older than the server ($srv); rebuild the image with PG_MAJOR=${srv%%.*}"
fi

dbsize=$(psql "$SRC" -Atqc "select pg_size_pretty(pg_database_size(current_database()))")
dbname=$(psql "$SRC" -Atqc "select current_database()")
info "database $dbname, $dbsize on disk"

# ------------------------------------------------------------------ manifest --
if [ ! -f "$RUN_DIR/meta.env" ]; then
  {
    echo "SRC_DB_NAME=$dbname"
    echo "SRC_SERVER_VERSION=$srv"
    echo "SRC_DB_SIZE=$dbsize"
    echo "STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$RUN_DIR/meta.env"
fi

# ---------------------------------------------------------------- table list --
# relkind='r' only: that is ordinary tables plus leaf partitions, i.e. exactly
# the relations that hold rows. Partitioned parents ('p') hold none. Tables that
# belong to an extension are skipped -- the extension recreates them, and
# restoring rows into them would collide.
TABLE_SQL="
SELECT '\"' || replace(n.nspname,'\"','\"\"') || '\".\"' || replace(c.relname,'\"','\"\"') || '\"',
       pg_total_relation_size(c.oid)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND n.nspname NOT LIKE 'pg_temp%'
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')
ORDER BY pg_total_relation_size(c.oid) $( [ "$DUMP_ORDER" = "desc" ] && echo DESC || echo ASC )
"

if [ ! -f "$RUN_DIR/tables.tsv" ] || [ "$REFRESH_TABLES" = "1" ]; then
  info "listing tables..."
  raw="$LOG_DIR/tables.raw"
  psql "$SRC" -At -F $'\t' -c "$TABLE_SQL" > "$raw" || die "failed to list tables"
  : > "$RUN_DIR/tables.tsv"
  i=0
  while IFS=$'\t' read -r qname bytes; do
    [ -z "$qname" ] && continue
    i=$((i + 1))
    printf '%s\t%s\t%s\t%s\n' "$i" "$qname" "$(printf '%04d__%s.dump' "$i" "$(slugify "$qname")")" "$bytes" \
      >> "$RUN_DIR/tables.tsv"
  done < "$raw"
  rm -f "$raw"
fi

TOTAL=$(wc -l < "$RUN_DIR/tables.tsv" | tr -d ' ')
info "$TOTAL tables to dump"

# ------------------------------------------------------------- schema: before --
# pre-data = schemas, types, functions, tables, defaults. Custom format so the
# restore side can parallelise and so we can inspect it with pg_restore -l.
if [ ! -f "$RUN_DIR/pre-data.dump" ]; then
  info "dumping pre-data (schema, types, tables)..."
  if pg_dump "$SRC" --section=pre-data --no-owner --no-acl -Fc -Z "$ZLEVEL" \
       -f "$RUN_DIR/pre-data.dump.part" 2>"$LOG_DIR/pre-data.err"; then
    mv "$RUN_DIR/pre-data.dump.part" "$RUN_DIR/pre-data.dump"
    ok "pre-data done"
  else
    sed 's/^/    /' "$LOG_DIR/pre-data.err" >&2
    die "pre-data dump failed"
  fi
else
  log "pre-data already present, skipping"
fi

# Extension inventory, so restore can try to create them before loading schema.
if [ ! -f "$RUN_DIR/extensions.tsv" ]; then
  psql "$SRC" -At -F $'\t' -c \
    "select extname, extversion from pg_extension where extname <> 'plpgsql' order by 1" \
    > "$RUN_DIR/extensions.tsv" 2>/dev/null || : > "$RUN_DIR/extensions.tsv"
fi

# ------------------------------------------------------------------- the data --
dump_one() {
  local line="$1" idx qname fname bytes target started elapsed size
  IFS=$'\t' read -r idx qname fname bytes <<< "$line"
  target="$DATA_DIR/$fname"

  if [ -f "$target" ]; then
    return 0
  fi

  started=$(date +%s)
  if pg_dump "$SRC" -Fc -Z "$ZLEVEL" --data-only --no-owner --no-acl \
        -t "$qname" -f "$target.part" 2>"$FAIL_DIR/$fname.err"; then
    mv "$target.part" "$target"
    rm -f "$FAIL_DIR/$fname.err"
    elapsed=$(( $(date +%s) - started ))
    size=$(du -h "$target" 2>/dev/null | awk '{print $1}')
    printf '  %s✓%s %-6s %-58s %6s  %ss\n' "$C_GREEN" "$C_RESET" "$idx/$TOTAL" "$qname" "${size:-?}" "$elapsed"
  else
    rm -f "$target.part"
    printf '  %s✗%s %-6s %-58s  %s\n' "$C_RED" "$C_RESET" "$idx/$TOTAL" "$qname" "see logs/failed/$fname.err" >&2
  fi
}

DONE_BEFORE=$(find "$DATA_DIR" -name '*.dump' -type f 2>/dev/null | wc -l | tr -d ' ')
info "dumping table data with $JOBS parallel jobs ($DONE_BEFORE/$TOTAL already on disk)"
run_workers "$RUN_DIR/tables.tsv" "$JOBS" dump_one

DONE_AFTER=$(find "$DATA_DIR" -name '*.dump' -type f 2>/dev/null | wc -l | tr -d ' ')
FAILED=$(find "$FAIL_DIR" -name '*.err' -type f 2>/dev/null | wc -l | tr -d ' ')

if [ "$DONE_AFTER" -lt "$TOTAL" ]; then
  warn "$DONE_AFTER/$TOTAL tables dumped, $FAILED failed this pass"
  warn "restore the connection and re-run the same command -- finished tables are skipped"
  exit 2
fi
ok "all $TOTAL tables dumped"

# -------------------------------------------------------------- sequences etc --
info "capturing sequence positions..."
psql "$SRC" -At -o "$RUN_DIR/sequences.sql.part" -c "
SELECT format('SELECT pg_catalog.setval(%L, %s, %s);',
              quote_ident(schemaname) || '.' || quote_ident(sequencename),
              coalesce(last_value, start_value),
              CASE WHEN last_value IS NULL THEN 'false' ELSE 'true' END)
FROM pg_sequences
WHERE schemaname NOT IN ('pg_catalog','information_schema')
ORDER BY schemaname, sequencename;
" && mv "$RUN_DIR/sequences.sql.part" "$RUN_DIR/sequences.sql" \
  || warn "sequence capture failed; sequences will start from their schema defaults"

info "capturing source row counts for verification..."
if [ "$EXACT_COUNTS" = "1" ]; then
  : > "$RUN_DIR/source_counts.tsv"
  while IFS=$'\t' read -r idx qname fname bytes; do
    n=$(psql "$SRC" -Atqc "select count(*) from $qname" 2>/dev/null || echo "?")
    printf '%s\t%s\n' "$qname" "$n" >> "$RUN_DIR/source_counts.tsv"
  done < "$RUN_DIR/tables.tsv"
  echo "exact" > "$RUN_DIR/source_counts.kind"
else
  psql "$SRC" -At -F $'\t' -o "$RUN_DIR/source_counts.tsv" -c "
    SELECT '\"' || replace(n.nspname,'\"','\"\"') || '\".\"' || replace(c.relname,'\"','\"\"') || '\"',
           c.reltuples::bigint
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname NOT IN ('pg_catalog','information_schema')
      AND n.nspname NOT LIKE 'pg_toast%'
      AND n.nspname NOT LIKE 'pg_temp%'
  " || : > "$RUN_DIR/source_counts.tsv"
  echo "estimate" > "$RUN_DIR/source_counts.kind"
fi

# ------------------------------------------------------------- schema: after --
# post-data = indexes, primary keys, constraints, triggers. Restored last so the
# data load is not paying index-maintenance cost on every row.
if [ ! -f "$RUN_DIR/post-data.dump" ]; then
  info "dumping post-data (indexes, constraints, triggers)..."
  if pg_dump "$SRC" --section=post-data --no-owner --no-acl -Fc -Z "$ZLEVEL" \
       -f "$RUN_DIR/post-data.dump.part" 2>"$LOG_DIR/post-data.err"; then
    mv "$RUN_DIR/post-data.dump.part" "$RUN_DIR/post-data.dump"
    ok "post-data done"
  else
    sed 's/^/    /' "$LOG_DIR/post-data.err" >&2
    die "post-data dump failed (re-run to retry; table data is kept)"
  fi
else
  log "post-data already present, skipping"
fi

grep -v '^FINISHED_AT=' "$RUN_DIR/meta.env" > "$RUN_DIR/meta.env.tmp" 2>/dev/null && mv "$RUN_DIR/meta.env.tmp" "$RUN_DIR/meta.env"
{
  echo "TABLES=$TOTAL"
  echo "FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$RUN_DIR/meta.env"
touch "$RUN_DIR/DUMP_COMPLETE"

total_size=$(du -sh "$RUN_DIR" 2>/dev/null | awk '{print $1}')
ok "dump complete -- $TOTAL tables, $total_size in $RUN_DIR"
echo
echo "The source is no longer needed. Next: ./pgshuttle restore"
