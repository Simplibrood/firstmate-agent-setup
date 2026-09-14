#!/usr/bin/env python3
"""Compare two public coding leaderboards against the Claude model this fleet runs.

This is the pure half of fm-benchmark-watch.sh: it never fetches, never writes,
and never executes anything. It names at most REPORT_LIMIT models per line and
records only those as reported, so a long standing field is delivered a few at a
time instead of as one wall of text that can never be repeated. It reads one JSON envelope naming already-fetched
files plus the previous snapshot, and prints one JSON object holding the report
line and the new snapshot. Keeping it pure is what lets the tests drive every
comparison and failure shape from fixtures with no network.

Everything read out of a leaderboard is untrusted text. Model names reach a
firstmate wake line, so they are filtered to a conservative character set and
length here rather than passed through.
"""

import argparse
import csv
import json
import re
import sys

SCHEMA = "fm-benchmark-watch-v1"

# A leaderboard row's model id is rendered into a wake line firstmate reads, so
# it is reduced to a set that cannot carry a newline, a quote, or prose.
NAME_OK = re.compile(r"[^A-Za-z0-9._+-]")
NAME_MAX = 48

# How many models one line names. The rest are NOT marked reported, so they are
# named by a later run instead of being summarised away once and lost.
REPORT_LIMIT = 3

# Consecutive failed collections before a site's silence is worth one line.
FAIL_REPORT_AT = 3

LIVEBENCH_CATEGORIES = ("Coding", "Agentic Coding")
DEEPSWE_METRIC = "pass@1"

SITE_LABEL = {"livebench": "LiveBench", "deepswe": "DeepSWE"}


class ShapeError(Exception):
    """A site answered, but not with the data this comparison needs."""


def clean_name(raw):
    name = NAME_OK.sub("", str(raw))[:NAME_MAX]
    return name or "?"


def is_ours(model):
    """True for an Anthropic model.

    The fleet's standing rule is Claude by default, so only a non-Claude model
    raises a question the captain has to answer. `provider` is null on most
    DeepSWE rows, so the model id is the only reliable signal and both sites
    spell the family the same way.
    """
    return str(model).lower().startswith("claude")


def is_baseline(model, baseline):
    """True for the exact baseline family, and not for a later point release.

    Both boards spell a point release by appending a numeric segment, so
    `claude-opus-5` is Opus 5 and `claude-opus-5-1` is Opus 5.1. Matching on a
    bare prefix would silently fold a newer model into the baseline and hide
    the comparison the captain asked for.
    """
    model = str(model).lower()
    baseline = baseline.lower()
    if not model.startswith(baseline):
        return False
    rest = model[len(baseline):]
    if not rest:
        return True
    if not rest.startswith("-"):
        return False
    return not rest[1:].split("-")[0].isdigit()


