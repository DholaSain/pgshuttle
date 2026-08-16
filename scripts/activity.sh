#!/usr/bin/env bash
# What the source server thinks your dump is doing right now. Run this from a
# second terminal while a dump is in progress, connected to the source.
#
# `./pgshuttle watch` tells you whether bytes are landing on disk.
# This tells you whether the server is still working on the other end.

set -uo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

: "${SRC_DB_URL:?SRC_DB_URL is required}"
SRC="$(sanitize_url "$SRC_DB_URL")"
export PGCONNECT_TIMEOUT=10

if ! psql "$SRC" -Atqc "select 1" >/dev/null 2>&1; then
  err "cannot reach the source -- the connection is down"
  err "that alone explains a stalled dump: stop it, reconnect, re-run ./pgshuttle dump"
  exit 1
fi
ok "source is reachable"
echo

info "connections this backup has open on the server:"
psql "$SRC" -x -c "
SELECT pid,
       state,
       to_char(now() - backend_start, 'HH24:MI:SS')  AS connected_for,
       to_char(now() - state_change, 'HH24:MI:SS')   AS in_this_state_for,
       wait_event_type,
       wait_event,
       left(regexp_replace(query, '\s+', ' ', 'g'), 90) AS query
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
  AND (application_name LIKE 'pg_dump%' OR query ILIKE '%COPY%TO STDOUT%')
ORDER BY backend_start;"

echo
info "how to read that:"
echo "  state = active, wait_event_type = Client / ClientWrite"
echo "      the server has data ready and is blocked sending it to you."
echo "      That is the tunnel being slow or dead -- check ./pgshuttle watch."
echo "  state = active, wait_event_type = IO or empty"
echo "      the server is genuinely reading the table. Just wait."
echo "  no rows at all"
echo "      the server has already dropped your connections. The dump is dead"
echo "      even if the terminal still looks busy -- Ctrl-C it and re-run."
