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

mkdir -p "${BACKUP_DIR}/logs"

RENDERED="$(sed "s#__BACKUP_DIR__#${BACKUP_DIR}#g" "$TEMPLATE")"

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

echo "Installed. Current crontab:"
crontab -l
echo
echo "Test before trusting cron with it:"
echo "  ${BACKUP_DIR}/scripts/backup_mssql.sh --dry-run"
echo "  ${BACKUP_DIR}/scripts/backup_mssql.sh"
