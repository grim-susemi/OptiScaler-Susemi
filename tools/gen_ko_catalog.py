#!/usr/bin/env python3
"""Row 2 of .omo/plans/susemi-next-ui-lang.md: generate the KO catalog include.

Reads the authored catalog `OptiScaler/menu/locales/ko.json` and emits
`OptiScaler/menu/locales/ko_catalog.inc` as pure ASCII with octal UTF-8 escapes,
so the build needs no /utf-8 flag, no BOM and no source-encoding dependency.

Deterministic by construction: sorted keys, no timestamps, LF endings, so two
runs over the same catalog are byte-identical.

Key space
---------
Keys are the *display* msgid: the English label with any "##id" suffix removed,
which is exactly the range the ImGui draw/measure seams hand to a lookup.
A NUL-separated item list (the ImGui combo item string) is expanded into one
entry per element. A label that is nothing but a "##id" has no display range and
therefore no entry.

Usage:
  python tools/gen_ko_catalog.py --catalog <ko.json> --out <ko_catalog.inc>
  python tools/gen_ko_catalog.py --catalog <ko.json> --out <inc> --check
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

TOOL = "tools/gen_ko_catalog.py"
INC_HEADER = '// OptiScaler/menu/locales/ko_catalog.inc'
ARRAY_NAME = "kLocalizationEntries_ko"
COUNT_NAME = "kLocalizationEntryCount_ko"
ENTRY_TYPE = "LocalizationEntry"


# --------------------------------------------------------------------------
# Key space.
def display_msgid(raw: str) -> str:
    """The range ImGui hands to the draw/measure layer: no "##id", trimmed."""
    hash_at = raw.find("##")
    text = raw if hash_at < 0 else raw[:hash_at]
    return text.strip()


def candidate_keys(candidates):
    """Expand the row-1 candidate records into the expected display-key set.

    Returns (keys, id_only). `id_only` holds candidates whose display range is
    empty, so no lookup can ever reach the catalog.
    """
    keys = set()
    id_only = []
    for record in candidates:
        msgid = record["msgid"] if isinstance(record, dict) else str(record)
        if "\0" in msgid:
            parts = [display_msgid(part) for part in msgid.split("\0")]
        else:
            parts = [display_msgid(msgid)]
        parts = [part for part in parts if part]
        if not parts:
            id_only.append(msgid)
            continue
        keys.update(parts)
    return keys, id_only


# --------------------------------------------------------------------------
# C escaping.
ESCAPES = {
    "\\": "\\\\",
    '"': '\\"',
    "\n": "\\n",
    "\t": "\\t",
    "\r": "\\r",
}
UNESCAPES = {
    "n": "\n",
    "t": "\t",
    "r": "\r",
    "0": "\0",
    "\\": "\\",
    '"': '"',
    "'": "'",
    "a": "\a",
    "b": "\b",
    "f": "\f",
    "v": "\v",
}


def c_string(value: str) -> str:
    """Escape one string as a pure-ASCII C literal body (octal UTF-8)."""
    out = []
    for ch in value:
        if ch in ESCAPES:
            out.append(ESCAPES[ch])
        elif 0x20 <= ord(ch) < 0x7F:
            out.append(ch)
        else:
            for byte in ch.encode("utf-8"):
                out.append("\\%03o" % byte)
    return "".join(out)


def decode_c_string(body: str) -> str:
    """Inverse of c_string for the octal/escape subset it emits.

    Octal escapes carry raw UTF-8 bytes, so the result is assembled as bytes and
    decoded once: a multi-byte Korean glyph must come back as one character.
    """
    out = bytearray()
    i = 0
    while i < len(body):
        ch = body[i]
        if ch != "\\" or i + 1 >= len(body):
            out.extend(ch.encode("utf-8"))
            i += 1
            continue
        nxt = body[i + 1]
        if nxt in UNESCAPES:
            out.extend(UNESCAPES[nxt].encode("utf-8"))
            i += 2
            continue
        match = re.match(r"([0-7]{1,3})", body[i + 1:])
        if match:
            out.append(int(match.group(1), 8))
            i += 1 + len(match.group(0))
            continue
        out.extend(nxt.encode("utf-8"))
        i += 2
    return out.decode("utf-8")


# --------------------------------------------------------------------------
# Catalog I/O.
class CatalogError(Exception):
    pass


def load_catalog(path: str):
    """Load ko.json, refusing duplicate keys silently collapsing."""
    with open(path, encoding="utf-8") as handle:
        text = handle.read()

    duplicates = []

    def pairs_hook(pairs):
        seen = {}
        for key, value in pairs:
            if key in seen:
                duplicates.append(key)
            seen[key] = value
        return seen

    data = json.loads(text, object_pairs_hook=pairs_hook)
    if duplicates:
        raise CatalogError("duplicate msgid in catalog: %s" % ", ".join(sorted(set(duplicates))))
    if not isinstance(data, dict):
        raise CatalogError("catalog must be a JSON object")
    entries = data.get("entries")
    if not isinstance(entries, dict):
        raise CatalogError("catalog is missing an 'entries' object")
    return data, entries


def ini_names(root: str):
    """INI sections and key names.

    A catalog msgid that doubles as an INI name (the shipped ini has DLSS, XeSS
    and FSR as section names, and Style as a key) is never translated: it must
    map to itself, so the string that reaches the display layer and the string
    that names a section stay the same token.
    """
    sections, keys = set(), set()
    config = os.path.join(root, "OptiScaler", "Config.cpp")
    if os.path.isfile(config):
        with open(config, encoding="utf-8", errors="replace") as handle:
            body = handle.read()
        for section, key in re.findall(r"read[A-Za-z]*\(\s*\"([^\"]+)\"\s*,\s*\"([^\"]+)\"", body):
            sections.add(section)
            keys.add(key)
    ini = os.path.join(root, "OptiScaler.ini")
    if os.path.isfile(ini):
        with open(ini, encoding="utf-8", errors="replace") as handle:
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


# --------------------------------------------------------------------------
# Emission.
def render_inc(entries: dict) -> str:
    lines = [
        INC_HEADER,
        "// GENERATED by %s from locales/ko.json. Do not edit by hand." % TOOL,
        "// Pure ASCII, octal UTF-8 escapes: no BOM, no /utf-8 flag, no codepage dependency.",
        "//",
        "// The including translation unit must provide:",
        "//   struct %s { const char* source; const char* text; };" % ENTRY_TYPE,
        "// The lookup key is the display range ImGui receives: the English label with any",
        '// "##id" suffix removed, trimmed. A missing key returns the original pointer, so',
        "// English behaviour is identical by construction. Entries are sorted by source.",
        "static const %s %s[] = {" % (ENTRY_TYPE, ARRAY_NAME),
    ]
    for msgid in sorted(entries):
        lines.append('    { "%s", "%s" },' % (c_string(msgid), c_string(entries[msgid])))
    lines.append("};")
    lines.append("static const unsigned %s = %uu;" % (COUNT_NAME, len(entries)))
    lines.append("")
    return "\n".join(lines)


def parse_inc(text: str):
    """Read back (source, text) pairs plus the declared count from a generated inc."""
    pairs = []
    for match in re.finditer(r'\{\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\}', text):
        pairs.append((decode_c_string(match.group(1)), decode_c_string(match.group(2))))
    count_match = re.search(r"static const unsigned %s = (\d+)u;" % COUNT_NAME, text)
    count = int(count_match.group(1)) if count_match else None
    return pairs, count


# --------------------------------------------------------------------------
def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="generate the KO catalog include")
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--check", action="store_true", help="compare instead of write")
    parser.add_argument("--root", default=None, help="tree root for the INI-name guard")
    args = parser.parse_args(argv)

    try:
        _, entries = load_catalog(args.catalog)
    except CatalogError as error:
        print("FAIL %s: %s" % (args.catalog, error))
        return 1

    root = args.root or os.getcwd()
    sections, keys = ini_names(root)
    offenders = sorted(
        msgid for msgid, value in entries.items()
        if (msgid in keys or msgid in sections) and value != msgid
    )
    if offenders:
        print("FAIL catalog translates INI keys or sections: %s" % ", ".join(offenders))
        return 1

    rendered = render_inc(entries)

    if args.check:
        with open(args.out, "rb") as handle:
            existing = handle.read()
        if existing != rendered.encode("ascii"):
            print("FAIL %s does not match a fresh generation" % args.out)
            return 1
        print("OK %s matches a fresh generation (%d entries)" % (args.out, len(entries)))
        return 0

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "wb") as handle:
        handle.write(rendered.encode("ascii"))
    print("wrote %s: %d entries, %d bytes" % (args.out, len(entries), len(rendered)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
