#!/usr/bin/env bash
# Shared helpers for backup_mssql.sh. Sourced, never executed directly.

set -euo pipefail

BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${BACKUP_ROOT}/config/backup.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FATAL: ${ENV_FILE} not found. Copy config/backup.env.example to config/backup.env and fill it in." >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${GCS_BUCKET:?missing in backup.env}"
: "${GCS_PREFIX:?missing in backup.env}"
: "${GCP_PROJECT_ID:?missing in backup.env}"
: "${GOOGLE_APPLICATION_CREDENTIALS:?missing in backup.env}"

export GOOGLE_APPLICATION_CREDENTIALS

mkdir -p "$LOG_DIR" "$BACKUP_TMP_DIR"

LOG_FILE="${LOG_DIR}/$(basename "$0" .sh)_$(date +%F).log"

log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*" | tee -a "$LOG_FILE" >&2
}

die() {
  log ERROR "$*"
  alert "MSSQL backup FAILED: $*"
  exit 1
}

alert() {
  local msg="$1"
  if [[ -n "${ALERT_EMAIL:-}" ]] && command -v mail >/dev/null 2>&1; then
    echo "$msg" | mail -s "[mssql-backup] $(basename "$0")" "$ALERT_EMAIL" || true
  fi
}

# Authenticates gcloud as the backup service account for this run. Done
# explicitly (rather than relying on ambient `gcloud auth login` state or
# GOOGLE_APPLICATION_CREDENTIALS auto-pickup, which the gcloud CLI itself
# doesn't reliably honor the way client libraries do) so cron runs under a
# fresh shell authenticate the same way every time.
[[ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]] \
  || die "GOOGLE_APPLICATION_CREDENTIALS file not found: $GOOGLE_APPLICATION_CREDENTIALS"
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS" --quiet \
  || die "Failed to activate GCP service account credentials"
gcloud config set project "$GCP_PROJECT_ID" --quiet \
  || die "Failed to set GCP project to ${GCP_PROJECT_ID}"

# Serializes runs so a slow backup never overlaps a second cron-triggered one.
acquire_lock() {
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    die "Another backup run is already holding ${LOCK_FILE}"
  fi
}

gcs_upload() {
  local src="$1" dest="gs://${GCS_BUCKET}/${GCS_PREFIX}/$2"
  gcloud storage cp "$src" "$dest" --quiet \
    || die "GCS upload failed: $src -> $dest"
  log INFO "Uploaded $src -> $dest"
}

sha256_sidecar() {
  local file="$1"
  # Record the checksum with a bare basename (not the full path) so the
  # sidecar stays valid after the file moves to a different download dir.
  ( cd "$(dirname "$file")" && sha256sum "$(basename "$file")" ) > "${file}.sha256"
}

# Deletes GCS objects under a prefix whose last-modified date is older than N days.
prune_gcs_prefix() {
  local prefix="$1" days="$2"
  local cutoff
  cutoff="$(date -d "-${days} days" +%F 2>/dev/null || date -v-"${days}"d +%F)"
  # `-l` prints "<size>  <RFC3339 timestamp>  <gs:// url>" per object plus a
  # trailing "TOTAL: ..." summary line, which the grep -v drops.
  gcloud storage ls -l "gs://${GCS_BUCKET}/${GCS_PREFIX}/${prefix}/**" 2>/dev/null \
    | grep -v '^TOTAL:' \
    | awk -v cutoff="$cutoff" 'substr($2,1,10) < cutoff {print $3}' \
    | while read -r url; do
      [[ -n "$url" ]] || continue
      log INFO "Deleting expired object (older than ${days}d): ${url}"
      gcloud storage rm "$url" --quiet || log WARN "Failed to delete ${url}"
    done
}
