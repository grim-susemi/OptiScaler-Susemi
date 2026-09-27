#!/usr/bin/env python3
"""Row 3 (susemi-next-ui-lang): extract the production bodies the seam runner compiles.

The runner must exercise the real label-key path and the real INI statements
instead of a copied predicate, so this tool lifts them verbatim out of the
production sources and writes them to include files:

  production-seam.inc            DlssNr::MenuSections::Slider / DeferredSlider
                                 (the R7 label-key path) from DlssNr_MenuControls.cpp
  production-config-read.inc     Config::readString from Config.cpp
  production-config-language.inc the [Menu] Language load and save statements,
                                 wrapped as object-like macros

Every extraction is anchored on an exact source marker: if a production line
moves or is edited, this tool fails instead of silently testing stale code.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

# (label, signature that starts the definition, expected content assertion)
MENU_FUNCTIONS = [
    ("Slider", "static void Slider(const char* label, Option& option, float minimum, float maximum, const char* format = \"%.2f\","),
    ("DeferredSlider", "static void DeferredSlider(const char* label, Option* opt, float mn, float mx, float def, bool inheritReset = false)"),
]

CONFIG_READ = "std::optional<std::string> Config::readString(std::string section, std::string key, bool lowercase)"

CONFIG_LANGUAGE_LOAD_MARKER = 'Language.set_from_config(readString("Menu", "Language", true)'
CONFIG_LANGUAGE_SAVE_MARKER = 'ini.SetValue("Menu", "Language",'
CONFIG_LANGUAGE_LOAD_REQUIRED = "Localization::NormalizeLanguageCode));"


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def skip_literal_or_comment(source: str, position: int) -> int | None:
    """If a string/char literal or comment starts at `position`, return the index just past it."""
    char = source[position]
    if char in "\"'":
        position += 1
        while position < len(source) and source[position] != char:
            position += 2 if source[position] == "\\" else 1
        return position + 1
    if source[position : position + 2] == "//":
        end = source.find("\n", position)
        return len(source) if end < 0 else end
    if source[position : position + 2] == "/*":
        end = source.find("*/", position)
        return len(source) if end < 0 else end + 2
    return None


def find_body_start(source: str, index: int) -> int:
    """Return the '{' that opens the definition body, skipping the parameter list."""
    position = source.find("(", index)
    if position < 0:
        raise SystemExit("no parameter list found")
    depth = 0
    while position < len(source):
        skipped = skip_literal_or_comment(source, position)
        if skipped is not None:
            position = skipped
            continue
        if source[position] == "(":
            depth += 1
        elif source[position] == ")":
            depth -= 1
            if depth == 0:
                break
        position += 1
    return source.find("{", position)


def extract_definition(source: str, signature: str, path: str) -> str:
    """Return the definition from its `template`/signature line through its closing brace."""
    index = source.find(signature)
    if index < 0:
        raise SystemExit(f"anchor missing in {path}: {signature}")
    if source.find(signature, index + 1) >= 0:
        raise SystemExit(f"anchor is not unique in {path}: {signature}")

    start = source.rfind("\n", 0, index) + 1
    # A preceding template<...> line (optionally with comments) belongs to the definition.
    probe = start - 1
    for _ in range(4):
        if probe <= 0:
            break
        line_start = source.rfind("\n", 0, probe) + 1
        line = source[line_start:probe].strip()
        if line.startswith("template"):
            start = line_start
            break
        if line == "" or line.startswith("//"):
            probe = line_start - 1
            continue
        break

    # Brace match, skipping string/char literals and comments.
    body_start = find_body_start(source, index)
    if body_start < 0:
        raise SystemExit(f"no body in {path}: {signature}")
    depth = 0
    position = body_start
    while position < len(source):
        skipped = skip_literal_or_comment(source, position)
        if skipped is not None:
            position = skipped
            continue
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                return source[start : position + 1]
        position += 1
    raise SystemExit(f"unterminated body in {path}: {signature}")


def extract_statement(source: str, marker: str, path: str, required: str = "") -> str:
    """Return the single statement line that contains `marker`, trimmed, ending at ';'."""
    hits = source.count(marker)
    if hits != 1:
        raise SystemExit(f"marker must appear exactly once in {path}: {marker} (found {hits})")
    start = source.rfind("\n", 0, source.find(marker)) + 1
    end = source.find("\n", source.find(marker))
    if end < 0:
        end = len(source)
    statement = source[start:end].strip()
    if not statement.endswith(";"):
        raise SystemExit(f"statement does not end with ';' in {path}: {statement}")
    if required and required not in statement:
        raise SystemExit(f"statement is missing {required!r} in {path}: {statement}")
    return statement


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--menus", required=True, help="path to DlssNr_MenuControls.cpp")
    parser.add_argument("--config", required=True, help="path to Config.cpp")
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--evidence", help="write a JSON receipt here")
    args = parser.parse_args()

    menus_path = pathlib.Path(args.menus)
    config_path = pathlib.Path(args.config)
    out_dir = pathlib.Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    menus_source = menus_path.read_text(encoding="utf-8")
    config_source = config_path.read_text(encoding="utf-8")

    extracted: dict[str, str] = {}

    blocks = [
        "// GENERATED by tools/i18n_extract_seam.py - do not edit.",
        f"// Verbatim from {menus_path.as_posix()} (DlssNr::MenuSections).",
        "// The runner wraps this include in that namespace and supplies HelpMarker.",
        "",
    ]
    for label, signature in MENU_FUNCTIONS:
        body = extract_definition(menus_source, signature, menus_path.as_posix())
        if "Localization" in body or "Translate" in body or "SetLanguage" in body:
            raise SystemExit(f"{label} now references the localization unit; the identity contract is broken")
        extracted[f"menus::{label}"] = body
        blocks += [f"// --- {label}", body, ""]
    (out_dir / "production-seam.inc").write_text("\n".join(blocks), encoding="ascii", newline="\n")

    read_body = extract_definition(config_source, CONFIG_READ, config_path.as_posix())
    extracted["config::readString"] = read_body
    (out_dir / "production-config-read.inc").write_text(
        "\n".join(
            [
                "// GENERATED by tools/i18n_extract_seam.py - do not edit.",
                f"// Verbatim from {config_path.as_posix()}.",
                f"// --- Config::readString",
                read_body,
                "",
            ]
        ),
        encoding="ascii",
        newline="\n",
    )

    load_statement = extract_statement(
        config_source, CONFIG_LANGUAGE_LOAD_MARKER, config_path.as_posix(), CONFIG_LANGUAGE_LOAD_REQUIRED
    )
    save_statement = extract_statement(config_source, CONFIG_LANGUAGE_SAVE_MARKER, config_path.as_posix())
    extracted["config::[Menu]Language:load"] = load_statement
    extracted["config::[Menu]Language:save"] = save_statement
    (out_dir / "production-config-language.inc").write_text(
        "\n".join(
            [
                "// GENERATED by tools/i18n_extract_seam.py - do not edit.",
                f"// Verbatim statements from {config_path.as_posix()}.",
                "#define I18N_PRODUCTION_LOAD_STATEMENT " + load_statement,
                "#define I18N_PRODUCTION_SAVE_STATEMENT " + save_statement,
                "",
            ]
        ),
        encoding="ascii",
        newline="\n",
    )

    receipt = {
        "tool": "tools/i18n_extract_seam.py",
        "schema": 1,
        "sources": {
            menus_path.as_posix(): sha256_text(menus_source),
            config_path.as_posix(): sha256_text(config_source),
        },
        "extracted": {name: {"sha256": sha256_text(text), "lines": text.count("\n") + 1} for name, text in extracted.items()},
        "outputs": sorted(
            path.name for path in out_dir.iterdir() if path.name.endswith(".inc")
        ),
    }
    print(
        "extracted "
        + ", ".join(f"{name} sha256={digest['sha256'][:12]}" for name, digest in receipt["extracted"].items())
    )
    if args.evidence:
        evidence_path = pathlib.Path(args.evidence)
        evidence_path.parent.mkdir(parents=True, exist_ok=True)
        evidence_path.write_text(json.dumps(receipt, indent=1) + "\n", encoding="ascii", newline="\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
