#!/usr/bin/env python3
"""Row 2 of .omo/plans/susemi-next-ui-lang.md: verify the KO catalog and its include.

Happy path checks the authored catalog against the row-1 candidate list and the
generated `ko_catalog.inc`. Failure path runs the same checks over the negative
fixtures under `tests/fixtures/ko` and requires each one to fail for its own
reason, naming the offending key.

Checks, happy path
------------------
  candidates     every row-1 candidate has a non-empty entry
  key-space      entries are the display msgid, no "##id" key is invented
  format-tokens  the %-token sequence of every entry matches the English source
  newlines       the number of newlines matches the English source
  urls           every URL in the English source survives byte-identical
  ini-names      a msgid that doubles as an INI key or section maps to itself
  glossary       every asserted Latin term survives in the Korean value
  include        the .inc is pure ASCII, decodes to the catalog, declares the
                 right count and regenerates byte-identical

Checks, failure path
--------------------
  every fixture must exit nonzero with the expected code and the expected key
  named. Exit code 0 means every fixture failed as designed.

Usage:
  python tools/verify_ko_catalog.py --catalog <ko.json> --inc <ko_catalog.inc> \
      --candidates <ko-source-candidates.json> --evidence <catalog-verify.json>
  python tools/verify_ko_catalog.py --fixtures tests/fixtures/ko --expect-fail \
      --evidence <catalog-negative.json>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

TOOL = "tools/verify_ko_catalog.py"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_ko_catalog  # noqa: E402  (sibling tool, same generated key space)

# The space flag is deliberately not modelled: "50% halves" would otherwise parse
# as a "% ha" conversion. Both the source and the value go through this same
# regex, so the comparison stays symmetric.
FMT_SPEC = re.compile(
    r"%[-+#0]*[0-9*]*(?:\.[0-9*]+)?(?:hh|h|ll|l|j|z|t|L)?[diouxXeEfgGaAcspn%]"
)
URL_RE = re.compile(r"https?://[^\s\"'<>]+")
DEFAULT_KEEP_LATIN = [
    "DLSS", "RR", "SR", "NR", "FSR", "XeSS", "NGX", "HDR", "FPS", "GPU", "VRAM",
]

# Dynamic status templates (R8, R10) that must exist as their own keys rather than
# being flattened into a neighbouring sentence. Every one of them carries at least
# one format token, which the generic token check compares against the English
# source.
REQUIRED_TEMPLATES = [
    "%s is active, but not currently used by the game\nPlease enter the game",
    "(Active: %d)",
    "(Current sharpness: %.3f)",
    "Applied at %u site(s).",
    "Applied: %s, %u %s",
    "Current method: %s",
    "Not applied: %s.",
    "DLSSG %s: RTX 40 MFG unlock applied.",
    "FSR 3.1 FG: %s",
    "FSR 3.1 SR: %s",
    "FSR Hooks: %s",
    "Private upscale: %s",
    "Running natively on Vulkan - %llu frames%s",
    "Running%s - %.2f ms elapsed%s",
    "Streamline plugin ceiling: %s.",
    "Update available: %s (current %s)",
    "Game asked %uX, sent %uX, Streamline presented %u (max seen %u)",
    "slDLSSGSetOptions returned sl::Result %u for that request.",
    "NR %.2f ms | Rest of frame ~%.2f ms",
    "Rendered frame: %.2f ms%s",
    "creation failed:",
    "evaluation failed:",
    "running:",
    "; applied after SR",
    "| Input: %s",
    "| Spoof: %s",
]

# Default negative fixtures: the six failure modes the row names.
EXPECTED_FIXTURES = [
    "token-reordered",
    "token-dropped",
    "empty-value",
    "newline-mismatch",
    "url-mismatch",
    "inc-non-ascii",
    "missing-key",
    "duplicate-key",
    "glossary-term-dropped",
]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def tokens(value: str):
    return FMT_SPEC.findall(value)


def urls(value: str):
    return URL_RE.findall(value)


def keep_terms_in(source: str, terms):
    hits = []
    for term in terms:
        pattern = r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(term)
        if re.search(pattern, source):
            hits.append(term)
    return hits


# --------------------------------------------------------------------------
# Catalog checks.
def check_catalog(catalog_path, inc_path, candidates_path, extra_ini_names=None,
                  root=None, require_templates=True):
    extra_ini_names = extra_ini_names or []
    failures = []
    warnings = []
    checks = []

    def fail(code, key, detail):
        failures.append({"code": code, "key": key, "detail": detail})

    try:
        data, entries = gen_ko_catalog.load_catalog(catalog_path)
    except gen_ko_catalog.CatalogError as error:
        message = str(error)
        code = "duplicate-key" if "duplicate" in message else "catalog-load"
        checks.append({"name": "catalog-loads", "passed": False, "detail": message})
        failures.append({"code": code, "key": os.path.basename(catalog_path), "detail": message})
        return {"checks": checks, "failures": failures, "warnings": warnings,
                "entries": {}, "counts": {}, "hashes": {},
                "details": {"entries": {}, "untranslated": [], "extra_keys": []}}

    checks.append({"name": "catalog-loads", "passed": True,
                   "detail": "%d entries, language=%s" % (len(entries), data.get("language"))})

    keep_latin = data.get("keep_latin") or DEFAULT_KEEP_LATIN
    if data.get("language") != "ko":
        fail("catalog-language", "language", "catalog language is %r, expected 'ko'" % data.get("language"))

    # --- candidates -------------------------------------------------------
    with open(candidates_path, encoding="utf-8") as handle:
        candidates = json.load(handle)
    expected_keys, id_only = gen_ko_catalog.candidate_keys(candidates["candidates"])
    missing = sorted(key for key in expected_keys if key not in entries)
    for key in missing:
        fail("missing-key", key, "row-1 candidate has no catalog entry")
    checks.append({"name": "candidates-covered", "passed": not missing,
                   "detail": "%d expected keys, %d missing" % (len(expected_keys), len(missing))})

    id_display = [key for key in entries if key.startswith("##")]
    if id_display:
        for key in id_display:
            fail("key-invented", key, "a '##id' label has no display range and must not be a key")

    # --- per entry --------------------------------------------------------
    empty = sorted(key for key, value in entries.items() if not value.strip())
    for key in empty:
        fail("empty-value", key, "catalog value is blank")
    checks.append({"name": "no-blank-values", "passed": not empty,
                   "detail": "%d blank entries" % len(empty)})

    token_failures, newline_failures, url_failures, glossary_failures = [], [], [], []
    for key, value in sorted(entries.items()):
        source_tokens, value_tokens = tokens(key), tokens(value)
        if source_tokens != value_tokens:
            if sorted(source_tokens) == sorted(value_tokens):
                code = "token-reordered"
            elif set(value_tokens) < set(source_tokens) and len(value_tokens) < len(source_tokens):
                code = "token-dropped"
            elif set(source_tokens) < set(value_tokens) and len(value_tokens) > len(source_tokens):
                code = "token-added"
            else:
                code = "token-mismatch"
            detail = "%s -> %s" % (source_tokens, value_tokens)
            token_failures.append(key)
            fail(code, key, detail)
        if key.count("\n") != value.count("\n"):
            newline_failures.append(key)
            fail("newline-mismatch", key, "%d newlines in source, %d in value" % (key.count("\n"), value.count("\n")))
        if urls(key) != urls(value):
            url_failures.append(key)
            fail("url-mismatch", key, "%s -> %s" % (urls(key), urls(value)))
        dropped = [term for term in keep_terms_in(key, keep_latin) if not keep_terms_in(value, [term])]
        if dropped:
            glossary_failures.append(key)
            fail("glossary-term-dropped", key, "Latin term(s) lost: %s" % ", ".join(dropped))

    checks.append({"name": "format-tokens", "passed": not token_failures,
                   "detail": "%d entries with a drifted token sequence" % len(token_failures)})
    checks.append({"name": "newline-count", "passed": not newline_failures,
                   "detail": "%d entries with a drifted newline count" % len(newline_failures)})
    checks.append({"name": "urls-intact", "passed": not url_failures,
                   "detail": "%d entries with a rewritten URL" % len(url_failures)})
    checks.append({"name": "glossary-latin", "passed": not glossary_failures,
                   "detail": "%d entries dropped an asserted Latin term" % len(glossary_failures)})

    # --- INI names stay Latin --------------------------------------------
    sections, keys = gen_ko_catalog.ini_names(root or os.getcwd())
    sections.update(extra_ini_names)
    keys.update(extra_ini_names)
    ini_offenders = sorted(
        key for key, value in entries.items()
        if (key in keys or key in sections) and value != key
    )
    for key in ini_offenders:
        fail("ini-name-translated", key, "msgid doubles as an INI name and must map to itself")
    checks.append({"name": "ini-names-latin", "passed": not ini_offenders,
                   "detail": "%d INI-doubling entries were translated" % len(ini_offenders)})

    # --- required dynamic templates -------------------------------------
    absent_templates = [msgid for msgid in REQUIRED_TEMPLATES
                        if require_templates and msgid not in entries]
    for msgid in absent_templates:
        fail("template-missing", msgid, "R8/R10 dynamic status template has no catalog key")
    drift_templates = [msgid for msgid in REQUIRED_TEMPLATES
                       if msgid in entries and tokens(msgid) != tokens(entries[msgid])]
    checks.append({"name": "dynamic-templates",
                   "passed": not absent_templates and not drift_templates,
                   "detail": "%d required templates, %d absent, %d with drifted tokens" % (
                       len(REQUIRED_TEMPLATES), len(absent_templates), len(drift_templates))})

    # --- generated include ------------------------------------------------
    hashes = {"catalog_sha256": sha256(open(catalog_path, "rb").read())}
    inc_checks = []
    if inc_path:
        raw = open(inc_path, "rb").read()
        hashes["inc_sha256"] = sha256(raw)
        non_ascii = [index for index, byte in enumerate(raw) if byte > 0x7F]
        if non_ascii:
            fail("inc-non-ascii", os.path.basename(inc_path),
                 "first non-ASCII byte at offset %d" % non_ascii[0])
        inc_checks.append({"name": "inc-ascii", "passed": not non_ascii,
                           "detail": "%d non-ASCII bytes" % len(non_ascii)})

        pairs, declared = gen_ko_catalog.parse_inc(raw.decode("ascii", errors="replace"))
        if declared != len(entries) or len(pairs) != len(entries):
            fail("inc-count-mismatch", os.path.basename(inc_path),
                 "declared %s, parsed %d, catalog %d" % (declared, len(pairs), len(entries)))
        inc_checks.append({"name": "inc-count", "passed": declared == len(entries) == len(pairs),
                           "detail": "declared %s, parsed %d, catalog %d" % (declared, len(pairs), len(entries))})

        drifted = [(source, text) for source, text in pairs
                   if entries.get(source) != text or entries.get(source) is None]
        for source, text in drifted:
            fail("inc-content-mismatch", source, "include decodes to %r" % text)
        inc_checks.append({"name": "inc-content", "passed": not drifted,
                           "detail": "%d entries differ after decoding the include" % len(drifted)})

        regenerated = gen_ko_catalog.render_inc(entries).encode("ascii")
        identical = regenerated == raw
        if not identical:
            fail("inc-not-regenerated", os.path.basename(inc_path),
                 "on-disk include differs from a fresh generation")
        inc_checks.append({"name": "inc-regenerates", "passed": identical,
                           "detail": "byte-identical: %s" % identical})
    checks.extend(inc_checks)

    # --- warnings ---------------------------------------------------------
    untranslated = sorted(key for key, value in entries.items() if value == key)
    extra_keys = sorted(key for key in entries if key not in expected_keys)
    for key in extra_keys:
        warnings.append({"code": "unknown-source", "key": key,
                         "detail": "catalog key is not in the row-1 candidate list"})
    warnings.extend({"code": "untranslated", "key": key,
                     "detail": "value equals the English source"}
                    for key in untranslated)

    counts = {
        "entries": len(entries),
        "expected_keys": len(expected_keys),
        "id_only_candidates": len(id_only),
        "candidate_records": len(candidates["candidates"]),
        "translated": len(entries) - len(untranslated),
        "untranslated": len(untranslated),
        "unknown_source_keys": len(extra_keys),
        "warnings": len(warnings),
        "failures": len(failures),
    }
    details = {"entries": entries, "untranslated": untranslated, "extra_keys": extra_keys}
    return {"checks": checks, "failures": failures, "warnings": warnings,
            "counts": counts, "hashes": hashes, "details": details,
            "keep_latin": keep_latin, "id_only": id_only}


# --------------------------------------------------------------------------
# Evidence side files.
def write_reports(evidence_path, result):
    report_dir = os.path.dirname(os.path.abspath(evidence_path))
    os.makedirs(report_dir, exist_ok=True)
    counts = result["counts"]
    lines = [
        "KO catalog key count",
        "tool: %s" % TOOL,
        "catalog: %s" % result.get("catalog_path", ""),
        "catalog sha256: %s" % result["hashes"].get("catalog_sha256", ""),
        "include: %s" % result.get("inc_path", ""),
        "include sha256: %s" % result["hashes"].get("inc_sha256", ""),
        "candidate records (row 1): %d" % counts.get("candidate_records", 0),
        "expected display keys: %d" % counts.get("expected_keys", 0),
        "id-only candidates (no display range): %d" % counts.get("id_only_candidates", 0),
        "catalog entries: %d" % counts.get("entries", 0),
        "translated entries: %d" % counts.get("translated", 0),
        "untranslated entries: %d" % counts.get("untranslated", 0),
        "keys not in the candidate list: %d" % counts.get("unknown_source_keys", 0),
        "failures: %d" % counts.get("failures", 0),
    ]
    with open(os.path.join(report_dir, "ko-key-count.txt"), "w", encoding="ascii", newline="\n") as handle:
        handle.write("\n".join(lines) + "\n")

    untranslated = result["details"]["untranslated"]
    report = [
        "Untranslated KO catalog entries (value identical to the English source)",
        "",
        "These are entries whose Korean form is intentionally the same text: printf",
        "format strings with unit words (ms, fps, px), Latin product and API tokens,",
        "and INI-doubling names such as DLSS, XeSS and FSR. Any entry here that is",
        "not one of those classes is a translation gap and must be fixed in ko.json.",
        "",
        "count: %d of %d" % (len(untranslated), result["counts"].get("entries", 0)),
        "",
    ]
    report.extend(untranslated)
    with open(os.path.join(report_dir, "untranslated-report.txt"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(report) + "\n")

    # Receipt chain: the exact bytes of every artifact this receipt speaks for.
    tools_dir = os.path.dirname(os.path.abspath(__file__))
    tool_lines = ["artifact sha256 receipt"]
    for label, path in [("catalog", result.get("catalog_path")),
                        ("include", result.get("inc_path")),
                        ("candidates", result.get("candidates_path")),
                        ("gen_ko_catalog.py", os.path.join(tools_dir, "gen_ko_catalog.py")),
                        ("verify_ko_catalog.py", os.path.join(tools_dir, "verify_ko_catalog.py"))]:
        if path and os.path.isfile(path):
            tool_lines.append("%s  %s" % (sha256(open(path, "rb").read()), label))
    with open(os.path.join(report_dir, "tool-hashes.txt"), "w", encoding="ascii", newline="\n") as handle:
        handle.write("\n".join(tool_lines) + "\n")


def emit(evidence_path, result, mode, extra=None):
    payload = {
        "tool": TOOL,
        "mode": mode,
        "catalog": result.get("catalog_path"),
        "include": result.get("inc_path"),
        "candidates": result.get("candidates_path"),
        "hashes": result["hashes"],
        "counts": result["counts"],
        "checks": result["checks"],
        "failures": result["failures"],
        "warnings": result["warnings"][:200],
        "passed": not result["failures"],
        "exit_code": 0 if not result["failures"] else 1,
    }
    if extra:
        payload.update(extra)
    with open(evidence_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=True, indent=1)
        handle.write("\n")
    return payload


# --------------------------------------------------------------------------
# Fixtures.
def run_fixture(case_dir, root):
    with open(os.path.join(case_dir, "case.json"), encoding="utf-8") as handle:
        case = json.load(handle)
    catalog = os.path.join(case_dir, "ko.json")
    inc = os.path.join(case_dir, "ko_catalog.inc")
    candidates = os.path.join(case_dir, "candidates.json")
    result = check_catalog(catalog, inc if os.path.isfile(inc) else None, candidates,
                           extra_ini_names=case.get("ini_names"), root=root,
                           require_templates=False)
    codes = sorted({failure["code"] for failure in result["failures"]})
    keys = sorted({failure["key"] for failure in result["failures"]})
    expected_code = case["expect_code"]
    expected_key = case["expect_key"]
    detected = (expected_code in codes) and (expected_key in keys)
    return {
        "name": case["name"],
        "expect_code": expected_code,
        "expect_key": expected_key,
        "observed_codes": codes,
        "observed_keys": keys,
        "failure_count": len(result["failures"]),
        "detected": detected,
        "failures": result["failures"][:20],
        "checks": result["checks"],
    }


def run_fixtures(fixtures_dir, evidence_path, root):
    if not os.path.isdir(fixtures_dir):
        print("FAIL fixtures directory missing: %s" % fixtures_dir)
        return 1
    names = sorted(name for name in os.listdir(fixtures_dir)
                   if os.path.isfile(os.path.join(fixtures_dir, name, "case.json")))
    results = []
    for name in names:
        outcome = run_fixture(os.path.join(fixtures_dir, name), root)
        results.append(outcome)
        marker = "ok  " if outcome["detected"] else "MISS"
        print("%s %-18s expect %-18s observed %s" % (
            marker, outcome["name"], outcome["expect_code"], ",".join(outcome["observed_codes"])))

    missing = [name for name in EXPECTED_FIXTURES
               if name not in {result["name"] for result in results}]
    all_detected = all(result["detected"] for result in results) and not missing
    payload = {
        "tool": TOOL,
        "mode": "fixtures",
        "fixtures_dir": fixtures_dir,
        "fixture_count": len(results),
        "expected_fixture_names": EXPECTED_FIXTURES,
        "missing_expected_fixtures": missing,
        "cases": results,
        "all_cases_failed_as_designed": all_detected,
        "failures": [] if all_detected else [{"code": "fixture-not-detected", "key": name,
                                              "detail": "fixture did not fail as designed"}
                                             for name in missing],
        "warnings": [],
        "counts": {"fixtures": len(results), "detected": sum(1 for r in results if r["detected"])},
        "hashes": {},
        "passed": all_detected,
        "exit_code": 0 if all_detected else 1,
    }
    with open(evidence_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=True, indent=1)
        handle.write("\n")
    print("fixtures: %d, detected as designed: %d, missing expected: %s" % (
        len(results), sum(1 for result in results if result["detected"]),
        ",".join(missing) if missing else "none"))
    return 0 if all_detected else 1


# --------------------------------------------------------------------------
def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="verify the KO catalog and its include")
    parser.add_argument("--catalog")
    parser.add_argument("--inc")
    parser.add_argument("--candidates")
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--fixtures")
    parser.add_argument("--expect-fail", action="store_true")
    parser.add_argument("--strict", action="store_true", help="treat warnings as failures")
    parser.add_argument("--root", default=None, help="tree root for the INI-name guard")
    args = parser.parse_args(argv)

    if args.expect_fail:
        if not args.fixtures:
            print("FAIL --expect-fail needs --fixtures")
            return 2
        return run_fixtures(args.fixtures, args.evidence, args.root or os.getcwd())

    for required in ("catalog", "inc", "candidates"):
        if not getattr(args, required):
            print("FAIL --%s is required outside fixture mode" % required)
            return 2

    result = check_catalog(args.catalog, args.inc, args.candidates, root=args.root or os.getcwd())
    result["catalog_path"] = args.catalog
    result["inc_path"] = args.inc
    result["candidates_path"] = args.candidates
    write_reports(args.evidence, result)

    strict_info = None
    if args.strict:
        # Informational warnings stay informational: an identity entry is a legitimate
        # design choice for a format string or a Latin token. Any other warning is a
        # catalog defect and fails the strict run.
        blockers = [warning for warning in result["warnings"] if warning["code"] != "untranslated"]
        strict_info = {"gate": "strict", "blocking_warnings": blockers,
                       "informational_codes": ["untranslated"]}

    payload = emit(args.evidence, result, "verify",
                   extra={"strict": strict_info} if strict_info else None)

    print("entries          : %d" % result["counts"]["entries"])
    print("translated       : %d" % result["counts"]["translated"])
    print("untranslated     : %d" % result["counts"]["untranslated"])
    print("unknown sources  : %d" % result["counts"]["unknown_source_keys"])
    for check in result["checks"]:
        print("%-4s %-18s %s" % ("ok" if check["passed"] else "FAIL", check["name"], check["detail"]))
    for failure in result["failures"][:40]:
        print("FAIL %s %s: %s" % (failure["code"], failure["key"], failure["detail"]))

    if strict_info:
        print("STRICT: %d blocking warnings" % len(strict_info["blocking_warnings"]))
        if strict_info["blocking_warnings"]:
            return 1
    return payload["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
