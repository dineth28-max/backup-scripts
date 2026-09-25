#!/usr/bin/env bash
# Backs up a single SQL Server database (running in its own local Docker
# container) to GCS. Backup-only by design: no restore script.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${DIR}/../lib/common.sh"

: "${MSSQL_CONTAINER:?missing in backup.env}"
: "${MSSQL_USER:?missing in backup.env}"
: "${MSSQL_PASSWORD_FILE:?missing in backup.env}"
: "${MSSQL_DATABASE:?missing in backup.env}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

acquire_lock
log INFO "=== backup_mssql.sh starting (db=${MSSQL_DATABASE}, dry_run=${DRY_RUN}) ==="

# Reads the sa password from a file — never as a CLI arg, which would leak it
# into `ps`/`docker inspect`.
mssql_password() {
  [[ -f "$MSSQL_PASSWORD_FILE" ]] || die "MSSQL_PASSWORD_FILE not found: $MSSQL_PASSWORD_FILE"
  cat "$MSSQL_PASSWORD_FILE"
}

STAMP="$(date +%F_%H%M%S)"
WORKDIR="${BACKUP_TMP_DIR}/${STAMP}"
mkdir -p "$WORKDIR"

BAK_NAME="${MSSQL_DATABASE}_${STAMP}.bak"
CONTAINER_BAK_PATH="/var/opt/mssql/backup/${BAK_NAME}"
LOCAL_BAK_PATH="${WORKDIR}/${BAK_NAME}"
OUTFILE="${LOCAL_BAK_PATH}.gz"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log INFO "[dry-run] skipping BACKUP DATABASE / GCS upload for ${MSSQL_DATABASE}"
else
  log INFO "Running BACKUP DATABASE [${MSSQL_DATABASE}] inside ${MSSQL_CONTAINER}"
  docker exec "$MSSQL_CONTAINER" mkdir -p /var/opt/mssql/backup \
    || die "Could not create backup dir inside ${MSSQL_CONTAINER}"

  # SQLCMDPASSWORD env var (not -P on the command line) keeps the password
  # out of argv, same rationale as the file-based read above.
  docker exec -e SQLCMDPASSWORD="$(mssql_password)" "$MSSQL_CONTAINER" \
    /opt/mssql-tools18/bin/sqlcmd -S localhost -U "$MSSQL_USER" \
    -Q "BACKUP DATABASE [${MSSQL_DATABASE}] TO DISK = N'${CONTAINER_BAK_PATH}' WITH INIT, STATS = 10;" \
    || die "BACKUP DATABASE failed for ${MSSQL_DATABASE}"

  log INFO "Copying backup file out of container"
  docker cp "${MSSQL_CONTAINER}:${CONTAINER_BAK_PATH}" "$LOCAL_BAK_PATH" \
    || die "docker cp failed for ${CONTAINER_BAK_PATH}"

  docker exec "$MSSQL_CONTAINER" rm -f "$CONTAINER_BAK_PATH" \
    || log WARN "Could not clean up ${CONTAINER_BAK_PATH} inside the container"

  log INFO "Compressing backup"
  gzip "$LOCAL_BAK_PATH" || die "gzip failed for ${LOCAL_BAK_PATH}"
  sha256_sidecar "$OUTFILE"

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
