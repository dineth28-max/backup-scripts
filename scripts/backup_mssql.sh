#!/usr/bin/env bash
# Exports a single SQL Server database as a .bacpac (schema + data, via
# SqlPackage) to GCS. Backup-only by design: no restore script.
#
# Unlike a native BACKUP DATABASE, SqlPackage is a host-side tool that
# connects to SQL Server over the network like any client — this does not
# use `docker exec` at all, it just needs the container's port reachable.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${DIR}/../lib/common.sh"

: "${MSSQL_HOST:?missing in backup.env}"
: "${MSSQL_PORT:?missing in backup.env}"
: "${MSSQL_USER:?missing in backup.env}"
: "${MSSQL_PASSWORD_FILE:?missing in backup.env}"
: "${MSSQL_DATABASE:?missing in backup.env}"
: "${BACKUP_NAME_PREFIX:?missing in backup.env}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

acquire_lock
log INFO "=== backup_mssql.sh starting (db=${MSSQL_DATABASE}, dry_run=${DRY_RUN}) ==="

# Reads the sa password from a file. Note: unlike sqlcmd's SQLCMDPASSWORD env
# var, SqlPackage has no equivalent env-var pickup for /SourcePassword — it
# has to be passed as a CLI arg below, which is visible to other local users
# via `ps` for the duration of the export. Restrict shell access to this host
# accordingly; this is a real limitation of the SqlPackage CLI, not a bug here.
mssql_password() {
  [[ -f "$MSSQL_PASSWORD_FILE" ]] || die "MSSQL_PASSWORD_FILE not found: $MSSQL_PASSWORD_FILE"
  cat "$MSSQL_PASSWORD_FILE"
}

STAMP="$(date +%F_%H%M%S)"
WORKDIR="${BACKUP_TMP_DIR}/${STAMP}"
mkdir -p "$WORKDIR"

OUTFILE="${WORKDIR}/${BACKUP_NAME_PREFIX}_${STAMP}.bacpac"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log INFO "[dry-run] skipping SqlPackage export / GCS upload for ${MSSQL_DATABASE}"
else
  log INFO "Exporting ${MSSQL_DATABASE} -> ${OUTFILE} via SqlPackage"
  sqlpackage /Action:Export \
    /SourceServerName:"${MSSQL_HOST},${MSSQL_PORT}" \
    /SourceDatabaseName:"${MSSQL_DATABASE}" \
    /SourceUser:"${MSSQL_USER}" \
    /SourcePassword:"$(mssql_password)" \
    /SourceTrustServerCertificate:True \
    /TargetFile:"${OUTFILE}" \
    || die "SqlPackage export failed for ${MSSQL_DATABASE}"

  # .bacpac is already a compressed package, so no gzip step here (unlike a
  # raw native .bak, gzip'ing it further buys almost nothing).
  sha256_sidecar "${OUTFILE}"

  upload_to_tier() {
    local tier="$1"
    local dest_prefix="${tier}/${STAMP}"
    gcs_upload "$OUTFILE" "${dest_prefix}/$(basename "$OUTFILE")"
    gcs_upload "${OUTFILE}.sha256" "${dest_prefix}/$(basename "$OUTFILE").sha256"
  }

  log INFO "Uploading to daily/"
  upload_to_tier "daily"

  if [[ "$(date +%u)" -eq 7 ]]; then
    log INFO "Sunday — also uploading to weekly/"
    upload_to_tier "weekly"
  fi

  if [[ "$((10#$(date +%d)))" -eq 1 ]]; then
    log INFO "1st of the month — also uploading to monthly/"
    upload_to_tier "monthly"
  fi
fi

log INFO "Cleaning local staging dir"
rm -rf "$WORKDIR"

if [[ "$DRY_RUN" -eq 0 ]]; then
  log INFO "Pruning daily/ older than ${DAILY_RETENTION_DAYS}d, weekly/ older than ${WEEKLY_RETENTION_DAYS}d, monthly/ older than ${MONTHLY_RETENTION_DAYS}d"
  prune_gcs_prefix "daily" "$DAILY_RETENTION_DAYS"
  prune_gcs_prefix "weekly" "$WEEKLY_RETENTION_DAYS"
  prune_gcs_prefix "monthly" "$MONTHLY_RETENTION_DAYS"
fi

log INFO "=== backup_mssql.sh completed successfully ==="
