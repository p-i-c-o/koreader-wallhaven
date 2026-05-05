#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PLUGIN_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONF="$SCRIPT_DIR/wallpapers.conf"

if [ ! -f "$CONF" ]; then
  echo "Missing config: $CONF" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$CONF"

API_KEY_FILE=$(printf "%s" "$API_KEY_FILE" | sed "s|__PLUGIN_DIR__|$PLUGIN_DIR|g")
LOGS_DIR="$PLUGIN_DIR/logs"
WORK_DIR="$PLUGIN_DIR/work"
STATUS_FILE="${1:-$LOGS_DIR/sync.status}"
LOG_FILE="${2:-$LOGS_DIR/sync.log}"
MODE="${3:-sync}"

HTTP_BIN=""
LAST_HTTP_ERR=""
REQUEST_DELAY_SEC="${REQUEST_DELAY_SEC:-1}"
MAX_PAGES="${MAX_PAGES:-20}"

status() { echo "$1" >> "$STATUS_FILE"; }
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }

select_http_bin() {
  if command -v curl >/dev/null 2>&1; then HTTP_BIN="curl"; return; fi
  if command -v wget >/dev/null 2>&1; then HTTP_BIN="wget"; return; fi
  if command -v busybox >/dev/null 2>&1 && busybox wget --help >/dev/null 2>&1; then HTTP_BIN="busybox-wget"; return; fi
  status "ERROR No HTTP client found. Need curl, wget, or busybox wget."
  exit 1
}

fetch_to_file() {
  url="$1"; out="$2"; LAST_HTTP_ERR=""
  errfile="$WORK_DIR/http-sync-$$.log"
  rm -f "$errfile"
  case "$HTTP_BIN" in
    curl)
      if ! curl -fsSL --connect-timeout 20 --retry 1 "$url" -o "$out" 2>"$errfile"; then LAST_HTTP_ERR=$(cat "$errfile" 2>/dev/null || true); return 1; fi ;;
    wget)
      if ! wget -q -t 1 -T 20 -O "$out" "$url" 2>"$errfile"; then LAST_HTTP_ERR=$(cat "$errfile" 2>/dev/null || true); return 1; fi ;;
    busybox-wget)
      if ! busybox wget -q -T 20 -O "$out" "$url" 2>"$errfile"; then LAST_HTTP_ERR=$(cat "$errfile" 2>/dev/null || true); return 1; fi ;;
    *) return 1 ;;
  esac
  rm -f "$errfile"
}

extract_paths() {
  tr ',' '\n' < "$1" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g'
}

extract_api_error() {
  sed -n 's/.*"error":"\([^"]*\)".*/\1/p' "$1" | sed 's#\\/#/#g'
}

mkdir -p "$LOGS_DIR" "$WORK_DIR" "$DOWNLOAD_DIR"
rm -f "$STATUS_FILE"
touch "$LOG_FILE"
status "START"

for cmd in sed tr grep mkdir wc basename head; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "Missing dependency: $cmd"
    status "ERROR Missing dependency: $cmd"
    exit 1
  fi
done

if [ ! -f "$API_KEY_FILE" ]; then
  status "ERROR API key file missing"
  exit 1
fi
API_KEY=$(tr -d '\r\n' < "$API_KEY_FILE")
if [ -z "$API_KEY" ] || [ "$API_KEY" = "PUT_YOUR_WALLHAVEN_API_KEY_HERE" ]; then
  status "ERROR API key not set"
  exit 1
fi

if [ -z "${COLLECTION_NAME:-}" ]; then
  status "ERROR Collection name not set"
  exit 1
fi
if [ -z "${COLLECTION_USERNAME:-}" ]; then
  status "ERROR Collection username not set"
  exit 1
fi

select_http_bin
log "Sync collection start. name='$COLLECTION_NAME' user='$COLLECTION_USERNAME' client=$HTTP_BIN"

COL_FILE="$WORK_DIR/collections-$$.json"
if ! fetch_to_file "https://wallhaven.cc/api/v1/collections?apikey=$API_KEY" "$COL_FILE"; then
  if printf '%s' "$LAST_HTTP_ERR" | grep -qi "429"; then
    status "ERROR Wallhaven rate limit hit (429). Try again later."
    exit 1
  fi
  if printf '%s' "$LAST_HTTP_ERR" | grep -Eqi "timed out|timeout"; then
    status "ERROR Network timeout while listing collections"
    exit 1
  fi
  if printf '%s' "$LAST_HTTP_ERR" | grep -Eqi "bad address|resolve|Name or service not known"; then
    status "ERROR DNS/Network failure resolving wallhaven.cc"
    exit 1
  fi
  log "Failed collections list: $LAST_HTTP_ERR"
  status "ERROR Network check failed. Enable Wi-Fi and verify internet."
  exit 1
fi

api_error=$(extract_api_error "$COL_FILE" | head -n 1 || true)
if [ -n "$api_error" ]; then
  log "Collections API error: $api_error"
  status "ERROR Collections API error: $api_error"
  exit 1
fi

