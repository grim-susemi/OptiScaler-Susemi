#!/usr/bin/env python3
"""Slim one-click installer repack from the reviewed rc2 ZIP.

Builds the slim installer identity (default version tag ``v11.3-installer-a2``)
by taking every rc2 ZIP member byte-exact EXCEPT those in the explicit DELETE
list and regenerating ``SHA256SUMS.txt``. Internal QA provenance stays outside
the user-facing ZIP.

This recipe never publishes anything. It refuses the rc2 identity (rc2 is only
reproducible through ``tools/repack_rc2.py``) and writes only a local ZIP plus the
adjacent one-line release ``SHA256SUMS.txt`` (the ZIP's own digest).

Determinism: kept members keep their original ZipInfo (including ``date_time``);
new / regenerated members use a fixed timestamp, so two runs with identical
inputs produce a byte-identical output ZIP. Any drift in an addition input
between runs changes the recorded per-member SHA and the output ZIP hash.

Machine-readable stdout lines: input-sha=/output-sha=/sums-out=/sums-sha=/members=/removed=/kept=.
Exit 0 ok / 1 refused / 2 invalid invocation.
"""
import argparse
import copy
import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile
import zipfile

# Reviewed byte-exact local rc2 ZIP (owner-observed).
BASE_SHA = '42bac65ff8d9c2ada98cbcfa9c24753f3fe5253d08f7c956a9df977c0e21cc2a'
BASE_NAME = 'OptiScaler-NR-v11.2-rc2.zip'
BASE_MEMBERS = 54

# Owner-observed runtime/loader pins; must survive the repack unchanged.
CORE_MEMBER = 'OptiScaler.dll'
CORE_SHA = '0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60'
UAL_MEMBER = 'tools/asi-loader/Ultimate-ASI-Loader-x64.dll'
UAL_SHA = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'

VERSION = 'v11.3-installer-a2'
OUT_NAME = 'OptiScaler-NR-' + VERSION + '.zip'

MANIFEST = 'SHA256SUMS.txt'

# Explicitly deleted from the package (owner decision 2026-09-28).
# NOTE: setup_windows.bat is NOT here — susemi_installer.ps1 invokes
#   it at `--orchestrated` install time to rename OptiScaler.dll → .asi.
DELETED = {
    '!! EXTRACT ALL FILES TO GAME FOLDER !!',
    'setup_linux.sh',
    'Install_AsiLoader_windows.bat',
    'Streamline_fetcher_windows.bat',
    'Config.md',
    'CONTRIBUTING.md',
    'README.md',
    'INSTALL-KO.md',
    'INSTALL-DLSSNR.md',
    'Spoofing.md',
    'Features.md',
    'OptiScaler.ini',
    # Orphaned tool helpers (parent BATs deleted)
    'tools/Get-StreamlineRuntime.ps1',
    'tools/asi_loader_install.ps1',
}
# Entire docs folder deleted.
for _sub in (
    'docs/CREDITS.md',
    'docs/DEFERRED-NR-DLSS.md',
    'docs/NR-COMPATIBILITY.md',
    'docs/NR-DIRECT-RUNTIME.md',
    'docs/NR-DLSS-ENLARGEMENT.md',
    'docs/NR-FINISHED-BRIDGES.md',
    'docs/NR-GPU-RETIREMENT.md',
    'docs/NR-INITIALIZATION-DIAGNOSTICS.md',
    'docs/NR-MOTION-METADATA.md',
    'docs/NR-NATIVE-STREAMLINE-PRESENT.md',
    'docs/NR-PHOTO-DIAGNOSTIC.md',
    'docs/NR-PIPELINE-UI.md',
    'docs/NR-VULKAN.md',
    'docs/RELEASE-NOTES-r3-KO.md',
    'docs/RELEASE-v0.8.8.md',
    'docs/RELEASE-v11.2-rc2.md',
    'docs/RTX40-MFG.md',
    'docs/XEFG-NR-RESHADE-LOAD-ORDER.md',
):
    DELETED.add(_sub)

# Files from worktree needed by the slim package (previously added by
# repack_installer_candidate.py). read_inputs() verifies these exist + SHA-stable.
SLIM_WORKTREE_INPUTS = (
    'Install_OptiScaler_windows.bat',
    'INSTALL-ONECLICK.md',
    # Three coordinator PS1 scripts from worktree (not in rc2).
    'tools/susemi_installer.ps1',
    'tools/susemi_transaction.ps1',
    'tools/susemi_stage_helpers.ps1',
)

# Base members replaced with the worktree's fixed versions (same rel path).
SLIM_WORKTREE_REPLACEMENTS = (
    'setup_windows.bat',
)

