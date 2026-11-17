"""Repack the verified v11.4 layout with committed v11.5 sources and one built core."""

import argparse
import hashlib
import json
import re
import struct
import subprocess
import zipfile
from pathlib import Path
from typing import Final

BASE_SHA: Final = "d26fcfa69736ea06a1be3f42657f6ee5da4df1284e10adc69d84f6acd4eed759"
CORE_SHA: Final = "e050434cd054ebe0ea43882ff60c2f96755fcc9396fcdd7f709649967469feef"
NAME: Final = "OptiScaler-NR-v11.5.zip"
SOURCES: Final = (
    "Install_OptiScaler_windows.bat",
    "INSTALL-ONECLICK.md",
    "setup_windows.bat",
    "tools/susemi_installer.ps1",
    "tools/susemi_transaction.ps1",
    "tools/susemi_stage_helpers.ps1",
    "Streamline_fetcher_windows.bat",
    "tools/Get-StreamlineRuntime.ps1",
    "docs/CREDITS.md",
)
PRIVATE: Final = re.compile(
    rb"(?:[cC]:[/\\](?:[uU]sers[/\\]USER|omo-research)|"
    rb"ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|"
    rb"sk-[A-Za-z0-9]{30,}|AKIA[A-Z0-9]{16})", re.I
)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(repo: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(repo), *args])


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--base", required=True, type=Path)
    parser.add_argument("--core", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    repo: Path = args.repo
    base: Path = args.base
    core_path: Path = args.core
    out: Path = args.out
    revision = git(repo, "rev-parse", "HEAD").decode().strip()
    require(not git(repo, "status", "--porcelain", "--untracked-files=no").strip(),
            "Commit the validated source before packaging")
    require(sha(base.read_bytes()) == BASE_SHA, "Wrong v11.4 base archive")
    core = core_path.read_bytes()
    require(sha(core) == CORE_SHA, "Wrong unified v11.5 core")
    pe = struct.unpack_from("<I", core, 0x3C)[0]
    require(core[:2] == b"MZ" and core[pe:pe + 4] == b"PE\0\0"
            and struct.unpack_from("<H", core, pe + 4)[0] == 0x8664,
            "Core must be an x64 PE")
    require(b"v11.5-unified-lag-extent" in core
            or "v11.5-unified-lag-extent".encode("utf-16le") in core,
            "Release build marker missing")

    with zipfile.ZipFile(base) as archive:
        require(len(archive.namelist()) == 27 and archive.testzip() is None,
                "Unexpected v11.4 archive layout")
        payload = {name: archive.read(name) for name in archive.namelist()}
    # The superseded NR readme referred to the old manual installation flow.
    del payload["OptiScaler/dlssnr/README.md"]
    payload["OptiScaler.dll"] = core
    for name in SOURCES:
        data = git(repo, "show", f"{revision}:{name}")
        if name in payload and data.replace(b"\r\n", b"\n") == payload[name].replace(b"\r\n", b"\n"):
            data = payload[name]
        # cmd.exe batch parsing, particularly labels, requires the Windows transport.
        if name.lower().endswith(".bat"):
            data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        payload[name] = data
    require(CORE_SHA.encode() in payload["tools/susemi_installer.ps1"],
            "Installer core pin differs from the built artifact")
    payload["RELEASE-MANIFEST.json"] = (json.dumps({
        "version": "v11.5",
        "repository": "https://github.com/grim-susemi/OptiScaler-Susemi",
        "source_commit": revision,
        "base_archive_sha256": BASE_SHA,
        "core_sha256": CORE_SHA,
        "core_build_label": "v11.5-unified-lag-extent",
        "integrated_gpu_gameplay_tested": False,
        "nvidia_model_binaries_bundled": False,
        "windows_batch_line_endings": "CRLF",
    }, indent=2) + "\n").encode()
    del payload["SHA256SUMS.txt"]
    for name, data in payload.items():
        if name.lower().endswith(".bat"):
            require(re.search(rb"(?<!\r)\n", data) is None,
                    f"Non-Windows batch transport: {name}")
        require(".." not in Path(name).parts and not name.startswith(("/", "\\")),
                f"Unsafe member: {name}")
        require(not re.search(r"(?:^|/)(?:tests?|external|SDK|\.git|\.omo)(?:/|$)"
                              r"|\.(?:pdb|obj|lib|log|exp)$|nvngx_.*\.dll$|sm86", name, re.I),
                f"Forbidden release member: {name}")
        require(not PRIVATE.search(data)
                and not PRIVATE.search(data.replace(b"\0", b"")),
                f"Private path or secret pattern in: {name}")
    payload["SHA256SUMS.txt"] = "".join(
        f"{sha(payload[name]).upper()} *{name}\r\n" for name in sorted(payload)
    ).encode("ascii")
    require(len(payload) == 30, "Unexpected final package layout")
    out.mkdir(parents=True, exist_ok=True)
    target = out / NAME
    require(not target.exists(), "Refusing to overwrite a prior release artifact")
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9) as archive:
        for name in sorted(payload):
            info = zipfile.ZipInfo(name, (2026, 11, 17, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, payload[name])
    with zipfile.ZipFile(target) as archive:
        require(archive.testzip() is None and set(archive.namelist()) == set(payload),
                "ZIP round-trip failed")
    digest = sha(target.read_bytes())
    (out / "SHA256SUMS.txt").write_text(f"{digest} *{NAME}\n", encoding="ascii")
    print(f"REPACK_V115_RESULT members={len(payload)} sha256={digest} source={revision}")


if __name__ == "__main__":
    main()
