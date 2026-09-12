#!/usr/bin/env bash
# fm-pause-resume.sh - resume a crewmate whose OWN declared wait has expired.
#
# Usage:
#   fm-pause-resume.sh sweep
#   fm-pause-resume.sh due <task-id>
#   fm-pause-resume.sh steered <task-id>
#   fm-pause-resume.sh nudged <task-id>
#
# A worker that is deliberately idling on a known external dependency declares
# it itself with `paused: <why> until <YYYY-MM-DDTHH:MM[:SS]Z>`, and supervision
# then leaves its idle endpoint alone on the long recheck cadence instead of
# treating it as a possible wedge. bin/fm-classify-lib.sh owns that vocabulary
# (status_is_paused, status_paused_until) and bin/fm-watch.sh owns the cadence.
#
# What was missing is the other end of that declaration. Once the declared
# clearing time passed, the watcher only RE-SURFACED the wait for firstmate to
# notice and steer by hand - so a worker whose session was cut off mid-work (the
# shared account hitting its usage limit is the case this exists for) sat idle
# until a human happened to read that recheck. This script closes that loop:
# supervision sends the resume steer itself, and still reports that it did.
#
# What this script owns:
#   - the decision "is a resume nudge owed for this task right now", as a pure
#     read of durable state, so it is testable without any send mechanism;
#   - the nudge text, which asks the worker to verify the wait, then either
#     clear the declaration with its own `resolved:` line or re-declare a fresh
#     `paused: ... until <time>` (bin/fm-brief.sh rule 6 owns that contract);
#   - the once-per-declaration idempotency record, state/<id>.pause-resume-nudged;
#   - sending through bin/fm-send.sh's ordinary steering-inbox plane, the same
#     durable record a firstmate steer lands in. Ordinary rather than
#     fire-and-forget on purpose: the worker acknowledges the record by handling
#     it, so the watcher's existing re-ring ladder carries the steer to a worker
#     that missed its doorbell and escalates one that never picks it up - which
#     is exactly the worker this sweep exists for;
#   - appending the durable `check` wake that keeps the action visible, and
#     recording whether that report landed, so `steered` can tell a reported
#     steer from one firstmate was never told about.
#
# What this script must never do:
#   - write a task's status file. The worker owns its own ledger; a declaration
#     this script cleared on the worker's behalf would be a record of something
#     that did not happen.
#   - act on a persistent secondmate (kind=secondmate). A mate is idle by
#     default and acts only on work its parent routes; its declared wait is its
#     own home's business, not a crewmate task to restart. Crewmate tasks only.
#   - act on the primary firstmate session. There is nothing to act on: firstmate
#     is the process that would be blocked, so no supervision of its own can
#     steer it. That is an accepted limitation, not a gap to paper over.
#
# Idempotency, and which way it fails:
#   The record binds ONE declaration: the expired `until` time plus the status
#   log's own observed signature (bin/fm-wake-lib.sh's fm_wake_signal_sig, the
#   same identity the watcher's re-surface throttle is keyed to). A nudge fires
#   once for that declaration, not once per poll and not once per watcher
#   process; a task later re-paused with a new deadline - or re-declaring the
#   same one - is a different declaration and earns its own nudge.
#   The attempt epoch is recorded BEFORE the send and the declaration only after
#   it succeeds, so an interrupted or failed send retries after the cooldown
#   rather than either hammering the worker every poll or going silent forever.
#   Both directions are deliberate: a nudge a worker did not need is a no-op it
#   acknowledges and ignores, while never resuming a genuinely waiting worker is
#   invisible and costs the whole wait.
#   FM_PAUSE_RESUME_COOLDOWN_SECONDS (default 900, valid 60..86400) is that
#   floor. It bounds a pathologically re-declaring worker and a persistently
#   failing send; it never cancels a nudge, only delays it.
#
# Away mode is out of scope here: while the away-posture daemon owns triage it
# also owns its own declared-wait classification (bin/fm-supervise-daemon.sh),
# and this sweep is wired into the attended watcher poll only.
#
# Cost: one metadata glob plus one last-status-line read per task per poll, all
# local file reads. A task with no declared wait costs nothing further, and only
# a genuinely due declaration reaches a send, bounded by
# FM_PAUSE_RESUME_SEND_BUDGET_SECS (default 20, valid 1..120).
#
# sweep prints one line per ACTIONABLE outcome and is otherwise silent, so a
# caller can treat any output as "something happened":
#   sent: <id> <until-iso>            one resume steer was recorded
#   failed: <id> <until-iso> <detail> the steer could not be recorded
# It exits 0 when nothing failed, 1 when at least one due task could not be
# nudged, and 2 on unusable configuration.
# due prints `owed: <id> until=<iso>` and exits 0 when a nudge is owed now, or
# `held: <id> <reason>` and exits 1 when it is not; 2 on unusable input.
# steered is the silent read the watcher uses to stand its own due recheck down:
# exit 0 only when <task-id>'s CURRENT declaration has already been steered AND
# that steer was reported, so a steer whose report never landed keeps the
# watcher's own recheck in play rather than silencing both records of one event.
# nudged prints the recorded declaration record for <task-id>, or exits 1.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

