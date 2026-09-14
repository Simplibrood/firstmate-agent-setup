#!/usr/bin/env bash
# fm-benchmark-watch.sh - wake firstmate when a public coding leaderboard shows a
# non-Claude model pulling ahead of the Claude model this fleet runs.
#
# Usage:
#   fm-benchmark-watch.sh [check]
#   fm-benchmark-watch.sh run [--force]
#   fm-benchmark-watch.sh --once
#   fm-benchmark-watch.sh arm
#   fm-benchmark-watch.sh disarm
#   fm-benchmark-watch.sh --help
#
# README
# ------
# Two boards are read, each from the machine-readable file the site's own front
# end loads, never by scraping rendered HTML:
#
#   livebench.ai            the landing page names a hashed JS bundle; the bundle
#                           carries the release list; the newest release names
#                           table_<release>.csv and categories_<release>.json.
#                           Category scores are the mean of that category's task
#                           columns, which is the arithmetic the bundle itself does.
#   deepswe.datacurve.ai    artifacts/v1.1/leaderboard-live.json, the artifact the
#                           page's own query loads, with one row per
#                           harness+model+effort configuration.
#
# Both payloads are untrusted text. Nothing fetched is ever executed, sourced, or
# interpolated into a command; the fetch writes to a file and a separate pure
# comparator (fm-benchmark-watch.py) parses it and filters every model name down
# to a character set that cannot carry a newline or prose into a wake line.
#
# WHAT WAKES FIRSTMATE
# The captain's rule is Claude by default, so only a NON-Claude model raises a
# question he has to answer: a newer Claude overtaking Opus 5 needs no approval
# and is deliberately silent here. A model counts as ahead only when it clears
# the baseline by a margin - on DeepSWE by the site's own published confidence
# interval, on LiveBench by FM_BENCHMARK_MARGIN_PP (default 1.0 points) - because
# the captain settled that a small capability gain does not justify a large
# allowance burn, and a bare > comparison would report run-to-run noise every
# morning. The baseline is the best-scoring Claude Opus 5 configuration on each
# board, which is the hardest version of the comparison to clear.
#
# A line is printed only when a model is newly ahead since the last stored
# snapshot, and it names at most the three largest margins. The models it does
# not name are NOT recorded as reported, so they lead the next run's line rather
# than being summarised away once and lost - which is what keeps a day where
# five models are already ahead from arriving as a wall of text. A model dropping
# back is never reported, and it is forgotten rather than held as reported, so
# its return is news again the way a first arrival is.
#
# WHEN IT RUNS
# `run` collects at most once per Europe/Amsterdam day, at or after 08:00. That
# gate lives here rather than in the crontab, so `arm` can install an hourly
# entry and a machine asleep at 08:00 still collects when it wakes - a daily
# 08:00 entry alone would simply be skipped. The 23 gated runs a day do no
# network work and exit immediately.
#
# HOW IT REACHES FIRSTMATE
# `run` stages its line; the watcher-dispatched `check` prints it once and clears
# it. The collection is therefore never inside FM_CHECK_TIMEOUT, and `check` does
# no network work at all. `arm` writes state/benchmark-watch.check.sh, binds its
# bytes with fm-check-register.sh, and installs the cron entry; `disarm` reverses
# both. Never hand-compose the shim or its trust binding around those actions.
#
# A site that cannot be read, or that changes shape, is silent for two days and
# reports one short line on the third consecutive failure, then stays silent so a
# dead source is noticed without becoming a daily nag. A failed site keeps its
# last known leader set, so its next good day does not report the whole field as
# new.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

CHECK_ID=benchmark-watch
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
SNAPSHOT="$STATE/.benchmark-watch"
PENDING="$STATE/.benchmark-watch-pending"
DAY_MARK="$STATE/.benchmark-watch-day"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
COMPARE_BIN="$SCRIPT_DIR/fm-benchmark-watch.py"
CRON_TAG="fm-benchmark-watch $FM_HOME"
SCHEDULE_TZ=Europe/Amsterdam
SCHEDULE_HOUR=8
BASELINE_MODEL=claude-opus-5

LIVEBENCH_BASE=https://livebench.ai
DEEPSWE_URL=https://deepswe.datacurve.ai/artifacts/v1.1/leaderboard-live.json

# Wider than the digest default: one line can name several boards, each with a
# model id and two scores. Still one bounded line.
MAX_LINE=420

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-benchmark-watch.sh [check]   print the staged line, if any, and clear it (no network)
  fm-benchmark-watch.sh run       collect once per Europe/Amsterdam day at or after 08:00
  fm-benchmark-watch.sh run --force   collect now, ignoring the daily gate
  fm-benchmark-watch.sh --once    collect now and print the result without storing it
  fm-benchmark-watch.sh arm       write and register state/benchmark-watch.check.sh, install the cron entry
  fm-benchmark-watch.sh disarm    remove the shim, its trust binding, the cron entry, and the stored state
  fm-benchmark-watch.sh --help    print this help

