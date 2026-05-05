#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
CONF="$SCRIPT_DIR/wallpapers.conf"

if [ ! -f "$CONF" ]; then
  echo "Missing config: $CONF" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$CONF"

DEFAULT_DIR="/mnt/onboard/.pluginwallpapers"
NEW_DIR="${1:-}"
[ -z "${NEW_DIR:-}" ] && NEW_DIR="$DEFAULT_DIR"
PLUGIN_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
LOGS_DIR="$PLUGIN_DIR/logs"
STATUS_FILE="${2:-$LOGS_DIR/setdir.status}"
LOG_FILE="${3:-$LOGS_DIR/setdir.log}"

status() {
  echo "$1" >> "$STATUS_FILE"
}

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

mkdir -p "$(dirname "$STATUS_FILE")" "$(dirname "$LOG_FILE")"
rm -f "$STATUS_FILE"
touch "$LOG_FILE"
status "START"
log "Set download dir requested: $NEW_DIR"

[ -z "$NEW_DIR" ] && {
  echo "Path cannot be empty" >&2
  log "Path empty"
  status "ERROR Path cannot be empty"
  exit 1
}
if ! mkdir -p "$NEW_DIR"; then
  log "Failed to create directory: $NEW_DIR"
  status "ERROR Could not create directory"
  exit 1
fi

TMP="$CONF.tmp"
if ! sed "s|^DOWNLOAD_DIR=.*$|DOWNLOAD_DIR=\"$NEW_DIR\"|" "$CONF" > "$TMP"; then
  log "Failed to render new config"
  status "ERROR Failed to update config"
  exit 1
fi
if ! mv "$TMP" "$CONF"; then
  log "Failed to replace config file"
  status "ERROR Failed to write config"
  exit 1
fi

echo "Download directory updated to: $NEW_DIR"
log "Download directory updated to: $NEW_DIR"
status "DONE"
