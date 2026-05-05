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

HTTP_BIN=""
LAST_HTTP_ERR=""
SCRIPT_VERSION="2026-05-05.3"
MAX_PAGES="${MAX_PAGES:-0}"
MAX_WARN_FAILS="${MAX_WARN_FAILS:-20}"
REQUEST_DELAY_SEC="${REQUEST_DELAY_SEC:-1}"
TARGET_COUNT="${TARGET_COUNT:-1}"
DEBUG_LOG="${DEBUG_LOG:-1}"

select_http_bin() {
  if command -v curl >/dev/null 2>&1; then
    HTTP_BIN="curl"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    HTTP_BIN="wget"
    return
  fi
  if command -v busybox >/dev/null 2>&1 && busybox wget --help >/dev/null 2>&1; then
    HTTP_BIN="busybox-wget"
    return
  fi
  status "ERROR No HTTP client found. Need curl, wget, or busybox wget."
  log "No HTTP client found"
  exit 4
}

fetch_to_file() {
  url="$1"
  out="$2"
  LAST_HTTP_ERR=""
  errfile="$WORK_DIR/http-err-$$.log"
  rm -f "$errfile"
  case "$HTTP_BIN" in
    curl)
      if ! curl -fsSL --connect-timeout 20 --retry 1 --retry-delay 1 "$url" -o "$out" 2>"$errfile"; then
        LAST_HTTP_ERR=$(cat "$errfile" 2>/dev/null || true)
        rm -f "$errfile"
        return 1
      fi
      ;;
    wget)
      if ! wget -q -t 1 -T 20 -O "$out" "$url" 2>"$errfile"; then
        LAST_HTTP_ERR=$(cat "$errfile" 2>/dev/null || true)
        rm -f "$errfile"
        return 1
      fi
      ;;
    busybox-wget)
      if ! busybox wget -q -T 20 -O "$out" "$url" 2>"$errfile"; then
        LAST_HTTP_ERR=$(cat "$errfile" 2>/dev/null || true)
        rm -f "$errfile"
        return 1
      fi
      ;;
    *)
      rm -f "$errfile"
      return 1
      ;;
  esac
  rm -f "$errfile"
}

fetch_to_null() {
  url="$1"
  case "$HTTP_BIN" in
    curl)
      curl -fsSL --connect-timeout 10 --retry 1 "$url" -o /dev/null
      ;;
    wget)
      wget -q -t 2 -T 10 -O /dev/null "$url"
      ;;
    busybox-wget)
      busybox wget -q -T 10 -O /dev/null "$url"
      ;;
    *)
      return 1
      ;;
  esac
}

if [ ! -f "$API_KEY_FILE" ]; then
  echo "Missing API key file: $API_KEY_FILE" >&2
  exit 1
fi

API_KEY=$(tr -d '\r\n' < "$API_KEY_FILE")
if [ -z "$API_KEY" ]; then
  echo "API key file is empty: $API_KEY_FILE" >&2
  exit 1
fi
if [ "$API_KEY" = "PUT_YOUR_WALLHAVEN_API_KEY_HERE" ] || [ "$API_KEY" = "YOUR_API_KEY_HERE" ]; then
  mkdir -p "$PLUGIN_DIR/logs"
  STATUS_FILE="$PLUGIN_DIR/logs/fetch.status"
  LOG_FILE="$PLUGIN_DIR/logs/fetch.log"
  echo "ERROR API key is placeholder. Edit scripts/wallhaven.cred" >> "$STATUS_FILE"
  echo "$(date '+%Y-%m-%d %H:%M:%S') API key placeholder detected in $API_KEY_FILE" >> "$LOG_FILE"
  echo "API key placeholder detected: $API_KEY_FILE" >&2
  exit 1
fi

AUTO_RUN=0
LOGS_DIR="$PLUGIN_DIR/logs"
WORK_DIR="$PLUGIN_DIR/work"
STATUS_FILE="$LOGS_DIR/fetch.status"
LOG_FILE="$LOGS_DIR/fetch.log"
if [ "${1:-}" = "--auto-run" ]; then
  AUTO_RUN=1
  if [ -n "${2:-}" ]; then
    STATUS_FILE="$2"
  fi
  if [ -n "${3:-}" ]; then
    LOG_FILE="$3"
  fi
