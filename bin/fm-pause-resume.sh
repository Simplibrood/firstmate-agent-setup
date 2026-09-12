#!/usr/bin/env bash
# fm-pause-resume.sh - resume a crewmate whose OWN declared wait has expired.
#
# Usage:
#   fm-pause-resume.sh sweep
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
#   - appending the durable `check` wake that keeps the action visible,
#     deduplicated by payload so a repeated identical report cannot pile up while
#     a genuinely different outcome still gets its own row. The declaration is
#     recorded only once that report really landed, so an outcome firstmate was
#     never told about is never filed as delivered.
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
#   The attempt epoch is recorded BEFORE the send, and the declaration only once
#   the steer landed AND its report was really appended, so an interrupted send,
#   a failed send, or a report that never reached the queue all retry rather than
#   being filed as delivered. Both directions are deliberate: a nudge a worker
#   did not need is a no-op it acknowledges and ignores, while never resuming a
#   genuinely waiting worker is invisible and costs the whole wait.
#
# Two different floors, because a retry and a re-declaration are different risks.
#   Whether the declaration is recorded is what distinguishes them, so no extra
#   field is needed:
#   - a recorded declaration means the last attempt was delivered and reported,
#     so a DIFFERENT declaration arriving after it is paced by
#     FM_PAUSE_RESUME_COOLDOWN_SECONDS (default 900, valid 60..86400). That floor
#     exists only to bound a worker re-declaring in a tight loop.
#   - no recorded declaration means the last attempt failed or was interrupted,
#     so the retry is paced by the declared wait's OWN recheck cadence,
#     FM_PAUSE_RESURFACE_SECS (default 14400, owned by bin/fm-classify-lib.sh).
#     A failing steer must never wake firstmate more often than the wait it
#     replaced would have on its own cadence; pacing a retry off the tight
#     cooldown did exactly that, 16x too fast.
#   Neither floor ever cancels a steer. They only delay it.
#
# A positively gone endpoint is not retried at all. When the backend confidently
# reports the agent dead or missing (bin/fm-backend.sh's fm_backend_agent_alive,
# the same read bin/fm-watch.sh's pause_state_class uses), no amount of steering
# will reach it: the task is reported ONCE as needing recovery, the declaration
# is recorded so the sweep stands down for it, and fm-send's own re-ring ladder
# owns routing a dead endpoint to recovery from there. Only a confident dead
# verdict counts; `unknown` liveness is treated as an ordinary retryable failure,
# so an unreadable endpoint is never mistaken for a gone one.
#
# Away mode is excluded, and bin/fm-watch.sh ENFORCES that at the sweep's call
# site rather than leaving it to this header: the poll loop skips the sweep while
# either away marker exists. The away-posture daemon owns triage and its own
# expired-declared-wait escalation (bin/fm-supervise-daemon.sh), so steering from
# here as well would both act under a posture this script does not cover and
# surface one moment twice. Extending auto-resume into away mode, bound against
# that daemon escalation, is separate follow-up work.
#
# Cost: one metadata glob plus one last-status-line read per task per poll, all
# local file reads. A task with no declared wait costs nothing further, and only
# a genuinely due declaration reaches a send, bounded by
# FM_PAUSE_RESUME_SEND_BUDGET_SECS (default 20, valid 1..120).
#
# sweep prints one line per ACTIONABLE outcome and is otherwise silent, so a
# caller can treat any output as "something happened":
#   sent: <id> <until-iso>            one resume steer was recorded
#   gone: <id> <until-iso>            the endpoint is gone; reported once for recovery
#   failed: <id> <until-iso> <detail> the steer could not be recorded
# It exits 0 when nothing failed, 1 when at least one due task could not be
# nudged, and 2 on unusable configuration. A `gone:` task is accounted for
# rather than failed: nothing further can be delivered to it, and the report
# naming it for recovery is the whole of what this sweep owes.
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
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

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

# The retry floor for a steer that did not land, deliberately the declared wait's
# OWN recheck cadence rather than the tight re-declaration cooldown above.
# fm-classify-lib.sh owns the default; this script only consumes it.
FM_PAUSE_RESUME_RETRY_SECONDS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
case "$FM_PAUSE_RESUME_RETRY_SECONDS" in
  ''|*[!0-9]*|0)
    printf 'fm-pause-resume: FM_PAUSE_RESURFACE_SECS must be a positive whole number of seconds\n' >&2
    exit 2
    ;;
esac

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