Environment:
  FM_BENCHMARK_MARGIN_PP   points a model must clear the baseline by on LiveBench (default 1.0)
  FM_BENCHMARK_FETCH_SECS  seconds allowed per fetch (default 25)
EOF
}

die_usage() {
  printf 'fm-benchmark-watch: %s\n' "$1" >&2
  usage >&2
  exit 2
}

MARGIN_PP=${FM_BENCHMARK_MARGIN_PP:-1.0}
case "$MARGIN_PP" in
  ''|*[!0-9.]*|*.*.*)
    printf 'fm-benchmark-watch: FM_BENCHMARK_MARGIN_PP must be a non-negative number\n' >&2
    exit 2
    ;;
esac

FETCH_SECS=${FM_BENCHMARK_FETCH_SECS:-25}
case "$FETCH_SECS" in
  ''|*[!0-9]*)
    printf 'fm-benchmark-watch: FM_BENCHMARK_FETCH_SECS must be a whole number of seconds\n' >&2
    exit 2
    ;;
esac
if [ "$FETCH_SECS" -lt 5 ] || [ "$FETCH_SECS" -gt 120 ]; then
  printf 'fm-benchmark-watch: FM_BENCHMARK_FETCH_SECS must be from 5 to 120\n' >&2
  exit 2
fi

# --- fetching ---------------------------------------------------------------

# fetch <url> <destination>: one bounded HTTPS GET into a file.
# Redirects are followed only within https and only a few hops, so a hijacked
# redirect cannot move the read onto another scheme, and a runaway body cannot
# fill the home.
fetch() {
  local url=$1 dest=$2
  curl -fsS \
    --proto '=https' --proto-redir '=https' \
    --location --max-redirs 3 \
    --max-time "$FETCH_SECS" \
    --max-filesize 16777216 \
    -o "$dest" \
    -- "$url" 2>/dev/null
}

# LiveBench publishes its data beside a content-hashed bundle, so both the bundle
# name and the release change without notice. Neither is pinned here: the landing
# page names the bundle, the bundle names the releases, and the newest release
# that actually serves both of its files wins. A release string is accepted only
# as a bare ISO date, so nothing else found in the bundle can become a URL.
livebench_collect() {
  local work=$1 bundle release slug candidates
  if ! fetch "$LIVEBENCH_BASE/" "$work/index.html"; then
    printf 'landing page unreachable\n'
    return 1
  fi
  bundle=$(grep -o 'static/js/main\.[A-Za-z0-9]\{1,40\}\.js' "$work/index.html" | head -n 1)
  if [ -z "$bundle" ]; then
    printf 'landing page names no data bundle\n'
    return 1
  fi
  if ! fetch "$LIVEBENCH_BASE/$bundle" "$work/bundle.js"; then
    printf 'data bundle unreachable\n'
    return 1
  fi
  candidates=$(grep -o '"[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}"' "$work/bundle.js" \
    | tr -d '"' | sort -u -r | head -n 3)
  if [ -z "$candidates" ]; then
    printf 'data bundle names no release\n'
    return 1
  fi
  for release in $candidates; do
    slug=${release//-/_}
    if fetch "$LIVEBENCH_BASE/table_$slug.csv" "$work/table.csv" \
      && fetch "$LIVEBENCH_BASE/categories_$slug.json" "$work/categories.json"; then
      printf '%s\n' "$release"
      return 0
    fi
  done
  printf 'no release serves both data files\n'
  return 1
}

deepswe_collect() {
  local work=$1
  if ! fetch "$DEEPSWE_URL" "$work/deepswe.json"; then
    printf 'leaderboard artifact unreachable\n'
    return 1
  fi
  printf 'ok\n'
}

# --- comparison -------------------------------------------------------------

# collect: fetch both sites, hand the files and the previous snapshot to the
# comparator, and leave its JSON result in COMPARE_RESULT. A site that fails is
# reported to the comparator as a failure rather than omitted, because the
# consecutive-failure count is the comparator's to keep.
COMPARE_RESULT=

collect() {
  local work previous lb_status lb_release ds_status envelope
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-benchmark-watch.XXXXXX") || return 1
  # shellcheck disable=SC2064  # $work is fixed now; expanding later is the point.
  trap "rm -rf -- '$work'" RETURN

  if lb_release=$(livebench_collect "$work"); then
    lb_status=ok
  else
    lb_status=$lb_release
    lb_release=
  fi
  if ds_status=$(deepswe_collect "$work"); then
    ds_status=ok
  fi

  previous=$work/previous.json
  if [ -f "$SNAPSHOT" ] && [ ! -L "$SNAPSHOT" ] && python3 -c '
import json, sys
json.load(open(sys.argv[1]))
' "$SNAPSHOT" 2>/dev/null; then
    cat "$SNAPSHOT" > "$previous" || return 1
  else
    printf 'null\n' > "$previous" || return 1
  fi

  envelope=$work/envelope.json
  LB_STATUS=$lb_status LB_RELEASE=$lb_release DS_STATUS=$ds_status \
  WORK=$work PREVIOUS=$previous BASELINE=$BASELINE_MODEL MARGIN=$MARGIN_PP \
  python3 -c '
import json, os, sys

work = os.environ["WORK"]
lb_ok = os.environ["LB_STATUS"] == "ok"
ds_ok = os.environ["DS_STATUS"] == "ok"
with open(os.environ["PREVIOUS"], encoding="utf-8") as handle:
    previous = json.load(handle)
livebench = {"ok": True, "release": os.environ["LB_RELEASE"],
             "table_csv": os.path.join(work, "table.csv"),
             "categories_json": os.path.join(work, "categories.json")} if lb_ok \
    else {"ok": False, "error": os.environ["LB_STATUS"]}
deepswe = {"ok": True, "json": os.path.join(work, "deepswe.json")} if ds_ok \
    else {"ok": False, "error": os.environ["DS_STATUS"]}
json.dump({
    "baseline_model": os.environ["BASELINE"],
    "margin_pp": float(os.environ["MARGIN"]),
    "now": os.environ.get("NOW", ""),
    "previous": previous,
    "sites": {"livebench": livebench, "deepswe": deepswe},
}, sys.stdout)
' > "$envelope" || return 1

  COMPARE_RESULT=$(NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ) python3 "$COMPARE_BIN" --envelope "$envelope") || return 1
  [ -n "$COMPARE_RESULT" ] || return 1
}

