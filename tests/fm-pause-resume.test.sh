#!/usr/bin/env bash
# tests/fm-pause-resume.test.sh - supervision resuming a crewmate whose own
# declared wait has expired.
#
# A worker that is deliberately idling declares it with
# `paused: <why> until <UTC ISO 8601>`. Until now the expiry of that declaration
# only re-surfaced the wait for firstmate to read and steer by hand, so a worker
# whose session was cut off mid-work sat idle until a human noticed. This suite
# pins the loop closing itself: the decision of whether a resume steer is owed,
# the steer landing as a real durable record through the real fm-send, the
# once-per-declaration idempotency that keeps repeated supervision passes quiet,
# the cooldown floor that bounds a failing send and a re-declaring worker, the
# crewmate-only scope, and the real watcher poll driving all of it.
#
# Every case drives the real bin/fm-pause-resume.sh over a stubbed tmux, so the
# send path exercised is fm-send's own inbox plane rather than a mock of it.
# Retirement of the idempotency record belongs to the script that removes a task's
# records, so tests/fm-teardown.test.sh covers it against a real teardown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESUME="$ROOT/bin/fm-pause-resume.sh"
WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-pause-resume)

# Two fixed points on the clock, so no case depends on the wall clock: the
# declared time every fixture pauses until, and a "now" well past it.
PAST_ISO='2026-09-12T03:00Z'
LATER_ISO='2026-09-12T03:30Z'
iso_epoch() {  # <YYYY-MM-DDTHH:MMZ>
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${1%Z}:00Z" +%s 2>/dev/null \
    || date -u -d "${1%Z}:00Z" +%s 2>/dev/null
}
PAST_EPOCH=$(iso_epoch "$PAST_ISO")
NOW_EPOCH=$((PAST_EPOCH + 3600))
[ -n "$PAST_EPOCH" ] || { echo "skip: no portable UTC ISO date reader"; exit 0; }

# A tmux that satisfies both consumers in one stub: fm-send's composer read,
# cursor probe, and doorbell ring (literal text recorded to FM_SEND_LOG), and the
# watcher's window listing and pane capture. FM_FAKE_TMUX_SEND_FAIL=1 breaks the
# ring alone, which is deliberately NOT a failed steer on the inbox plane.
make_home() {  # <name> -> echoes the case dir
  local name=$1 dir fb
  dir="$TMP_ROOT/$name"
  fb="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/data" "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    # -t <session>: the task endpoint's own session answers from
    # FM_TEST_ENDPOINT_WINDOWS so the liveness probe sees a live window; every
    # other session answers from FM_FAKE_TMUX_WINDOWS, which is what the
    # watcher's own window inventory reads.
    _sess=; _prev=
    for _a in "$@"; do
      [ "$_prev" = -t ] && { _sess=$_a; break; }
      _prev=$_a
    done
    if [ "$_sess" = sess ]; then
      [ -z "${FM_TEST_ENDPOINT_WINDOWS-fm-t1}" ] || printf '%s\n' "${FM_TEST_ENDPOINT_WINDOWS-fm-t1}"
    else
      [ -z "${FM_FAKE_TMUX_WINDOWS:-}" ] || printf '%s\n' "$FM_FAKE_TMUX_WINDOWS"
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/sleep"
  printf '%s\n' "$dir"
}

add_task() {  # <case-dir> <id> [kind]
  local dir=$1 id=$2 kind=${3:-ship}
  fm_write_meta "$dir/state/$id.meta" \
    "window=sess:fm-$id" "endpoint_task_id=$id" "kind=$kind" \
    "harness=claude" "backend=tmux"
}

declare_pause() {  # <case-dir> <id> <until-iso> [why]
  local dir=$1 id=$2 until=$3 why=${4:-shared account usage limit}
  printf 'paused: %s until %s\n' "$why" "$until" >> "$dir/state/$id.status"
}

run_resume() {  # <case-dir> <now-epoch> <subcommand...>
  local dir=$1 now=$2
  shift 2
  env PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 \
    FM_SEND_LOG="$dir/send.log" FM_PAUSE_RESUME_NOW="$now" \
    FM_TEST_ENDPOINT_WINDOWS="${FM_TEST_ENDPOINT_WINDOWS-fm-t1}" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    ${FM_TEST_RESUME_ENV:+$FM_TEST_RESUME_ENV} \
    "$RESUME" "$@" 2>"$dir/resume.err"
}