SEND_BIN="${FM_PAUSE_RESUME_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"

FM_PAUSE_RESUME_COOLDOWN_SECONDS=${FM_PAUSE_RESUME_COOLDOWN_SECONDS:-900}
case "$FM_PAUSE_RESUME_COOLDOWN_SECONDS" in
  ''|*[!0-9]*)
    printf 'fm-pause-resume: FM_PAUSE_RESUME_COOLDOWN_SECONDS must be a whole number from 60 to 86400\n' >&2
    exit 2
    ;;
esac
if [ "$FM_PAUSE_RESUME_COOLDOWN_SECONDS" -lt 60 ] || [ "$FM_PAUSE_RESUME_COOLDOWN_SECONDS" -gt 86400 ]; then
  printf 'fm-pause-resume: FM_PAUSE_RESUME_COOLDOWN_SECONDS must be a whole number from 60 to 86400\n' >&2
  exit 2
fi

FM_PAUSE_RESUME_SEND_BUDGET_SECS=${FM_PAUSE_RESUME_SEND_BUDGET_SECS:-20}
case "$FM_PAUSE_RESUME_SEND_BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-pause-resume: FM_PAUSE_RESUME_SEND_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
    exit 2
    ;;
esac
if [ "$FM_PAUSE_RESUME_SEND_BUDGET_SECS" -gt 120 ]; then
  printf 'fm-pause-resume: FM_PAUSE_RESUME_SEND_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
  exit 2
fi

usage() {
  cat <<'EOF'
usage: fm-pause-resume.sh sweep
       fm-pause-resume.sh due <task-id>
       fm-pause-resume.sh nudged <task-id>

sweep   send one resume steer to every crewmate task in this home whose own
        `paused: ... until <time>` declaration has expired and has not already
        been nudged for that declaration, append the durable wake that reports
        it, and print one line per actionable outcome.
due     read-only: exit 0 when a resume nudge is owed for <task-id> right now,
        1 when it is not, 2 on unusable input. Sends nothing.
steered read-only and silent: exit 0 only when <task-id>'s current declaration
        has already been steered and that steer was reported to firstmate.
nudged  print the recorded nudge declaration for <task-id>.
EOF
}

fail() { printf 'fm-pause-resume: %s\n' "$*" >&2; exit 2; }

# Overridable only so a test can pin a deterministic clock.
resume_now() {
  case "${FM_PAUSE_RESUME_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_PAUSE_RESUME_NOW" ;;
  esac
}

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

marker_path() {  # <task-id>
  printf '%s/%s.pause-resume-nudged\n' "$STATE" "$1"
}