sweep   send one resume steer to every crewmate task in this home whose own
        `paused: ... until <time>` declaration has expired and has not already
        been steered for that declaration, append the durable wake that reports
        it, and print one line per actionable outcome:
          sent: <id> <until-iso>            one resume steer was recorded
          gone: <id> <until-iso>            the endpoint is gone; reported for recovery
          failed: <id> <until-iso> <detail> the steer could not be recorded
        Silent when nothing is due. Exits 0 when nothing failed, 1 when at least
        one due task could not be steered, 2 on unusable configuration.
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

# Is a resume steer owed for <task-id> right now? A pure read, no side effects.
# 0 = owed; PAUSE_RESUME_UNTIL and PAUSE_RESUME_DECLARATION are then set.
# 1 = not owed (no declared wait, not yet due, already steered, or inside a floor).
# 2 = this task cannot be evaluated at all.
PAUSE_RESUME_UNTIL=
PAUSE_RESUME_DECLARATION=
nudge_owed() {  # <task-id>
  local id=$1 meta statusf last until now marker attempted recorded age floor
  PAUSE_RESUME_UNTIL=
  PAUSE_RESUME_DECLARATION=
  valid_id "$id" || return 2
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 2
  # Crewmate tasks only; this script's header owns why a mate is excluded.
  if [ "$(record_value "$meta" kind)" = secondmate ]; then
    return 1
  fi
  statusf="$STATE/$id.status"
  last=$(last_status_line "$statusf")
  until=$(status_paused_until "$last") || return 1
  now=$(resume_now)
  [ "$now" -ge "$until" ] || return 1
  PAUSE_RESUME_UNTIL=$until
  PAUSE_RESUME_DECLARATION=$(pause_declaration "$statusf" "$until") || return 2
  marker=$(marker_path "$id")
  recorded=$(record_value "$marker" declaration)
  if [ -n "$recorded" ] && [ "$recorded" = "$PAUSE_RESUME_DECLARATION" ]; then
    return 1
  fi
  # Which floor paces the next attempt follows from what the last one recorded: a
  # recorded declaration means it was delivered and reported, so only a tight
  # re-declaration loop needs bounding; no recorded declaration means it failed or
  # was interrupted, and a retry must not outpace the wait's own cadence.
  if [ -n "$recorded" ]; then
    floor=$FM_PAUSE_RESUME_COOLDOWN_SECONDS
  else
    floor=$FM_PAUSE_RESUME_RETRY_SECONDS
  fi
  attempted=$(record_value "$marker" attempt_epoch)
  case "$attempted" in ''|*[!0-9]*) attempted= ;; esac
  if [ -n "$attempted" ]; then
    age=$(( now - attempted ))
    # A clock that moved backwards must not silence the task forever.
    [ "$age" -lt 0 ] || [ "$age" -ge "$floor" ] || return 1
  fi
  return 0
}

# 0 when the task's recorded endpoint is POSITIVELY gone - the backend confidently
# reports its agent dead or missing. `unknown` is deliberately not gone: an
# endpoint this home cannot read is retried, never written off.
endpoint_positively_gone() {  # <task-id>
  local id=$1 meta window backend
  meta="$STATE/$id.meta"
  window=$(record_value "$meta" window)
  [ -n "$window" ] || return 1
  backend=$(record_value "$meta" backend)
  [ -n "$backend" ] || backend=tmux
  [ "$(fm_backend_agent_alive "$backend" "$window" 2>/dev/null || printf unknown)" = dead ]
}

