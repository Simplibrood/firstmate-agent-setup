#!/usr/bin/env bash
# fm-context-window.sh - the one owner of "what compaction window is in force,
# and did a session actually respect it".
#
# Usage:
#   fm-context-window.sh effective [--cwd <dir>]        print the configured window and the scope that set it
#   fm-context-window.sh verify --max <n> [--cwd <dir>] assert a window is configured and is at most <n>
#   fm-context-window.sh overshoot [--state <dir>]      report every session whose peak context passed its window
#   fm-context-window.sh --help
#
# WHY THIS EXISTS, and what it honestly can and cannot promise.
#
# Measured on 2026-09-14 across 192 worker sessions: when a 400,000 window is in
# force, auto-compaction fires at 349k-369k - 87 to 92 percent of the limit, 8
# firings out of 8 below it, none above - even in sessions whose single turns grew
# by 174k and 223k tokens. The mechanism is not late and is not defeated by a large
# tool result. But 11 sessions never compacted at all, reaching 792,073, and across
# those there were 104 turn boundaries above 400,000 with zero firings. The window
# was simply not in force for them.
#
# THERE IS NO LEVER THAT TRUNCATES A RUNNING CONVERSATION FROM OUTSIDE.
# Compaction happens inside the agent process. Nothing in this repo - and nothing
# firstmate can run - can make a live session shed context. Any claim of a runtime
# ceiling would be a fake ceiling. So this script offers exactly two real things:
#
#   `verify`     a LAUNCH-TIME guarantee. It proves the configuration a new worker
#                will read is present and within the ceiling, and lets its caller
#                refuse to dispatch otherwise. It binds new workers only.
#   `overshoot`  an AFTER-THE-FACT detector. It reads what sessions actually did
#                and reports any that passed their own window, so the failure is
#                visible instead of discovered by accident.
#
# `verify` is necessary but NOT sufficient, and this is the most important caveat
# in this file. The 2026-09-14 measurement includes a session started after the
# setting was already in place which still reached 573,797 with zero compactions,
# with no recorded difference from the sessions that compacted correctly. So a
# passing `verify` proves the configuration is right; it does not prove the process
# honours it. `overshoot` is what catches that case, and it is the reason both
# exist rather than just the first.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# Where the harness keeps its per-working-directory session transcripts. A
# transcript directory name is the absolute working directory with every "/" and
# "." replaced by "-", which is why this is derived rather than guessed.
PROJECTS_ROOT="${FM_CLAUDE_PROJECTS_ROOT:-$HOME/.claude/projects}"
USER_SETTINGS="${FM_CLAUDE_USER_SETTINGS:-$HOME/.claude/settings.json}"

# The ceiling firstmate's own session is expected to hold. Reported by `overshoot`
# alongside the workers', because the 2026-09-14 measurement found firstmate
# compacting at 961k-967k against a configured 700,000 - the same class of failure
# at a wider margin, and the captain asked for it to be covered.
FM_SELF_WINDOW=${FM_SELF_COMPACTION_WINDOW:-700000}
# How far past its window a session must go before it is worth waking anyone. A
# session that compacts correctly still peaks a little under its window, so a small
# band avoids reporting a correct session as a failure.
OVERSHOOT_GRACE=${FM_CONTEXT_OVERSHOOT_GRACE:-10000}

die() { echo "fm-context-window: $*" >&2; exit 1; }

# Read one numeric key out of a settings file without a JSON dependency this repo
# does not already have. Prints nothing and returns 1 when the file is missing,
# unreadable, not an object, or does not define the key.
settings_window() {  # <file>
  local f=$1
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  python3 - "$f" <<'PY' 2>/dev/null || return 1
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if not isinstance(d,dict): sys.exit(1)
v=d.get("autoCompactWindow")
if isinstance(v,bool) or not isinstance(v,(int,float)): sys.exit(1)
if int(v) <= 0: sys.exit(1)
print(int(v))
PY
}

# The configured window a session started in <cwd> would read, and which scope
# supplied it. Scopes are consulted from most specific to least, so a project or
# local file that narrows the window is honoured over the user file.
#
# This reports CONFIGURATION ONLY. It cannot observe a running process, so it
# never claims the value is in force - see the header.
cmd_effective() {  # [--cwd <dir>]
  local cwd=$PWD scope value
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --cwd) cwd=${2-}; shift 2 ;;
      *) die "unknown effective option: $1" ;;
    esac
  done
  [ -n "$cwd" ] || die "--cwd requires a directory"
  for scope in "$cwd/.claude/settings.local.json" "$cwd/.claude/settings.json" "$USER_SETTINGS"; do
    if value=$(settings_window "$scope"); then
      printf 'window=%s scope=%s\n' "$value" "$scope"
      return 0
    fi
  done
  printf 'window=none scope=none\n'
  return 1
}

