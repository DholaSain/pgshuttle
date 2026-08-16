#!/usr/bin/env bash
# Compare the restored copy against the counts captured from the source at dump
# time. Reports anything missing, empty, or materially short.

set -uo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

: "${TGT_DB_URL:?TGT_DB_URL is required}"
RUN_DIR="${RUN_DIR:?RUN_DIR is required}"
TOLERANCE="${TOLERANCE:-5}"   # percent drift tolerated before a row is flagged

# The target is local: never force TLS on it, but honour it if the URL asks.
TGT="$(PGSSLMODE_DEFAULT=prefer sanitize_url "$TGT_DB_URL")"
export PGCONNECT_TIMEOUT=15

[ -s "$RUN_DIR/source_counts.tsv" ] || die "no source_counts.tsv in $RUN_DIR -- dump did not complete"
KIND=$(cat "$RUN_DIR/source_counts.kind" 2>/dev/null || echo estimate)

info "comparing target row counts against source ($KIND) counts"
[ "$KIND" = "estimate" ] && log "source numbers are planner estimates; small drift is normal"
echo

printf '%-58s %14s %14s   %s\n' "TABLE" "SOURCE" "TARGET" "STATUS"
printf '%s\n' "$(printf '%.0s-' $(seq 1 100))"

missing=0; empty=0; empty_small=0; short=0; okc=0

while IFS=$'\t' read -r qname src; do
  [ -z "$qname" ] && continue
  if ! tgt=$(psql "$TGT" -Atqc "select count(*) from $qname" 2>/dev/null); then
    printf '%-58s %14s %14s   %sMISSING%s\n' "$qname" "$src" "-" "$C_RED" "$C_RESET"
    missing=$((missing + 1)); continue
  fi

  if [ "$tgt" -eq 0 ] && [ "${src%.*}" -gt 0 ] 2>/dev/null; then
    # A planner estimate of "a handful of rows" on a table that is now genuinely
    # empty is the single most common false alarm here, so separate the two.
    if [ "$KIND" = "estimate" ] && [ "$src" -lt 100 ]; then
      printf '%-58s %14s %14s   %sempty (est. was tiny)%s\n' "$qname" "$src" "$tgt" "$C_YELLOW" "$C_RESET"
      empty_small=$((empty_small + 1))
    else
      printf '%-58s %14s %14s   %sEMPTY%s\n' "$qname" "$src" "$tgt" "$C_RED" "$C_RESET"
      empty=$((empty + 1))
    fi
    continue
  fi

  flag=$(awk -v s="$src" -v t="$tgt" -v tol="$TOLERANCE" \
    'BEGIN { if (s <= 0) { print "ok"; exit } d = (s - t) / s * 100; print (d > tol) ? "short" : "ok" }')
  if [ "$flag" = "short" ]; then
    printf '%-58s %14s %14s   %sSHORT%s\n' "$qname" "$src" "$tgt" "$C_YELLOW" "$C_RESET"
    short=$((short + 1))
  else
    printf '%-58s %14s %14s   ok\n' "$qname" "$src" "$tgt"
    okc=$((okc + 1))
  fi
done < "$RUN_DIR/source_counts.tsv"

echo
info "$okc ok, $short short (>${TOLERANCE}%), $empty_small empty-but-tiny-estimate, $empty empty, $missing missing"
if [ "$KIND" = "estimate" ] && { [ "$short" -gt 0 ] || [ "$empty_small" -gt 0 ]; }; then
  log "short/tiny-estimate rows compare against pg_class.reltuples, which drifts badly"
  log "on churny tables. For a definitive comparison set EXACT_COUNTS=1 in .env"
  log "before the next dump -- it counts every row on the source instead."
fi

# Objects that a debug copy actually needs to be usable.
idx=$(psql "$TGT" -Atqc "select count(*) from pg_indexes where schemaname not in ('pg_catalog','information_schema')")
fks=$(psql "$TGT" -Atqc "select count(*) from pg_constraint where contype='f'")
seqs=$(psql "$TGT" -Atqc "select count(*) from pg_sequences where schemaname not in ('pg_catalog','information_schema')")
size=$(psql "$TGT" -Atqc "select pg_size_pretty(pg_database_size(current_database()))")
info "target has $idx indexes, $fks foreign keys, $seqs sequences, $size on disk"

if [ "$missing" -gt 0 ] || [ "$empty" -gt 0 ]; then
  err "verification failed"
  exit 1
fi
[ "$short" -gt 0 ] && warn "some tables are short; on a live source this is expected for hot tables"
[ "$empty_small" -gt 0 ] && warn "$empty_small table(s) are empty where the estimate said only a few rows -- almost always stale statistics, not lost data"
ok "verification passed"
