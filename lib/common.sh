#!/usr/bin/env bash
# Shared helpers for backup_mssql.sh. Sourced, never executed directly.

set -euo pipefail

# cron runs with PATH=/usr/bin:/bin, which misses sqlpackage (/usr/local/bin)
# and a snap-installed gcloud (/snap/bin).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH:-}"

BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${BACKUP_ROOT}/config/backup.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FATAL: ${ENV_FILE} not found. Copy config/backup.env.example to config/backup.env and fill it in." >&2
  exit 1
fi
# A backup.env saved with Windows (CRLF) line endings would put a hidden \r
# on the end of every value (bucket, paths ...) and break everything subtly.
if grep -q $'\r' "$ENV_FILE"; then
  echo "FATAL: ${ENV_FILE} has Windows (CRLF) line endings. Fix with: sed -i 's/\r\$//' ${ENV_FILE}" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${GCS_BUCKET:?missing in backup.env}"
: "${GCS_PREFIX:?missing in backup.env}"
: "${GCP_PROJECT_ID:?missing in backup.env}"
: "${GOOGLE_APPLICATION_CREDENTIALS:?missing in backup.env}"
: "${LOG_DIR:?missing in backup.env}"
: "${BACKUP_TMP_DIR:?missing in backup.env}"
: "${LOCK_FILE:?missing in backup.env}"

export GOOGLE_APPLICATION_CREDENTIALS
# Private gcloud config for this script, so activating the backup service
# account doesn't switch the active gcloud account for anything else the
# user runs on this host.
export CLOUDSDK_CONFIG="${BACKUP_ROOT}/.gcloud"
mkdir -p "$CLOUDSDK_CONFIG"
chmod 700 "$CLOUDSDK_CONFIG"

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

# Returns non-zero on failure instead of dying, so one failed instance does
# not stop the rest of the queue.
gcs_upload() {
  local src="$1" dest="gs://${GCS_BUCKET}/${GCS_PREFIX}/$2"
  if ! gcloud storage cp "$src" "$dest" --quiet; then
    log ERROR "GCS upload failed: $src -> $dest"
    return 1
  fi
  log INFO "Uploaded $src -> $dest"
}

sha256_sidecar() {
  local file="$1"
  # Record the checksum with a bare basename (not the full path) so the
  # sidecar stays valid after the file moves to a different download dir.
  ( cd "$(dirname "$file")" && sha256sum "$(basename "$file")" ) > "${file}.sha256"
}


prune_gcs_folder() {
  local folder="$1" days="$2" ref_date="$3"
  local cutoff listing url stamp
  cutoff="$(date -d "${ref_date} -$(( days - 1 )) days" +%F)"
  if ! listing="$(gcloud storage ls "gs://${GCS_BUCKET}/${GCS_PREFIX}/${folder}/" 2>>"$LOG_FILE")"; then
    log WARN "[${folder}] could not list gs://${GCS_BUCKET}/${GCS_PREFIX}/${folder}/ — retention prune skipped (does the service account have storage.objects.list?)"
    return 0
  fi
  while read -r url; do
    [[ "$url" == */ ]] || continue
    stamp="$(basename "$url")"
    [[ "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_ ]] || continue
    if [[ "${stamp:0:10}" < "$cutoff" ]]; then
      log INFO "Deleting expired backup (older than ${days}d): ${url}"
      gcloud storage rm -r "$url" --quiet || log WARN "Failed to delete ${url} (does the service account have storage.objects.delete?)"
    fi
  done <<< "$listing"
}
