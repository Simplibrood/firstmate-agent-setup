#!/usr/bin/env bash
# tests/fm-quiet-feed.test.sh - behavior tests for bin/fm-quiet-feed.sh, the
# ledger and page that hold events the watcher settles without waking firstmate.
#
# The guarantee under test is that "settled below firstmate" never means "lost or
# torn". Everything here drives the real script through its command line:
#   - a recorded event reaches both the ledger and the rendered page
#   - the page reads newest first, so the captain's glance lands on now
#   - retention holds at both bounds, by count and by age, so neither file grows
#     without limit and a note about a finished job ages out on its own
#   - caller text can never escape into page markup or break the record format
#   - --best-effort is silent and zero on every failure, because a watcher that
#     records an absorb must never be failed by its own bookkeeping
#   - without --best-effort the same failures are loud and non-zero, so a direct
#     run or a test still sees them
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FEED="$ROOT/bin/fm-quiet-feed.sh"
TMP_ROOT=$(fm_test_tmproot fm-quiet-feed-tests)
trap fm_test_cleanup EXIT

# A hermetic home: its own state and data roots, so nothing here can touch a real
# home's ledger or page.
make_home() {  # <name> -> home dir on stdout
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/data"
  printf '%s\n' "$dir"
}

feed() {  # <home> <args...>
  local home=$1
  shift
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$FEED" "$@"
}

# --- a recorded event reaches both surfaces -----------------------------------

HOME_DIR=$(make_home record)
LEDGER="$HOME_DIR/state/quiet-feed.tsv"
PAGE="$HOME_DIR/data/quiet/quiet.html"

feed "$HOME_DIR" record --kind wait --task eitr-backend \
  --detail 'paused, awaiting the captain merge' \
  || fail "recording a settled event must succeed"

[ -f "$LEDGER" ] || fail "record must create the ledger at $LEDGER"
[ -f "$PAGE" ] || fail "record must render the page at $PAGE"
assert_grep 'eitr-backend' "$LEDGER" "the ledger must carry the task the event belongs to"
assert_grep 'awaiting the captain merge' "$PAGE" "the page must carry the event's own words"
pass "a settled event reaches both the ledger and the rendered page"

# The ledger is the record format every later read depends on, so pin it.
LINE=$(head -1 "$LEDGER")
printf '%s' "$LINE" | awk -F'\t' 'NF == 4 && $1 ~ /^[0-9]+$/ { exit 0 } { exit 1 }' \
  || fail "a ledger row must be epoch<TAB>kind<TAB>task<TAB>detail: got [$LINE]"
pass "a ledger row keeps its four-field record format with a numeric epoch"

# --- the page reads newest first ----------------------------------------------

HOME_DIR=$(make_home order)
PAGE="$HOME_DIR/data/quiet/quiet.html"
for n in first second third; do
  feed "$HOME_DIR" record --kind t --task "task-$n" --detail "detail $n" \
    || fail "recording $n must succeed"
done
ORDER=$(grep -o 'task-[a-z]*' "$PAGE" | tr '\n' ' ')
case "$ORDER" in
  "task-third task-second task-first "*) ;;
  *) fail "the page must read newest first so a glance lands on now: got [$ORDER]" ;;
esac
pass "the page lists the newest settled event first"

# --- retention: by count -------------------------------------------------------

HOME_DIR=$(make_home count)
LEDGER="$HOME_DIR/state/quiet-feed.tsv"
for n in 1 2 3 4 5 6; do
  FM_QUIET_FEED_MAX_ENTRIES=3 feed "$HOME_DIR" record --kind t --task "task$n" --detail "d$n" \
    || fail "recording task$n must succeed"
done
KEPT=$(wc -l < "$LEDGER" | tr -d '[:space:]')
assert_equals 3 "$KEPT" "the ledger must settle at exactly the entry bound, not one above it"
assert_no_grep 'task3' "$LEDGER" "an entry past the count bound must be dropped"
assert_grep 'task6' "$LEDGER" "the newest entry must survive the count bound"
pass "retention holds the ledger at exactly its entry bound, dropping oldest first"

# --- retention: by age ---------------------------------------------------------