# Regenerated members: content comes from base ZIP, overwritten with new hash set.
REGENERATED = (MANIFEST,)

# Forbidden path fragments (internal tests/evidence).
FORBIDDEN_PATH = ('.omo', 'evidence/', 'journal/', 'tests/')
BAD_BINARY = re.compile(r'(?:sm75|sm86|ampere|nvngx|nvidia|dlssg_for)', re.I)
BAD_MODEL = re.compile(r'\.onnx$', re.I)

FIXED_TS = (2026, 9, 27, 22, 36, 44)
FIXED_ATTR = 0o140000000
SIZE_SANITY = 200 * 1024 * 1024


class InvalidInvocation(Exception):
    """CLI misuse -> exit 2."""


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def check(ok, message):
    if not ok:
        raise ValueError(message)


def names_of(infos, total_max=SIZE_SANITY):
    names = [info.filename for info in infos]
    check(len(names) == len(set(n.casefold() for n in names)), 'duplicate/casefold member')
    for info in infos:
        n = info.filename
        check(n and all(32 <= ord(c) < 127 for c in n) and chr(92) not in n
              and ':' not in n and not n.startswith('/') and not n.endswith('/')
              and all(p not in ('', '.', '..') for p in n.split('/')),
              'unsafe member: ' + repr(n))
        check((info.external_attr >> 16) & 0o170000 != 0o120000, 'symlink member: ' + n)
        check(not BAD_BINARY.search(n) or n == 'tools/Get-StreamlineRuntime.ps1',
              'forbidden B/NVIDIA binary member: ' + n)
        check(not BAD_MODEL.search(n), 'forbidden NR-model member: ' + n)
        check(info.file_size <= total_max, 'implausible member size: ' + n)
    return names


def parse_manifest(data):
    rows = data.splitlines(keepends=True)
    result = {}
    for row in rows:
        m = re.fullmatch(rb'([0-9A-F]{64}) \*([^\r\n]+)\r\n', row)
        check(m is not None, 'invalid manifest row')
        n = m[2].decode('ascii')
        check(n not in result, 'duplicate manifest row: ' + n)
        result[n] = m[1].decode('ascii').lower()
    return result


def read_inputs(root):
    """Read slim worktree inputs; return (bytes dict, sha dict).

    These files weren't in the original rc2 — they were added by the previous
    candidate repack. For the slim variant we pull them back from the worktree.
    """
    check(root.is_dir(), 'root not a directory: ' + str(root))
    blobs, shas = {}, {}
    for rel in SLIM_WORKTREE_INPUTS + SLIM_WORKTREE_REPLACEMENTS:
        check(all(frag not in rel for frag in FORBIDDEN_PATH),
              'forbidden path in input set: ' + rel)
        path = root / rel.replace('/', os.sep)
        check(path.is_file(), 'missing input: ' + rel)
        data = path.read_bytes()
        check(sha(data) == file_sha(path), 'input changed during read: ' + rel)
        blobs[rel] = data
        shas[rel] = sha(data)
    return blobs, shas


