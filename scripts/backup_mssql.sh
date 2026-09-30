#!/usr/bin/env bash


set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${DIR}/../lib/common.sh"

: "${DAILY_RETENTION_DAYS:?missing in backup.env}"
[[ "$DAILY_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] \
  || die "DAILY_RETENTION_DAYS must be a whole number >= 1 (got: ${DAILY_RETENTION_DAYS})"
EXPORT_TIMEOUT="${EXPORT_TIMEOUT:-6h}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
[[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] || die "MIN_FREE_GB must be a whole number (got: ${MIN_FREE_GB})"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"


export TMPDIR="${BACKUP_TMP_DIR}"

DRY_RUN=0
ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --only)    ONLY="${2:?--only needs a container name}"; shift ;;
    *)         die "Unknown argument: $1" ;;
  esac
  shift
done

if [[ "$DRY_RUN" -eq 0 ]]; then
  command -v sqlpackage >/dev/null 2>&1 || die "sqlpackage not found on PATH (see README section 3)"
fi

acquire_lock
STAMP="$(date +%F_%H%M%S)"
log INFO "=== backup_mssql.sh starting (stamp=${STAMP}, dry_run=${DRY_RUN}${ONLY:+, only=${ONLY}}) ==="
if [[ -n "${ALERT_EMAIL:-}" ]] && ! command -v mail >/dev/null 2>&1; then
  log WARN "ALERT_EMAIL is set but the 'mail' command is not installed — failure emails will NOT be sent"
fi

# Old daily logs (this script writes one per day).
find "$LOG_DIR" -maxdepth 1 -name 'backup_mssql_*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

mssql_password() {
  local name="$1" file="$2"
  if [[ ! -f "$file" ]]; then
    log ERROR "[${name}] password file not found: ${file}"
    return 1
  fi
  tr -d '\r\n' < "$file"
}

# Used only when MSSQL_<n>_DATABASE=*.
# Lists the ONLINE user databases of a container by running sqlcmd inside it
# (the mssql images ship sqlcmd; the host doesn't need it). The password is
# handed over via the environment, not argv, so it doesn't show up in `ps`.
list_databases() {
  local name="$1" user="$2" pw="$3" sqlcmd opts=()
  if docker exec "$name" test -x /opt/mssql-tools18/bin/sqlcmd 2>/dev/null; then
    sqlcmd=/opt/mssql-tools18/bin/sqlcmd; opts=(-C)   # ODBC 18: trust self-signed cert
  elif docker exec "$name" test -x /opt/mssql-tools/bin/sqlcmd 2>/dev/null; then
    sqlcmd=/opt/mssql-tools/bin/sqlcmd
  else
    log ERROR "[${name}] no sqlcmd found inside the container (or container not running)"
    return 1
  fi
  SQLCMDPASSWORD="$pw" docker exec -e SQLCMDPASSWORD "$name" "$sqlcmd" "${opts[@]}" \
    -S localhost -U "$user" -b -h -1 -W \
    -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE' ORDER BY name" \
    | tr -d '\r' | sed '/^[[:space:]]*$/d'
}

backup_database() {
  local name="$1" host="$2" port="$3" user="$4" pw="$5" db="$6"
  local workdir="${BACKUP_TMP_DIR}/${name}"
  local outfile="${workdir}/${db}_${STAMP}.bacpac"
  local dest="${name}/${STAMP}"
  mkdir -p "$workdir"
  # Leftovers from a crashed earlier run (the lock guarantees no other run is
  # using this directory right now).
  rm -f "$workdir"/*.bacpac "$workdir"/*.bacpac.sha256

  # This disk also holds the live SQL Server data — never let an export fill it.
  local free_gb
  free_gb=$(( $(df -Pk "$BACKUP_TMP_DIR" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  if (( free_gb < MIN_FREE_GB )); then
    log ERROR "[${name}] only ${free_gb} GB free on ${BACKUP_TMP_DIR} (MIN_FREE_GB=${MIN_FREE_GB}) — skipping ${db}"
    return 1
  fi

  log INFO "[${name}] exporting ${db} -> ${outfile} (${free_gb} GB free)"
  # sqlpackage's own (verbose) output always goes to the log file; when run by
  # hand from a terminal it is also shown live, so a long export visibly makes
  # progress (under cron it stays out of cron.log). -k: if it ignores the
  # timeout's SIGTERM, SIGKILL it 5 minutes later so the queue can never hang.
  local live=/dev/null started=$SECONDS
  [[ -t 2 ]] && live=/dev/stderr
  if ! timeout -k 5m "$EXPORT_TIMEOUT" sqlpackage /Action:Export \
      /SourceServerName:"${host},${port}" \
      /SourceDatabaseName:"${db}" \
      /SourceUser:"${user}" \
      /SourcePassword:"${pw}" \
      /SourceTrustServerCertificate:True \
      /TargetFile:"${outfile}" 2>&1 | tee -a "$LOG_FILE" >"$live"; then
    log ERROR "[${name}] SqlPackage export failed for ${db} (details above in ${LOG_FILE})"
    rm -f "$outfile"
    return 1
  fi
  local took=$(( SECONDS - started ))
  log INFO "[${name}] exported ${db} in $(( took / 60 ))m $(( took % 60 ))s ($(du -h "$outfile" | cut -f1)) — uploading"

  sha256_sidecar "$outfile"
  local rc=0
  gcs_upload "$outfile" "${dest}/$(basename "$outfile")" \
    && gcs_upload "${outfile}.sha256" "${dest}/$(basename "$outfile").sha256" \
    || rc=1

  # Local copy is only staging — remove it straight away so disk usage never
  # grows beyond one .bacpac at a time.
  rm -f "$outfile" "${outfile}.sha256"
  if [[ "$rc" -eq 0 ]]; then
    log INFO "[${name}] ${db} done"
  fi
  return "$rc"
}

backup_instance() {
  local name="$1" host="$2" port="$3" user="$4" pw_file="$5" dbs="$6"
  local pw db rc=0
  local -a db_list

  log INFO "--- [${name}] ${user}@${host}:${port} ---"
  pw="$(mssql_password "$name" "$pw_file")" || return 1

  if [[ "$dbs" == "*" ]]; then
    dbs="$(list_databases "$name" "$user" "$pw")" || { log ERROR "[${name}] could not list databases"; return 1; }
  else
    dbs="$(tr ',' '\n' <<< "$dbs")"
  fi
  mapfile -t db_list <<< "$dbs"
  if [[ -z "${db_list[*]// /}" ]]; then
    log WARN "[${name}] no user databases found — nothing to back up"
    return 0
  fi
  log INFO "[${name}] databases: ${db_list[*]}"

  for db in "${db_list[@]}"; do
    db="$(trim "$db")"
    [[ -n "$db" ]] || continue
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log INFO "[dry-run] [${name}] would export ${db} -> ${GCS_PREFIX}/${name}/${STAMP}/"
      continue
    fi
    backup_database "$name" "$host" "$port" "$user" "$pw" "$db" || rc=1
  done

  [[ "$DRY_RUN" -eq 1 ]] && return 0
  if [[ "$rc" -eq 0 ]]; then
    prune_gcs_folder "$name" "$DAILY_RETENTION_DAYS" "${STAMP:0:10}"
  else
    # Never prune after a failed run: older good backups must survive until a
    # new one actually lands.
    log WARN "[${name}] backup had failures — skipping retention prune, older backups kept"
  fi
  return "$rc"
}

# Every block number that has a MSSQL_<n>_CONTAINER, in numeric order. Gaps
# are fine (1, 2, 5 ...); comment out a whole block to skip that server.
mapfile -t INSTANCE_IDS < <(compgen -v | sed -nE 's/^MSSQL_([0-9]+)_CONTAINER$/\1/p' | sort -n)
[[ ${#INSTANCE_IDS[@]} -gt 0 ]] || die "No SQL Servers defined in backup.env (expected MSSQL_1_CONTAINER, MSSQL_1_HOST, ...)"
log INFO "Queue: ${#INSTANCE_IDS[@]} SQL Server(s) defined in backup.env"

# Reads MSSQL_<n>_<field> from the environment (loaded from backup.env).
field() {
  local var="MSSQL_$1_$2"
  trim "${!var:-}"
}

FAILED=()
SUCCEEDED=0
MATCHED=0
for n in "${INSTANCE_IDS[@]}"; do
  name="$(field "$n" CONTAINER)"
  [[ -n "$ONLY" && "$name" != "$ONLY" ]] && continue
  MATCHED=$(( MATCHED + 1 ))

  host="$(field "$n" HOST)"
  port="$(field "$n" PORT)"
  user="$(field "$n" USER)"
  pw_file="$(field "$n" PASSWORD_FILE)"
  dbs="$(field "$n" DATABASE)"

  missing=()
  for f in CONTAINER HOST PORT USER PASSWORD_FILE DATABASE; do
    [[ -n "$(field "$n" "$f")" ]] || missing+=("MSSQL_${n}_${f}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log ERROR "[${name:-block ${n}}] incomplete block ${n} in backup.env — missing: ${missing[*]}"
    FAILED+=("${name:-block_${n}}")
    continue
  fi
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    log ERROR "[${name}] MSSQL_${n}_PORT is not a number: ${port}"
    FAILED+=("${name}")
    continue
  fi

  if backup_instance "$name" "$host" "$port" "$user" "$pw_file" "$dbs"; then
    SUCCEEDED=$(( SUCCEEDED + 1 ))
  else
    FAILED+=("$name")
  fi
done

[[ -n "$ONLY" && "$MATCHED" -eq 0 ]] && die "--only ${ONLY}: no MSSQL_<n>_CONTAINER with that name in backup.env"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  log ERROR "=== finished with failures: ${#FAILED[@]} failed, ${SUCCEEDED} ok. Failed: ${FAILED[*]} ==="
  alert "MSSQL backup FAILED on $(hostname) for: ${FAILED[*]} (see ${LOG_FILE})"
  exit 1
fi

log INFO "=== backup_mssql.sh completed successfully (${SUCCEEDED} instances) ==="
