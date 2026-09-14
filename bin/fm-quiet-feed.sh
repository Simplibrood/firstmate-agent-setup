#!/usr/bin/env bash
# fm-quiet-feed.sh - the captain's routine-notification page and its ledger.
#
# Usage:
#   fm-quiet-feed.sh record --kind <kind> --task <task> --detail <text> [--next <seconds>] [--best-effort]
#   fm-quiet-feed.sh render [--best-effort]
#   fm-quiet-feed.sh path [ledger|page]
#
# WHY THIS EXISTS. A supervision wake costs a whole firstmate turn, and a turn
# re-reads the entire conversation; measured over 2026-09-11..14 that is a median
# 616k context tokens per wake, 95% of which is re-reading. So a repeat event that
# carries no new information must be settled inside the watcher, which is shell and
# costs nothing, instead of waking firstmate to read it and shrug. This script is
# where such a settled event is written down, so "settled below firstmate" never
# means "lost": the captain reads the page whenever they want, at no token cost to
# anyone, and bin/fm-watch.sh keeps every bounded wake path it already had.
#
# WHAT MAY BE RECORDED HERE. Only an event that repeats WITHOUT carrying new
# information, and only where the caller still holds a bounded wake path for it:
# a recheck of a declared wait nothing has changed about, a repeat wedge escalation
# on an unchanged pane, a deferred bare turn-end. Anything naming a decision, a
# blocker, a failure, a finished pull request, or a first sighting of a new problem
# goes to firstmate as it always did, and never comes here instead.
#
# PUBLICATION. The ledger is rewritten whole under a home-local lock and renamed
# over its path, so a reader sees the previous or the next complete file, never a
# torn one. The page is rendered from the ledger the same way. Both are bounded by
# FM_QUIET_FEED_MAX_ENTRIES and FM_QUIET_FEED_MAX_AGE_SECS, so neither grows without
# limit and a note about a job that has since finished ages out on its own.
#
# --best-effort makes every failure append one bounded line to
# state/.quiet-feed.log and exit zero, so a watcher that records an absorb can
# never be failed by its own bookkeeping. Without it, failures print and return
# non-zero for tests and direct diagnostics.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

LEDGER="$STATE/quiet-feed.tsv"
PAGE_DIR="$DATA/quiet"
PAGE="$PAGE_DIR/quiet.html"
LOCK="$STATE/.quiet-feed.lock"
ERROR_LOG="$STATE/.quiet-feed.log"
ERROR_LOG_MAX_BYTES=${FM_QUIET_FEED_ERROR_LOG_MAX_BYTES:-65536}

# Retention. 200 entries or 48 hours, whichever bites first: the page is a glance
# surface, not an archive, and the durable record of anything that mattered is the
# task's own status log.
MAX_ENTRIES=${FM_QUIET_FEED_MAX_ENTRIES:-200}
MAX_AGE_SECS=${FM_QUIET_FEED_MAX_AGE_SECS:-172800}
# How long the rendered page may go unrefreshed before it calls itself stale. The
# watcher polls far more often than this, so exceeding it means the watcher is not
# running - which the separate liveness guard alarms on independently.
STALE_SECS=${FM_QUIET_FEED_STALE_SECS:-900}
LOCK_WAIT_SECS=${FM_QUIET_FEED_LOCK_WAIT_SECS:-5}

case "$MAX_ENTRIES" in ''|*[!0-9]*|0) MAX_ENTRIES=200 ;; esac
case "$MAX_AGE_SECS" in ''|*[!0-9]*|0) MAX_AGE_SECS=172800 ;; esac
case "$STALE_SECS" in ''|*[!0-9]*|0) STALE_SECS=900 ;; esac
case "$LOCK_WAIT_SECS" in ''|*[!0-9]*) LOCK_WAIT_SECS=5 ;; esac

BEST_EFFORT=0
LOCK_HELD=0

