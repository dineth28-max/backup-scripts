#!/usr/bin/env bash
# Installs (or updates) the backup cron schedule for the current user, without
# clobbering any other cron entries already in place.
#
# Usage: ./install_cron.sh

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$(dirname "$DIR")"
TEMPLATE="${DIR}/../cron/crontab.txt"
MARKER_START="# >>> mssql-backup (managed by install_cron.sh) >>>"
MARKER_END="# <<< mssql-backup <<<"

ENV_FILE="${BACKUP_DIR}/config/backup.env"

mkdir -p "${BACKUP_DIR}/logs"

# Schedule comes from backup.env (BACKUP_CRON_SCHEDULE), default 02:00 daily.
# Cron uses the SERVER's timezone — check it with `timedatectl`.
SCHEDULE="0 2 * * *"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  SCHEDULE="$(set -a; source "$ENV_FILE" >/dev/null 2>&1; printf '%s' "${BACKUP_CRON_SCHEDULE:-0 2 * * *}")"
fi
if [[ "$(wc -w <<< "$SCHEDULE")" -ne 5 ]]; then
  echo "BACKUP_CRON_SCHEDULE must be 5 cron fields, e.g. \"0 2 * * *\" (got: ${SCHEDULE})" >&2
  exit 1
fi

RENDERED="$(sed -e "s#__BACKUP_DIR__#${BACKUP_DIR}#g" -e "s#__SCHEDULE__#${SCHEDULE}#g" "$TEMPLATE")"

EXISTING="$(crontab -l 2>/dev/null || true)"
# Strip any previously-installed block so re-running this script updates
# cleanly instead of appending duplicates.
STRIPPED="$(printf '%s\n' "$EXISTING" | awk -v s="$MARKER_START" -v e="$MARKER_END" '
  $0==s {skip=1}
  !skip {print}
  $0==e {skip=0}
')"

{
  printf '%s\n' "$STRIPPED"
  echo "$MARKER_START"
  printf '%s\n' "$RENDERED"
  echo "$MARKER_END"
} | crontab -

echo "Installed (schedule: ${SCHEDULE}, server timezone: $(date +%Z)). Current crontab:"
crontab -l

# Cron fires in the SERVER's timezone. Show what that is in Sri Lanka time so
# a UTC server doesn't silently run the "02:00" backup at 07:30 local.
read -r CRON_MIN CRON_HOUR _ <<< "$SCHEDULE"
if [[ "$CRON_MIN" =~ ^[0-9]+$ && "$CRON_HOUR" =~ ^[0-9]+$ ]]; then
  LOCAL_TIME="$(TZ=Asia/Colombo date -d "$(date +%F) ${CRON_HOUR}:${CRON_MIN} $(date +%z)" +%H:%M)"
  echo
  echo "Runs daily at $(printf '%02d:%02d' "$CRON_HOUR" "$CRON_MIN") server time ($(date +%Z)) = ${LOCAL_TIME} Sri Lanka time (Asia/Colombo)."
  if [[ "$LOCAL_TIME" != "02:00" ]]; then
    echo "  NOTE: that is not 02:00 in Sri Lanka. For 02:00 Sri Lanka time on this server use:"
    echo "        BACKUP_CRON_SCHEDULE=\"$(date -d "$(date +%F) 02:00 +0530" '+%-M %-H') * * *\"  (then re-run this script)"
  fi
fi
echo
echo "Test before trusting cron with it:"
echo "  ${BACKUP_DIR}/scripts/backup_mssql.sh --dry-run"
echo "  ${BACKUP_DIR}/scripts/backup_mssql.sh"
