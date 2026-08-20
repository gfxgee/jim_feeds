#!/usr/bin/env bash
#
# fetch-feed.sh — fetch an RSS/Atom feed, validate it, save a timestamped .xml snapshot.
# Intended to run hourly from cron.
#
# Usage:  ./fetch-feed.sh <feed-url> [label]
# Example: ./fetch-feed.sh https://example.com/feed cloudway
#
# Exit codes: 0 = ok, 1 = usage, 2 = fetch failed, 3 = not valid XML,
#             4 = no items, 5 = feed is stale

set -uo pipefail

# ---------- config ----------
BASE_DIR="${FEED_BASE_DIR:-/var/feeds}"   # override with FEED_BASE_DIR
KEEP_DAYS=30                              # how long to keep snapshots
KEEP_SNAPSHOTS="${FEED_KEEP_SNAPSHOTS:-1}"  # 0 = only write latest.xml (use in CI)
STALE_HOURS="${FEED_STALE_HOURS:-48}"     # warn if newest item is older than this
REPAIR="${FEED_REPAIR:-}"                   # comma-list of repairs, e.g. "amp". Empty = none.
TIMEOUT=30
# ----------------------------

FEED_URL="${1:-}"
LABEL="${2:-feed}"

if [[ -z "$FEED_URL" ]]; then
  echo "usage: $0 <feed-url> [label]" >&2
  exit 1
fi

OUT_DIR="$BASE_DIR/$LABEL"
SNAP_DIR="$OUT_DIR/snapshots"
LOG_FILE="$OUT_DIR/fetch.log"
LATEST="$OUT_DIR/latest.xml"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPAIR_NOTE=""
TMP="$(mktemp)"

mkdir -p "$OUT_DIR"
[[ "$KEEP_SNAPSHOTS" != "0" ]] && mkdir -p "$SNAP_DIR"
trap 'rm -f "$TMP" "$TMP.rep"' EXIT

log() {
  printf '%s [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$LABEL" "$*" >> "$LOG_FILE"
}

fail() {
  log "FAIL($2): $1"
  echo "$LABEL: $1" >&2
  # Keep the bad response for diagnosis — this is usually the most useful artifact.
  cp "$TMP" "$OUT_DIR/last-failure.raw" 2>/dev/null
  exit "$2"
}

# 1. Fetch. --fail makes curl treat 4xx/5xx as an error rather than saving the error body.
HTTP_CODE=$(curl -sS --fail --location --max-time "$TIMEOUT" \
  --user-agent "feed-monitor/1.0" \
  --write-out '%{http_code}' \
  --output "$TMP" \
  "$FEED_URL") || fail "fetch failed (curl exit, http=${HTTP_CODE:-none})" 2

# 2. Non-empty?
if [[ ! -s "$TMP" ]]; then
  fail "empty response body (http=$HTTP_CODE)" 2
fi

# 2b. Optional repair, opt-in per feed via FEED_REPAIR. This runs BEFORE validation
#     so a feed with a known upstream defect can still be mirrored as valid XML.
#     It is deliberately narrow: it cannot rescue an HTML error page, because the
#     root-element and item-count checks below still have to pass afterwards.
case ",$REPAIR," in
  *,amp,*)
    # Escape bare "&" without touching valid entities. sed has no lookahead, so
    # protect real entities with a sentinel byte, escape what is left, restore.
    if sed -E 's/&(#[0-9]+;|#[xX][0-9a-fA-F]+;|[a-zA-Z][a-zA-Z0-9]*;)/\x01\1/g; s/&/\&amp;/g; s/\x01/\&/g' \
         "$TMP" > "$TMP.rep" && [[ -s "$TMP.rep" ]]; then
      if cmp -s "$TMP" "$TMP.rep"; then
        REPAIR_NOTE=" repair=amp(no-op)"
      else
        # Still worth surfacing: upstream is serving invalid XML and hasn't fixed it.
        REPAIR_NOTE=" repair=amp(applied)"
      fi
      mv "$TMP.rep" "$TMP"
    else
      rm -f "$TMP.rep"
      fail "amp repair failed to produce output" 3
    fi
    ;;