record_value() {  # <file> <key>
  local f=$1 key=$2
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  grep "^${key}=" "$f" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

meta_field() {  # <meta-file> <key>
  local f=$1 key=$2
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  grep "^${key}=" "$f" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

iso_utc() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$1"
}

# The declaration one nudge is bound to: the expired time plus the status log's
# own observed signature, so any later status event is a different declaration.
# Returns 1 when the signature cannot be read, which keeps an unreadable log out
# of the nudge path rather than binding a nudge to an identity that means nothing.
pause_declaration() {  # <status-file> <until-epoch>
  local sig
  sig=$(fm_wake_signal_sig "$1") || return 1
  [ -n "$sig" ] || return 1
  printf 'due:%s:%s' "$2" "$sig"
}

# The steer itself. Deliberately independent of why the worker paused: by the
# time this lands the declared wait may have cleared, may not have, or the worker
# may have resumed on its own, and all three are answered by asking it to check.
resume_text() {  # <until-iso>
  cat <<EOF
The declared wait on your last status line should have cleared - please check and resume your work.

That line declared a wait until $1, which has now passed.

- If what you were waiting on has cleared, append \`resolved: <how it cleared>\` to your status file and continue from where you stopped.
- If it has NOT cleared, append a fresh \`paused: <why> until <YYYY-MM-DDTHH:MMZ>\` line carrying the new expected time, so the wait stays declared instead of reading as a stuck worker.
- If you already resumed on your own, nothing is needed here.

Supervision sent this automatically when your declared time passed; no reply is expected.
EOF
}

# Is a resume nudge owed for <task-id> right now? A pure read, no side effects.
# 0 = owed; PAUSE_RESUME_UNTIL and PAUSE_RESUME_DECLARATION are then set.
# 1 = not owed; PAUSE_RESUME_HOLD names why.
# 2 = this task cannot be evaluated at all.
PAUSE_RESUME_UNTIL=
PAUSE_RESUME_DECLARATION=
PAUSE_RESUME_HOLD=
nudge_owed() {  # <task-id>
  local id=$1 meta statusf last until now marker attempted recorded age
  PAUSE_RESUME_UNTIL=
  PAUSE_RESUME_DECLARATION=
  PAUSE_RESUME_HOLD=
  valid_id "$id" || { PAUSE_RESUME_HOLD='not a task id'; return 2; }
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || { PAUSE_RESUME_HOLD='no task record'; return 2; }
  # Crewmate tasks only; this script's header owns why a mate is excluded.
  if [ "$(meta_field "$meta" kind)" = secondmate ]; then
    PAUSE_RESUME_HOLD='secondmate'
    return 1
  fi
  statusf="$STATE/$id.status"
  last=$(last_status_line "$statusf")
  if ! until=$(status_paused_until "$last"); then
    PAUSE_RESUME_HOLD='no declared wait with a stated time'
    return 1
  fi
  now=$(resume_now)
  if [ "$now" -lt "$until" ]; then
    PAUSE_RESUME_HOLD="declared time not reached ($(( until - now ))s away)"
    return 1
  fi
  PAUSE_RESUME_UNTIL=$until
  PAUSE_RESUME_DECLARATION=$(pause_declaration "$statusf" "$until") || {
    PAUSE_RESUME_HOLD='status log signature unreadable'
    return 2
  }
  marker=$(marker_path "$id")
  recorded=$(record_value "$marker" declaration)
  if [ -n "$recorded" ] && [ "$recorded" = "$PAUSE_RESUME_DECLARATION" ]; then
    PAUSE_RESUME_HOLD='already nudged for this declaration'
    return 1
  fi
  attempted=$(record_value "$marker" attempt_epoch)
  case "$attempted" in ''|*[!0-9]*) attempted= ;; esac
  if [ -n "$attempted" ]; then
    age=$(( now - attempted ))
    # A clock that moved backwards must not silence the task forever.
    if [ "$age" -ge 0 ] && [ "$age" -lt "$FM_PAUSE_RESUME_COOLDOWN_SECONDS" ]; then
      PAUSE_RESUME_HOLD="cooldown ${age}s"
      return 1
    fi
  fi
  return 0
}

# Record an attempt, and the declaration only once it actually landed. <reported>
# says whether firstmate was told; it gates `steered` below.
write_marker() {  # <task-id> <attempt-epoch> <declaration-or-empty> <reported>
  local id=$1 epoch=$2 declaration=$3 reported=$4 marker tmp
  marker=$(marker_path "$id")
  tmp="$marker.tmp.$$"
  {
    printf 'schema=fm-pause-resume.v1\n'
    printf 'attempt_epoch=%s\n' "$epoch"
    printf 'reported=%s\n' "$reported"
    [ -z "$declaration" ] || printf 'declaration=%s\n' "$declaration"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$marker" || { rm -f -- "$tmp"; return 1; }
}

# One durable wake row per task, skipped while an unhandled one is still queued,
# so a retried failure cannot pile rows onto a queue nobody has drained yet.
publish_wake() {  # <task-id> <payload>
  local key="pause-resume:$1" queued
  queued=$(fm_wake_queued_keys check 2>/dev/null || true)
  if printf '%s\n' "$queued" | grep -Fx -- "$key" >/dev/null 2>&1; then
    return 0
  fi
  fm_wake_append check "$key" "$2"
}

# Send and record for one due task, under this task's own nudge lock so two
# supervision passes cannot both steer it.
nudge_task() {  # <task-id> -> 0 sent, 1 failed, 2 nothing owed
  local id=$1 lock until_iso epoch send_rc=0 detail payload reported
  lock="$STATE/.$id.pause-resume.lock"
  fm_lock_try_acquire "$lock" || return 2
  if ! nudge_owed "$id"; then
    fm_lock_release "$lock"
    return 2
  fi
  until_iso=$(iso_utc "$PAUSE_RESUME_UNTIL")
  epoch=$(resume_now)
  # The attempt is recorded BEFORE the send: a crash between the two must cost a
  # cooldown, never a nudge on every poll thereafter.
  if ! write_marker "$id" "$epoch" '' 0; then
    fm_lock_release "$lock"
    payload="pause-resume: $id declared its wait until $until_iso, which has passed, but the attempt could not be recorded, so nothing was sent - steer it yourself"
    publish_wake "$id" "$payload" || true
    printf 'failed: %s %s could not record the resume attempt\n' "$id" "$until_iso"
    return 1
  fi
  fm_run_timed "$FM_PAUSE_RESUME_SEND_BUDGET_SECS" \
    env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SEND_BIN" "$id" "$(resume_text "$until_iso")" >/dev/null 2>&1 || send_rc=$?
  if [ "$send_rc" -ne 0 ]; then
    fm_lock_release "$lock"
    if [ "$send_rc" -eq 124 ]; then
      detail="the steer did not finish within ${FM_PAUSE_RESUME_SEND_BUDGET_SECS}s"
    else
      detail="the steer could not be recorded (fm-send exit $send_rc)"
    fi
    payload="pause-resume: $id declared its wait until $until_iso, which has passed, and $detail - steer it yourself"
    publish_wake "$id" "$payload" || true
    printf 'failed: %s %s %s\n' "$id" "$until_iso" "$detail"
    return 1
  fi
  payload="pause-resume: $id declared its wait until $until_iso, which has passed; supervision sent the resume steer itself - confirm the work restarted"
  reported=0
  publish_wake "$id" "$payload" && reported=1
  if ! write_marker "$id" "$epoch" "$PAUSE_RESUME_DECLARATION" "$reported"; then
    # The worker holds the steer; only this home's record of it is missing, so
    # say so rather than letting the next pass steer again in silence.
    fm_lock_release "$lock"
    printf 'failed: %s %s sent, but the nudge record could not be written\n' "$id" "$until_iso"
    return 1
  fi
  fm_lock_release "$lock"
  if [ "$reported" -ne 1 ]; then
    # The steer landed but nothing will report it. Say so on this pass, because
    # an action taken invisibly is exactly what this script must not produce -
    # and the unreported steer deliberately leaves the watcher's own due recheck
    # in play (see `steered`), so the event still reaches firstmate somehow.
    printf 'failed: %s %s sent, but the report of it could not be queued\n' "$id" "$until_iso"
    return 1
  fi
  printf 'sent: %s %s\n' "$id" "$until_iso"
  return 0
}

cmd_sweep() {
  local meta id rc=0 task_rc
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    nudge_owed "$id" || continue
    task_rc=0
    nudge_task "$id" || task_rc=$?
    [ "$task_rc" -ne 1 ] || rc=1
  done
  return "$rc"
}

cmd_due() {
  local id owed_rc=0
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  id=$1
  nudge_owed "$id" || owed_rc=$?
  case "$owed_rc" in
    0) printf 'owed: %s until=%s\n' "$id" "$(iso_utc "$PAUSE_RESUME_UNTIL")"; return 0 ;;
    1) printf 'held: %s %s\n' "$id" "$PAUSE_RESUME_HOLD"; return 1 ;;
    *) fail "$PAUSE_RESUME_HOLD: $id" ;;
  esac
}

# The watcher's stand-down read: has this exact declaration already been steered
# and reported? Silent by contract, because it runs on the watcher's stale path.
cmd_steered() {  # <task-id>
  local id owed_rc=0
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  id=$1
  nudge_owed "$id" || owed_rc=$?
  # Anything but "this declaration is already recorded" means no steer covers the
  # declaration the task is sitting on right now.
  [ "$owed_rc" -eq 1 ] || return 1
  [ "$PAUSE_RESUME_HOLD" = 'already nudged for this declaration' ] || return 1
  [ "$(record_value "$(marker_path "$id")" reported)" = 1 ] || return 1
  return 0
}

cmd_nudged() {
  local id marker
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  id=$1
  valid_id "$id" || fail "not a task id: $id"
  marker=$(marker_path "$id")
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  cat "$marker"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
cmd=$1; shift
case "$cmd" in
  sweep) cmd_sweep "$@" ;;
  due) cmd_due "$@" ;;
  steered) cmd_steered "$@" ;;
  nudged) cmd_nudged "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