quiet_feed_log() {  # <message>
  local sz
  # A best-effort caller must never see output from its own bookkeeping, so the
  # redirection itself runs inside a subshell whose stderr is discarded: an
  # unwritable log path is bash's own message, not the command's.
  ( printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$ERROR_LOG" ) 2>/dev/null || return 0
  sz=$(wc -c < "$ERROR_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$ERROR_LOG_MAX_BYTES" ]; then
    tail -n 200 "$ERROR_LOG" > "$ERROR_LOG.tmp" 2>/dev/null && mv -f "$ERROR_LOG.tmp" "$ERROR_LOG" 2>/dev/null
    rm -f "$ERROR_LOG.tmp" 2>/dev/null || true
  fi
}

quiet_feed_fail() {  # <message>
  if [ "$BEST_EFFORT" -eq 1 ]; then
    quiet_feed_log "$1"
    release_lock
    exit 0
  fi
  echo "fm-quiet-feed: $1" >&2
  release_lock
  exit 1
}

# mkdir is the atomic primitive here deliberately: this stays a leaf script the
# watcher can call on an absorb path without dragging in the wake-queue graph.
acquire_lock() {
  local waited=0
  while [ "$waited" -le "$LOCK_WAIT_SECS" ]; do
    if mkdir "$LOCK" 2>/dev/null; then
      printf '%s' "$$" > "$LOCK/pid" 2>/dev/null || true
      LOCK_HELD=1
      return 0
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  return 1
}

release_lock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  rm -f "$LOCK/pid" 2>/dev/null || true
  rmdir "$LOCK" 2>/dev/null || true
  LOCK_HELD=0
}

# Collapse a caller's free text to one safe single-line ledger field. Tabs and
# newlines would break the record format itself, so they become spaces before
# anything else looks at the value.
sanitize_field() {  # <text>
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-400
}

html_escape() {  # <text>
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# Keep only entries inside both bounds, newest last. Reads the ledger, writes the
# retained set to stdout.
prune_entries() {  # <now> [keep]
  local now=$1 keep=${2:-$MAX_ENTRIES} cutoff
  cutoff=$(( now - MAX_AGE_SECS ))
  [ "$keep" -ge 1 ] 2>/dev/null || keep=1
  [ -f "$LEDGER" ] || return 0
  awk -F'\t' -v cutoff="$cutoff" 'NF >= 4 && $1 ~ /^[0-9]+$/ && $1 >= cutoff' "$LEDGER" 2>/dev/null \
    | tail -n "$keep"
}

# Newest first for a reader, without depending on tac (GNU) or tail -r (BSD).
reverse_lines() {
  awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }'
}

# Human-readable age, for a captain reading the page rather than a log.
render_age() {  # <seconds>
  local s=$1
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm' "$(( s / 60 ))"
  elif [ "$s" -lt 86400 ]; then printf '%sh' "$(( s / 3600 ))"
  else printf '%sd' "$(( s / 86400 ))"
  fi
}