fi

status() {
  echo "$1" >> "$STATUS_FILE"
}

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

debug() {
  if [ "$DEBUG_LOG" = "1" ]; then
    log "DEBUG $1"
  fi
}

check_dependencies() {
  missing=""
  for cmd in sed mkdir grep tr date; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing="$missing $cmd"
    fi
  done
  if [ -n "$missing" ]; then
    echo "Missing dependencies:$missing" >&2
    log "Missing dependencies:$missing"
    status "ERROR Missing dependencies:$missing"
    exit 5
  fi
  log "Dependency check OK"
  debug "sed=$(command -v sed), mkdir=$(command -v mkdir), grep=$(command -v grep), tr=$(command -v tr), date=$(command -v date)"
}

check_wifi() {
  if command -v ifconfig >/dev/null 2>&1; then
    if ifconfig 2>/dev/null | grep -q "^wlan0"; then
      if ! ifconfig wlan0 2>/dev/null | grep -Eq "RUNNING|UP"; then
        log "Wi-Fi check failed: wlan0 not up"
        status "ERROR Wi-Fi appears disabled (wlan0 not up)"
        exit 2
      fi
    fi
  fi
}

check_network() {
  if ! fetch_to_null "https://wallhaven.cc/api/v1/search?sorting=date_added&page=1"; then
    if command -v ping >/dev/null 2>&1; then
      if ! ping -c 1 -W 3 wallhaven.cc >/dev/null 2>&1; then
        log "DNS/connectivity check failed for wallhaven.cc"
        status "ERROR DNS/Network failure resolving wallhaven.cc"
        exit 3
      fi
    fi
    log "Network check failed: cannot reach wallhaven API"
    status "ERROR Network check failed. Enable Wi-Fi and verify internet."
    exit 3
  fi
  debug "Network probe OK for wallhaven API"
}

if [ "$AUTO_RUN" -ne 1 ]; then
  printf "Search query [%s]: " "$QUERY"; read -r IN || true; [ -n "${IN:-}" ] && QUERY="$IN"
  printf "Categories [%s]: " "$CATEGORIES"; read -r IN || true; [ -n "${IN:-}" ] && CATEGORIES="$IN"
  printf "Purity [%s]: " "$PURITY"; read -r IN || true; [ -n "${IN:-}" ] && PURITY="$IN"
  printf "Sorting [%s]: " "$SORTING"; read -r IN || true; [ -n "${IN:-}" ] && SORTING="$IN"
  printf "Order [%s]: " "$ORDER"; read -r IN || true; [ -n "${IN:-}" ] && ORDER="$IN"
  printf "At least resolution [%s]: " "$ATLEAST"; read -r IN || true; [ -n "${IN:-}" ] && ATLEAST="$IN"
  printf "Ratios [%s]: " "$RATIOS"; read -r IN || true; [ -n "${IN:-}" ] && RATIOS="$IN"
  printf "Colors [%s]: " "$COLORS"; read -r IN || true; [ -n "${IN:-}" ] && COLORS="$IN"
  printf "Download directory [%s]: " "$DOWNLOAD_DIR"; read -r IN || true; [ -n "${IN:-}" ] && DOWNLOAD_DIR="$IN"
fi

# Wallhaven expects 4x3, not 3x4.
if [ "${RATIOS:-}" = "3x4" ]; then
  RATIOS="4x3"
  log "Normalized ratio 3x4 -> 4x3"
  status "WARN Ratio 3x4 normalized to 4x3"
fi

# Auto-scale page budget when MAX_PAGES is not explicitly set.
# Wallhaven returns ~24 items/page, so derive pages from requested count.
if [ "$MAX_PAGES" -le 0 ] 2>/dev/null; then
  MAX_PAGES=$(( (TARGET_COUNT + 23) / 24 ))
  [ "$MAX_PAGES" -lt 1 ] && MAX_PAGES=1
  [ "$MAX_PAGES" -gt 8 ] && MAX_PAGES=8
fi

mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$(dirname "$STATUS_FILE")" "$(dirname "$LOG_FILE")"
mkdir -p "$WORK_DIR"
rm -f "$STATUS_FILE"
touch "$LOG_FILE"
log "Starting wallpaper fetch (v$SCRIPT_VERSION)"
log "Script path: $0"
log "Config file: $CONF"
log "Plugin dir: $PLUGIN_DIR"
log "Work dir: $WORK_DIR"
log "Status file: $STATUS_FILE"
log "Download dir: $DOWNLOAD_DIR"
log "Runtime: AUTO_RUN=$AUTO_RUN TARGET_COUNT=$TARGET_COUNT MAX_PAGES=$MAX_PAGES REQUEST_DELAY_SEC=$REQUEST_DELAY_SEC MAX_WARN_FAILS=$MAX_WARN_FAILS"
debug "Device uname: $(uname -a 2>/dev/null || echo unknown)"
debug "API key file: $API_KEY_FILE"
debug "API key length: $(printf '%s' "$API_KEY" | wc -c | tr -d ' ')"
debug "Filters: QUERY='${QUERY:-}' CATEGORIES='${CATEGORIES:-}' PURITY='${PURITY:-}' SORTING='${SORTING:-}' ORDER='${ORDER:-}' ATLEAST='${ATLEAST:-}' RATIOS='${RATIOS:-}' COLORS='${COLORS:-}' TOP_RANGE='${TOP_RANGE:-}'"
status "START"
check_dependencies
select_http_bin
status "INFO Using HTTP client: $HTTP_BIN"
debug "HTTP client selected: $HTTP_BIN"
check_wifi
check_network
WORKFILE="$WORK_DIR/wallhaven-search-$$.json"
trap 'rm -f "$WORKFILE" "$WORKFILE.paths"' EXIT INT TERM

extract_paths() {
  tr ',' '\n' < "$1" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g'
}

extract_ids() {
  sed -n 's/.*"id":"\([a-z0-9]*\)".*/\1/p' "$1"
}

extract_api_error() {
  sed -n 's/.*"error":"\([^"]*\)".*/\1/p' "$1" | sed 's#\\/#/#g'
}

count=0
failed=0
page=1
warn_fails=0
last_download_err=""

