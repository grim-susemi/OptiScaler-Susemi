#!/usr/bin/env python3
"""Static precheck for the row 6 in-game KO/EN visual protocol.

Row 6 of `.omo/plans/susemi-next-ui-lang.md` authors two things: the owner walk
list (`docs/in-game-ko-check.md`) and this precheck. The precheck proves, without
launching the game and without touching the live install, that

  1. the protocol walks every surface row 6 names, with an explicit expectation
     per step and a language state per step;
  2. the shipped payload carries the Korean catalog (KO sentinels) and the
     language switch (ASCII sentinels);
  3. the shipped `OptiScaler.ini` carries no `[Menu] Language` key, so an
     untouched install stays English;
  4. the owner checklist is a template: owner fields empty and the result
     PENDING, never PASS. `--require-owner` is the F2 gate, and it fails on any
     empty owner cell or non-PASS verdict.

It also records the static catalog coverage gaps it finds on the walked surface
(wrapper-helper labels and ini-name title labels that the shipped catalog has no
entry for). Findings never fail the run: they are the honest boundary of what a
static check proves, and the protocol names them so an owner FAIL on one of them
is a correct FAIL.

Exit codes: 0 all hard checks pass, 1 a hard check failed, 2 usage error.

No game launch, no DLL swap, no live-install touch. This tool only reads.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import sys

TOOL = "tools/verify_visual_protocol.py"
SCHEMA = 1
PLAN_ROW = 6

# --------------------------------------------------------------------------
# The surfaces row 6 names, mapped to the ids the protocol walks. The protocol's
# inventory table must carry every id, and at least one step row must cover it.
PLAN_GROUPS = {
    "core menu sections": ["core-menu-sections"],
    "NR panel (enable, placement, performance, model passes, colour, precision, compare, debug)": [
        "nr-panel",
        "nr-enable",
        "nr-placement",
        "nr-performance",
        "nr-model-passes",
        "nr-colour",
        "nr-precision",
        "nr-compare",
        "nr-debug",
    ],
    "(?) tooltips": ["tooltips"],
    "keybind notes": ["keybinds"],
    "FG status": ["fg-status"],
    "MFG status": ["mfg-status"],
    "bottom bar": ["bottom-bar"],
    "splash": ["splash"],
    "toast": ["toast"],
    "persistence / restart": ["persistence-restart"],
}
REQUIRED_SURFACES = [sid for ids in PLAN_GROUPS.values() for sid in ids]

# The residue the plan and contract C8 accept: dynamic status and version strings.
RESIDUE_MARKERS = ["Recorded English residue", "dynamic status", "version string"]

LANGUAGES = {"en", "ko", "en->ko", "ko->en"}

CATALOG_JSON = "OptiScaler/menu/locales/ko.json"
CATALOG_INC = "OptiScaler/menu/locales/ko_catalog.inc"
LOCALIZATION_HEADER = "OptiScaler/menu/Localization.h"

# KO sentinels are read from the generated catalog, so the check follows the
# shipped catalog rather than a copy pasted into this file. One msgid per walked
# surface group: bottom bar, keybinds, NR panel, FG compare, toast-era labels.
SENTINEL_MSGIDS = [
    "Menu Scale",
    "Save Settings",
    "Close",
    "Debug view",
    "Model passes",
    "Hold frame",
    "Side by side",
    "Swap sides",
]

# ASCII sentinels that only this feature can put in the DLL.
SENTINEL_ASCII = [
    "##Language",  # the hidden combo label of the switch in the bottom bar
    "Korean font not found (malgun.ttf, gulim.ttc, Noto CJK KR) - the menu stays English",
]
# Octal UTF-8 escapes of the Korean entry label "한국어" as written in
# Localization.h's Languages[] table; decoded here so the check is over bytes.
SENTINEL_HEADER_ESCAPES = r"\355\225\234\352\265\255\354\226\264"

WALKED_FILES = [
    "OptiScaler/menu/menu_common.cpp",
    "OptiScaler/dlssnr/DlssNr_Menu.cpp",
    "OptiScaler/dlssnr/DlssNr_MenuControls.cpp",
    "OptiScaler/dlssnr/DlssNr_PipelineUi.h",
    "OptiScaler/dlssnr/DlssNr_MenuOverlay.cpp",
    "OptiScaler/dlssnr/DlssNr_MenuSections.h",
]
WRAPPER_HELPERS = ["Slider", "DeferredSlider", "slider", "CheckboxWrapped"]


# --------------------------------------------------------------------------
# help


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def decode_escapes(text: str) -> bytes:
    """Decode the octal UTF-8 escapes gen_ko_catalog.py writes into raw bytes."""
    out = bytearray()
    i = 0
    while i < len(text):
        if text[i] == "\\" and i + 3 < len(text) and text[i + 1:i + 4].isdigit():
            out.append(int(text[i + 1:i + 4], 8))
            i += 4
            continue
        if text[i] == "\\" and i + 1 < len(text):
            out.extend({"n": b"\n", "t": b"\t", "\\": b"\\", '"': b'"'}.get(text[i + 1], text[i + 1].encode()))
            i += 2
            continue
        out.extend(text[i].encode("utf-8"))
        i += 1
    return bytes(out)


# --------------------------------------------------------------------------
# markdown protocol


def split_row(line: str):
    line = line.strip()
    if not line.startswith("|"):
        return None
    cells = re.split(r"(?<!\\)\|", line)
    if cells and cells[0].strip() == "":
        cells = cells[1:]
    if cells and cells[-1].strip() == "":
        cells = cells[:-1]
    return [cell.replace("\\|", "|").strip() for cell in cells]


def table_after(lines, heading, columns):
    """Return the data rows of the first markdown table under `heading`.

    The header row and its separator are skipped, so a shape mismatch names a
    real data row rather than the column titles.
    """
    start = None
    for index, line in enumerate(lines):
        if line.strip() == heading:
            start = index + 1
            break
    if start is None:
        return []
    raw = []
    for line in lines[start:]:
        if line.strip().startswith("#") and raw:
            break
        cells = split_row(line)
        if cells is None:
            if raw:
                break
            continue
        raw.append((cells, line))
    if len(raw) < 2:
        return []
    rows = []
    for cells, line in raw[2:] if set("".join(raw[1][0])) <= set("-: ") else raw[1:]:
        if len(cells) != columns:
            rows.append(("__bad__", cells, line))
            continue
        rows.append((None, cells, line))
    return rows


def parse_protocol(text: str, failures: list, warnings: list):
    lines = text.splitlines()
    inventory = table_after(lines, "## Frozen surface inventory", 4)
    steps = table_after(lines, "## Steps", 7)

    surfaces, bad_surfaces = {}, []
    for bad, cells, line in inventory:
        if bad:
            bad_surfaces.append(line.strip()[:90])
            continue
        surfaces[cells[1].strip("`")] = {"row": cells[0], "surface": cells[2], "anchors": cells[3]}

    parsed_steps, bad_steps = [], []
    for bad, cells, line in steps:
        if bad:
            bad_steps.append(line.strip()[:90])
            continue
        parsed_steps.append(
            {
                "step": cells[0],
                "surface": cells[1].strip("`"),
                "language": cells[2],
                "expected": cells[3],
                "actual": cells[4],
                "verdict": cells[5],
                "note": cells[6],
            }
        )

    for line in bad_surfaces:
        failures.append({"check": "inventory-table-shape", "detail": line})
    for line in bad_steps:
        failures.append({"check": "steps-table-shape", "detail": line, "hint": "escape a literal pipe as \\|"})

    if not surfaces:
        failures.append({"check": "inventory-table-present", "detail": "## Frozen surface inventory has no table"})
    if not parsed_steps:
        failures.append({"check": "steps-table-present", "detail": "## Steps has no table"})

    for surface_id in REQUIRED_SURFACES:
        if surface_id not in surfaces:
            failures.append(
                {"check": "surface-in-inventory", "surface": surface_id,
                 "detail": "the surface row 6 names is missing from the inventory table"}
            )

    covered = {}
    for step in parsed_steps:
        covered.setdefault(step["surface"], 0)
        covered[step["surface"]] += 1
    for surface_id in REQUIRED_SURFACES:
        if not covered.get(surface_id):
            failures.append(
                {"check": "surface-has-steps", "surface": surface_id,
                 "detail": "no step row walks this surface"}
            )

    unknown = sorted(set(covered) - set(REQUIRED_SURFACES))
    for surface_id in unknown:
        warnings.append({"check": "step-surface-not-in-inventory", "surface": surface_id,
                         "detail": "a step names a surface id the inventory table does not carry"})

    for step in parsed_steps:
        if step["language"] not in LANGUAGES:
            failures.append({"check": "step-language-state", "step": step["step"],
                             "detail": "language state %r is not one of %s" % (step["language"], sorted(LANGUAGES))})
        if not step["expected"]:
            failures.append({"check": "step-expectation", "step": step["step"],
                             "detail": "the Expected result cell is empty"})
        if step["actual"] or step["verdict"]:
            failures.append({"check": "step-owner-cells-empty", "step": step["step"],
                             "detail": "the protocol itself carries an owner cell; the template must leave them empty"})

    low = text.lower()
    for marker in RESIDUE_MARKERS:
        if marker.lower() not in low:
            failures.append({"check": "residue-documented", "detail": "the protocol does not name %r" % marker})

    transitions = sorted({s["language"] for s in parsed_steps if "->" in s["language"]})
    if not transitions:
        failures.append({"check": "transition-steps", "detail": "no step covers an en->ko or ko->en transition"})

    return {
        "inventory_surfaces": surfaces,
        "steps": parsed_steps,
        "steps_per_surface": {k: covered[k] for k in sorted(covered)},
        "required_surfaces": REQUIRED_SURFACES,
        "plan_groups": PLAN_GROUPS,
        "transitions": transitions,
    }


# --------------------------------------------------------------------------
# payload


def catalog_entries(root: str):
    path = os.path.join(root, CATALOG_JSON.replace("/", os.sep))
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
    return payload.get("entries", {}), payload


def sentinels(root: str, failures: list):
    inc_path = os.path.join(root, CATALOG_INC.replace("/", os.sep))
    with open(inc_path, encoding="ascii", errors="strict") as handle:
        inc = handle.read()

    entries = {}
    for match in re.finditer(r'^\s*\{\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"\s*\}\s*,?\s*$', inc, re.M):
        entries[match.group(1)] = match.group(2)

    records = []
    for msgid in SENTINEL_MSGIDS:
        ko = entries.get(msgid)
        if ko is None:
            failures.append({"check": "sentinel-in-catalog", "msgid": msgid,
                             "detail": "the shipped ko_catalog.inc has no entry for this sentinel"})
            continue
        raw = decode_escapes(ko)
        if raw == msgid.encode("utf-8") or not any(byte >= 0x80 for byte in raw):
            failures.append({"check": "sentinel-is-korean", "msgid": msgid,
                             "detail": "the entry carries no Korean bytes, so it cannot witness Hangul in the DLL"})
        records.append({"kind": "ko-catalog", "msgid": msgid, "bytes": len(raw), "needle_hex": raw.hex()})
        records[-1]["_raw"] = raw

    header_path = os.path.join(root, LOCALIZATION_HEADER.replace("/", os.sep))
    with open(header_path, encoding="utf-8", errors="replace") as handle:
        header = handle.read()
    if SENTINEL_HEADER_ESCAPES not in header:
        failures.append({"check": "language-entry-label", "detail": "Localization.h no longer carries the 한국어 entry escapes"})
    else:
        records.append({"kind": "ko-header", "msgid": "한국어 (Languages[] label)",
                        "bytes": len(decode_escapes(SENTINEL_HEADER_ESCAPES)),
                        "needle_hex": decode_escapes(SENTINEL_HEADER_ESCAPES).hex(), "_raw": decode_escapes(SENTINEL_HEADER_ESCAPES)})

    for text in SENTINEL_ASCII:
        raw = text.encode("ascii")
        records.append({"kind": "ascii-switch", "msgid": text, "bytes": len(raw),
                        "needle_hex": raw.hex(), "_raw": raw})
    return records


def check_dll(dll_path: str, sentinel_records, failures: list):
    with open(dll_path, "rb") as handle:
        blob = handle.read()
    found, missing = [], []
    for record in sentinel_records:
        hit = blob.find(record["_raw"])
        if hit < 0:
            missing.append(record["msgid"])
        else:
            found.append({"msgid": record["msgid"], "kind": record["kind"], "offset": hit})
    for msgid in missing:
        failures.append({"check": "dll-sentinel", "msgid": msgid,
                         "detail": "the sentinel is absent from the payload under test"})
    return {"bytes": len(blob), "sha256": sha256_file(dll_path), "sentinels_found": found,
            "sentinels_missing": missing}


def check_ini(ini_path: str, failures: list):
    with open(ini_path, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().splitlines()
    section = None
    sections = []
    menu_language, anywhere_language = [], []
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        head = re.fullmatch(r"\[([^\[\]]+)\]", stripped)
        if head:
            section = head.group(1)
            sections.append(section)
            continue
        key = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=", stripped)
        if key:
            if key.group(1).lower() == "language":
                anywhere_language.append(number)
                if section == "Menu":
                    menu_language.append(number)
    if "Menu" not in sections:
        failures.append({"check": "ini-menu-section", "detail": "the shipped OptiScaler.ini has no [Menu] section"})
    if anywhere_language:
        failures.append({"check": "ini-language-key-absent", "lines": anywhere_language,
                         "detail": "the shipped OptiScaler.ini carries a Language key; an untouched ini must stay English"})
    return {"path": ini_path, "sha256": sha256_file(ini_path), "sections": len(sections),
            "menu_section_present": "Menu" in sections, "language_key_lines": anywhere_language,
            "language_key_in_menu": menu_language, "lines": len(lines)}


# --------------------------------------------------------------------------
# static catalog coverage findings


def coverage_findings(root: str, warnings: list):
    """Three named classes of visible label the shipped catalog has no entry for.

    All are row 1 residue, not row 6 defects. Row 1's extractor keys its scan on
    ImGui function names, so a label handed to a local helper never entered the
    candidate set, and a label whose text equals a shipped ini key or section name
    was dropped by the do-not-translate rule even though it is a visible title.

    Classes, in precedence order:
      1. wrapper-helper  - first argument of Slider / DeferredSlider / slider /
                           CheckboxWrapped, the NR panel's local label helpers;
      2. ini-name        - reached a scanned ImGui call, dropped as an ini key or
                           ini section name by row 1's do-not-translate rule;
      3. other-helper    - first argument of any other call shape the extractor
                           cannot see (PopulateCombo, ShowTooltip, showHelp,
                           setTitle, AddResourceBarrier, InputText, ...).
    The third class is a static superset and is carried with a caveat: it holds
    strings the protocol already declares residue (toast titles, FG status tips)
    next to labels that are additional gaps. Every member carries its file:line
    anchor in the receipt, and class 3 alone is not treated as a defect list.
    Shapes whose literal is an identifier rather than a label (ImGui::Begin and
    BeginTable ids, PushID, CalcTextSize measurements) are excluded.
    """
    tools_dir = os.path.join(root, "tools")
    if tools_dir not in sys.path:
        sys.path.insert(0, tools_dir)
    try:
        import extract_menu_strings as X  # type: ignore
    except Exception as error:  # pragma: no cover - missing row 1 tool
        warnings.append({"check": "coverage-findings-skipped",
                         "detail": "row 1 extractor unavailable: %s" % error})
        return {"skipped": True, "reason": str(error)}, None

    entries, _ = catalog_entries(root)
    sections, keys = X.load_ini_names(root)
    class_names = set()
    for _, pattern in X.CALL_CLASSES:
        class_names.update(pattern.split("|"))

    helper_gaps, ini_gaps, other_gaps = {}, {}, {}
    skip_names = class_names | {"if", "for", "while", "switch", "sizeof", "LOG_DEBUG",
                                 "LOG_INFO", "LOG_WARN", "LOG_ERROR", "LOG_TRACE"}
    # Shapes whose first literal is an identifier or a measurement, never a label.
    id_shapes = {"Begin", "BeginTable", "PushID", "CalcTextSize", "push_back", "memset", "strcmp"}
    for rel in WALKED_FILES:
        path = os.path.join(root, rel.replace("/", os.sep))
        if not os.path.isfile(path):
            warnings.append({"check": "walked-file-missing", "detail": rel})
            continue
        text = open(path, encoding="utf-8", errors="replace").read()
        masked, literals = X.mask_source(text)

        # class 1: labels handed to a wrapper helper the extractor cannot see
        for match in re.finditer(r"(?<![\w:])(?:[A-Za-z_][A-Za-z0-9_]*::)*([A-Za-z_][A-Za-z0-9_]*)\s*\(", masked):
            name = match.group(1)
            if name not in WRAPPER_HELPERS:
                continue
            open_paren = match.end() - 1
            frags = X.collect_call_literals(masked, literals, open_paren)
            if not frags:
                continue
            start, _, decoded = frags[0]
            if masked[open_paren + 1:start].strip().strip('"').strip():
                continue
            value = X.normalize(decoded)
            key = value.split("##")[0].strip()
            if not key or key in entries or X.is_pure_format(value) or "\x00" in value:
                continue
            record = helper_gaps.setdefault(key, {"site": "%s:%d" % (rel, X.line_of(text, match.start())),
                                                  "helpers": set(), "occurrences": 0})
            record["helpers"].add(name)
            record["occurrences"] += 1

        # class 2: visible titles the ini-name rule dropped
        for class_name, pattern in X.CALL_CLASSES:
            call_re = re.compile(r"(?<![\w:])(?:ImGui::)?(?:%s)\s*\(" % pattern)
            for match in call_re.finditer(masked):
                open_paren = match.end() - 1
                for start, _, decoded in X.collect_call_literals(masked, literals, open_paren):
                    value = X.normalize(decoded)
                    key = value.split("##")[0].strip()
                    if not key or key in entries or X.is_pure_format(value) or "\x00" in value:
                        continue
                    reason = X.classify_drop(key, sections, keys)
                    if reason not in ("ini-key", "ini-section-name"):
                        continue
                    record = ini_gaps.setdefault(key, {"site": "%s:%d" % (rel, X.line_of(text, start)),
                                                       "reason": reason, "class": class_name})
                    record["reason"] = reason

        # class 3: any other call shape whose first argument is a visible label
        for match in re.finditer(r"(?<![\w:])(?:[A-Za-z_][A-Za-z0-9_]*::)*([A-Za-z_][A-Za-z0-9_]*)\s*\(", masked):
            name = match.group(1)
            if name in skip_names or name in id_shapes:
                continue
            open_paren = match.end() - 1
            frags = X.collect_call_literals(masked, literals, open_paren)
            if not frags:
                continue
            start, _, decoded = frags[0]
            if masked[open_paren + 1:start].strip().strip('"').strip():
                continue
            value = X.normalize(decoded)
            key = value.split("##")[0].strip()
            if not key or key in entries or X.is_pure_format(value) or "\x00" in value:
                continue
            if key in helper_gaps or key in ini_gaps:
                continue
            statement = masked[max(masked.rfind(";", 0, match.start()), masked.rfind("{", 0, match.start()),
                                   masked.rfind("}", 0, match.start())) + 1:match.start()]
            if X.LOG_MARKERS.search(statement):
                continue
            record = other_gaps.setdefault(key, {"site": "%s:%d" % (rel, X.line_of(text, match.start())),
                                                 "helpers": set(), "occurrences": 0})
            record["helpers"].add(name)
            record["occurrences"] += 1

    def flatten(gaps):
        return [
            dict({"msgid": key}, **{k: (sorted(v) if isinstance(v, set) else v) for k, v in value.items()})
            for key, value in sorted(gaps.items())
        ]

    return (
        {
            "skipped": False,
            "catalog_entries": len(entries),
            "wrapper_helpers": WRAPPER_HELPERS,
            "wrapper_passed": {"count": len(helper_gaps), "labels": flatten(helper_gaps)},
            "ini_name": {"count": len(ini_gaps), "labels": flatten(ini_gaps)},
            "other_helper_call": {"count": len(other_gaps), "labels": flatten(other_gaps)},
            "row1_tool_sha256": sha256_file(os.path.join(tools_dir, "extract_menu_strings.py")),
            "note": "non-blocking: the protocol names these so an owner FAIL on one is a correct FAIL",
        },
        None,
    )


# --------------------------------------------------------------------------
# owner checklist


def write_checklist(path: str, protocol_path: str, protocol_sha: str, steps, dll_path: str, dll_sha: str, ini_sha: str):
    payload = {
        "tool": TOOL,
        "schema": SCHEMA,
        "plan_row": PLAN_ROW,
        "kind": "owner-checklist-template",
        "state": "TEMPLATE - owner fields are empty on purpose; an empty cell is PENDING, never PASS",
        "protocol": protocol_path,
        "protocol_sha256": protocol_sha,
        "built_dll": dll_path,
        "built_dll_sha256": dll_sha,
        "shipped_ini_sha256": ini_sha,
        "generated_utc": utc_now(),
        "owner": "",
        "owner_date": "",
        "installed_dll_sha256": "",
        "result": "PENDING",
        "steps": [
            {
                "step": step["step"],
                "surface": step["surface"],
                "language": step["language"],
                "expected": step["expected"],
                "actual": "",
                "verdict": "",
                "note": "",
            }
            for step in steps
        ],
    }
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=True, indent=1, sort_keys=False)
        handle.write("\n")
    return payload


def check_checklist(path, steps, dll_sha, require_owner, failures, warnings, protocol_sha):
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)

    owner = payload.get("owner", "")
    result = payload.get("result", "")
    recorded_dll = payload.get("built_dll_sha256", payload.get("installed_dll_sha256", ""))
    entries = payload.get("steps", [])

    recorded_protocol = payload.get("protocol_sha256", "")
    if recorded_protocol != protocol_sha:
        failures.append({"check": "checklist-protocol-binding", "detail":
                         "the checklist was generated from protocol %r, the protocol under test hashes %r"
                         % (recorded_protocol or "(none)", protocol_sha)})

    expected = [(s["step"], s["surface"], s["language"]) for s in steps]
    actual = [(s.get("step"), s.get("surface"), s.get("language")) for s in entries]
    if expected != actual:
        for index, (want, got) in enumerate(zip(expected, actual)):
            if want != got:
                failures.append({"check": "checklist-step-parity", "step": want[0],
                                 "detail": "checklist step %r does not match the protocol row %r" % (got, want)})
                break
        else:
            failures.append({"check": "checklist-step-parity",
                             "detail": "checklist carries %d steps, the protocol carries %d" % (len(actual), len(expected))})

    empty_actual = [s.get("step") for s in entries if not str(s.get("actual", "")).strip()]
    empty_verdict = [s.get("step") for s in entries if not str(s.get("verdict", "")).strip()]
    non_pass = [s.get("step") for s in entries if str(s.get("verdict", "")).strip().upper() not in ("", "PASS")]

    if require_owner:
        if not owner.strip():
            failures.append({"check": "owner-recorded", "detail": "the owner field is empty; acceptance needs an owner"})
        if not str(payload.get("owner_date", "")).strip():
            failures.append({"check": "owner-date", "detail": "the owner date field is empty"})
        if recorded_dll != dll_sha:
            failures.append({"check": "checklist-dll-binding", "detail":
                             "the checklist records %r, the payload under test hashes %r" % (recorded_dll, dll_sha)})
        for step in entries:
            if not str(step.get("actual", "")).strip():
                failures.append({"check": "owner-observation", "step": step.get("step"),
                                 "detail": "no actual result recorded"})
            if str(step.get("verdict", "")).strip().upper() != "PASS":
                failures.append({"check": "owner-verdict", "step": step.get("step"),
                                 "detail": "verdict is %r, expected PASS" % step.get("verdict")})
        if result.strip().upper() != "PASS":
            failures.append({"check": "owner-result", "detail": "the checklist result is %r, expected PASS" % result})
    else:
        # template mode: an unfilled cell is PENDING, and it must not read as acceptance
        if str(result).strip().upper() not in ("PENDING", ""):
            failures.append({"check": "template-not-accepted", "detail":
                             "the template records result %r; a template is PENDING, not acceptance" % result})
        if owner.strip() or payload.get("owner_date", "").strip() or payload.get("installed_dll_sha256", "").strip():
            failures.append({"check": "template-owner-fields-empty", "detail":
                             "a template must leave owner, owner_date and installed_dll_sha256 empty"})
        if empty_actual and empty_verdict and empty_actual == empty_verdict:
            pass  # the expected template state
        elif not empty_actual or not empty_verdict:
            warnings.append({"check": "template-cells", "detail":
                             "some owner cells carry text: actual-empty=%d verdict-empty=%d"
                             % (len(empty_actual), len(empty_verdict))})
        if non_pass:
            failures.append({"check": "template-verdicts", "steps": non_pass,
                             "detail": "a template must not carry a verdict"})

    return {
        "path": path,
        "sha256": sha256_file(path),
        "state": result,
        "owner": owner,
        "recorded_dll_sha256": recorded_dll,
        "steps": len(entries),
        "owner_cells_empty": {"actual": len(empty_actual), "verdict": len(empty_verdict)},
        "require_owner": require_owner,
    }


# --------------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(description="row 6 static precheck for the in-game KO/EN protocol")
    parser.add_argument("--protocol", required=True)
    parser.add_argument("--checklist")
    parser.add_argument("--dll")
    parser.add_argument("--ini")
    parser.add_argument("--evidence")
    parser.add_argument("--root", default=".")
    parser.add_argument("--require-owner", action="store_true")
    parser.add_argument("--write-checklist", action="store_true")
    parser.add_argument("--no-findings", action="store_true", help="skip the static coverage-gap scan")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    failures, warnings = [], []

    protocol_path = os.path.abspath(args.protocol)
    if not os.path.isfile(protocol_path):
        print("protocol not found: %s" % protocol_path, file=sys.stderr)
        return 2
    with open(protocol_path, encoding="utf-8", errors="replace") as handle:
        protocol_text = handle.read()
    protocol_sha = sha256_file(protocol_path)

    protocol = parse_protocol(protocol_text, failures, warnings)

    dll, ini, checklist = None, None, None
    if args.dll:
        if not os.path.isfile(args.dll):
            print("payload not found: %s" % args.dll, file=sys.stderr)
            return 2
        dll_sha = sha256_file(args.dll)
        records = sentinels(root, failures)
        dll = check_dll(args.dll, records, failures)
        dll["path"] = os.path.abspath(args.dll)
    else:
        dll_sha = ""
        warnings.append({"check": "payload-omitted", "detail": "no --dll given, sentinel checks skipped"})

    if args.ini:
        if not os.path.isfile(args.ini):
            print("ini not found: %s" % args.ini, file=sys.stderr)
            return 2
        ini = check_ini(args.ini, failures)
    else:
        warnings.append({"check": "ini-omitted", "detail": "no --ini given, the shipped-default check was skipped"})

    if args.write_checklist:
        if not args.checklist or not args.dll or not args.ini:
            print("--write-checklist needs --checklist, --dll and --ini", file=sys.stderr)
            return 2
        written = write_checklist(args.checklist, args.protocol, protocol_sha, protocol["steps"],
                                  os.path.abspath(args.dll), dll_sha, ini["sha256"])
        print("checklist template written: %s (%d steps, result %s)"
              % (args.checklist, len(written["steps"]), written["result"]))

    if args.checklist and os.path.isfile(args.checklist) and not args.write_checklist:
        checklist = check_checklist(args.checklist, protocol["steps"], dll_sha, args.require_owner,
                                    failures, warnings, protocol_sha)
    elif args.checklist and not os.path.isfile(args.checklist):
        failures.append({"check": "checklist-present", "detail": "no checklist at %s" % args.checklist})

    findings = None
    if not args.no_findings:
        findings, _ = coverage_findings(root, warnings)

    payload = {
        "tool": TOOL,
        "schema": SCHEMA,
        "plan_row": PLAN_ROW,
        "contract": "row 6 happy assertions: the protocol covers every surface in the surface inventory; the precheck finds the KO sentinels in the DLL and confirms the ini key is absent by default",
        "generated_utc": utc_now(),
        "root": root.replace("\\", "/"),
        "mode": "require-owner" if args.require_owner else "template-precheck",
        "inputs": {
            "protocol": {"path": protocol_path.replace("\\", "/"), "sha256": protocol_sha},
            "dll": dll,
            "ini": ini,
            "checklist": checklist,
        },
        "coverage": {
            "required_surfaces": protocol["required_surfaces"],
            "inventory_surfaces": sorted(protocol["inventory_surfaces"]),
            "steps": len(protocol["steps"]),
            "steps_per_surface": protocol["steps_per_surface"],
            "transition_steps": protocol["transitions"],
        },
        "findings": findings,
        "failures": failures,
        "warnings": warnings,
        "result": "PASS" if not failures else "FAIL",
        "exit_code_meaning": "0 = every hard static check passed; 1 = a hard check failed and is named above; 2 = usage error",
    }

    hard = ["surface-inventory", "surface-steps", "step-shape"]
    if dll:
        hard.append("dll-sentinels")
    if ini:
        hard.append("shipped-ini-default")
    if checklist:
        hard.append("owner-checklist")
    payload["hard_checks_run"] = hard

    if args.evidence:
        out_dir = os.path.dirname(os.path.abspath(args.evidence))
        os.makedirs(out_dir, exist_ok=True)
        with open(args.evidence, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, ensure_ascii=True, indent=1, sort_keys=False)
            handle.write("\n")

    print("%s: %d hard checks, %d failures, %d warnings" % (TOOL, len(hard), len(failures), len(warnings)))
    print("protocol              : %s (%d steps, %d surfaces)"
          % (args.protocol, len(protocol["steps"]), len(protocol["inventory_surfaces"])))
    if dll:
        print("payload               : %s sha256=%s sentinels %d/%d"
              % (os.path.basename(dll["path"]), dll["sha256"][:16], len(dll["sentinels_found"]),
                 len(dll["sentinels_found"]) + len(dll["sentinels_missing"])))
    if ini:
        print("shipped ini           : %s sha256=%s language key lines=%s"
              % (os.path.basename(ini["path"]), ini["sha256"][:16], ini["language_key_lines"] or "none"))
    if checklist:
        print("owner checklist       : %s state=%s owner cells empty=%s"
              % (os.path.basename(checklist["path"]), checklist["state"], checklist["owner_cells_empty"]))
    if findings and not findings.get("skipped"):
        print("static coverage gaps  : %d wrapper-passed, %d ini-name, %d other helper call (non-blocking)"
              % (findings["wrapper_passed"]["count"], findings["ini_name"]["count"],
                 findings["other_helper_call"]["count"]))
    for failure in failures:
        print("FAIL  %-28s %s" % (failure.get("check"), failure.get("detail", "")))
    if args.evidence:
        print("evidence              : %s" % args.evidence)
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
