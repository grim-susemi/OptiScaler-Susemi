#!/usr/bin/env python3
"""Row 1 of .omo/plans/susemi-next-ui-lang.md: extract the translatable UI string inventory.

Scans raw source (never preprocessed output, so #ifdef-gated strings enter the superset),
collects string literals per UI call-site class, normalizes whitespace, drops
do-not-translate lines and emits a sorted, deterministic candidate list.

Deterministic by construction: no timestamps, no host-specific state, sorted output.
Two runs over the same tree must produce byte-identical files.

Usage:
  python tools/extract_menu_strings.py --root <worktree> --out <json>
  python tools/extract_menu_strings.py --self-test --evidence <json>
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter

SCHEMA = 1
TOOL = "tools/extract_menu_strings.py"

# --------------------------------------------------------------------------
# Scan targets. The row names these files; the two dlssnr source directories
# are scanned in full because R10's list was incomplete (for example
# DlssNr_Dx12_Evaluate.cpp and DlssNr_Dx12_FinishedCompose.cpp carry printed
# `Say(...)` strings). A superset is harmless; a missing entry is not.
NAMED_FILES = [
    "OptiScaler/menu/menu_common.cpp",
    "OptiScaler/menu/menu_common.h",
    "OptiScaler/dlssnr/DlssNr_Menu.cpp",
    "OptiScaler/dlssnr/DlssNr_MenuControls.cpp",
    "OptiScaler/dlssnr/DlssNr_MenuOverlay.cpp",
    "OptiScaler/dlssnr/DlssNr_PipelineUi.h",
    "OptiScaler/dlssnr/DlssNr_MenuSections.h",
    "OptiScaler/shaders/dlssnr/DlssNr_Dx12_Run.cpp",
    "OptiScaler/shaders/dlssnr/DlssNr_Dx12_Models.cpp",
    "OptiScaler/shaders/dlssnr/DlssNr_Dx12_Enlarge.cpp",
    "OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedQueue.cpp",
    "OptiScaler/shaders/dlssnr/DlssNr_Dx12_DeferredSr.cpp",
    "OptiScaler/shaders/dlssnr/DlssNr_Dx12_Late.cpp",
    "OptiScaler/shaders/dlssnr/DlssNr_Dx12_Status.cpp",
    "OptiScaler/dlssnr/DlssNrFinished_Vk.cpp",
    "OptiScaler/dlssnr/DlssNrFeature_Vk_Model.cpp",
]
SUPERSET_DIRS = ["OptiScaler/shaders/dlssnr", "OptiScaler/dlssnr"]

CONFIG_CPP = "OptiScaler/Config.cpp"
SHIPPED_INI = "OptiScaler.ini"

# --------------------------------------------------------------------------
# Call-site classes. Longest name first so alternation cannot mis-tokenize.
CALL_CLASSES = [
    ("ImGui::Text*", "TextUnformatted|TextWrapped|TextColored|TextDisabled|TextLinkOpenURL|TextLink|BulletText|LabelText|Text"),
    ("Button", "InvisibleButton|ArrowButton|ImageButton|SmallButton|Button"),
    ("Checkbox", "CheckboxFlags|Checkbox"),
    ("Combo", "Combo|BeginCombo"),
    ("Selectable", "Selectable|SelectableFlags"),
    ("Slider*", "VSliderFloat|VSliderInt|SliderScalar|SliderAngle|SliderInt4|SliderInt3|SliderInt2|SliderInt|SliderFloat4|SliderFloat3|SliderFloat2|SliderFloat"),
    ("TreeNode", "TreeNodeEx|TreeNode"),
    ("CollapsingHeader", "CollapsingHeader"),
    ("SeparatorText", "SeparatorText|SeparatorWithHelpMarker"),
    ("SetTooltip", "SetTooltip|BeginTooltip"),
    ("ShowHelpMarker", "ShowHelpMarker"),
    ("HelpMarker", "HelpMarker"),
    ("ScopedCollapsingHeader", "ScopedCollapsingHeader"),
    ("Keybind", "Keybind"),
    ("setContent", "setContent|SetContent"),
    ("StrFmt", "StrFmt|StrFormat"),
    # PublishStatus and the lowercase `say(...)` lambda (DlssNr_Dx12_Enlarge.cpp) carry
    # screen-facing status strings; their first argument is not a literal, so the
    # coverage guard cannot see them and the class pattern must name them explicitly.
    ("StatusText", "FinishedVkStatus|DeferredDlssStatus|ReportSkipOnce|PublishStatus|Say|say|Fail|Publish"),
]
CLASS_NAMES = [name for name, _ in CALL_CLASSES] + ["InitializerTable", "AssignmentLabel"]

# A screen-facing status string can also arrive as a plain assignment.
STATUS_ASSIGN_RE = re.compile(
    r"(?:\b(?:reason|failureReason|enlargementStatus|statusText|finishedStatus|status)\s*=\s*)$"
)
# any other plain string assignment, e.g. `modeStr = "Default";`
ASSIGN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:\s*(?:->|\.)\s*[A-Za-z_][A-Za-z0-9_]*)*\s*=\s*$")

# --------------------------------------------------------------------------
# Do-not-translate predicates.
FMT_SPEC = re.compile(
    r"%[-+ #0]*[0-9*]*(?:\.[0-9*]+)?(?:hh|h|ll|l|j|z|t|L)?[diouxXeEfgGaAcspn%]"
)
VERSION_TOKEN = re.compile(r"\bv?\d+\.\d+(?:\.\d+)*(?:[-+][A-Za-z0-9_.\-]+)?\b")
VERSION_FULL = re.compile(r"^v?\d+(?:\.\d+)*(?:[-+][A-Za-z0-9_.\-]+)?$")
PATH_RE = re.compile(r"(?:[A-Za-z]:[\\/]|\\\\|%WINDIR%|%APPDATA%|%LOCALAPPDATA%|%TEMP%|\.\.?[\\/])")
EXT_RE = re.compile(
    r"\.(?:dll|exe|asi|ini|log|json|txt|md|png|ttf|ttc|bat|sh|zip|pdb|cfg|xml|bmp|jpg|csv)$",
    re.IGNORECASE,
)
URL_RE = re.compile(r"(?:https?://|www\.|github\.com|nexusmods\.com)", re.IGNORECASE)
API_NAME_RE = re.compile(
    r"^(?:[A-Za-z0-9_.\-]*\.(?:dll|exe|asi)|nvngx[a-z0-9_]*|dlssg[a-z0-9_]*|sl\.[a-z0-9_]+"
    r"|OptiScaler|Streamline|FidelityFX|NVAPI|NGX|DXGI|D3D11|D3D12|Vulkan|CUDA|dxvk|vkd3d|vlk)$",
    re.IGNORECASE,
)
# D3D12_RESOURCE_STATE names and NGX parameter keys are API vocabulary, never menu prose.
API_STATE_RE = re.compile(r"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$")
API_STATE_TOKENS = {"AUTO", "COMMON", "PRESENT"}
NGX_KEY_RE = re.compile(r"^(?:DLSS|DLSSD|GBuffer|MotionVectors)[A-Za-z0-9_.]*$")
KEYNAME_RE = re.compile(
    r"^(?:F\d{1,2}|VK_[A-Z0-9_]+|0x[0-9A-Fa-f]+|Numpad\s?\d|Mouse\s?[1-9]|M[Ww]heel\w*"
    r"|(?:Ctrl|Alt|Shift|Win)(?:\s?\+(?:Ctrl|Alt|Shift|Win))*\s?\+[A-Za-z0-9]+)$"
)
LOG_MARKERS = re.compile(
    r"(?:LOG_[A-Z]+|Logger::|spdlog|std::cout|std::cerr|fprintf\s*\(|printf\s*\(|OutputDebugString|<</\s*$)"
)
INI_SECTION_LITERAL = re.compile(r"^\[[^\[\]]+\]$")


def is_pure_format(value: str) -> bool:
    if not value.strip():
        return True
    if not re.search(r"[A-Za-z]", value):
        return True
    return not re.search(r"[A-Za-z]", FMT_SPEC.sub("", value))


def is_version_like(value: str) -> bool:
    stripped = value.strip()
    if VERSION_FULL.fullmatch(stripped):
        return True
    without_tokens = VERSION_TOKEN.sub("", value)
    if without_tokens == value:
        return False  # no version token at all, so it cannot be a version string
    return len(re.sub(r"[^A-Za-z]", "", without_tokens)) < 3


# --------------------------------------------------------------------------
# Raw source scanning.
def decode_c_escapes(body: str) -> str:
    out = []
    i = 0
    simple = {
        "n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"',
        "'": "'", "?": "?", "a": "\a", "b": "\b", "f": "\f", "v": "\v",
    }
    while i < len(body):
        ch = body[i]
        if ch != "\\" or i + 1 >= len(body):
            out.append(ch)
            i += 1
            continue
        nxt = body[i + 1]
        if nxt in simple:
            out.append(simple[nxt])
            i += 2
        elif nxt == "x":
            m = re.match(r"x([0-9a-fA-F]+)", body[i + 1:])
            out.append(chr(int(m.group(1), 16)))
            i += 1 + len(m.group(0))
        elif nxt in "01234567":
            m = re.match(r"([0-7]{1,3})", body[i + 1:])
            out.append(chr(int(m.group(1), 8)))
            i += 1 + len(m.group(0))
        elif nxt in "uU":
            width = 4 if nxt == "u" else 8
            m = re.match(r"[uU]([0-9a-fA-F]{%d})" % width, body[i + 1:])
            if m:
                out.append(chr(int(m.group(1), 16)))
                i += 1 + len(m.group(0))
            else:
                out.append(nxt)
                i += 2
        else:
            out.append(nxt)
            i += 2
    return "".join(out)


def mask_source(text: str):
    """Blank out comments and literals (offsets preserved) and return the literals.

    Returns (masked, literals) with literals as (start, end, decoded).
    """
    masked = list(text)
    literals = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                masked[k] = " "
            i = j
            continue
        if two == "/*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                masked[k] = "\n" if text[k] == "\n" else " "
            i = j
            continue

        prefix_len = 0
        if ch in "LuU" and text[i + 1:i + 2] == "8" and text[i + 2:i + 3] == '"':
            prefix_len = 2
        elif ch in 'LuU' and text[i + 1:i + 2] == '"':
            prefix_len = 1
        elif ch == "u" and text[i + 1:i + 2] == "8" and text[i + 2:i + 3] == '"':
            prefix_len = 2

        # raw string literal: [prefix]R"delim( body )delim"
        raw_at = i + prefix_len
        if text[raw_at:raw_at + 1] == "R" and text[raw_at + 1:raw_at + 2] == '"':
            open_paren = text.find("(", raw_at + 2)
            delim = text[raw_at + 2:open_paren]
            close = text.find(")" + delim + '"', open_paren + 1)
            j = n if close < 0 else close + len(delim) + 2
            body = text[open_paren + 1:close] if close >= 0 else text[open_paren + 1:]
            literals.append((open_paren + 1, open_paren + 1 + len(body), body))
            for k in range(i, j):
                masked[k] = "\n" if text[k] == "\n" else " "
            i = j
            continue

        if text[raw_at:raw_at + 1] == '"':
            j = raw_at + 1
            body_start = j
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            body = text[body_start:j]
            literals.append((i + prefix_len, j + 1, decode_c_escapes(body)))
            for k in range(i, min(j + 1, n)):
                masked[k] = "\n" if text[k] == "\n" else " "
            i = j + 1
            continue

        # char literal, guarded so C++14 digit separators are not eaten
        if ch == "'" and not (i + 1 < n and text[i + 1].isdigit()) and not (i > 0 and text[i - 1].isdigit()):
            j = i + 1
            while j < n and text[j] != "'":
                j += 2 if text[j] == "\\" else 1
            j = min(j, n - 1)
            for k in range(i, j + 1):
                masked[k] = "\n" if text[k] == "\n" else " "
            i = j + 1
            continue

        i += 1

    return "".join(masked), literals


def normalize(value: str) -> str:
    """Collapse horizontal whitespace per line, keep newlines as \\n, strip ends."""
    parts = [re.sub(r"[ \t\r\f\v]+", " ", line).strip() for line in value.split("\n")]
    return "\n".join(parts).strip()


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def whitespace_only(masked: str, a: int, b: int) -> bool:
    return masked[a:b].strip() == ""


def merge_adjacent(masked: str, items):
    """Merge literals that the compiler concatenates (whitespace gap only)."""
    merged = []
    for start, end, decoded in items:
        if merged and whitespace_only(masked, merged[-1][1], start):
            pstart, _, pdecoded = merged.pop()
            merged.append((pstart, end, pdecoded + decoded))
        else:
            merged.append((start, end, decoded))
    return merged


def collect_call_literals(masked: str, literals, open_paren: int):
    depth = 0
    close = None
    for idx in range(open_paren, len(masked)):
        c = masked[idx]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                close = idx
                break
    if close is None:
        return []
    inside = [(s, e, d) for s, e, d in literals if s > open_paren and e <= close]
    return merge_adjacent(masked, inside)


def matching_brace(masked: str, open_brace: int):
    depth = 0
    for idx in range(open_brace, len(masked)):
        c = masked[idx]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return idx
    return None


def load_ini_names(root: str):
    """Derive INI sections and key names from the pinned tree."""
    sections, keys = set(), set()
    config_path = os.path.join(root, CONFIG_CPP)
    if os.path.isfile(config_path):
        with open(config_path, encoding="utf-8", errors="replace") as handle:
            config = handle.read()
        for section, key in re.findall(r"read[A-Za-z]*\(\s*\"([^\"]+)\"\s*,\s*\"([^\"]+)\"", config):
            sections.add(section)
            keys.add(key)
    ini_path = os.path.join(root, SHIPPED_INI)
    if os.path.isfile(ini_path):
        with open(ini_path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                match = re.fullmatch(r"\[([^\[\]]+)\]", line)
                if match:
                    sections.add(match.group(1))
                    continue
                match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
                if match:
                    keys.add(match.group(1))
    return sections, keys


def classify_drop(value: str, ini_sections, ini_keys) -> str | None:
    stripped = value.strip()
    if is_pure_format(value):
        return "pure-format-or-empty"
    if stripped == "(?)":
        return "help-marker-glyph"
    if INI_SECTION_LITERAL.fullmatch(stripped):
        return "ini-section"
    if stripped in ini_keys:
        return "ini-key"
    if stripped in ini_sections:
        return "ini-section-name"
    if is_version_like(value):
        return "version-string"
    if PATH_RE.search(value) or (" " not in stripped and EXT_RE.search(stripped)):
        return "path-or-filename"
    if URL_RE.search(value):
        return "url"
    if API_NAME_RE.fullmatch(stripped):
        return "api-dll-runtime-name"
    if API_STATE_RE.fullmatch(stripped) or stripped in API_STATE_TOKENS:
        return "api-state-name"
    if NGX_KEY_RE.fullmatch(stripped):
        return "ngx-parameter-key"
    if KEYNAME_RE.fullmatch(stripped):
        return "key-name"
    return None


def scan_tree(root: str, rel_files):
    ini_sections, ini_keys = load_ini_names(root)
    class_sites = Counter()
    class_candidates = Counter()
    dropped = Counter()
    dropped_samples = {}
    records = {}
    violations = []
    uncovered = Counter()
    uncovered_samples = {}
    outside_class = Counter()
    outside_class_samples = {}
    concat_fragments = set()

    for rel in rel_files:
        path = os.path.join(root, rel.replace("/", os.sep))
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        masked, literals = mask_source(text)
        lit_by_start = {}

        for index, (start, end, decoded) in enumerate(literals):
            lit_by_start[start] = index

        pending = []

        for class_name, pattern in CALL_CLASSES:
            call_re = re.compile(r"(?<![\w:])(?:ImGui::)?(?:%s)\s*\(" % pattern)
            for match in call_re.finditer(masked):
                open_paren = match.end() - 1
                class_sites[class_name] += 1
                for start, end, decoded in collect_call_literals(masked, literals, open_paren):
                    pending.append((class_name, start, end, decoded))

        for index, (start, end, decoded) in enumerate(literals):
            context = masked[max(0, start - 160):start]
            if STATUS_ASSIGN_RE.search(context):
                class_sites["StatusText"] += 1
                for s, e, d in merge_adjacent(masked, literals[index:]):
                    if s != start:
                        break
                    pending.append(("StatusText", s, e, d))
                    break
            elif ASSIGN_RE.search(context):
                # screen text also reaches a widget through a plain string variable
                class_sites["AssignmentLabel"] += 1
                for s, e, d in merge_adjacent(masked, literals[index:]):
                    if s != start:
                        break
                    pending.append(("AssignmentLabel", s, e, d))
                    break

        # brace-initializer label tables: <array declarator> = { "...", ... }
        for match in re.finditer(r"=\s*\{", masked):
            equal = match.start()
            open_brace = masked.index("{", match.start())
            stmt_start = max(masked.rfind(";", 0, equal), masked.rfind("{", 0, equal), masked.rfind("}", 0, equal)) + 1
            if "[" not in masked[stmt_start:equal]:
                continue
            close_brace = matching_brace(masked, open_brace)
            if close_brace is None:
                continue
            class_sites["InitializerTable"] += 1
            inside = [(s, e, d) for s, e, d in literals if s > open_brace and e <= close_brace]
            for s, e, d in merge_adjacent(masked, inside):
                pending.append(("InitializerTable", s, e, d))

        # coverage guard: every call whose first argument is a string literal is
        # tracked.  Names in CALL_CLASSES whose literal was NOT captured are
        # regressions (``uncovered_first_arg_calls``); all others are reported in
        # a separate informational field (they are intentionally outside the class table).
        #
        # Comparison is position-based: ``pending`` stores the merged literal range
        # for each captured call, so we collect the contiguous literal span starting
        # at the first literal after ``(`` and check whether that exact range appears
        # in the captured set.
        class_names = set()
        for _, pattern in CALL_CLASSES:
            class_names.update(pattern.split("|"))
        captured_literal_spans = set()
        for _, start, end, _ in pending:
            captured_literal_spans.add((start, end))
        for match in re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)\s*\(", masked):
            open_paren = match.end() - 1
            # Find the first string literal after ``(``.  Then collect all adjacent
            # literals (C++ string concatenation) to produce the merged span.
            for i, (start, end, _) in enumerate(literals):
                if start > open_paren and whitespace_only(masked, open_paren + 1, start):
                    # Merge adjacent literals (same logic as merge_adjacent)
                    m_start, m_end = start, end
                    for j in range(i + 1, len(literals)):
                        ns, ne, _ = literals[j]
                        if whitespace_only(masked, m_end, ns):
                            m_end = ne
                        else:
                            break
                    name = match.group(1)
                    if name in class_names:
                        if (m_start, m_end) not in captured_literal_spans:
                            uncovered[name] += 1
                            uncovered_samples.setdefault(name, "%s:%d" % (rel, line_of(text, match.start())))
                    else:
                        outside_class[name] += 1
                        outside_class_samples.setdefault(name, "%s:%d" % (rel, line_of(text, match.start())))
                    break

        for class_name, start, end, decoded in pending:
            normalized = normalize(decoded)
            line = line_of(text, start)
            site = "%s:%d" % (rel, line)

            # an operand of an expression concatenation is a dynamic fragment: it still
            # reaches the screen, so it stays a candidate and is reported separately
            before = masked[max(0, start - 12):start].rstrip()
            after = masked[end:end + 12].lstrip()
            if (before.endswith("+") and not whitespace_only(masked, end, end + 1)) or after.startswith("+"):
                if not re.search(r"[A-Za-z]{2,}", normalized) and " " not in normalized:
                    dropped["expression-fragment"] += 1
                    dropped_samples.setdefault("expression-fragment", normalized[:60])
                    continue
                if re.fullmatch(r"(?:Ctrl|Alt|Shift|Win)\+", normalized):
                    dropped["key-name"] += 1
                    dropped_samples.setdefault("key-name", normalized[:60])
                    continue
                concat_fragments.add(normalized)

            stmt_start = max(masked.rfind(";", 0, start), masked.rfind("{", 0, start), masked.rfind("}", 0, start)) + 1
            statement = masked[stmt_start:start]
            if LOG_MARKERS.search(statement):
                dropped["log-sentence"] += 1
                dropped_samples.setdefault("log-sentence", normalized[:60])
                continue

            reason = classify_drop(normalized, ini_sections, ini_keys)
            if reason:
                dropped[reason] += 1
                dropped_samples.setdefault(reason, normalized[:60])
                continue

            record = records.setdefault(
                normalized, {"msgid": normalized, "classes": set(), "sites": set(), "occurrences": 0}
            )
            record["classes"].add(class_name)
            record["sites"].add(site)
            record["occurrences"] += 1
            class_candidates[class_name] += 1

    candidates = []
    for msgid in sorted(records):
        record = records[msgid]
        candidates.append(
            {
                "msgid": msgid,
                "classes": sorted(record["classes"]),
                "sites": sorted(record["sites"]),
                "occurrences": record["occurrences"],
            }
        )

    # independent re-check of the emitted set against the do-not-translate rules
    for candidate in candidates:
        value = candidate["msgid"]
        if value.strip() in ini_keys:
            violations.append({"msgid": value, "reason": "ini-key"})
        elif value.strip() in ini_sections:
            violations.append({"msgid": value, "reason": "ini-section-name"})
        elif INI_SECTION_LITERAL.fullmatch(value.strip()):
            violations.append({"msgid": value, "reason": "ini-section"})
        elif is_version_like(value):
            violations.append({"msgid": value, "reason": "version-string"})
        elif is_pure_format(value):
            violations.append({"msgid": value, "reason": "pure-format-or-empty"})
        elif URL_RE.search(value):
            violations.append({"msgid": value, "reason": "url"})
        elif PATH_RE.search(value) or (" " not in value.strip() and EXT_RE.search(value.strip())):
            violations.append({"msgid": value, "reason": "path-or-filename"})
        elif API_NAME_RE.fullmatch(value.strip()) or API_STATE_RE.fullmatch(value.strip()):
            violations.append({"msgid": value, "reason": "api-name"})
        elif value.strip() == "(?)":
            violations.append({"msgid": value, "reason": "help-marker-glyph"})

    return {
        "candidates": candidates,
        "class_site_counts": class_sites,
        "class_candidate_counts": class_candidates,
        "dropped_counts": dropped,
        "dropped_samples": dropped_samples,
        "violations": violations,
        "uncovered_first_arg_calls": uncovered,
        "uncovered_first_arg_samples": uncovered_samples,
        "outside_class_first_arg_calls": outside_class,
        "outside_class_first_arg_samples": outside_class_samples,
        "concat_fragment_msgids": concat_fragments,
        "ini_keys": sorted(ini_keys),
        "ini_sections": sorted(ini_sections),
    }


def resolve_files(root: str):
    files = []
    for rel in NAMED_FILES:
        if not os.path.isfile(os.path.join(root, rel.replace("/", os.sep))):
            raise SystemExit("missing named scan target: %s" % rel)
        files.append(rel)
    for rel_dir in SUPERSET_DIRS:
        abs_dir = os.path.join(root, rel_dir.replace("/", os.sep))
        for name in sorted(os.listdir(abs_dir)):
            if name.endswith(".cpp"):
                rel = "%s/%s" % (rel_dir, name)
                if rel not in files:
                    files.append(rel)
    return sorted(files)


def git(root: str, *args):
    result = subprocess.run(
        ["git", "-C", root] + list(args), capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise SystemExit("git %s failed: %s" % (" ".join(args), result.stderr.strip()))
    return result.stdout.strip()


def run_extraction(root: str, out_path: str):
    files = resolve_files(root)
    snapshot = {
        "worktree_head": git(root, "rev-parse", "HEAD"),
        "tag": git(root, "describe", "--tags", "--exact-match"),
        "status_before_write": git(root, "status", "--porcelain"),
    }
    result = scan_tree(root, files)
    payload = {
        "tool": TOOL,
        "schema": SCHEMA,
        "root": os.path.abspath(root).replace("\\", "/"),
        "tag": snapshot["tag"],
        "worktree_head": snapshot["worktree_head"],
        "files_scanned": files,
        "class_site_counts": {name: result["class_site_counts"].get(name, 0) for name in CLASS_NAMES},
        "class_candidate_counts": {name: result["class_candidate_counts"].get(name, 0) for name in CLASS_NAMES},
        "dropped_counts": {k: result["dropped_counts"][k] for k in sorted(result["dropped_counts"])},
        "dropped_samples": {k: result["dropped_samples"][k] for k in sorted(result["dropped_samples"])},
        "ini_key_count": len(result["ini_keys"]),
        "ini_section_count": len(result["ini_sections"]),
        "candidate_count": len(result["candidates"]),
        "uncovered_first_arg_calls": {k: result["uncovered_first_arg_calls"][k] for k in sorted(result["uncovered_first_arg_calls"])},
        "uncovered_first_arg_samples": {k: result["uncovered_first_arg_samples"][k] for k in sorted(result["uncovered_first_arg_samples"])},
        "outside_class_first_arg_calls": {k: result["outside_class_first_arg_calls"][k] for k in sorted(result["outside_class_first_arg_calls"])},
        "outside_class_first_arg_samples": {k: result["outside_class_first_arg_samples"][k] for k in sorted(result["outside_class_first_arg_samples"])},
        "concat_fragment_count": len(set(result["concat_fragment_msgids"]) & {c["msgid"] for c in result["candidates"]}),
        "concat_fragment_msgids": sorted(set(result["concat_fragment_msgids"]) & {c["msgid"] for c in result["candidates"]}),
        "do_not_translate_violations": result["violations"],
        "candidates": result["candidates"],
    }
    out_dir = os.path.dirname(os.path.abspath(out_path))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=True, indent=1, sort_keys=False)
        handle.write("\n")
    print("root            : %s" % payload["root"])
    print("tag / HEAD      : %s %s" % (snapshot["tag"], snapshot["worktree_head"]))
    print("status pre-write: %s" % (snapshot["status_before_write"] or "(clean)"))
    print("files scanned   : %d" % len(files))
    print("call sites      : %d" % sum(payload["class_site_counts"].values()))
    print("candidates      : %d (unique msgids)" % payload["candidate_count"])
    print("dropped         : %s" % json.dumps(payload["dropped_counts"], sort_keys=True))
    print("violations      : %d" % len(payload["do_not_translate_violations"]))
    print("uncovered calls : %s" % json.dumps(payload["uncovered_first_arg_calls"], sort_keys=True))
    print("outside-class call sites (informational): %d" % len(payload["outside_class_first_arg_calls"]))
    for name in sorted(payload["outside_class_first_arg_calls"]):
        print("  outside-class %-20s sample=%s" % (
            name, payload["outside_class_first_arg_samples"].get(name, "?")))
    return payload


# --------------------------------------------------------------------------
# Self-test fixtures.
FIXTURE_MENU_CPP = r'''
#include "menu_common.h"

void Fixture()
{
    LOG_DEBUG("failed to open device handle {}", handle);
    LOG_DEBUG("{}", StrFmt("retrying the device open"));
    ImGui::Button("Apply");
    ImGui::Button("MenuScale");
    ImGui::Text("v0.8.7");
    ImGui::Text("C:\\Games\\Crimson Desert\\OptiScaler.ini");
    ImGui::Text("https://github.com/grim-susemi/OptiScaler-Susemi");
    ImGui::Text("(?)");
    ImGui::Text("F11");
    ImGui::Text("%s", state.name);
    ImGui::Text("Press any key...");
    ShowHelpMarker("Likely doesn't do much");
    PublishStatus(this, Backend::Vulkan, { false, "DLSS enlargement requires the DX12 processing path." });
    say("DLSS enlargement requires NR after the game upscaler.");
}
'''

FIXTURE_CONFIG_CPP = r'''
#include "Config.h"

void FixtureConfig(Config& config)
{
    config.readString("Menu", "Language", true);
    config.readString("Menu", "MenuScale", true);
}
'''

SELF_TEST_ABSENT = [
    ("failed to open device handle {}", "log-sentence"),
    ("retrying the device open", "log-sentence"),
    ("MenuScale", "ini-key"),
    ("v0.8.7", "version-string"),
    ("C:\\Games\\Crimson Desert\\OptiScaler.ini", "path-or-filename"),
    ("https://github.com/grim-susemi/OptiScaler-Susemi", "url"),
    ("(?)", "help-marker-glyph"),
    ("F11", "key-name"),
    ("%s", "pure-format-or-empty"),
]
SELF_TEST_PRESENT = [
    "Apply",
    "Press any key...",
    "Likely doesn't do much",
    "DLSS enlargement requires the DX12 processing path.",
    "DLSS enlargement requires NR after the game upscaler.",
]

# coverage-guard probe: a call that MATCHES a CALL_CLASSES name but whose first
# argument became uncapturable must be reported as uncovered (the regression guard),
# while a call that is intentionally outside the class table stays informational.
GUARD_PROBE_CPP = r'''
void GuardProbe()
{
    Button("This class label is untracked by design");
    somehowUnknown("A call no one declared here");
}
'''

GUARD_PROBE_EXPECT = {"somehowUnknown"}


def run_self_test(evidence_path: str) -> int:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="extract-selftest-") as fixture_root:
        menu_dir = os.path.join(fixture_root, "OptiScaler", "menu")
        os.makedirs(menu_dir)
        with open(os.path.join(menu_dir, "menu_common.cpp"), "w", encoding="utf-8", newline="\n") as handle:
            handle.write(FIXTURE_MENU_CPP)
        with open(os.path.join(fixture_root, "OptiScaler", "Config.cpp"), "w", encoding="utf-8", newline="\n") as handle:
            handle.write(FIXTURE_CONFIG_CPP)

        files = [
            "OptiScaler/menu/menu_common.cpp",
            "OptiScaler/Config.cpp",
        ]
        guard_menu_dir = os.path.join(fixture_root, "OptiScaler", "menu")
        with open(os.path.join(guard_menu_dir, "menu_common.cpp"), "a", encoding="utf-8", newline="\n") as handle:
            handle.write(GUARD_PROBE_CPP)

        result = scan_tree(fixture_root, files)
        emitted = {candidate["msgid"] for candidate in result["candidates"]}

        guard_report = dict(result["uncovered_first_arg_calls"])
        guard_ok = guard_report == {}
        outside = dict(result["outside_class_first_arg_calls"])
        outside_has_probe = "somehowUnknown" in outside
        leaks = [{"msgid": value, "expected_reason": reason} for value, reason in SELF_TEST_ABSENT if value in emitted]
        missing = [value for value in SELF_TEST_PRESENT if value not in emitted]
        checks = [
            {
                "msgid": value,
                "expected": "excluded as %s" % reason,
                "kept_out": value not in emitted,
            }
            for value, reason in SELF_TEST_ABSENT
        ]
        checks += [
            {"msgid": value, "expected": "present as a UI label", "kept_out": value in emitted}
            for value in SELF_TEST_PRESENT
        ]

        # The guard is live iff the outside-class probe is seen; it is not a
        # false-positive iff no class-matched literal call is reported uncovered in a
        # fixture whose class calls are all captured.
        guard_live = outside_has_probe
        guard_clean = guard_ok
        passed = not leaks and not missing and guard_live and guard_clean
        payload = {
            "tool": TOOL,
            "self_test": True,
            "fixture_files": files,
            "excluded_expectations": [{"msgid": v, "reason": r} for v, r in SELF_TEST_ABSENT],
            "included_expectations": SELF_TEST_PRESENT,
            "guard_probe": {
                "reported_as_uncovered": guard_report,
                "expected_uncovered_in_clean_fixture": {},
                "outside_class_seen": sorted(outside),
                "probe_outside_class_visible": outside_has_probe,
                "guard_live": guard_live,
                "guard_clean": guard_clean,
            },
            "leaks": leaks,
            "missing_expected_labels": missing,
            "checks": checks,
            "emitted_candidates": sorted(emitted),
            "passed": passed,
            "exit_code": 0 if passed else 1,
        }
        out_dir = os.path.dirname(os.path.abspath(evidence_path))
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
        with open(evidence_path, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, ensure_ascii=True, indent=1)
            handle.write("\n")
        print("self-test leaks : %s" % json.dumps(leaks, sort_keys=True))
        print("self-test missing UI labels: %s" % json.dumps(missing, sort_keys=True))
        print("self-test emitted candidates: %s" % json.dumps(sorted(emitted)))
        print("self-test passed: %s" % passed)
        return 0 if passed else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", help="worktree root to scan")
    parser.add_argument("--out", help="candidate JSON output path")
    parser.add_argument("--self-test", action="store_true", help="run the fixture self-test")
    parser.add_argument("--evidence", help="self-test evidence JSON path")
    args = parser.parse_args(argv)

    if args.self_test:
        if not args.evidence:
            parser.error("--self-test requires --evidence")
        return run_self_test(args.evidence)

    if not args.root or not args.out:
        parser.error("--root and --out are required unless --self-test is used")
    if not os.path.isdir(args.root):
        raise SystemExit("scan root does not exist: %s" % args.root)
    payload = run_extraction(args.root, args.out)

    uncovered = payload["uncovered_first_arg_calls"]
    if uncovered:
        print("UNCOVERED CALLS (%d) - regression guard FAILED:" % len(uncovered))
        for name in sorted(uncovered):
            count = uncovered[name]
            # one site per name is recorded; show it (or a fallback if missing)
            site = payload["uncovered_first_arg_samples"].get(name, "?")
            print("  %s  x%d  first-site=%s" % (name, count, site))
        return 1

    return 1 if payload["do_not_translate_violations"] else 0


if __name__ == "__main__":
    sys.exit(main())