# Fail closed. A caller that cannot prove a window is configured and within its
# ceiling must not dispatch, because an unbounded worker is exactly what the
# 2026-09-14 measurement found running to 792,073.
cmd_verify() {  # --max <n> [--cwd <dir>]
  local cwd=$PWD max='' out value
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --max) max=${2-}; shift 2 ;;
      --cwd) cwd=${2-}; shift 2 ;;
      *) die "unknown verify option: $1" ;;
    esac
  done
  case "$max" in ''|*[!0-9]*) die "verify requires --max <whole number of tokens>" ;; esac
  if ! out=$(cmd_effective --cwd "$cwd"); then
    echo "fm-context-window: no compaction window is configured for $cwd" >&2
    echo "fm-context-window: set autoCompactWindow in $USER_SETTINGS (or the project's .claude/settings.json) to at most $max" >&2
    return 1
  fi
  value=${out#window=}; value=${value%% *}
  if [ "$value" -gt "$max" ]; then
    echo "fm-context-window: the configured compaction window is $value, above the $max ceiling this launch requires" >&2
    echo "fm-context-window: ${out#* }" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# The transcript directory the harness uses for a working directory.
transcript_dir() {  # <cwd>
  local cwd=$1 mangled
  mangled=${cwd//\//-}
  mangled=${mangled//./-}
  printf '%s/%s' "$PROJECTS_ROOT" "$mangled"
}

# Peak context any single model call in <dir>'s transcripts reached, and how many
# times that session compacted. Context is input plus cache-read plus
# cache-creation, which is the whole conversation handed over on that call.
peak_and_compactions() {  # <transcript-dir>
  local dir=$1
  [ -d "$dir" ] || return 1
  python3 - "$dir" <<'PY' 2>/dev/null || return 1
import json,glob,os,sys
MARK='being continued from a previous conversation'
def text_of(m):
    c=m.get("content")
    if isinstance(c,str): return c
    if isinstance(c,list):
        return "\n".join(p.get("text") or "" for p in c if isinstance(p,dict) and p.get("type")=="text")
    return ""
def is_tool_result(m):
    c=m.get("content")
    return isinstance(c,list) and any(isinstance(p,dict) and p.get("type")=="tool_result" for p in c)
best=(0,0,"")
for f in glob.glob(os.path.join(sys.argv[1],"*.jsonl")):
    peak=0;fires=0
    try:
        for line in open(f):
            line=line.strip()
            if not line.startswith("{"): continue
            r=json.loads(line)
            t=r.get("type")
            if t=="assistant":
                u=(r.get("message") or {}).get("usage") or {}
                c=((u.get("input_tokens") or 0)+(u.get("cache_read_input_tokens") or 0)
                   +(u.get("cache_creation_input_tokens") or 0))
                if c>peak: peak=c
            elif t=="user":
                m=r.get("message") or {}
                if not is_tool_result(m) and MARK in text_of(m)[:400]: fires+=1
    except Exception:
        continue
    if peak>best[0]: best=(peak,fires,os.path.basename(f))
if not best[0]: sys.exit(1)
print(f"{best[0]} {best[1]} {best[2]}")
PY
}

# Report every session that passed its own window. Prints one line per offender
# and nothing at all when every session held, so it composes with the watcher's
# state-check contract. Never repairs anything: a session cannot be truncated from
# outside, so the only honest action is to report it for a stand-down and relaunch.
cmd_overshoot() {  # [--state <dir>]
  local state=$STATE meta task worktree window out peak fires cwd found=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) state=${2-}; shift 2 ;;
      *) die "unknown overshoot option: $1" ;;
    esac
  done
  [ -d "$state" ] || return 1
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    task=$(basename "$meta" .meta)
    worktree=$(sed -n 's/^worktree=//p' "$meta" 2>/dev/null | head -1)
    [ -n "$worktree" ] || continue
    if out=$(cmd_effective --cwd "$worktree" 2>/dev/null); then
      window=${out#window=}; window=${window%% *}
    else
      continue
    fi
    out=$(peak_and_compactions "$(transcript_dir "$worktree")") || continue
    peak=${out%% *}; fires=${out#* }; fires=${fires%% *}
    if [ "$peak" -gt "$(( window + OVERSHOOT_GRACE ))" ]; then
      printf 'context overshoot: %s reached %s against its %s window (%s compactions) - stand it down and relaunch; a running session cannot be truncated from outside\n' \
        "$task" "$peak" "$window" "$fires"
      found=0
    fi
  done
  # Firstmate's own session is covered too: the same measurement found it
  # compacting near 1,000,000 against a configured 700,000.
  cwd=${FM_SELF_CWD:-$FM_HOME}
  if out=$(peak_and_compactions "$(transcript_dir "$cwd")"); then
    peak=${out%% *}; fires=${out#* }; fires=${fires%% *}
    if [ "$peak" -gt "$(( FM_SELF_WINDOW + OVERSHOOT_GRACE ))" ]; then
      printf 'context overshoot: firstmate itself reached %s against its %s window (%s compactions) - its configured window is not the one in force\n' \
        "$peak" "$FM_SELF_WINDOW" "$fires"
      found=0
    fi
  fi
  return "$found"
}

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  effective) shift; cmd_effective "$@" ;;
  verify)    shift; cmd_verify "$@" ;;
  overshoot) shift; cmd_overshoot "$@" ;;
  -h|--help|help|'') usage ;;
  *) echo "fm-context-window: unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
