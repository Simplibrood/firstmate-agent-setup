#!/usr/bin/env bash
# tests/fm-context-window.test.sh - behavior tests for bin/fm-context-window.sh,
# the owner of "what compaction window is configured, and did a session hold it".
#
# The measurement that produced this script (2026-09-14, 192 worker sessions) found
# two separate facts, and the tests below pin both halves plus the boundary between
# what the script may and may not claim:
#
#   - when a window is in force, compaction fires below it every time, so a
#     correctly-compacting session must NOT be reported as an offender;
#   - a session can run with no window in force at all and reach 792,073, so an
#     absent configuration must fail a launch rather than be assumed benign.
#
# The script must never claim it can bound a RUNNING session. Everything here
# drives its real command line; nothing asserts on source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CW="$ROOT/bin/fm-context-window.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-window-tests)
trap fm_test_cleanup EXIT

# A hermetic world: its own settings scopes, its own transcript root, its own
# state dir, so nothing here reads the real fleet.
make_world() {  # <name> -> dir
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/.claude" "$dir/projects" "$dir/state" "$dir/work/.claude"
  printf '%s\n' "$dir"
}

cw() {  # <world> <args...>
  local w=$1
  shift
  FM_CLAUDE_PROJECTS_ROOT="$w/projects" FM_CLAUDE_USER_SETTINGS="$w/home/.claude/settings.json" \
    FM_STATE_OVERRIDE="$w/state" FM_HOME="$w" "$CW" "$@"
}

# Write a transcript whose calls reach <peak> context, with <fires> compactions.
write_transcript() {  # <world> <cwd> <peak> <fires>
  local w=$1 cwd=$2 peak=$3 fires=$4 dir mangled f i
  mangled=${cwd//\//-}; mangled=${mangled//./-}
  dir="$w/projects/$mangled"
  mkdir -p "$dir"
  f="$dir/session.jsonl"
  : > "$f"
  for i in $(seq 1 "$fires"); do
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"This session is being continued from a previous conversation that ran out of context."}]}}' >> "$f"
  done
  printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":10,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0,"output_tokens":5}}}\n' \
    "$(( peak - 10 ))" >> "$f"
}

# --- effective: the configured window, and which scope set it ------------------

W=$(make_world effective)
printf '{"autoCompactWindow": 400000}\n' > "$W/home/.claude/settings.json"
OUT=$(cw "$W" effective --cwd "$W/work") || fail "effective must succeed when the user scope sets a window"
assert_contains "$OUT" 'window=400000' "the configured window must be reported"
assert_contains "$OUT" "$W/home/.claude/settings.json" "the scope that set the window must be named, so an operator knows where to change it"
pass "effective reports the configured window and the scope that supplied it"

# A project scope narrows the window and must win over the user scope.
printf '{"autoCompactWindow": 200000}\n' > "$W/work/.claude/settings.json"
OUT=$(cw "$W" effective --cwd "$W/work") || fail "effective must succeed with a project scope"
assert_contains "$OUT" 'window=200000' "a narrower project scope must win over the user scope"
pass "a project scope that narrows the window wins over the user scope"

# --- effective: absence is reported as absence, never as a default -------------

W2=$(make_world absent)
OUT=$(cw "$W2" effective --cwd "$W2/work") && fail "effective must fail when nothing configures a window"
assert_contains "$OUT" 'window=none' "an absent window must be reported as none, never silently defaulted"
pass "an absent window is reported as absent rather than assumed"

# Malformed and nonsense values are absence, not configuration.
for BAD in '{"autoCompactWindow": "400000"}' '{"autoCompactWindow": 0}' '{"autoCompactWindow": true}' 'not json at all'; do
  printf '%s\n' "$BAD" > "$W2/home/.claude/settings.json"
  cw "$W2" effective --cwd "$W2/work" >/dev/null 2>&1 \
    && fail "a window of [$BAD] must not be accepted as configuration"
done
pass "a malformed, zero, boolean or unparsable window is treated as absent, not accepted"

# --- verify: fails closed, which is the whole point ----------------------------