esac

# 3. Is it actually XML? A 200 that returns an HTML error/maintenance page is the
#    silent failure this whole script exists to catch — don't let it overwrite latest.xml.
if ! xmllint --noout "$TMP" 2>/dev/null; then
  HEAD_SNIPPET=$(head -c 120 "$TMP" | tr '\n' ' ')
  fail "response is not well-formed XML (http=$HTTP_CODE) starts: $HEAD_SNIPPET" 3
fi

# 4. Is the root element actually a feed? Some HTML error pages happen to be
#    well-formed XML, so passing xmllint is not proof this is a feed.
ROOT=$(xmllint --xpath 'local-name(/*)' "$TMP" 2>/dev/null)
case "$ROOT" in
  rss|feed|RDF) ;;
  *) fail "not a feed — root element is <${ROOT:-unknown}> (http=$HTTP_CODE)" 3 ;;
esac

# 5. Does it contain feed items?
ITEM_COUNT=$(xmllint --xpath 'count(//*[local-name()="item" or local-name()="entry"])' "$TMP" 2>/dev/null || echo 0)
ITEM_COUNT=${ITEM_COUNT%.*}
if [[ "${ITEM_COUNT:-0}" -eq 0 ]]; then
  fail "valid XML but zero items — feed is rendering empty (http=$HTTP_CODE)" 4
fi

# 6. Save. Hash the old copy first — after this, latest.xml is gone.
PREV_HASH=""
[[ -f "$LATEST" ]] && PREV_HASH=$(sha256sum "$LATEST" | cut -d' ' -f1)

# Snapshots are local history. Set FEED_KEEP_SNAPSHOTS=0 when git already
# provides that history (CI), otherwise you commit 24 files a day forever.
if [[ "$KEEP_SNAPSHOTS" != "0" ]]; then
  SNAPSHOT="$SNAP_DIR/${LABEL}-${STAMP}.xml"
  cp "$TMP" "$SNAPSHOT"
fi
cp "$TMP" "$LATEST"

# 7. Did the content change? Compared before the overwrite, so this works even on an
#    ephemeral CI runner where only latest.xml was restored from the repo.
CHANGED="first-run"
if [[ -n "$PREV_HASH" ]]; then
  if [[ "$PREV_HASH" == "$(sha256sum "$TMP" | cut -d' ' -f1)" ]]; then
    CHANGED="unchanged"
  else
    CHANGED="changed"
  fi
fi

# 8. Freshness of the newest item — catches a feed that still serves but stopped updating.
NEWEST=$(xmllint --xpath 'string((//*[local-name()="item" or local-name()="entry"])[1]/*[local-name()="pubDate" or local-name()="updated" or local-name()="published"])' "$TMP" 2>/dev/null)
STALE_NOTE=""
if [[ -n "$NEWEST" ]]; then
  if NEWEST_EPOCH=$(date -d "$NEWEST" +%s 2>/dev/null); then
    AGE_HOURS=$(( ( $(date +%s) - NEWEST_EPOCH ) / 3600 ))
    if (( AGE_HOURS > STALE_HOURS )); then
      STALE_NOTE=" STALE(newest item ${AGE_HOURS}h old)"
    fi
  fi
fi

log "OK http=$HTTP_CODE items=$ITEM_COUNT $CHANGED bytes=$(stat -c%s "$LATEST")$REPAIR_NOTE$STALE_NOTE"

# 9. Prune old snapshots.
if [[ "$KEEP_SNAPSHOTS" != "0" ]]; then
  find "$SNAP_DIR" -name '*.xml' -type f -mtime +$KEEP_DAYS -delete 2>/dev/null
fi

if [[ -n "$STALE_NOTE" ]]; then
  echo "$LABEL:$STALE_NOTE" >&2
  exit 5
fi

exit 0
