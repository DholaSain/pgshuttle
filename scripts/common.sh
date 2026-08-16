#!/usr/bin/env bash
# Shared helpers for dump.sh / restore.sh / verify.sh.
# Sourced, never executed directly.

set -uo pipefail

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'

log()   { printf '%s[%s]%s %s\n' "$C_DIM" "$(date +%H:%M:%S)" "$C_RESET" "$*"; }
info()  { printf '%s[%s]%s %s%s%s\n' "$C_DIM" "$(date +%H:%M:%S)" "$C_RESET" "$C_BLUE" "$*" "$C_RESET"; }
ok()    { printf '%s[%s]%s %s%s%s\n' "$C_DIM" "$(date +%H:%M:%S)" "$C_RESET" "$C_GREEN" "$*" "$C_RESET"; }
warn()  { printf '%s[%s]%s %s%s%s\n' "$C_DIM" "$(date +%H:%M:%S)" "$C_RESET" "$C_YELLOW" "$*" "$C_RESET" >&2; }
err()   { printf '%s[%s]%s %s%s%s\n' "$C_DIM" "$(date +%H:%M:%S)" "$C_RESET" "$C_RED" "$*" "$C_RESET" >&2; }
die()   { err "$*"; exit 1; }

# libpq understands these; anything else in the query string makes psql/pg_dump
# refuse the URI outright. Prisma-style URLs carry ?schema=... which is exactly
# the kind of thing that has to be stripped.
LIBPQ_PARAMS="sslmode sslrootcert sslcert sslkey sslpassword sslcompression \
connect_timeout keepalives keepalives_idle keepalives_interval keepalives_count \
application_name fallback_application_name options target_session_attrs \
gssencmode channel_binding client_encoding tcp_user_timeout require_auth"

# sanitize_url <url> -> prints a libpq-safe URL with sane defaults for an
# unreliable link.
sanitize_url() {
  local url="$1" base query out key val kv keep p oldifs
  base="${url%%\?*}"
  if [ "$base" = "$url" ]; then query=""; else query="${url#*\?}"; fi

  local -a kept=()
  local -a pairs=()
  local has_sslmode=0 has_keepalive=0 has_timeout=0 has_tcpto=0

  if [ -n "$query" ]; then
    oldifs="$IFS"; IFS='&'
    # shellcheck disable=SC2206
    pairs=($query)
    IFS="$oldifs"
  fi

  for kv in ${pairs[@]+"${pairs[@]}"}; do
    [ -z "$kv" ] && continue
    key="${kv%%=*}"; val="${kv#*=}"
    keep=0
    for p in $LIBPQ_PARAMS; do
      if [ "$key" = "$p" ]; then keep=1; break; fi
    done
    if [ "$keep" = 1 ]; then
      kept+=("$key=$val")
      [ "$key" = "sslmode" ] && has_sslmode=1
      [ "$key" = "keepalives" ] && has_keepalive=1
      [ "$key" = "connect_timeout" ] && has_timeout=1
      [ "$key" = "tcp_user_timeout" ] && has_tcpto=1
    else
      printf 'note: dropping non-libpq URL parameter "%s" (pg_dump would reject it)\n' "$key" >&2
    fi
  done

  [ "$has_sslmode" = 0 ] && kept+=("sslmode=${PGSSLMODE_DEFAULT:-require}")
  [ "$has_timeout" = 0 ] && kept+=("connect_timeout=15")
  if [ "$has_keepalive" = 0 ]; then
    # Detects a tunnel that died while no data was arriving. Probes are answered
    # by the peer's kernel regardless of how busy the server is, so being
    # aggressive here cannot kill a healthy-but-slow dump -- it only shortens how
    # long a genuinely dead socket sits there looking like it is working.
    kept+=("keepalives=1" "keepalives_idle=15" "keepalives_interval=5" "keepalives_count=3")
  fi
  if [ "$has_tcpto" = 0 ] && [ -n "${LIBPQ_TCP_TIMEOUT_MS:-60000}" ]; then
    # Detects a tunnel that died mid-transfer, which keepalives do not: the
    # kernel gives up on unacknowledged data after this long. Without it a
    # black-holed tunnel leaves pg_dump hanging with no output and no error --
    # exactly the "pgAdmin just sat there" failure mode.
    kept+=("tcp_user_timeout=${LIBPQ_TCP_TIMEOUT_MS:-60000}")
  fi

  out="$base"
  if [ "${#kept[@]}" -gt 0 ]; then
    local joined; printf -v joined '%s&' "${kept[@]}"
    out="$base?${joined%&}"
  fi
  printf '%s' "$out"
}

# redact <url> -> same URL with the password replaced, safe to print/log.
redact() {
  printf '%s' "$1" | sed -E 's#(://[^:/@]+):[^@]*@#\1:****@#'
}

# url_host <url> -> hostname only. Uses the LAST '@' so unescaped '@' in a
# password does not throw the parse off.
url_host() {
  local t="${1#*://}"
  t="${t##*@}"
  t="${t%%/*}"
  t="${t%%\?*}"
  t="${t%%:*}"
  printf '%s' "$t"
}

# slugify <qualified-table-name> -> filesystem-safe token
slugify() {
  printf '%s' "$1" | tr -d '"' | tr -c 'A-Za-z0-9._-' '_'
}

# Run N worker shells over a TSV file, round-robin by line number.
# usage: run_workers <tsv-file> <jobs> <function-name>
# The function receives the raw TSV line as $1.
run_workers() {
  local file="$1" jobs="$2" fn="$3" w
  case "$jobs" in
    ''|*[!0-9]*|0) die "JOBS must be a positive whole number, got: '$jobs' (check JOBS_DUMP / JOBS_RESTORE in .env)" ;;
  esac
  for w in $(seq 0 $((jobs - 1))); do
    (
      awk -v w="$w" -v n="$jobs" 'NR % n == w' "$file" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        "$fn" "$line"
      done
    ) &
  done
  wait
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "required binary not found: $1"
}