render_page() {  # <now>
  local now=$1 tmp epoch kind task detail age rows=0
  mkdir -p "$PAGE_DIR" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "$PAGE_DIR/.quiet.html.XXXXXX") || return 1
  {
    cat <<HEAD
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>Routine notifications</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--ink:#1d232a;--mute:#5b6570;--line:#dde2e8;--ok:#23804a;--warn:#b5570b;--bad:#b3261e}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,-apple-system,sans-serif}
.wrap{max-width:900px;margin:0 auto;padding:20px 16px}
h1{font-size:19px;margin:0 0 12px}
.strip{border-radius:8px;padding:12px 14px;font-weight:600;margin:0 0 14px}
.strip.ok{background:#edf7f1;color:var(--ok);border:1px solid #bfe0cd}
.strip.stale{background:#fdecea;color:var(--bad);border:1px solid #f0bfba}
.strip span{font-weight:400;color:var(--mute)}
table{border-collapse:collapse;width:100%;font-size:14px;background:var(--card);border:1px solid var(--line);border-radius:8px;overflow:hidden}
th,td{border-bottom:1px solid var(--line);padding:7px 9px;text-align:left;vertical-align:top}
th{background:#eef2f7;font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--mute)}
td.age{text-align:right;white-space:nowrap;color:var(--mute)}
td.old{color:var(--warn);font-weight:600}
.empty{color:var(--mute);padding:18px 2px}
.foot{color:var(--mute);font-size:13px;margin-top:14px}
.scroll{overflow-x:auto}
</style></head>
<div class="wrap">
<h1>Routine notifications</h1>
<div class="strip ok" id="strip">&#10003; Nothing here needs you. <span id="freshness">updated $(date -d "@$now" '+%H:%M' 2>/dev/null || date -r "$now" '+%H:%M' 2>/dev/null)</span></div>
<div class="scroll"><table>
<tr><th>When</th><th>Project</th><th>What happened</th><th>Kind</th><th>Age</th></tr>
HEAD
    while IFS=$(printf '\t') read -r epoch kind task detail; do
      [ -n "$epoch" ] || continue
      rows=$(( rows + 1 ))
      age=$(( now - epoch ))
      [ "$age" -ge 0 ] || age=0
      printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td class="age%s">%s</td></tr>\n' \
        "$(date -d "@$epoch" '+%H:%M' 2>/dev/null || date -r "$epoch" '+%H:%M' 2>/dev/null)" \
        "$(html_escape "$task")" \
        "$(html_escape "$detail")" \
        "$(html_escape "$kind")" \
        "$( [ "$age" -ge 21600 ] && printf ' old' )" \
        "$(render_age "$age")"
    done < <(prune_entries "$now" | reverse_lines)
    if [ "$rows" -eq 0 ]; then
      printf '<tr><td colspan="5" class="empty">Nothing recorded yet.</td></tr>\n'
    fi
    cat <<FOOT
</table></div>
<p class="foot">Every line here was settled without waking firstmate, and each one still has its own bounded path back to firstmate if it stops being routine.
Anything naming a decision, a blocker, a failure or a finished pull request never appears here - it reaches firstmate immediately and you hear it in chat.
Newest $MAX_ENTRIES entries or $(( MAX_AGE_SECS / 3600 )) hours, whichever is smaller.</p>
</div>
<script>
(function(){
  var generated = $now * 1000, staleMs = $STALE_SECS * 1000;
  function tick(){
    var age = Date.now() - generated, strip = document.getElementById('strip');
    var fresh = document.getElementById('freshness');
    var mins = Math.floor(age / 60000);
    if (age > staleMs) {
      strip.className = 'strip stale';
      strip.firstChild.nodeValue = 'This page is stale - it has not refreshed for ' + mins + ' minutes, which means supervision is not running. ';
    }
    if (fresh) { fresh.textContent = 'updated ' + new Date(generated).toLocaleTimeString() + ', ' + mins + ' min ago'; }
  }
  tick(); setInterval(tick, 15000);
})();
</script>
</html>
FOOT
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$PAGE" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

cmd_record() {
  local kind='' task='' detail='' next='' now retained tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) kind=${2-}; shift 2 ;;
      --task) task=${2-}; shift 2 ;;
      --detail) detail=${2-}; shift 2 ;;
      --next) next=${2-}; shift 2 ;;
      --best-effort) BEST_EFFORT=1; shift ;;
      *) quiet_feed_fail "unknown record option: $1" ;;
    esac
  done
  [ -n "$kind" ] || quiet_feed_fail "record requires --kind"
  [ -n "$task" ] || quiet_feed_fail "record requires --task"
  [ -n "$detail" ] || quiet_feed_fail "record requires --detail"
  case "$next" in
    '') ;;
    *[!0-9]*) quiet_feed_fail "--next must be whole seconds" ;;
    *) detail="$detail - next look in $(render_age "$next")" ;;
  esac
  mkdir -p "$STATE" 2>/dev/null || quiet_feed_fail "state directory $STATE is not writable"
  acquire_lock || quiet_feed_fail "another quiet-feed write holds $LOCK"
  now=$(date +%s)
  retained=$(prune_entries "$now" "$(( MAX_ENTRIES - 1 ))")
  tmp=$(umask 077; mktemp "$STATE/.quiet-feed.tsv.XXXXXX") || quiet_feed_fail "could not create an atomic ledger file in $STATE"
  {
    [ -z "$retained" ] || printf '%s\n' "$retained"
    printf '%s\t%s\t%s\t%s\n' "$now" "$(sanitize_field "$kind")" "$(sanitize_field "$task")" "$(sanitize_field "$detail")"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; quiet_feed_fail "could not write the ledger"; }
  mv -f "$tmp" "$LEDGER" 2>/dev/null || { rm -f "$tmp"; quiet_feed_fail "could not publish the ledger"; }
  render_page "$now" || quiet_feed_fail "could not render $PAGE"
  release_lock
}

cmd_render() {
  local now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --best-effort) BEST_EFFORT=1; shift ;;
      *) quiet_feed_fail "unknown render option: $1" ;;
    esac
  done
  mkdir -p "$STATE" 2>/dev/null || quiet_feed_fail "state directory $STATE is not writable"
  acquire_lock || quiet_feed_fail "another quiet-feed write holds $LOCK"
  now=$(date +%s)
  render_page "$now" || quiet_feed_fail "could not render $PAGE"
  release_lock
}

cmd_path() {
  case "${1:-page}" in
    ledger) printf '%s\n' "$LEDGER" ;;
    page) printf '%s\n' "$PAGE" ;;
    *) echo "fm-quiet-feed: path takes ledger or page" >&2; exit 1 ;;
  esac
}

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
}

trap 'release_lock' EXIT
case "${1:-}" in
  record) shift; cmd_record "$@" ;;
  render) shift; cmd_render "$@" ;;
  path)   shift; cmd_path "$@" ;;
  -h|--help|help|'') usage ;;
  *) echo "fm-quiet-feed: unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
