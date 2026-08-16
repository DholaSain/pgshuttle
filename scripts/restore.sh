#!/usr/bin/env bash
# Restore a dump produced by dump.sh into a local Postgres. Entirely local -- the
# source is not needed. Resumable: each table records a marker once it lands, and
# every table restore is a single transaction so a killed run never leaves half
# a table behind.

set -uo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

: "${TGT_DB_URL:?TGT_DB_URL is required}"
RUN_DIR="${RUN_DIR:?RUN_DIR is required}"
JOBS="${JOBS:-4}"
RESTORE_FRESH="${RESTORE_FRESH:-0}"    # 1 = wipe the target schema before loading

# The target is local: never force TLS on it, but honour it if the URL asks.
TGT="$(PGSSLMODE_DEFAULT=prefer sanitize_url "$TGT_DB_URL")"

DATA_DIR="$RUN_DIR/data"
LOG_DIR="$RUN_DIR/logs"
MARK_DIR="$RUN_DIR/restored"
mkdir -p "$MARK_DIR" "$LOG_DIR"

# fsync is already off on the throwaway target; these help the big COPY/CREATE INDEX steps.
export PGOPTIONS="-c synchronous_commit=off -c maintenance_work_mem=512MB -c statement_timeout=0"
export PGCONNECT_TIMEOUT=15

[ -d "$DATA_DIR" ] || die "no dump found at $RUN_DIR -- run ./pgshuttle dump first"
[ -f "$RUN_DIR/pre-data.dump" ] || die "$RUN_DIR/pre-data.dump missing -- the dump did not get far enough"
if [ ! -f "$RUN_DIR/DUMP_COMPLETE" ]; then
  warn "this dump is incomplete (no DUMP_COMPLETE marker) -- restoring what exists anyway"
fi

info "target: $(redact "$TGT")"
psql "$TGT" -Atqc "select 1" >/dev/null 2>"$LOG_DIR/target.err" \
  || { sed 's/^/    /' "$LOG_DIR/target.err" >&2; die "cannot connect to the target database"; }

