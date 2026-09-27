#!/usr/bin/env python3
"""Doc checks for the RTX 20/30 (SM75/SM86) MFG unlock install notes.

Two independent checks, both required by the plan's todo 9 acceptance:

1. Relative-link check over the docs that carry the unlock section (plus the
   payload contract note). Every relative markdown/HTML link target must exist
   on disk under --root. External URLs, mailto links and pure anchors are out
   of scope. Anchors are stripped before resolving, so a section-level link is
   checked against the file it points at.

2. Fact assertions: the four load-bearing facts of the unlock section must be
   present in BOTH install docs (EN and KO): requirements (RTX 20/30 only,
   driver R580+, payload bundled with the build), the 1..5 = 2X..6X mapping,
   the 6X caveat (game must ship a Streamline FG plugin 2.11.1+), and the
   explicit hardware-verification gap (no RTX 20/30 on this project's host,
   externally reported).

Exit codes: 0 = both checks pass, 1 = at least one failure, 2 = bad usage.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DOCS = [
    "INSTALL-DLSSNR.md",
    "INSTALL-KO.md",
    "README.md",
    "docs/rtx2030-payload-contract.md",
]

# The docs that must carry the unlock section.
UNLOCK_DOCS = ["INSTALL-DLSSNR.md", "INSTALL-KO.md"]

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HTML_RE = re.compile(r"(?:href|src)=\"([^\"]+)\"")
EXTERNAL_PREFIXES = ("http://", "https://", "mailto:", "tel:", "data:")

# fact name -> [required patterns per doc]. Every pattern must be found.
FACT_ASSERTIONS: dict[str, dict[str, list[str]]] = {
    "requirements": {
        "INSTALL-DLSSNR.md": ["RTX 20", "RTX 30", "R580", "ships with this build"],
        "INSTALL-KO.md": ["RTX 20", "RTX 30", "R580", "동봉"],
    },
    "mapping-1-5-2x-6x": {
        "INSTALL-DLSSNR.md": ["AmpereMfgMaxFrames", "1 = 2X, 2 = 3X, 3 = 4X, 4 = 5X, 5 = 6X"],
        "INSTALL-KO.md": ["AmpereMfgMaxFrames", "1 = 2X, 2 = 3X, 3 = 4X, 4 = 5X, 5 = 6X"],
    },
    "6x-caveat": {
        "INSTALL-DLSSNR.md": ["6X", "Streamline frame-generation plugin 2.11.1"],
        "INSTALL-KO.md": ["6X", "Streamline FG 플러그인 2.11.1"],
    },
    "hardware-gap": {
        "INSTALL-DLSSNR.md": ["No RTX 20/30 hardware", "externally reported"],
        "INSTALL-KO.md": ["RTX 20/30 실기 GPU", "externally reported"],
    },
}

# Facts that only make sense next to the unlock docs, stated once here so the
# acceptance can point at a single place: attribution and the uninstall steps.
EXTRA_ASSERTIONS: dict[str, dict[str, list[str]]] = {
    "attribution": {
        "INSTALL-DLSSNR.md": [
            "sdli1995/dlssg_for_sm86",
            "v0.3.5",
            "9621db5",
            "THIRD_PARTY_NOTICES",
            "github.com/sdli1995/dlssg_for_sm86",
        ],
        "INSTALL-KO.md": [
            "sdli1995/dlssg_for_sm86",
            "v0.3.5",
            "9621db5",
            "THIRD_PARTY_NOTICES",
            "github.com/sdli1995/dlssg_for_sm86",
        ],
    },
    "uninstall": {
        "INSTALL-DLSSNR.md": ["Delete `OptiScaler\\dlssg_sm86\\`", "AmpereMfgUnlock=false"],
        "INSTALL-KO.md": ["`OptiScaler\\dlssg_sm86\\`", "AmpereMfgUnlock=false"],
    },
    "payload-path-in-package": {
        "INSTALL-DLSSNR.md": ["OptiScaler\\dlssg_sm86\\dlssg_sm86.dll"],
        "INSTALL-KO.md": ["OptiScaler\\dlssg_sm86\\dlssg_sm86.dll"],
    },
    "restart-required": {
        "INSTALL-DLSSNR.md": ["restart"],
        "INSTALL-KO.md": ["재시작"],
    },
    "no-sideload-required": {
        "INSTALL-DLSSNR.md": ["no manual sideload"],
        "INSTALL-KO.md": ["사이드로드할 필요"],
    },
}


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def link_targets(text: str) -> list[str]:
    targets = LINK_RE.findall(text)
    targets += HTML_RE.findall(text)
    return targets


def check_links(root: Path, docs: list[str]) -> tuple[bool, list[str], list[str]]:
    ok = True
    report: list[str] = []
    failures: list[str] = []
    for rel in docs:
        path = root / rel
        if not path.is_file():
            ok = False
            failures.append(f"{rel}: document missing")
            report.append(f"[FAIL] {rel}: document missing")
            continue
        checked = 0
        broken: list[str] = []
        for target in link_targets(read_text(path)):
            if target.startswith(EXTERNAL_PREFIXES) or target.startswith("#"):
                continue
            bare = target.split("#", 1)[0]
            if not bare:
                continue
            stripped = bare[2:] if bare.startswith("./") else bare
            checked += 1
            resolved = (path.parent / stripped).resolve()
            if not resolved.exists():
                broken.append(target)
        if broken:
            ok = False
            failures.append(f"{rel}: broken relative link(s): {', '.join(broken)}")
            report.append(f"[FAIL] {rel}: {checked} relative link(s) checked, broken: {', '.join(broken)}")
        else:
            report.append(f"[ OK ] {rel}: {checked} relative link(s) checked, all resolve")
    return ok, report, failures


def check_facts(root: Path, assertions: dict[str, dict[str, list[str]]]) -> tuple[bool, list[str], list[str]]:
    ok = True
    report: list[str] = []
    failures: list[str] = []
    for fact, per_doc in assertions.items():
        for rel, patterns in per_doc.items():
            path = root / rel
            if not path.is_file():
                ok = False
                failures.append(f"{fact}: {rel} missing")
                report.append(f"[FAIL] {fact} in {rel}: document missing")
                continue
            text = read_text(path)
            missing = [p for p in patterns if p not in text]
            if missing:
                ok = False
                failures.append(f"{fact}: {rel} missing {missing}")
                report.append(f"[FAIL] {fact} in {rel}: missing {missing}")
            else:
                report.append(f"[ OK ] {fact} in {rel}: {len(patterns)} pattern(s) found")
    return ok, report, failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=".", help="repository root (default: current directory)")
    parser.add_argument("--docs", nargs="*", default=DOCS, help="docs to run the relative-link check over")
    parser.add_argument("--facts-only", action="store_true", help="skip the relative-link check")
    parser.add_argument("--links-only", action="store_true", help="skip the fact assertions")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    if not (root / "INSTALL-DLSSNR.md").is_file():
        print(f"error: {root} does not look like the repository root", file=sys.stderr)
        return 2

    print(f"check_rtx2030_docs: root={root}")
    all_ok = True
    all_failures: list[str] = []

    if not args.facts_only:
        print("\n== relative link check ==")
        ok, report, failures = check_links(root, list(args.docs))
        print("\n".join(report))
        all_ok = all_ok and ok
        all_failures += failures

    if not args.links_only:
        print("\n== fact assertions (both install docs) ==")
        ok, report, failures = check_facts(root, FACT_ASSERTIONS)
        print("\n".join(report))
        print("\n== extra assertions (attribution, uninstall, restart, no sideload) ==")
        ok2, report2, failures2 = check_facts(root, EXTRA_ASSERTIONS)
        print("\n".join(report2))
        all_ok = all_ok and ok and ok2
        all_failures += failures + failures2

    print("\n== summary ==")
    if all_ok:
        print("OK: no broken relative links, every required fact present in both install docs")
        return 0
    print(f"FAIL: {len(all_failures)} check(s) failed")
    for failure in all_failures:
        print(f"  - {failure}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