# result_field <name>: one string field out of the comparator's JSON result.
result_field() {
  RESULT_JSON=$COMPARE_RESULT python3 -c '
import json, os, sys
print(json.loads(os.environ["RESULT_JSON"])[sys.argv[1]])
' "$1" 2>/dev/null
}

# persist_snapshot: replace the stored snapshot by rename, so a reader never sees
# a half-written comparison and the next run never compares against a torn file.
persist_snapshot() {
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.fm-benchmark-snapshot.XXXXXX") || return 1
  if ! RESULT_JSON=$COMPARE_RESULT python3 -c '
import json, os, sys
json.dump(json.loads(os.environ["RESULT_JSON"])["snapshot"], open(sys.argv[1], "w"), indent=1)
' "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$SNAPSHOT"
}

# stage <line>: leave one bounded line for the next watcher check. Appending
# rather than replacing would let two collections compound into a multi-line
# check result, so a staged line that was never read is replaced by the newer
# one, which already carries everything still unreported.
stage() {
  local line=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.fm-benchmark-pending.XXXXXX") || return 1
  fm_cap_line_var "$line" "$MAX_LINE"
  printf '%s\n' "$FM_LINE_CAP_LINE" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$PENDING"
}

# --- the daily gate ---------------------------------------------------------

schedule_day() { TZ="$SCHEDULE_TZ" date +%Y-%m-%d; }
schedule_hour() { TZ="$SCHEDULE_TZ" date +%H; }

# due: true when this home has not collected yet on the current scheduled day and
# the scheduled hour has arrived.
due() {
  local today hour last
  today=$(schedule_day) || return 1
  hour=$(schedule_hour) || return 1
  [ "$((10#$hour))" -ge "$SCHEDULE_HOUR" ] || return 1
  last=
  [ ! -f "$DAY_MARK" ] || last=$(head -n 1 "$DAY_MARK" 2>/dev/null)
  [ "$last" != "$today" ]
}

# claim_day: record the day before collecting, so one failed or slow collection
# is one day's silence rather than an attempt on every cron tick.
claim_day() {
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.fm-benchmark-day.XXXXXX") || return 1
  schedule_day > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$DAY_MARK"
}

# --- actions ----------------------------------------------------------------

action_check() {
  local line
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || return 0
  line=$(head -n 1 "$PENDING" 2>/dev/null)
  rm -f -- "$PENDING"
  [ -n "$line" ] || return 0
  printf '%s\n' "$line"
}

