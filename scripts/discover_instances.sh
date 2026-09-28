#!/usr/bin/env bash
# Lists every running SQL Server container on this host and prints ready-to-
# paste MSSQL_<n>_* blocks for config/backup.env (DATABASE=* — replace with
# real database names if you want only specific ones).
#
# With --write-secrets <dir>, also writes <dir>/<container>.password (chmod 600)
# from each container's MSSQL_SA_PASSWORD / SA_PASSWORD env var. Existing
# password files are never overwritten.
#
# Usage: ./discover_instances.sh [--write-secrets /opt/antlerfoundry/secrets/mssql]

set -euo pipefail

SECRETS_DIR="/opt/antlerfoundry/secrets/mssql"
WRITE=0
if [[ "${1:-}" == "--write-secrets" ]]; then
  SECRETS_DIR="${2:?--write-secrets needs a directory}"
  WRITE=1
  mkdir -p "$SECRETS_DIR"
  chmod 700 "$SECRETS_DIR"
fi

n=0
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' \
  | awk -F'\t' '$2 ~ /mssql\/server/' \
  | sort \
  | while IFS=$'\t' read -r name _image ports; do
    port="$(grep -oE '0\.0\.0\.0:[0-9]+->1433/tcp' <<< "$ports" | head -1 | sed -E 's/0\.0\.0\.0:([0-9]+)->.*/\1/')"
    if [[ -z "$port" ]]; then
      echo "# ${name}: port 1433 not published on the host — skipped"
      echo
      continue
    fi
    n=$(( n + 1 ))
    file="${SECRETS_DIR}/${name}.password"
    cat <<EOF
# --- SQL Server ${n} ---
MSSQL_${n}_CONTAINER=${name}
MSSQL_${n}_HOST=localhost
MSSQL_${n}_PORT=${port}
MSSQL_${n}_USER=sa
MSSQL_${n}_PASSWORD_FILE=${file}
MSSQL_${n}_DATABASE=*

EOF

    [[ "$WRITE" -eq 1 ]] || continue
    if [[ -f "$file" ]]; then
      echo "  (kept existing ${file})" >&2
      continue
    fi
    pw="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" \
      | sed -nE 's/^(MSSQL_SA_PASSWORD|SA_PASSWORD)=//p' | head -1)"
    if [[ -z "$pw" ]]; then
      echo "  WARNING: no SA password env var on ${name} — create ${file} by hand" >&2
      continue
    fi
    ( umask 077; printf '%s' "$pw" > "$file" )
    echo "  wrote ${file}" >&2
  done