W3=$(make_world verify)
printf '{"autoCompactWindow": 400000}\n' > "$W3/home/.claude/settings.json"
cw "$W3" verify --max 400000 --cwd "$W3/work" >/dev/null \
  || fail "a window exactly at the ceiling must verify"
pass "a window at the ceiling verifies"

set +e
OUT=$(cw "$W3" verify --max 200000 --cwd "$W3/work" 2>&1); RC=$?
set -e
assert_not_equals 0 "$RC" "a window above the ceiling must fail the launch"
assert_contains "$OUT" '400000' "the refusal must name the window it found"
assert_contains "$OUT" '200000' "the refusal must name the ceiling it required"
pass "a window above the ceiling fails closed and names both numbers"

W4=$(make_world verify-absent)
set +e
OUT=$(cw "$W4" verify --max 400000 --cwd "$W4/work" 2>&1); RC=$?
set -e
assert_not_equals 0 "$RC" "an unconfigured window must fail the launch, never pass by default"
assert_contains "$OUT" 'no compaction window is configured' "the refusal must say plainly that nothing is configured"
assert_contains "$OUT" 'settings.json' "the refusal must name the file an operator has to fix"
pass "an unconfigured window fails the launch and says what to fix"

# --- overshoot: reports a session that passed its window ----------------------

W5=$(make_world overshoot)
printf '{"autoCompactWindow": 400000}\n' > "$W5/home/.claude/settings.json"
mkdir -p "$W5/wt-over" "$W5/wt-ok"
printf 'worktree=%s\n' "$W5/wt-over" > "$W5/state/runaway.meta"
printf 'worktree=%s\n' "$W5/wt-ok" > "$W5/state/behaved.meta"
# The shape the measurement actually found: a session that never compacted and
# ran far past its window, beside one that compacted and stayed under it.
write_transcript "$W5" "$W5/wt-over" 792073 0
write_transcript "$W5" "$W5/wt-ok" 369091 2
OUT=$(cw "$W5" overshoot) || fail "overshoot must report an offender"
assert_contains "$OUT" 'runaway' "the overshooting session must be named"
assert_contains "$OUT" '792073' "the peak it actually reached must be reported"
assert_contains "$OUT" '400000' "the window it was measured against must be reported"
assert_not_contains "$OUT" 'behaved' "a session that compacted below its window must not be reported as an offender"
pass "overshoot names the session, its peak and its window, and leaves a correctly-compacting session alone"

# The action it recommends must be the only honest one: a running session cannot
# be truncated from outside, so the report says stand down and relaunch.
assert_contains "$OUT" 'cannot be truncated from outside' \
  "the report must state plainly that no runtime truncation lever exists"
pass "the report states that a running session cannot be truncated from outside"

# --- overshoot: silence when every session held -------------------------------

W6=$(make_world quiet)
printf '{"autoCompactWindow": 400000}\n' > "$W6/home/.claude/settings.json"
mkdir -p "$W6/wt"
printf 'worktree=%s\n' "$W6/wt" > "$W6/state/fine.meta"
write_transcript "$W6" "$W6/wt" 355369 1
set +e
OUT=$(cw "$W6" overshoot 2>&1); RC=$?
set -e
assert_not_equals 0 "$RC" "overshoot must return non-zero when nothing needs attention"
[ -z "$OUT" ] || fail "overshoot must print nothing when every session held its window: [$OUT]"
pass "overshoot is silent and non-zero when every session held its window"

# A session just under its window is not an offender; the grace band exists
# because a correctly-compacting session still peaks close to the limit.
W7=$(make_world grace)
printf '{"autoCompactWindow": 400000}\n' > "$W7/home/.claude/settings.json"
mkdir -p "$W7/wt"
printf 'worktree=%s\n' "$W7/wt" > "$W7/state/edge.meta"
write_transcript "$W7" "$W7/wt" 405000 1
set +e
OUT=$(cw "$W7" overshoot 2>&1); RC=$?
set -e
assert_not_equals 0 "$RC" "a session inside the grace band must not be reported"
pass "a session marginally over its window is inside the grace band and is not reported"

echo "# fm-context-window.test.sh: all assertions passed"