def run(base, root, out):
    check(base.is_file(), 'missing base ZIP')
    digest = file_sha(base)
    check(digest == BASE_SHA, 'base rc2 SHA mismatch: ' + digest)
    check(out.name == OUT_NAME, 'output name must be ' + OUT_NAME)

    # Allow overwrite for iterative slim builds.
    if out.exists():
        out.unlink()

    blobs, shas = read_inputs(root)

    with zipfile.ZipFile(base) as z:
        infos = z.infolist()
        names = names_of(infos)
        check(len(names) == BASE_MEMBERS and MANIFEST in names,
              'base member set is not the 54-member rc2 layout')
        check(z.comment == b'', 'base ZIP comment changed')
        raw = {n: z.read(n) for n in names}
    check(parse_manifest(raw[MANIFEST]).get(CORE_MEMBER) == CORE_SHA,
          'base core DLL pin mismatch')
    check(parse_manifest(raw[MANIFEST]).get(UAL_MEMBER) == UAL_SHA,
          'base UAL pin mismatch')
    check(sha(raw[CORE_MEMBER]) == CORE_SHA, 'base core DLL bytes mismatch')
    check(sha(raw[UAL_MEMBER]) == UAL_SHA, 'base UAL bytes mismatch')
    check(MANIFEST in names, 'base is missing ' + MANIFEST)

    # Build the working set: start with all base members.
    new = dict(raw)

    # Remove DELETE-list items.
    for rel in names:
        if rel in DELETED:
            del new[rel]

    # Merge worktree inputs (replace or append).
    for rel, data in blobs.items():
        new[rel] = data

    # Build final member order: original rc2 order (kept members in place,
    # non-deleted entries stay at their original index).
    # SHA256SUMS.txt (MANIFEST) is regenerated so it belongs with
    # the appended set, not at its original base position.
    output_order = []
    output_set = set()
    for n in names:
        if n not in DELETED and n != MANIFEST:
            output_order.append(n)
            output_set.add(n)

    # Add newly-created / regenerated members AFTER base members.
    generated_appends = [MANIFEST] + list(SLIM_WORKTREE_INPUTS)
    for rel in generated_appends:
        check(rel not in output_set, 'generated file already in base: ' + rel)
        output_order.append(rel)
        output_set.add(rel)

    output_names = output_order
    members = len(output_names)
    expected_members = BASE_MEMBERS - len(DELETED) + len(SLIM_WORKTREE_INPUTS)
    check(members == expected_members,
          'member count mismatch: expected ' + str(expected_members) + ' got ' + str(members))

    # Pre-compute per-member digests BEFORE regeneration.
    new_shas = {n: sha(new[n]) for n in output_names}

    # Regenerate SHA256SUMS.txt (lists every member except itself, in archive order).
    sums_lines = []
    for n in output_names:
        if n == MANIFEST:
            continue
        sums_lines.append((sha(new[n]).upper() + ' *' + n + '\r\n').encode('ascii'))
    new[MANIFEST] = b''.join(sums_lines)

    # Verify inputs didn't drift during build.
    check(set(new) == set(output_names), 'missing/extra output member')
    check(len(parse_manifest(new[MANIFEST])) == members - 1,
          'new manifest row count invalid')
    check(parse_manifest(new[MANIFEST]) ==
          {n: sha(new[n]) for n in output_names if n != MANIFEST},
          'new manifest content invalid')
    check(names_of(infos) == names, 'base name set changed')

    out.parent.mkdir(parents=True, exist_ok=True)
    temp = None
    try:
        with tempfile.NamedTemporaryFile(prefix='.slim-', suffix='.zip',
                                         dir=out.parent, delete=False) as stream:
            temp = Path(stream.name)
        with zipfile.ZipFile(temp, 'w', allowZip64=True) as z:
            # Kept members from base: preserve original ZipInfo (timestamp + attrs).
            for info in infos:
                fname = info.filename
                if fname not in new:
                    continue
                # Skip all non-base members — they get their own ZipInfo below.
                if fname in (MANIFEST,) or fname in SLIM_WORKTREE_INPUTS:
                    continue
                entry = copy.copy(info)
                z.writestr(entry, new[entry.filename])
            # All generated/new members in output_names order.
            for rel in (MANIFEST,) + SLIM_WORKTREE_INPUTS:
                entry = zipfile.ZipInfo(rel, date_time=FIXED_TS)
                entry.create_system = 0
                entry.external_attr = FIXED_ATTR
                entry.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(entry, new[rel])
        with zipfile.ZipFile(temp) as z:
            check(names_of(z.infolist()) == output_names and z.testzip() is None,
                  'output ZIP name/order/CRC mismatch')
            actual = {n: z.read(n) for n in output_names}
            check(actual == new, 'output member bytes mismatch')
            check(parse_manifest(actual[MANIFEST]) ==
                  {n: sha(actual[n]) for n in output_names if n != MANIFEST},
                  'output manifest mismatch')
        out_digest = file_sha(temp)
        check(not out.exists(), 'output appeared during build')
        os.rename(temp, out)
        temp = None
    finally:
        if temp is not None:
            temp.unlink(missing_ok=True)

    sums_path = out.with_name(MANIFEST)
    sums_data = (out_digest + ' *' + out.name + '\n').encode('ascii')
    sums_path.write_bytes(sums_data)
    check(file_sha(sums_path) == sha(sums_data), 'sums write mismatch')

    print('input-sha=' + digest)
    print('sums-out=' + str(sums_path))
    print('sums-sha=' + sha(sums_data))
    print('output-sha=' + out_digest)
    print('members=' + str(members))
    print('removed=' + str(len(DELETED)))
    print('kept=' + str(members - len(SLIM_WORKTREE_INPUTS) - 1))
    print('version=' + VERSION)
    print('base-name=' + BASE_NAME)


def main(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base', required=True, type=Path)
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--root', type=Path,
                   default=Path(__file__).resolve().parent.parent)
    p.add_argument('--version', default=VERSION)
    try:
        a = p.parse_args(argv)
        if a.version != VERSION:
            raise InvalidInvocation('refused version: ' + a.version +
                                    ' (expected ' + VERSION + ')')
        run(a.base, a.root, a.out)
    except InvalidInvocation as e:
        print('INVALID:', e, file=sys.stderr)
        return 2
    except (OSError, ValueError, zipfile.BadZipFile, UnicodeError) as e:
        print('REFUSED:', e, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