action_run() {
  local force=${1:-} report
  mkdir -p "$STATE" || return 1
  if [ "$force" != --force ] && ! due; then
    return 0
  fi
  claim_day || return 1
  collect || {
    printf 'fm-benchmark-watch: could not complete the collection\n' >&2
    return 1
  }
  persist_snapshot || {
    printf 'fm-benchmark-watch: could not store the comparison\n' >&2
    return 1
  }
  report=$(result_field report) || return 1
  [ -n "$report" ] || return 0
  stage "$report"
}

# A manual run answers the operator and leaves every durable record alone, so
# asking the question never consumes the wake the next scheduled run owes.
action_once() {
  local report
  mkdir -p "$STATE" || return 1
  collect || {
    printf 'fm-benchmark-watch: could not complete the collection\n' >&2
    return 1
  }
  report=$(result_field report) || return 1
  if [ -n "$report" ]; then
    fm_cap_line "$report" "$MAX_LINE"
  else
    printf 'fm-benchmark-watch: nothing new ahead of Claude Opus 5\n' >&2
  fi
}

# --- arming -----------------------------------------------------------------

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would reach another home.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-benchmark-watch.sh - daily benchmark leader poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-benchmark-watch.sh") check"
}

SHIM_WRITE_TMP=

# Guards run before anything is written, so a symlink at the shim path is refused
# instead of followed, and the bytes arrive by rename so the watcher never reads a
# half-written shim and rejects it as unauthenticated.
shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-benchmark-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# An unregistered shim is not inert: the watcher rejects it every cycle and wakes
# firstmate about an unauthenticated state check. So a failed arm never leaves a
# shim without a matching trust binding.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-benchmark-watch: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

cron_line() {
  local home=$1
  # Hourly, because the daily gate inside `run` is what pins the collection to
  # 08:00 Europe/Amsterdam. An hourly entry lets a machine that was asleep at
  # 08:00 still collect the same day; the gated ticks do no network work.
  printf '0 * * * * FM_HOME=%s %s run >/dev/null 2>&1  # %s\n' \
    "$home" "$SCRIPT_DIR/fm-benchmark-watch.sh" "$CRON_TAG"
}

# cron_rewrite rewrites only this home's own tagged line and copies every other
# entry through untouched, so a shared crontab keeps whatever else the captain
# scheduled there.
#
# A crontab that cannot be READ is never rewritten. An empty crontab and an
# unreadable one both exit non-zero, and telling them apart is the difference
# between adding one line and replacing the captain's whole schedule with it, so
# only the "no crontab for this user" answer is treated as empty.
cron_rewrite() {
  local keep=$1 want=$2 current filtered errors status
  command -v crontab >/dev/null 2>&1 || return 2
  errors=$(mktemp "${TMPDIR:-/tmp}/fm-benchmark-cron.XXXXXX") || return 1
  current=$(crontab -l 2>"$errors")
  status=$?
  if [ "$status" -ne 0 ]; then
    if grep -qi 'no crontab' "$errors"; then
      current=
    else
      rm -f -- "$errors"
      return 1
    fi
  fi
  rm -f -- "$errors"
  filtered=$(printf '%s\n' "$current" | grep -v -F -- "$CRON_TAG" | grep -v '^[[:space:]]*$')
  if [ "$keep" = install ]; then
    filtered=$(printf '%s\n%s' "$filtered" "$want")
  fi
  printf '%s\n' "$filtered" | grep -v '^[[:space:]]*$' | crontab - 2>/dev/null
}

action_arm() {
  local want home cron_status
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-benchmark-watch: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  command -v python3 >/dev/null 2>&1 || {
    printf 'fm-benchmark-watch: python3 required\n' >&2
    return 1
  }
  command -v curl >/dev/null 2>&1 || {
    printf 'fm-benchmark-watch: curl required\n' >&2
    return 1
  }
  want=$(shim_content "$home")
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-benchmark-watch: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-benchmark-watch: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"

  cron_rewrite install "$(cron_line "$home")"
  cron_status=$?
  case "$cron_status" in
    0) printf 'scheduled: hourly, collecting once daily from %02d:00 %s\n' "$SCHEDULE_HOUR" "$SCHEDULE_TZ" ;;
    2)
      printf 'fm-benchmark-watch: no crontab command, so add this entry yourself:\n' >&2
      cron_line "$home" >&2
      ;;
    *)
      printf 'fm-benchmark-watch: could not update the crontab, so add this entry yourself:\n' >&2
      cron_line "$home" >&2
      ;;
  esac
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$SNAPSHOT" "$PENDING" "$DAY_MARK"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  if cron_rewrite remove ''; then
    printf 'unscheduled: crontab entry removed\n'
  fi
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  run) shift; action_run "${1:-}" ;;
  --once) action_once ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
