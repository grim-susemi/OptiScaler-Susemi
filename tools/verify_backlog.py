#!/usr/bin/env python3
"""verify_backlog.py - row 8 of .omo/plans/susemi-next-ui-lang.md.

Checks the friction backlog handed off by row 8:

  * docs/ko-friction-backlog.md holds at least --min-items items, one per `### ` heading;
  * every item carries a category, a priority, a fix-on-discovery disposition and an explicit
    out-of-scope-for-this-release marker;
  * with --require-anchors, every item carries at least one `path:line` (or `path:start-end`)
    anchor, and every anchor resolves to a real file and line under --root;
  * an item that claims an already-fixed state without an evidence receipt fails.

Read-only: this tool edits nothing. Exit codes: 0 pass, 1 check failure, 2 usage/parse failure.

Usage:
  python tools/verify_backlog.py --backlog docs/ko-friction-backlog.md --min-items 5 \
      --require-anchors --evidence .omo/evidence/susemi-next-ui-lang/08/backlog-check.json
  python tools/verify_backlog.py --fixtures <dir> --expect-fail --evidence <file>
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
from pathlib import Path

TOOL = "tools/verify_backlog.py"
SCHEMA = 1
PLAN_ROW = 8
CONTRACT = (
    "row 8: docs/ko-friction-backlog.md carries at least --min-items items, each with a category, "
    "a priority, a fix-on-discovery disposition and an out-of-scope-for-this-release marker; with "
    "--require-anchors every item resolves at least one path:line anchor under --root; an "
    "already-fixed claim without an evidence receipt fails"
)

CATEGORIES = ("layout", "font", "wording", "residue", "behavior")
PRIORITIES = ("P1", "P2", "P3")
DISPOSITION_TOKEN = "fix-on-discovery"
SCOPE_TOKEN = "out-of-scope-for-this-release"

ITEM_RE = re.compile(r"^###\s+(?P<title>\S.*?)\s*$")
BLOCK_END_RE = re.compile(r"^#{1,3}\s")
FIELD_RE = re.compile(
    r"^-\s*(?P<name>Anchor|Category|Priority|Disposition|Scope|Evidence)\s*:\s*(?P<value>.+?)\s*$",
    re.IGNORECASE,
)
ANCHOR_RE = re.compile(r"(?P<path>[A-Za-z0-9_][A-Za-z0-9_./\\-]*\.[A-Za-z0-9]+):(?P<start>\d+)(?:\s*-\s*(?P<end>\d+))?")
FIXED_CLAIM_RE = re.compile(
    r"\b(?:already[\s-]fixed|fixed\s+in\s+this\s+release|fixed\s+here|resolved\s+in\s+this\s+release|"
    r"no\s+longer\s+repro(?:duces)?|no\s+longer\s+present)\b",
    re.IGNORECASE,
)
EXPECT_FAILURE_RE = re.compile(r"<!--\s*expect-failure:\s*(?P<kind>[a-z0-9-]+)\s*-->")

HARD_CHECKS = (
    "item count is at least --min-items",
    "every item carries a known category",
    "every item carries a P1/P2/P3 priority",
    "every item carries the fix-on-discovery disposition",
    "every item carries the out-of-scope-for-this-release marker",
    "with --require-anchors every anchor resolves to a real file and line under --root",
    "no item claims an already-fixed state without an evidence receipt",
)


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_items(text: str) -> list[dict]:
    """Split the document into item blocks keyed on `### ` headings."""
    items: list[dict] = []
    current: dict | None = None
    for number, raw in enumerate(text.splitlines(), start=1):
        match = ITEM_RE.match(raw)
        if match:
            current = {"title": match.group("title"), "line": number, "fields": {}, "body": []}
            items.append(current)
            continue
        if current is None:
            continue
        if BLOCK_END_RE.match(raw):
            current = None
            continue
        current["body"].append(raw)
        field = FIELD_RE.match(raw)
        if field:
            name = field.group("name").lower()
            current["fields"].setdefault(name, []).append(field.group("value"))
    return items


def split_anchor_values(values: list[str]) -> list[str]:
    """Anchor lines may carry several anchors separated by ';'."""
    anchors: list[str] = []
    for value in values:
        for chunk in re.split(r"[;]", value):
            chunk = chunk.strip().strip("`").strip()
            if chunk:
                anchors.append(chunk)
    return anchors


def resolve_anchor(anchor: str, root: Path) -> dict:
    """Resolve one anchor against root. Returns a record with a failure code when it misses."""
    match = ANCHOR_RE.search(anchor)
    record = {"anchor": anchor, "path": None, "start": None, "end": None, "resolved": False,
              "total_lines": None, "code": None}
    if not match:
        record["code"] = "missing-anchor"
        return record
    raw_path = match.group("path")
    record["path"] = raw_path
    record["start"] = int(match.group("start"))
    record["end"] = int(match.group("end")) if match.group("end") else int(match.group("start"))
    candidate = root / raw_path.replace("\\", "/")
    if not candidate.is_file():
        record["code"] = "anchor-unresolved"
        return record
    try:
        total = len(candidate.read_text(encoding="utf-8", errors="replace").splitlines())
    except OSError:
        record["code"] = "anchor-unresolved"
        return record
    record["total_lines"] = total
    if record["start"] < 1 or record["end"] < record["start"] or record["end"] > total:
        record["code"] = "anchor-line-out-of-range"
        return record
    record["resolved"] = True
    return record


def check_backlog(path: Path, root: Path, min_items: int, require_anchors: bool) -> dict:
    text = path.read_text(encoding="utf-8", errors="replace")
    items = parse_items(text)
    failures: list[dict] = []
    warnings: list[dict] = []
    records: list[dict] = []

    if len(items) < min_items:
        failures.append({"code": "item-below-minimum", "item": None,
                         "detail": f"{len(items)} item(s) found, {min_items} required"})

    for item in items:
        title = item["title"]
        fields = item["fields"]
        record = {"title": title, "line": item["line"], "category": None, "priority": None,
                  "disposition": None, "scope": None, "evidence": None, "anchors": []}

        category = (fields.get("category") or [""])[0].strip().strip("`").lower()
        record["category"] = category or None
        if not category:
            failures.append({"code": "missing-category", "item": title, "detail": "no Category field"})
        elif category not in CATEGORIES:
            failures.append({"code": "unknown-category", "item": title,
                             "detail": f"'{category}' is not one of {', '.join(CATEGORIES)}"})

        priority = (fields.get("priority") or [""])[0].strip().strip("`").upper()
        record["priority"] = priority or None
        if not priority:
            failures.append({"code": "missing-priority", "item": title, "detail": "no Priority field"})
        elif priority not in PRIORITIES:
            failures.append({"code": "bad-priority", "item": title,
                             "detail": f"'{priority}' is not one of {', '.join(PRIORITIES)}"})

        disposition = (fields.get("disposition") or [""])[0].lower()
        record["disposition"] = disposition or None
        if not disposition:
            failures.append({"code": "missing-disposition", "item": title, "detail": "no Disposition field"})
        elif DISPOSITION_TOKEN not in disposition:
            failures.append({"code": "bad-disposition", "item": title,
                             "detail": f"Disposition must contain '{DISPOSITION_TOKEN}'"})

        scope = (fields.get("scope") or [""])[0].lower()
        record["scope"] = scope or None
        if not scope:
            failures.append({"code": "missing-scope-marker", "item": title, "detail": "no Scope field"})
        elif SCOPE_TOKEN not in scope:
            failures.append({"code": "missing-scope-marker", "item": title,
                             "detail": f"Scope must contain '{SCOPE_TOKEN}'"})

        anchors = split_anchor_values(fields.get("anchor") or [])
        record["anchors"] = anchors
        if require_anchors and not anchors:
            failures.append({"code": "missing-anchor", "item": title,
                             "detail": "no Anchor field; --require-anchors is on"})
        for anchor in anchors:
            resolved = resolve_anchor(anchor, root)
            record.setdefault("anchor_records", []).append(resolved)
            if not resolved["resolved"]:
                failures.append({"code": resolved["code"], "item": title,
                                 "detail": f"anchor '{anchor}' did not resolve under {root}"})

        evidence = (fields.get("evidence") or [""])[0].strip()
        record["evidence"] = evidence or None
        body = "\n".join(item["body"])
        if FIXED_CLAIM_RE.search(body) and not evidence:
            failures.append({"code": "unevidenced-fixed-claim", "item": title,
                             "detail": "claims an already-fixed state with no Evidence receipt"})

        records.append(record)

    if not items:
        warnings.append({"code": "no-items", "detail": f"no '### ' item heading found in {path}"})

    categories = {}
    priorities = {}
    for record in records:
        categories[record["category"] or "missing"] = categories.get(record["category"] or "missing", 0) + 1
        priorities[record["priority"] or "missing"] = priorities.get(record["priority"] or "missing", 0) + 1
    anchors_total = sum(len(r["anchors"]) for r in records)
    anchors_resolved = sum(
        1 for r in records for a in r.get("anchor_records", []) if a["resolved"]
    )

    return {
        "backlog": str(path),
        "item_count": len(records),
        "min_items": min_items,
        "require_anchors": require_anchors,
        "items": records,
        "coverage": {
            "item_count": len(records),
            "categories": categories,
            "priorities": priorities,
            "anchors_total": anchors_total,
            "anchors_resolved": anchors_resolved,
        },
        "failures": failures,
        "warnings": warnings,
        "result": "PASS" if not failures else "FAIL",
    }


def run_suite(args, payload_out: Path | None) -> int:
    root = Path(args.root).resolve()
    backlog = Path(args.backlog)
    if not backlog.is_file():
        print(f"FAIL backlog not found: {backlog}", file=sys.stderr)
        return 2

    report = check_backlog(backlog, root, args.min_items, args.require_anchors)
    payload = {
        "tool": TOOL,
        "schema": SCHEMA,
        "plan_row": PLAN_ROW,
        "contract": CONTRACT,
        "generated_utc": utc_now(),
        "root": str(root),
        "mode": "backlog",
        "inputs": {"backlog": str(backlog), "min_items": args.min_items,
                   "require_anchors": args.require_anchors},
        "coverage": report["coverage"],
        "items": report["items"],
        "findings": {
            "item_count": report["item_count"],
            "failures": len(report["failures"]),
            "warnings": len(report["warnings"]),
            "anchors_resolved": report["coverage"]["anchors_resolved"],
            "anchors_total": report["coverage"]["anchors_total"],
        },
        "failures": report["failures"],
        "warnings": report["warnings"],
        "result": report["result"],
        "exit_code_meaning": "0 = all hard checks passed, 1 = at least one hard check failed, 2 = usage or parse error",
        "hard_checks_run": list(HARD_CHECKS),
    }
    emit(payload, payload_out)

    print(f"{report['result']}: {report['item_count']} item(s), "
          f"{report['coverage']['anchors_resolved']}/{report['coverage']['anchors_total']} anchor(s) resolved, "
          f"{len(report['failures'])} failure(s)")
    for failure in report["failures"]:
        print(f"  FAIL [{failure['code']}] {failure.get('item') or '-'}: {failure['detail']}")
    for warning in report["warnings"]:
        print(f"  WARN [{warning['code']}] {warning['detail']}")
    return 0 if report["result"] == "PASS" else 1


def run_expect_fail(args, payload_out: Path | None) -> int:
    root = Path(args.root).resolve()
    fixtures = Path(args.fixtures)
    if not fixtures.is_dir():
        print(f"FAIL fixtures directory not found: {fixtures}", file=sys.stderr)
        return 2

    files = sorted(p for p in fixtures.rglob("*.md") if p.is_file())
    if not files:
        print(f"FAIL no .md fixture under {fixtures}", file=sys.stderr)
        return 2

    cases = []
    bad = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        marker = EXPECT_FAILURE_RE.search(text)
        expected = marker.group("kind") if marker else None
        report = check_backlog(path, root, args.min_items, True)
        codes = sorted({failure["code"] for failure in report["failures"]})
        case = {
            "fixture": str(path),
            "expected_failure": expected,
            "result": report["result"],
            "failure_codes": codes,
            "failures": report["failures"],
        }
        ok = report["result"] == "FAIL"
        if ok and expected and expected not in codes:
            ok = False
            case["detail"] = f"expected failure '{expected}' not among {codes}"
        if not ok and report["result"] == "PASS":
            case["detail"] = "fixture passed but --expect-fail expects a failure"
        case["ok"] = ok
        if not ok:
            bad.append(case)
        cases.append(case)

    payload = {
        "tool": TOOL,
        "schema": SCHEMA,
        "plan_row": PLAN_ROW,
        "contract": CONTRACT,
        "generated_utc": utc_now(),
        "root": str(root),
        "mode": "expect-fail",
        "inputs": {"fixtures": str(fixtures), "min_items": args.min_items},
        "coverage": {"fixtures": len(cases), "rejected_as_expected": len(cases) - len(bad)},
        "cases": cases,
        "findings": {"fixtures": len(cases), "unexpected": len(bad)},
        "failures": bad,
        "warnings": [],
        "result": "PASS" if not bad else "FAIL",
        "exit_code_meaning": "0 = every fixture failed as expected, 1 = a fixture passed or failed for the wrong reason, 2 = usage error",
        "hard_checks_run": [
            "every fixture exits nonzero",
            "every fixture names its declared expect-failure code",
        ],
    }
    emit(payload, payload_out)

    print(f"{payload['result']}: {len(cases) - len(bad)}/{len(cases)} fixture(s) rejected as expected")
    for case in cases:
        status = "ok" if case["ok"] else "UNEXPECTED"
        print(f"  {status} {Path(case['fixture']).name}: {case['result']} codes={case['failure_codes']}"
              + (f" ({case.get('detail')})" if case.get("detail") else ""))
    return 0 if not bad else 1


def emit(payload: dict, target: Path | None) -> None:
    text = json.dumps(payload, ensure_ascii=True, indent=1)
    if target is not None:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text + "\n", encoding="utf-8")
    print(text if target is None else f"evidence: {target}")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Verify the row 8 KO friction backlog.")
    parser.add_argument("--backlog", help="path to docs/ko-friction-backlog.md")
    parser.add_argument("--fixtures", help="directory of negative fixtures (with --expect-fail)")
    parser.add_argument("--expect-fail", action="store_true",
                        help="every fixture must fail the check (negative control)")
    parser.add_argument("--min-items", type=int, default=5, help="minimum number of items (default 5)")
    parser.add_argument("--require-anchors", action="store_true", help="every item needs a resolving path:line anchor")
    parser.add_argument("--evidence", help="write the JSON receipt to this path")
    parser.add_argument("--root", default=".", help="worktree root the anchors resolve against (default .)")
    args = parser.parse_args(argv)

    if args.expect_fail:
        if not args.fixtures:
            print("FAIL --expect-fail needs --fixtures", file=sys.stderr)
            return 2
        if args.backlog:
            print("FAIL --expect-fail takes --fixtures, not --backlog", file=sys.stderr)
            return 2
        return run_expect_fail(args, Path(args.evidence) if args.evidence else None)

    if not args.backlog:
        print("FAIL --backlog is required (or --fixtures with --expect-fail)", file=sys.stderr)
        return 2
    if args.min_items < 1:
        print("FAIL --min-items must be at least 1", file=sys.stderr)
        return 2
    return run_suite(args, Path(args.evidence) if args.evidence else None)


if __name__ == "__main__":
    sys.exit(main())