def parse_livebench(table_path, categories_path, baseline):
    """Return {category: {"ours": score, "others": {model: score}}} in percent.

    LiveBench publishes one column per task and a separate category map, so a
    category score is the mean of its task columns - the same arithmetic the
    site's own bundle does. A model missing any task column in a category is
    left out of that category rather than averaged over a short row.
    """
    with open(categories_path, encoding="utf-8") as handle:
        categories = json.load(handle)
    if not isinstance(categories, dict):
        raise ShapeError("category map is not an object")

    with open(table_path, encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise ShapeError("leaderboard table is empty")
    if "model" not in (rows[0] or {}):
        raise ShapeError("leaderboard table has no model column")

    result = {}
    for category in LIVEBENCH_CATEGORIES:
        tasks = categories.get(category)
        if not isinstance(tasks, list) or not tasks:
            raise ShapeError("category %s is missing" % category)
        ours = None
        others = {}
        for row in rows:
            model = row.get("model")
            if not model:
                continue
            try:
                values = [float(row[task]) for task in tasks]
            except (KeyError, TypeError, ValueError):
                continue
            score = sum(values) / len(values)
            if is_baseline(model, baseline):
                ours = score if ours is None else max(ours, score)
            elif not is_ours(model):
                name = clean_name(model)
                others[name] = max(score, others.get(name, score))
        if ours is None:
            raise ShapeError("%s is not listed under %s" % (baseline, category))
        result[category] = {"ours": ours, "others": others}
    return result


def parse_deepswe(path, baseline):
    """Return {metric: {...}} in percent, carrying DeepSWE's own intervals.

    DeepSWE ships a confidence interval per configuration, so a challenger is
    only ahead here when its interval clears ours outright. That is the site's
    own statistic rather than a threshold invented for it, and it is what keeps
    run-to-run noise from reading as a new leader every morning.
    """
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
    rows = payload.get("rows") if isinstance(payload, dict) else None
    if not isinstance(rows, list) or not rows:
        raise ShapeError("leaderboard has no rows")

    def pct(value):
        return None if value is None else float(value) * 100.0

    ours = None
    others = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        model = row.get("model")
        if not model:
            continue
        try:
            score = pct(row.get("pass_at_1"))
            lo = pct(row.get("ci_lo"))
            hi = pct(row.get("ci_hi"))
        except (TypeError, ValueError):
            continue
        if score is None:
            continue
        entry = {"score": score, "ci_lo": lo, "ci_hi": hi}
        if is_baseline(model, baseline):
            if ours is None or score > ours["score"]:
                ours = entry
        elif not is_ours(model):
            name = clean_name(model)
            if name not in others or score > others[name]["score"]:
                others[name] = entry
    if ours is None:
        raise ShapeError("%s is not listed" % baseline)
    return {DEEPSWE_METRIC: {"ours": ours, "others": others}}


def ahead_livebench(board, margin_pp):
    """Models clear of our score by the margin, best first."""
    ours = board["ours"]
    ahead = [
        (name, score)
        for name, score in board["others"].items()
        if score > ours + margin_pp
    ]
    ahead.sort(key=lambda item: (-item[1], item[0]))
    return ours, ahead


def ahead_deepswe(board, margin_pp):
    """Models whose interval clears ours outright, best first.

    An interval is only missing if the site stops publishing one; the margin is
    the documented fallback for that case rather than a silent comparison of
    two point estimates.
    """
    ours = board["ours"]
    ahead = []
    for name, entry in board["others"].items():
        if entry["ci_lo"] is not None and ours["ci_hi"] is not None:
            clear = entry["ci_lo"] > ours["ci_hi"]
        else:
            clear = entry["score"] > ours["score"] + margin_pp
        if clear:
            ahead.append((name, entry["score"]))
    ahead.sort(key=lambda item: (-item[1], item[0]))
    return ours["score"], ahead


def board_key(site, category):
    return "%s/%s" % (site, category)


def previous_reported(previous, key):
    """The models already named in a wake line for one board.

    This is deliberately NOT the set of models that were ahead. A run names at
    most REPORT_LIMIT models, and only those are recorded here, so a model that
    was ahead but did not fit is still news on the next run rather than being
    swallowed by a summary it never appeared in.
    """
    if not isinstance(previous, dict):
        return []
    boards = previous.get("boards")
    if not isinstance(boards, dict):
        return []
    entry = boards.get(key)
    if not isinstance(entry, dict):
        return []
    reported = entry.get("reported")
    return reported if isinstance(reported, list) else []


def previous_streak(previous, site):
    if not isinstance(previous, dict):
        return 0
    sites = previous.get("sites")
    if not isinstance(sites, dict):
        return 0
    entry = sites.get(site)
    if not isinstance(entry, dict):
        return 0
    streak = entry.get("fail_streak")
    return streak if isinstance(streak, int) and streak > 0 else 0


def carry_boards(previous, site, snapshot):
    """Keep a failed site's last known boards.

    A site that could not be read must not look like a site where everyone
    vanished, or its next good day would report the whole field as new.
    """
    if not isinstance(previous, dict):
        return
    boards = previous.get("boards")
    if not isinstance(boards, dict):
        return
    for key, entry in boards.items():
        if key.startswith(site + "/") and isinstance(entry, dict):
            snapshot["boards"][key] = entry


def build(envelope):
    baseline = envelope.get("baseline_model", "claude-opus-5")
    margin_pp = float(envelope.get("margin_pp", 1.0))
    previous = envelope.get("previous")
    sites = envelope.get("sites") or {}

    snapshot = {
        "schema": SCHEMA,
        "checked_at": envelope.get("now", ""),
        "baseline_model": baseline,
        "margin_pp": margin_pp,
        "sites": {},
        "boards": {},
    }
    findings = []
    failures = []

    for site in ("livebench", "deepswe"):
        spec = sites.get(site) or {}
        label = SITE_LABEL[site]
        error = None
        boards = None
        if not spec.get("ok"):
            error = str(spec.get("error") or "not collected")
        else:
            try:
                if site == "livebench":
                    boards = parse_livebench(
                        spec["table_csv"], spec["categories_json"], baseline
                    )
                else:
                    boards = parse_deepswe(spec["json"], baseline)
            except ShapeError as exc:
                error = str(exc)
            except (OSError, ValueError, KeyError) as exc:
                error = "unreadable (%s)" % type(exc).__name__

        if error is not None:
            streak = previous_streak(previous, site) + 1
            snapshot["sites"][site] = {"ok": False, "fail_streak": streak, "error": error[:120]}
            carry_boards(previous, site, snapshot)
            # Reported the once, on the day the silence becomes a pattern. A
            # site that stays down is already a durable record by then, and
            # repeating it every morning is the noise this check exists to avoid.
            if streak == FAIL_REPORT_AT:
                failures.append("%s unreadable %d days running (%s)" % (label, streak, error[:80]))
            continue

        snapshot["sites"][site] = {"ok": True, "fail_streak": 0}
        if spec.get("release"):
            snapshot["sites"][site]["release"] = str(spec["release"])[:32]

        for category, board in boards.items():
            if site == "livebench":
                ours, ahead = ahead_livebench(board, margin_pp)
            else:
                ours, ahead = ahead_deepswe(board, margin_pp)
            key = board_key(site, category)
            names = [name for name, _ in ahead]
            already = previous_reported(previous, key)
            # A model that fell back behind us is forgotten rather than kept as
            # reported, so its return is news again the way a first arrival is.
            snapshot["boards"][key] = {
                "ours": round(ours, 3),
                "leaders": names,
                "reported": [name for name in already if name in names],
            }
            for name, score in ahead:
                if name in already:
                    continue
                findings.append(
                    {
                        "board": key,
                        "site": label,
                        "category": category,
                        "model": name,
                        "score": score,
                        "ours": ours,
                        "gap": score - ours,
                    }
                )

    # Only what this line actually names becomes reported. Everything still
    # waiting keeps its place in the queue for the next run.
    findings.sort(key=lambda f: -f["gap"])
    named = findings[:REPORT_LIMIT]
    for finding in named:
        snapshot["boards"][finding["board"]]["reported"].append(finding["model"])

    return snapshot, compose(named, len(findings) - len(named), failures)


def compose(named, waiting, failures):
    """One bounded line: the largest margins first, then anything still queued."""
    parts = []
    if named:
        detail = "; ".join(
            "%s %s %s %.1f vs %.1f (+%.1f)"
            % (f["site"], f["category"], f["model"], f["score"], f["ours"], f["gap"])
            for f in named
        )
        noun = "model" if len(named) == 1 else "models"
        if waiting > 0:
            head = "%d of %d %s newly ahead of Claude Opus 5" % (
                len(named),
                len(named) + waiting,
                "models",
            )
            detail += "; %d more next run" % waiting
        else:
            head = "%d %s newly ahead of Claude Opus 5" % (len(named), noun)
        parts.append("%s - %s" % (head, detail))
    parts.extend(failures)
    return "benchmark: " + " | ".join(parts) if parts else ""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--envelope", required=True, help="JSON envelope path, or - for stdin")
    args = parser.parse_args(argv)

    source = sys.stdin if args.envelope == "-" else open(args.envelope, encoding="utf-8")
    try:
        envelope = json.load(source)
    finally:
        if source is not sys.stdin:
            source.close()

    snapshot, report = build(envelope)
    json.dump({"report": report, "snapshot": snapshot}, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