# ------------------------------------------------------------------- wipe it --
if [ "$RESTORE_FRESH" = "1" ]; then
  info "dropping existing non-system schemas in the target..."
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
  rm -f "$MARK_DIR"/*.ok 2>/dev/null
  rm -f "$RUN_DIR/PRE_DATA_RESTORED" "$RUN_DIR/RESTORE_COMPLETE"
fi

# ------------------------------------------------------------- extensions --
if [ -s "$RUN_DIR/extensions.tsv" ]; then
  info "creating extensions present on the source..."
  missing=0
  while IFS=$'\t' read -r extname extver; do
    [ -z "$extname" ] && continue
    if psql "$TGT" -v ON_ERROR_STOP=1 -qc "CREATE EXTENSION IF NOT EXISTS \"$extname\" CASCADE" \
         >>"$LOG_DIR/extensions.log" 2>&1; then
      log "  extension $extname ok"
    else
      warn "  extension $extname NOT available in this image (objects using it will fail)"
      missing=$((missing + 1))
    fi
  done < "$RUN_DIR/extensions.tsv"
  [ "$missing" -gt 0 ] && warn "$missing extension(s) missing -- see PG_IMAGE in .env if you need e.g. postgis"
fi

# -------------------------------------------------------------- pre-data --
if [ ! -f "$RUN_DIR/PRE_DATA_RESTORED" ]; then
  info "restoring pre-data (schema, types, tables)..."
  pg_restore -d "$TGT" --no-owner --no-acl --no-comments \
    "$RUN_DIR/pre-data.dump" > "$LOG_DIR/restore-pre.log" 2>&1
  perr=$(grep -c '^pg_restore: error' "$LOG_DIR/restore-pre.log" 2>/dev/null); perr=${perr:-0}
  if [ "$perr" -gt 0 ]; then
    warn "pre-data restored with $perr error(s) -- see logs/restore-pre.log"
    warn "  (CREATE EXTENSION / role errors here are usually harmless)"
  fi
  touch "$RUN_DIR/PRE_DATA_RESTORED"
  ok "pre-data restored"
else
  log "pre-data already restored, skipping"
fi

# ------------------------------------------------------------------ data --
TOTAL=$(find "$DATA_DIR" -name '*.dump' -type f | wc -l | tr -d ' ')
[ "$TOTAL" -eq 0 ] && die "no table data files in $DATA_DIR"

find "$DATA_DIR" -name '*.dump' -type f | sort > "$LOG_DIR/restore-list.txt"

restore_one() {
  local f="$1" base started elapsed
  base="$(basename "$f")"
  [ -f "$MARK_DIR/$base.ok" ] && return 0

  started=$(date +%s)
  if pg_restore -d "$TGT" --data-only --no-owner --no-acl --single-transaction \
       "$f" > "$LOG_DIR/restore-$base.log" 2>&1; then
    touch "$MARK_DIR/$base.ok"
    rm -f "$LOG_DIR/restore-$base.log"
    elapsed=$(( $(date +%s) - started ))
    printf '  %s✓%s %-62s %ss\n' "$C_GREEN" "$C_RESET" "$base" "$elapsed"
  elif grep -qi 'duplicate key\|already exists' "$LOG_DIR/restore-$base.log" 2>/dev/null; then
    # The transaction rolled back, so the table still holds exactly what it held
    # before. This only happens if the marker was lost while the rows survived.
    printf '  %s✗%s %-62s %s\n' "$C_RED" "$C_RESET" "$base" "already holds data -- see below" >&2
    touch "$MARK_DIR/.dupe"
  else
    printf '  %s✗%s %-62s %s\n' "$C_RED" "$C_RESET" "$base" "see logs/restore-$base.log" >&2
  fi
}

DONE_BEFORE=$(find "$MARK_DIR" -name '*.ok' -type f 2>/dev/null | wc -l | tr -d ' ')
info "loading table data with $JOBS parallel jobs ($DONE_BEFORE/$TOTAL already loaded)"
run_workers "$LOG_DIR/restore-list.txt" "$JOBS" restore_one

DONE_AFTER=$(find "$MARK_DIR" -name '*.ok' -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$DONE_AFTER" -lt "$TOTAL" ]; then
  warn "$DONE_AFTER/$TOTAL tables loaded -- re-run ./pgshuttle restore to retry the rest"
  warn "each table loads in one transaction, so nothing is half-applied"
  if [ -f "$MARK_DIR/.dupe" ]; then
    rm -f "$MARK_DIR/.dupe"
    echo >&2
    warn "some tables refused the load because they already contain rows."
    warn "the target and the dump have drifted apart -- reload from scratch with:"
    warn "    ./pgshuttle restore --fresh"
  fi
  exit 2
fi
ok "all $TOTAL tables loaded"

# ------------------------------------------------------------- post-data --
if [ -f "$RUN_DIR/post-data.dump" ]; then
  info "building indexes, constraints and triggers (this is the slow part)..."
  pg_restore -d "$TGT" --no-owner --no-acl -j "$JOBS" \
    "$RUN_DIR/post-data.dump" > "$LOG_DIR/restore-post.log" 2>&1
  perr=$(grep -c '^pg_restore: error' "$LOG_DIR/restore-post.log" 2>/dev/null); perr=${perr:-0}
  if [ "$perr" -gt 0 ]; then
    warn "post-data finished with $perr error(s) -- see logs/restore-post.log"
  else
    ok "post-data restored"
  fi
else
  warn "no post-data.dump -- the copy has no indexes or foreign keys"
fi

# ------------------------------------------------------------- sequences --
if [ -s "$RUN_DIR/sequences.sql" ]; then
  info "setting sequence positions..."
  psql "$TGT" -q -f "$RUN_DIR/sequences.sql" > "$LOG_DIR/sequences.log" 2>&1 \
    && ok "sequences set" || warn "some sequences failed -- see logs/sequences.log"
fi

info "running ANALYZE so the planner has statistics..."
psql "$TGT" -qc "ANALYZE" >/dev/null 2>&1 || warn "ANALYZE failed"

touch "$RUN_DIR/RESTORE_COMPLETE"
ok "restore complete"
echo
echo "Next: ./pgshuttle verify   (row-count comparison)"
echo "      ./pgshuttle psql     (open a shell on the restored copy)"