HOME_DIR=$(make_home age)
LEDGER="$HOME_DIR/state/quiet-feed.tsv"
feed "$HOME_DIR" record --kind t --task recent --detail 'still true' >/dev/null \
  || fail "seeding a recent entry must succeed"
# An entry older than the age bound, written directly so the test does not depend
# on wall-clock sleeping.
printf '1\tt\tancient\ta note about a job that finished long ago\n' >> "$LEDGER"
feed "$HOME_DIR" record --kind t --task fresh --detail 'now' >/dev/null \
  || fail "recording after an aged entry must succeed"
assert_no_grep 'ancient' "$LEDGER" "an entry past the age bound must be dropped even when the count bound is not reached"
assert_grep 'fresh' "$LEDGER" "the new entry must survive the age sweep"
pass "retention drops an entry past the age bound independently of the count bound"

# --- caller text cannot escape into markup or break the record -----------------

HOME_DIR=$(make_home escaping)
LEDGER="$HOME_DIR/state/quiet-feed.tsv"
PAGE="$HOME_DIR/data/quiet/quiet.html"
feed "$HOME_DIR" record --kind t --task '<script>alert(1)</script>' \
  --detail 'a & b "quoted" <b>bold</b>' \
  || fail "recording text with markup characters must succeed"
assert_no_grep '<script>alert' "$PAGE" "caller text must never reach the page as live markup"
assert_grep '&lt;script&gt;alert(1)&lt;/script&gt;' "$PAGE" "caller text must be escaped into the page, not dropped"
assert_grep 'a &amp; b &quot;quoted&quot; &lt;b&gt;bold&lt;/b&gt;' "$PAGE" "every markup character in the detail must be escaped"
pass "caller text is escaped into the page instead of becoming markup"

# A detail carrying tabs and newlines would otherwise split one event across
# several ledger rows and corrupt every later read.
HOME_DIR=$(make_home fieldsafety)
LEDGER="$HOME_DIR/state/quiet-feed.tsv"
feed "$HOME_DIR" record --kind t --task multi \
  --detail "$(printf 'line one\tcolumn two\nline three')" \
  || fail "recording multi-line text must succeed"
ROWS=$(wc -l < "$LEDGER" | tr -d '[:space:]')
assert_equals 1 "$ROWS" "text containing tabs and newlines must stay one ledger row"
assert_grep 'line one column two line three' "$LEDGER" "the collapsed text must keep its words"
pass "text carrying tabs or newlines cannot split one event across ledger rows"

# --- best-effort is silent and zero on failure ---------------------------------

UNWRITABLE=/proc/fm-quiet-feed-nonexistent/state
OUT="$TMP_ROOT/best-effort.out"
set +e
FM_STATE_OVERRIDE="$UNWRITABLE" FM_DATA_OVERRIDE="$TMP_ROOT/besteffort-data" \
  "$FEED" record --kind t --task x --detail y --best-effort > "$OUT" 2>&1
RC=$?
set -e
assert_equals 0 "$RC" "--best-effort must exit zero when the ledger cannot be written"
[ ! -s "$OUT" ] || fail "--best-effort must print nothing, or a watcher's absorb path becomes noisy: $(cat "$OUT")"
pass "--best-effort is silent and zero when its own bookkeeping fails"

# The same failure must stay loud for a direct run and for this suite.
set +e
FM_STATE_OVERRIDE="$UNWRITABLE" FM_DATA_OVERRIDE="$TMP_ROOT/loud-data" \
  "$FEED" record --kind t --task x --detail y > "$OUT" 2>&1
RC=$?
set -e
assert_not_equals 0 "$RC" "without --best-effort an unwritable ledger must fail loudly"
assert_contains "$(cat "$OUT")" 'fm-quiet-feed' "a loud failure must name the script that refused"
pass "without --best-effort the same failure is loud and non-zero"

# --- a missing required argument is refused, never guessed ---------------------

set +e
OUTPUT=$(feed "$(make_home args)" record --kind t --task x 2>&1)
RC=$?
set -e
assert_not_equals 0 "$RC" "a record missing its detail must be refused"
assert_contains "$OUTPUT" 'requires --detail' "the refusal must name the missing argument"
pass "a record missing a required field is refused rather than recorded half-formed"

echo "# fm-quiet-feed.test.sh: all assertions passed"