COLLECTION_ID=""
COLLECTION_COUNT="0"
ONE_LINE=$(tr -d '\r\n' < "$COL_FILE" | sed 's/},{/}\n{/g')
while IFS= read -r obj; do
  id=$(printf '%s' "$obj" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
  label=$(printf '%s' "$obj" | sed -n 's/.*"label"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g')
  cnt=$(printf '%s' "$obj" | sed -n 's/.*"count"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
  if [ -n "$id" ] && [ "$label" = "$COLLECTION_NAME" ]; then
    COLLECTION_ID="$id"
    [ -n "$cnt" ] && COLLECTION_COUNT="$cnt"
    break
  fi
done <<EOF2
$ONE_LINE
EOF2

if [ -z "$COLLECTION_ID" ]; then
  status "ERROR Collection not found by name"
  exit 1
fi

log "Resolved collection id=$COLLECTION_ID count=$COLLECTION_COUNT"
status "INFO Collection: $COLLECTION_NAME (#$COLLECTION_ID)"

page=1
saved=0
skipped=0
failed=0
candidate_total=0
pending_total=0
LIST_ALL="$WORK_DIR/sync-all-$$.txt"
LIST_PENDING="$WORK_DIR/sync-pending-$$.txt"
INDEX_COUNTER="$WORK_DIR/sync-index-$$.txt"
echo "0" > "$INDEX_COUNTER"
rm -f "$LIST_ALL" "$LIST_PENDING"

while [ "$page" -le "$MAX_PAGES" ]; do
  PAGE_FILE="$WORK_DIR/collection-page-$$-$page.json"
  URL="https://wallhaven.cc/api/v1/collections/$COLLECTION_USERNAME/$COLLECTION_ID?apikey=$API_KEY&page=$page"
  log "Page $page URL: $URL"
  if ! fetch_to_file "$URL" "$PAGE_FILE"; then
    if printf '%s' "$LAST_HTTP_ERR" | grep -qi "429"; then
      status "ERROR Wallhaven rate limit hit (429). Try again later."
    elif printf '%s' "$LAST_HTTP_ERR" | grep -Eqi "timed out|timeout"; then
      status "ERROR Network timeout while fetching collection page"
    elif printf '%s' "$LAST_HTTP_ERR" | grep -Eqi "bad address|resolve|Name or service not known"; then
      status "ERROR DNS/Network failure resolving wallhaven.cc"
    else
      status "ERROR Failed collection page $page"
    fi
    log "Failed collection page $page: $LAST_HTTP_ERR"
    exit 1
  fi

  api_error=$(extract_api_error "$PAGE_FILE" | head -n 1 || true)
  if [ -n "$api_error" ]; then
    status "ERROR API error: $api_error"
    exit 1
  fi

  PATHS_FILE="$WORK_DIR/collection-paths-$$-$page.txt"
  extract_paths "$PAGE_FILE" > "$PATHS_FILE"
  if [ -f "$PATHS_FILE" ]; then
    count_paths=$(wc -l < "$PATHS_FILE" | tr -d '[:space:]')
  else
    count_paths=0
  fi
  [ -z "$count_paths" ] && count_paths=0
  log "Page $page paths=$count_paths"
  [ "$count_paths" -eq 0 ] && break

  while IFS= read -r wurl || [ -n "${wurl:-}" ]; do
    [ -z "$wurl" ] && continue
    wid=$(basename "$wurl")
    wid=${wid%.*}
    wid=${wid#wallhaven-}
    [ -z "$wid" ] && continue
    ext=${wurl##*.}
    [ "$ext" = "$wurl" ] && ext="jpg"
    raw_idx=$(cat "$INDEX_COUNTER")
    idx=$((raw_idx + 1))
    echo "$idx" > "$INDEX_COUNTER"
    filename="$(printf '%04d' "$idx")_${wid}.${ext}"
    echo "$wid|$wurl|$filename" >> "$LIST_ALL"
    candidate_total=$((candidate_total + 1))
  done < "$PATHS_FILE"

  page=$((page + 1))
  sleep "$REQUEST_DELAY_SEC"
done

if [ ! -f "$LIST_ALL" ] || [ ! -s "$LIST_ALL" ]; then
  status "ERROR No wallpapers downloaded"
  exit 1
fi

# Pre-compare all candidates against existing local files.
while IFS='|' read -r wid wurl filename || [ -n "${wid:-}" ]; do
  [ -z "${wid:-}" ] && continue
  if ls "$DOWNLOAD_DIR"/*_"$wid".* >/dev/null 2>&1; then
    skipped=$((skipped + 1))
  else
    echo "$wid|$wurl|$filename" >> "$LIST_PENDING"
    pending_total=$((pending_total + 1))
  fi
done < "$LIST_ALL"

log "Collection scan complete: candidates=$candidate_total existing=$skipped pending=$pending_total"
status "INFO Collection scan: total=$candidate_total existing=$skipped pending=$pending_total"

if [ "$pending_total" -eq 0 ]; then
  status "WARN All collection items already present"
  status "PENDING 0"
  status "DONE 0 0"
  log "Sync done. nothing to download; all items present."
  exit 0
fi

status "PENDING $pending_total"

if [ "$MODE" = "--scan-only" ]; then
  log "Scan-only mode complete. pending=$pending_total"
  status "DONE 0 0"
  exit 0
fi

# Download only pending items.
while IFS='|' read -r wid wurl filename || [ -n "${wid:-}" ]; do
  [ -z "${wid:-}" ] && continue
  out="$DOWNLOAD_DIR/$filename"
  if fetch_to_file "$wurl" "$out"; then
    saved=$((saved + 1))
    status "PROGRESS $saved/$pending_total $wid"
    log "Saved $wid -> $out"
  else
    failed=$((failed + 1))
    log "Failed $wid: $LAST_HTTP_ERR"
    if printf '%s' "$LAST_HTTP_ERR" | grep -Eqi "timed out|timeout"; then
      status "WARN Network timeout downloading $wid"
    else
      status "WARN Failed to download $wid"
    fi
  fi
  sleep "$REQUEST_DELAY_SEC"
done < "$LIST_PENDING"

if [ "$saved" -eq 0 ] && [ "$pending_total" -gt 0 ]; then
  status "ERROR No wallpapers downloaded"
  exit 1
fi

status "DONE $saved $failed"
log "Sync done. saved=$saved skipped=$skipped failed=$failed pending=$pending_total total=$candidate_total"