while [ "$count" -lt "$TARGET_COUNT" ]; do
  if [ "$page" -gt "$MAX_PAGES" ]; then
    log "Reached MAX_PAGES=$MAX_PAGES, stopping with count=$count target=$TARGET_COUNT failed=$failed"
    if [ "$count" -gt 0 ]; then
      status "WARN Page limit reached ($MAX_PAGES). Downloaded $count/$TARGET_COUNT."
      break
    else
      status "ERROR Page limit reached ($MAX_PAGES) before any successful download. Broaden filters or lower target count."
      exit 1
    fi
  fi

  URL="https://wallhaven.cc/api/v1/search"
  QS="apikey=$API_KEY&categories=$CATEGORIES&purity=$PURITY&sorting=$SORTING&order=$ORDER&page=$page"
  [ -n "$QUERY" ] && QS="$QS&q=$(printf '%s' "$QUERY" | sed 's/ /%20/g')"
  [ -n "$ATLEAST" ] && QS="$QS&atleast=$ATLEAST"
  [ -n "$RATIOS" ] && QS="$QS&ratios=$RATIOS"
  [ -n "$COLORS" ] && QS="$QS&colors=$COLORS"
  [ "$SORTING" = "toplist" ] && [ -n "${TOP_RANGE:-}" ] && QS="$QS&topRange=$TOP_RANGE"
  debug "Page $page request URL: $URL?$QS"

  if ! fetch_to_file "$URL?$QS" "$WORKFILE"; then
    if printf '%s' "$LAST_HTTP_ERR" | grep -qi "429"; then
      log "Rate limited by API on page $page: $LAST_HTTP_ERR"
      status "ERROR Wallhaven rate limit hit (429). Try again later."
      exit 1
    fi
    echo "Search request failed on page $page" >&2
    log "Search request failed on page $page: $LAST_HTTP_ERR"
    status "ERROR Search request failed on page $page"
    exit 1
  fi
  debug "Search response bytes page $page: $(wc -c < "$WORKFILE" 2>/dev/null || echo 0)"
  sleep "$REQUEST_DELAY_SEC"

  extract_paths "$WORKFILE" > "$WORKFILE.paths"
  api_error=$(extract_api_error "$WORKFILE" | head -n 1 || true)
  debug "API error field page $page: ${api_error:-<empty>}"
  if [ -n "${api_error:-}" ]; then
    log "API error on page $page: $api_error"
    debug "API response head: $(head -c 500 "$WORKFILE" 2>/dev/null | tr '\n' ' ')"
    status "ERROR API error: $api_error"
    exit 1
  fi

  if [ ! -s "$WORKFILE.paths" ]; then
    if [ "$page" -eq 1 ]; then
      log "No results on first page with current filters"
      status "ERROR No results found. Check query/filter settings."
      exit 1
    fi
    log "No search results on page $page"
    status "WARN No more results found"
    break
  fi
  path_count=$(grep -c . "$WORKFILE.paths" 2>/dev/null || echo 0)
  log "Page $page extracted $path_count image path(s)"
  debug "First extracted path page $page: $(head -n 1 "$WORKFILE.paths" 2>/dev/null || echo '<none>')"
  status "INFO Page $page paths: $path_count"

  page_success_before="$count"
  page_failed_before="$failed"
  while IFS= read -r wurl || [ -n "${wurl:-}" ]; do
    [ -z "$wurl" ] && continue
    wid=$(basename "$wurl")
    wid=${wid%.*}
    wid=${wid#wallhaven-}
    [ -z "$wid" ] && wid="unknown"
    count=$((count + 1))
    ext=${wurl##*.}
    [ "$ext" = "$wurl" ] && ext="jpg"
    out="$DOWNLOAD_DIR/$(printf '%02d' "$count")_${wid}.${ext}"
    echo "[$count/$TARGET_COUNT] $wid"
    if ! fetch_to_file "$wurl" "$out"; then
      if printf '%s' "$LAST_HTTP_ERR" | grep -qi "429"; then
        log "Rate limited while downloading $wid: $LAST_HTTP_ERR"
        status "ERROR Rate limit hit (429) while downloading. Try again later."
        exit 1
      fi
      echo "Failed to download $wid" >&2
      last_download_err="$LAST_HTTP_ERR"
      log "Failed to download $wid from $wurl :: $LAST_HTTP_ERR"
      debug "Failed output path: $out"
      status "WARN Failed to download $wid"
      failed=$((failed + 1))
      warn_fails=$((warn_fails + 1))
      count=$((count - 1))
      if [ "$warn_fails" -ge "$MAX_WARN_FAILS" ]; then
        log "Too many download failures ($warn_fails), aborting."
        status "ERROR Too many download failures, aborting"
        exit 1
      fi
    else
      size_bytes=$(wc -c < "$out" 2>/dev/null || echo 0)
      log "Downloaded $wid to $out ($size_bytes bytes)"
      status "PROGRESS $count/$TARGET_COUNT $wid"
    fi
    sleep "$REQUEST_DELAY_SEC"
    [ "$count" -ge "$TARGET_COUNT" ] && break
  done < "$WORKFILE.paths"

  page_success_after="$count"
  page_failed_after="$failed"
  if [ "$page_success_after" -eq "$page_success_before" ] && [ "$page_failed_after" -gt "$page_failed_before" ]; then
    log "No successful downloads from page $page. Last error: $last_download_err"
    status "ERROR Could not download image files. Check connectivity to image CDN."
    exit 1
  fi

  page=$((page + 1))
done

if [ "$count" -eq 0 ]; then
  log "No downloadable wallpapers found after parsing API responses"
  debug "Final search response sample: $(head -c 500 "$WORKFILE" 2>/dev/null | tr '\n' ' ')"
  status "ERROR No downloadable wallpapers found for current config"
  exit 1
fi

if [ "$count" -lt "$TARGET_COUNT" ]; then
  log "Completed with partial results: $count/$TARGET_COUNT"
  status "WARN Only downloaded $count/$TARGET_COUNT due to API/network limits"
fi

echo "Done. Saved $count file(s) to $DOWNLOAD_DIR"
log "Done. Saved $count file(s), failed $failed, dir $DOWNLOAD_DIR"
status "DONE $count $failed"