# Record an attempt, and the declaration only once the steer landed AND its
# report was really appended. Whether the declaration is present is what picks
# the floor in nudge_owed above, so an unreported steer paces like a failure
# instead of being filed as delivered.
write_marker() {  # <task-id> <attempt-epoch> <declaration-or-empty>
  local id=$1 epoch=$2 declaration=$3 marker tmp
  marker=$(marker_path "$id")
  tmp="$marker.tmp.$$"
  {
    printf 'schema=fm-pause-resume.v1\n'
    printf 'attempt_epoch=%s\n' "$epoch"
    [ -z "$declaration" ] || printf 'declaration=%s\n' "$declaration"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$marker" || { rm -f -- "$tmp"; return 1; }
}

# Report one outcome durably, deduplicated by PAYLOAD rather than by task key.
#
# Key-only dedup was wrong in both directions. A wake row is consumed only by
# post-handling acknowledgement, so a row stays queued for the whole of
# firstmate's handling turn - and in that window a row written by an EARLIER
# outcome can describe the opposite of the current one (a failure row still
# queued while a later retry succeeded), or belong to an entirely different
# declaration. Suppressing on the key alone silently dropped those genuinely new
# events; counting the suppression as "reported" then filed them as delivered.
#
# Comparing payloads gets both right: an identical row already queued really does
# say this exact thing about this exact declaration, so firstmate will see it and
# nothing more is owed, while any different outcome gets its own row. A repeated
# identical failure still cannot pile rows up, which is what the dedup was for.
# The payloads built below are single-line and far under the queue's field cap, so
# the stored form is byte-identical to what is compared here.
#   0 = this outcome is on the queue, newly appended or already there
#   2 = the append failed
publish_wake() {  # <task-id> <payload>
  local key="pause-resume:$1" payload=$2 status=0 existing
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  existing=$(awk -F '\t' -v k="$key" '$3 == "check" && $4 == k { print $5 }' \
    "$FM_WAKE_QUEUE" 2>/dev/null || true)
  if printf '%s\n' "$existing" | grep -Fxq -- "$payload"; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  fm_wake_append_locked check "$key" "$payload" || status=2
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

# Send and record for one due task, under this task's own nudge lock so two
# supervision passes cannot both steer it.
nudge_task() {  # <task-id> -> 0 sent, 1 failed, 2 nothing owed, 3 endpoint gone
  local id=$1 lock until_iso epoch send_rc=0 detail payload
  lock="$STATE/.$id.pause-resume.lock"
  fm_lock_try_acquire "$lock" || return 2
  if ! nudge_owed "$id"; then
    fm_lock_release "$lock"
    return 2
  fi
  until_iso=$(iso_utc "$PAUSE_RESUME_UNTIL")
  epoch=$(resume_now)
  # The attempt is recorded BEFORE anything else: a crash between here and the
  # send must cost a retry floor, never a steer on every poll thereafter.
  if ! write_marker "$id" "$epoch" ''; then
    fm_lock_release "$lock"
    payload="pause-resume: $id declared its wait until $until_iso, which has passed, but the attempt could not be recorded, so nothing was sent - steer it yourself"
    publish_wake "$id" "$payload" >/dev/null 2>&1 || true
    printf 'failed: %s %s could not record the resume attempt\n' "$id" "$until_iso"
    return 1
  fi
  # A positively gone endpoint can never receive a steer, so do not spend one and
  # do not retry: report it once for recovery and stand down for this declaration.
  if endpoint_positively_gone "$id"; then
    payload="pause-resume: $id declared its wait until $until_iso, which has passed, and its endpoint is gone, so no steer can reach it - this task needs recovery"
    if publish_wake "$id" "$payload" && write_marker "$id" "$epoch" "$PAUSE_RESUME_DECLARATION"; then
      fm_lock_release "$lock"
      printf 'gone: %s %s\n' "$id" "$until_iso"
      return 3
    fi
    # The report did not land, so nothing may be filed as delivered; the retry
    # floor paces the next look rather than this poll repeating it.
    fm_lock_release "$lock"
    printf 'failed: %s %s endpoint gone, and the report of it could not be queued\n' "$id" "$until_iso"
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
    publish_wake "$id" "$payload" >/dev/null 2>&1 || true
    printf 'failed: %s %s %s\n' "$id" "$until_iso" "$detail"
    return 1
  fi
  payload="pause-resume: $id declared its wait until $until_iso, which has passed; supervision sent the resume steer itself - confirm the work restarted"
  if ! publish_wake "$id" "$payload"; then
    # The steer landed but nothing will report it, so nothing may be filed as
    # delivered: the declaration stays unrecorded and the retry floor paces the
    # next attempt. A duplicate steer later is a no-op the worker ignores, while a
    # steer filed as reported when firstmate was never told is not recoverable.
    fm_lock_release "$lock"
    printf 'failed: %s %s sent, but the report of it could not be queued\n' "$id" "$until_iso"
    return 1
  fi
  if ! write_marker "$id" "$epoch" "$PAUSE_RESUME_DECLARATION"; then
    fm_lock_release "$lock"
    printf 'failed: %s %s sent and reported, but the steer record could not be written\n' "$id" "$until_iso"
    return 1
  fi
  fm_lock_release "$lock"
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
    # 3 (endpoint gone) is an accounted-for outcome, not a failure to steer.
    [ "$task_rc" -ne 1 ] || rc=1
  done
  return "$rc"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
cmd=$1; shift
case "$cmd" in
  sweep) cmd_sweep "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