inbox_count() {  # <case-dir> <id>
  local n
  n=$(find "$1/state/$2.inbox" -maxdepth 1 -type f -name '*.msg' 2>/dev/null | wc -l)
  printf '%s' "${n//[[:space:]]/}"
}

# Whether the sweep has filed this declaration as delivered. Observable durable
# state the sweep itself writes, not implementation source.
declaration_recorded() {  # <case-dir> <id>
  grep -q '^declaration=' "$1/state/$2.pause-resume-nudged" 2>/dev/null
}

record_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

# Content fingerprint of a whole tree, so any write this sweep must not make shows up.
fingerprint_tree() {  # <dir>
  find "$1" -type f -print0 2>/dev/null | LC_ALL=C sort -z \
    | while IFS= read -r -d '' f; do printf '%s %s\n' "${f#"$1"}" "$(cksum < "$f")"; done
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

wait_for_exit() {  # <pid> [limit-ticks]
  local pid=$1 limit=${2:-150} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}


test_an_expired_declared_wait_earns_one_resume_steer() {
  local dir out body
  dir=$(make_home expired)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"

  out=$(run_resume "$dir" "$NOW_EPOCH" sweep) \
    || fail "the sweep failed on a plainly due declaration: $out $(cat "$dir/resume.err")"
  assert_contains "$out" "sent: t1 2026-09-12T03:00:00Z" \
    "the sweep did not report the steer it sent: $out"
  [ "$(inbox_count "$dir" t1)" = 1 ] \
    || fail "the resume steer did not land as exactly one durable record"
  body=$(record_body "$dir/state/t1.inbox/001.msg")
  assert_contains "$body" "please check and resume your work" \
    "the steer did not ask the worker to resume: $body"
  assert_contains "$body" "2026-09-12T03:00:00Z" \
    "the steer did not name the declared time that passed: $body"
  assert_contains "$body" 'resolved:' \
    "the steer did not tell the worker how to clear its own declaration: $body"
  assert_contains "$body" 'paused: <why> until' \
    "the steer did not offer re-declaring a still-unfinished wait: $body"
  pass "an expired declared wait earns one real resume steer, naming the time that passed"
}

test_the_resume_is_still_reported_to_firstmate() {
  local dir out
  dir=$(make_home reported)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"

  out=$(run_resume "$dir" "$NOW_EPOCH" sweep) || fail "the sweep failed: $out"
  [ -s "$dir/state/.wake-queue" ] \
    || fail "supervision steered the worker without queueing anything for firstmate"
  assert_grep "pause-resume:t1" "$dir/state/.wake-queue" \
    "the durable wake row was not keyed to the task"
  assert_grep "supervision sent the resume steer itself" "$dir/state/.wake-queue" \
    "the wake row did not say what supervision did: $(cat "$dir/state/.wake-queue")"
  assert_grep "check" "$dir/state/.wake-queue" \
    "the resume report was not queued as a check wake"
  pass "the resume is performed AND still reported: the steer never replaces the notification"
}

test_the_sweep_never_writes_the_workers_own_ledger() {
  local dir before after
  dir=$(make_home ledger)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"
  before=$(cksum < "$dir/state/t1.status")

  run_resume "$dir" "$NOW_EPOCH" sweep >/dev/null || fail "the sweep failed"
  after=$(cksum < "$dir/state/t1.status")
  [ "$before" = "$after" ] \
    || fail "the sweep rewrote the worker's own status ledger"
  assert_contains "$(cat "$dir/state/t1.status")" "paused: shared account usage limit" \
    "the worker's declaration was altered"
  pass "the worker keeps sole ownership of its status ledger; the sweep only steers"
}

test_the_same_declaration_is_never_steered_twice() {
  local dir out n
  dir=$(make_home once)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"

  run_resume "$dir" "$NOW_EPOCH" sweep >/dev/null || fail "the first sweep failed"
  # Every repeat is deliberately placed PAST the cooldown window, so the only
  # thing that can keep them quiet is the declaration record itself. Inside the
  # window the cooldown would carry this case and a broken record would pass.
  for n in 1 2 3; do
    out=$(run_resume "$dir" "$((NOW_EPOCH + n * 1000))" sweep) \
      || fail "a repeat sweep failed: $(cat "$dir/resume.err")"
    [ -z "$out" ] || fail "repeat sweep $n steered again instead of staying silent: $out"
  done
  [ "$(inbox_count "$dir" t1)" = 1 ] \
    || fail "repeated supervision passes sent more than one steer for one declaration"
  declaration_recorded "$dir" t1 \
    || fail "the delivered steer was not filed against its declaration, so it would be sent again"
  pass "one declaration earns exactly one steer, however many supervision passes see it"
}

test_a_wait_still_in_force_is_left_alone() {
  local dir out
  dir=$(make_home inforce)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"

  out=$(run_resume "$dir" "$((PAST_EPOCH - 600))" sweep) || fail "the sweep failed: $out"
  [ -z "$out" ] || fail "a wait whose declared time has not arrived was steered: $out"
  [ "$(inbox_count "$dir" t1)" = 0 ] || fail "an unexpired wait received a steer"
  declaration_recorded "$dir" t1 && fail "an unexpired wait was filed as steered"
  pass "a declared wait still in force is left to run out"
}

test_a_pause_with_no_stated_time_is_left_alone() {
  local dir out
  dir=$(make_home notime)
  add_task "$dir" t1
  printf 'paused: waiting on an upstream release\n' > "$dir/state/t1.status"

  out=$(run_resume "$dir" "$NOW_EPOCH" sweep) || fail "the sweep failed: $out"
  [ -z "$out" ] || fail "an open-ended pause was steered: $out"
  [ "$(inbox_count "$dir" t1)" = 0 ] || fail "an open-ended pause received a steer"
  [ ! -e "$dir/state/t1.pause-resume-nudged" ] \
    || fail "an open-ended pause produced a steer record"
  pass "an open-ended pause has no deadline to pass, so nothing is resumed on its behalf"
}

test_a_worker_that_moved_on_is_left_alone() {
  local dir out
  dir=$(make_home movedon)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"
  printf 'resolved: the limit reset\n' >> "$dir/state/t1.status"

  out=$(run_resume "$dir" "$NOW_EPOCH" sweep) || fail "the sweep failed: $out"
  [ -z "$out" ] || fail "a worker that already cleared its own wait was steered: $out"
  [ "$(inbox_count "$dir" t1)" = 0 ] || fail "a cleared wait received a steer"
  pass "a worker that cleared its own declaration is never steered about it"
}

test_a_re_declared_deadline_earns_its_own_steer() {
  local dir out second
  dir=$(make_home redeclared)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"
  run_resume "$dir" "$NOW_EPOCH" sweep >/dev/null || fail "the first sweep failed"

  # The worker came back, found the wait still in force, and said so with a new
  # time. That is a new declaration, and past the cooldown it earns its own steer.
  declare_pause "$dir" t1 "$LATER_ISO" "still limited"
  out=$(run_resume "$dir" "$((NOW_EPOCH + 2000))" sweep) \
    || fail "a re-declared deadline was not steered: $(cat "$dir/resume.err")"
  assert_contains "$out" "sent: t1 2026-09-12T03:30:00Z" \
    "the second steer did not name the new declared time: $out"
  [ "$(inbox_count "$dir" t1)" = 2 ] \
    || fail "the new declaration did not earn its own record"
  second=$(record_body "$dir/state/t1.inbox/002.msg")
  assert_contains "$second" "2026-09-12T03:30:00Z" \
    "the second steer carried the old time: $second"
  pass "a task re-paused with a new deadline is steered again for that new deadline"
}

test_the_cooldown_bounds_a_rapidly_redeclaring_worker() {
  local dir out
  dir=$(make_home cooldown)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"
  run_resume "$dir" "$NOW_EPOCH" sweep >/dev/null || fail "the first sweep failed"

  declare_pause "$dir" t1 "$LATER_ISO" "still limited"
  out=$(run_resume "$dir" "$((NOW_EPOCH + 30))" sweep) || fail "the sweep failed: $out"
  [ -z "$out" ] || fail "a new declaration inside the cooldown was steered at once: $out"
  [ "$(inbox_count "$dir" t1)" = 1 ] || fail "the cooldown did not bound the second steer"

  # A bound, never a cancellation: past the window the same declaration is steered.
  out=$(run_resume "$dir" "$((NOW_EPOCH + 1000))" sweep) \
    || fail "the cooldown swallowed the steer instead of delaying it: $(cat "$dir/resume.err")"
  assert_contains "$out" "sent: t1" "the delayed steer never arrived: $out"
  [ "$(inbox_count "$dir" t1)" = 2 ] || fail "the delayed steer did not land"
  pass "the cooldown delays a rapidly re-declaring worker's next steer, and never cancels it"
}

test_the_redeclaration_cooldown_window_is_fifteen_minutes() {
  local dir out
  dir=$(make_home window)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"
  run_resume "$dir" "$NOW_EPOCH" sweep >/dev/null || fail "the first sweep failed"
  declare_pause "$dir" t1 "$LATER_ISO" "still limited"

  out=$(run_resume "$dir" "$((NOW_EPOCH + 899))" sweep) || fail "the sweep failed: $out"
  [ -z "$out" ] || fail "a re-declaration was steered one second inside the window: $out"
  out=$(run_resume "$dir" "$((NOW_EPOCH + 900))" sweep) \
    || fail "the sweep failed at the window boundary: $(cat "$dir/resume.err")"
  assert_contains "$out" "sent: t1" \
    "no steer was sent at exactly 900s, so the re-declaration window is not fifteen minutes: $out"
  pass "the re-declaration cooldown window is fifteen minutes"
}

test_a_secondmate_is_never_steered_by_this_sweep() {
  local dir out
  dir=$(make_home mate)
  add_task "$dir" m1 secondmate
  declare_pause "$dir" m1 "$PAST_ISO"

  out=$(run_resume "$dir" "$NOW_EPOCH" sweep) || fail "the sweep failed: $out"
  [ -z "$out" ] || fail "a persistent secondmate was steered by the crewmate sweep: $out"
  [ "$(inbox_count "$dir" m1)" = 0 ] || fail "a secondmate received a crewmate resume steer"
  [ ! -e "$dir/state/m1.pause-resume-nudged" ] \
    || fail "a secondmate got a steer record from the crewmate sweep"
  pass "the sweep is crewmate-only: a persistent secondmate's own wait is its home's business"
}

test_a_failed_steer_reports_itself_and_retries_only_after_the_long_floor() {
  local dir out fake
  dir=$(make_home failed)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"

  # A send that cannot record the steer at all. Pointing the sweep at a failing
  # send keeps this case at the level it owns (what the sweep does when delivery
  # fails) without claiming anything about which real failures fm-send reports.
  fake="$dir/failing-send.sh"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$fake"
  chmod +x "$fake"

  out=$(FM_TEST_RESUME_ENV="FM_PAUSE_RESUME_SEND_BIN=$fake" \
    run_resume "$dir" "$NOW_EPOCH" sweep) && fail "a failed steer reported success: $out"
  assert_contains "$out" "failed: t1 2026-09-12T03:00:00Z" \
    "the failure was not reported for the task and time: $out"
  assert_contains "$out" "fm-send exit 7" "the failure did not carry its cause: $out"
  [ "$(inbox_count "$dir" t1)" = 0 ] || fail "a failed steer still recorded something"
  assert_grep "steer it yourself" "$dir/state/.wake-queue" \
    "a failed steer did not hand the task back to firstmate: $(cat "$dir/state/.wake-queue")"
  # The declaration is deliberately NOT recorded, so the steer is retried.
  declaration_recorded "$dir" t1 && fail "a failed steer recorded its declaration as delivered"

  # A failing steer must never wake firstmate faster than the wait it replaced, so
  # the retry is paced by the declared wait's own cadence, not the tight
  # re-declaration cooldown. 1000s is past that cooldown and well inside the
  # cadence: a retry here would be the 16x-too-fast loop this pins against.
  out=$(run_resume "$dir" "$((NOW_EPOCH + 1000))" sweep) || fail "the retry sweep failed: $out"
  [ -z "$out" ] || fail "a failed steer retried on the tight re-declaration cooldown: $out"
  out=$(run_resume "$dir" "$((NOW_EPOCH + 14400))" sweep) \
    || fail "a failed steer was never retried: $(cat "$dir/resume.err")"
  assert_contains "$out" "sent: t1" "the retry did not deliver: $out"
  [ "$(inbox_count "$dir" t1)" = 1 ] || fail "the retried steer did not land"
  pass "a failed steer is reported, never filed as sent, and retried only on the wait's own cadence"
}

test_a_broken_doorbell_is_still_a_delivered_steer() {
  local dir out
  dir=$(make_home doorbell)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"

  out=$(FM_TEST_RESUME_ENV="FM_FAKE_TMUX_SEND_FAIL=1" \
    run_resume "$dir" "$NOW_EPOCH" sweep) \
    || fail "a failed ring was treated as a failed steer: $out $(cat "$dir/resume.err")"
  assert_contains "$out" "sent: t1" "the durable steer was not reported as sent: $out"
  [ "$(inbox_count "$dir" t1)" = 1 ] \
    || fail "the steer was not recorded when its terminal ring failed"
  pass "the durable record is the delivery: a ring that could not land is still a sent steer"
}

test_an_unreported_outcome_is_never_filed_as_delivered() {
  local dir out
  dir=$(make_home unreported)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"
  # An unwritable wake queue: the steer still lands, but nothing can report it.
  : > "$dir/state/.wake-queue"
  chmod 400 "$dir/state/.wake-queue"

  out=$(run_resume "$dir" "$NOW_EPOCH" sweep) \
    && fail "an unreportable steer was reported as a clean send: $out"
  assert_contains "$out" "report of it could not be queued" \
    "the unreported steer did not say so: $out"
  [ "$(inbox_count "$dir" t1)" = 1 ] || fail "the steer itself did not land"
  declaration_recorded "$dir" t1 \
    && fail "a steer firstmate was never told about was filed as delivered"
  chmod 600 "$dir/state/.wake-queue"
  pass "an outcome firstmate was never told about is never filed as delivered"
}

test_an_older_queued_report_never_swallows_a_different_outcome() {
  local dir out rows
  dir=$(make_home queued)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"
  # An unhandled row for this task is already queued, written by an earlier
  # outcome. Wake rows are consumed only by post-handling acknowledgement, so it
  # can sit there describing the opposite of what happens next - which is exactly
  # when a dedup keyed on the task alone would drop the newer event.
  printf '%s\t1\tcheck\tpause-resume:t1\tpause-resume: t1 could not be steered - steer it yourself\n' \
    "$NOW_EPOCH" > "$dir/state/.wake-queue"

  out=$(run_resume "$dir" "$NOW_EPOCH" sweep) \
    || fail "a successful steer was lost behind an older queued row: $out $(cat "$dir/resume.err")"
  assert_contains "$out" "sent: t1" "the steer was not reported as sent: $out"
  rows=$(awk -F '\t' '$3 == "check" && $4 == "pause-resume:t1" { n++ } END { print n + 0 }' \
    "$dir/state/.wake-queue")
  [ "$rows" -eq 2 ] \
    || fail "the new outcome did not get its own durable row ($rows rows): $(cat "$dir/state/.wake-queue")"
  declaration_recorded "$dir" t1 \
    || fail "a reported steer was not filed against its declaration"
  pass "a queued row from an earlier outcome never swallows a different one"
}

test_an_identical_report_is_not_queued_twice() {
  local dir out rows
  dir=$(make_home identical)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"
  # A failing send, twice, past the retry floor: the second failure says exactly
  # what the first one said, and an undrained queue must not collect both.
  printf '#!/usr/bin/env bash\nexit 7\n' > "$dir/failing-send.sh"
  chmod +x "$dir/failing-send.sh"

  FM_TEST_RESUME_ENV="FM_PAUSE_RESUME_SEND_BIN=$dir/failing-send.sh" \
    run_resume "$dir" "$NOW_EPOCH" sweep >/dev/null
  out=$(FM_TEST_RESUME_ENV="FM_PAUSE_RESUME_SEND_BIN=$dir/failing-send.sh" \
    run_resume "$dir" "$((NOW_EPOCH + 14400))" sweep) && fail "the failing send reported success: $out"
  rows=$(awk -F '\t' '$3 == "check" && $4 == "pause-resume:t1" { n++ } END { print n + 0 }' \
    "$dir/state/.wake-queue")
  [ "$rows" -eq 1 ] \
    || fail "a repeated identical failure piled $rows rows onto an undrained queue: $(cat "$dir/state/.wake-queue")"
  pass "a repeated identical report is never queued twice onto an undrained queue"
}

test_a_status_log_with_no_task_record_is_never_steered() {
  local dir out
  dir=$(make_home unknown)
  # A status log carrying a due declared wait but no task record in this home.
  declare_pause "$dir" orphan "$PAST_ISO"

  out=$(run_resume "$dir" "$NOW_EPOCH" sweep) || fail "the sweep failed: $out"
  [ -z "$out" ] || fail "a status log with no task record was steered: $out"
  [ ! -e "$dir/state/orphan.inbox" ] || fail "a task this home does not carry received a steer"
  pass "only a task this home actually carries is ever steered"
}

test_away_posture_stops_the_sweep_from_steering_at_all() {
  local dir pid out i marker
  for marker in .afk .afk-contract; do
    dir=$(make_home "away${marker//./-}")
    add_task "$dir" t1
    declare_pause "$dir" t1 "$PAST_ISO"
    out="$dir/watch.out"
    : > "$dir/state/$marker"

    # The real watcher poll, the only place the sweep is reached from.
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
      FM_STATE_OVERRIDE="$dir/state" FM_WATCH_HANDLING_SUCCESSOR=1 \
      FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 FM_SEND_LOG="$dir/send.log" \
      FM_PAUSE_RESUME_NOW="$NOW_EPOCH" FM_FAKE_TMUX_CURRENT_COMMAND=claude \
      FM_TEST_ENDPOINT_WINDOWS=fm-t1 \
      FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$WATCH" > "$out" 2>"$dir/watch.err" &
    pid=$!
    i=0
    while [ "$i" -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
    reap "$pid"

    [ "$(inbox_count "$dir" t1)" = 0 ] \
      || fail "[$marker] the sweep steered a worker while the away posture was active"
    [ ! -e "$dir/state/t1.pause-resume-nudged" ] \
      || fail "[$marker] the sweep recorded an attempt while the away posture was active"
    assert_not_contains "$(cat "$out")" "check: pause-resume" \
      "[$marker] the sweep reported a resume while the away posture was active: $(cat "$out")"

    # Same fixture, posture cleared: the identical declaration IS steered, so the
    # guard is what held it back rather than the fixture never being due.
    rm -f "$dir/state/$marker"
    out=$(run_resume "$dir" "$NOW_EPOCH" sweep) \
      || fail "[$marker] the same fixture was not steerable once the posture cleared: $(cat "$dir/resume.err")"
    assert_contains "$out" "sent: t1" \
      "[$marker] clearing the away posture did not let the steer through: $out"
  done
  pass "away posture stops the sweep entirely, in either of its two markers"
}

test_a_gone_endpoint_is_reported_once_for_recovery_and_never_retried() {
  local dir out
  dir=$(make_home gone)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"
  # A reachable server whose window is simply not there any more - the shape a
  # harness exit leaves behind when it takes its pane with it. That is what the
  # backend reports as positively gone; an unreadable endpoint stays retryable.
  out=$(FM_TEST_ENDPOINT_WINDOWS='' run_resume "$dir" "$NOW_EPOCH" sweep) \
    || fail "the sweep failed: $out $(cat "$dir/resume.err")"
  assert_contains "$out" "gone: t1 2026-09-12T03:00:00Z" \
    "a gone endpoint was not reported as gone: $out"
  [ "$(inbox_count "$dir" t1)" = 0 ] \
    || fail "a steer was spent on an endpoint that cannot receive one"
  assert_grep "needs recovery" "$dir/state/.wake-queue" \
    "the gone endpoint was not handed to recovery: $(cat "$dir/state/.wake-queue")"
  declaration_recorded "$dir" t1 \
    || fail "a gone endpoint was not stood down, so it would be reported again"

  # Never retried: not on the tight cooldown, and not on the long cadence either.
  out=$(FM_TEST_ENDPOINT_WINDOWS='' run_resume "$dir" "$((NOW_EPOCH + 1000))" sweep) || fail "the sweep failed: $out"
  [ -z "$out" ] || fail "a gone endpoint was re-reported inside the cooldown: $out"
  out=$(FM_TEST_ENDPOINT_WINDOWS='' run_resume "$dir" "$((NOW_EPOCH + 100000))" sweep) || fail "the sweep failed: $out"
  [ -z "$out" ] || fail "a gone endpoint was re-reported on the long cadence: $out"
  pass "a positively gone endpoint is reported once for recovery and never steered or retried"
}

test_other_homes_tasks_are_never_touched() {
  local dir other before after
  dir=$(make_home ownhome)
  other="$dir/other-home"
  mkdir -p "$other/state"
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"
  fm_write_meta "$other/state/x9.meta" "window=sess:fm-x9" "kind=ship" "harness=claude" "backend=tmux"
  declare_pause "$other" x9 "$PAST_ISO"
  before=$(fingerprint_tree "$other")

  run_resume "$dir" "$NOW_EPOCH" sweep >/dev/null || fail "the sweep failed"
  after=$(fingerprint_tree "$other")
  [ "$before" = "$after" ] \
    || fail "the sweep reached outside its own home:"$'\n'"$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)"
  pass "the sweep only ever steers its own home's tasks"
}

test_the_watcher_poll_sends_the_steer_and_surfaces_it() {
  local dir pid out i=0
  dir=$(make_home watcher)
  add_task "$dir" t1
  declare_pause "$dir" t1 "$PAST_ISO"
  out="$dir/watch.out"

  # Armed as a successor, the way fm-watch-arm.sh arms one after firstmate
  # handled a wake: that is the only arm that stays in the poll loop instead of
  # re-announcing the previous round's downtime before the sweep can run.
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    FM_STATE_OVERRIDE="$dir/state" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 FM_SEND_LOG="$dir/send.log" \
    FM_PAUSE_RESUME_NOW="$NOW_EPOCH" FM_FAKE_TMUX_CURRENT_COMMAND=claude \
      FM_TEST_ENDPOINT_WINDOWS=fm-t1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>"$dir/watch.err" &
  pid=$!
  wait_for_exit "$pid" 200 || { reap "$pid"; fail "the watcher never surfaced the resume it performed: $(cat "$out") $(cat "$dir/watch.err")"; }
  reap "$pid"

  assert_contains "$(cat "$out")" "check: pause-resume" \
    "the watcher did not exit on the resume it performed: $(cat "$out")"
  [ "$(inbox_count "$dir" t1)" = 1 ] \
    || fail "the watcher poll did not send the resume steer itself: $(cat "$dir/watch.err")"
  assert_contains "$(record_body "$dir/state/t1.inbox/001.msg")" "resume your work" \
    "the watcher-sent steer was not the resume steer"
  assert_grep "pause-resume:t1" "$dir/state/.wake-queue" \
    "the watcher-sent resume left no durable record for firstmate"

  # And a second armed round stays quiet rather than re-steering.
  : > "$out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    FM_STATE_OVERRIDE="$dir/state" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 FM_SEND_LOG="$dir/send.log" \
    FM_PAUSE_RESUME_NOW="$((NOW_EPOCH + 5))" FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FM_TEST_ENDPOINT_WINDOWS=fm-t1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" >> "$out" 2>>"$dir/watch.err" &
  pid=$!
  while [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  reap "$pid"
  [ "$(inbox_count "$dir" t1)" = 1 ] \
    || fail "a second watcher round re-steered the same declaration"
  assert_not_contains "$(cat "$out")" "check: pause-resume" \
    "a second watcher round re-surfaced a resume it did not perform: $(cat "$out")"
  pass "the real watcher poll performs the resume, exits on it, and stays quiet afterwards"
}

test_an_expired_declared_wait_earns_one_resume_steer
test_the_resume_is_still_reported_to_firstmate
test_the_sweep_never_writes_the_workers_own_ledger
test_the_same_declaration_is_never_steered_twice
test_a_wait_still_in_force_is_left_alone
test_a_pause_with_no_stated_time_is_left_alone
test_a_worker_that_moved_on_is_left_alone
test_a_re_declared_deadline_earns_its_own_steer
test_the_cooldown_bounds_a_rapidly_redeclaring_worker
test_the_redeclaration_cooldown_window_is_fifteen_minutes
test_a_secondmate_is_never_steered_by_this_sweep
test_a_failed_steer_reports_itself_and_retries_only_after_the_long_floor
test_a_broken_doorbell_is_still_a_delivered_steer
test_an_unreported_outcome_is_never_filed_as_delivered
test_an_older_queued_report_never_swallows_a_different_outcome
test_an_identical_report_is_not_queued_twice
test_a_status_log_with_no_task_record_is_never_steered
test_away_posture_stops_the_sweep_from_steering_at_all
test_a_gone_endpoint_is_reported_once_for_recovery_and_never_retried
test_other_homes_tasks_are_never_touched
test_the_watcher_poll_sends_the_steer_and_surfaces_it
