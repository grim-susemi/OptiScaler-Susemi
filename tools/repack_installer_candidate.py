#!/usr/bin/env python3
"""Pinned local A-only installer-candidate repack from the reviewed rc2 ZIP.

Builds a NEW local candidate identity (default version tag ``v11.3-installer-a1``)
by taking every rc2 ZIP member byte-identical, replacing ``setup_windows.bat``
with the reviewed orchestrated-mode file, appending the reviewed installer
addition set and regenerating ``SHA256SUMS.txt`` plus a
``NEW-CANDIDATE-MANIFEST.md`` provenance member.

This recipe never publishes anything. It refuses the rc2 identity (rc2 is only
reproducible through ``tools/repack_rc2.py``) and writes only a local ZIP.

Determinism: rc2 members keep their original ZipInfo (including ``date_time``);
new members use a fixed timestamp, so two runs with identical inputs produce a
byte-identical output ZIP. Any drift in an addition input between runs changes
the recorded per-member SHA and the output ZIP hash.

Machine-readable stdout lines: input-sha=, output-sha=, members=, changed=,
additions=. Exit 0 ok / 1 refused / 2 invalid invocation.
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

VERSION = 'v11.3-installer-a1'
OUT_NAME = 'OptiScaler-NR-' + VERSION + '.zip'

MANIFEST = 'SHA256SUMS.txt'
CANDIDATE_MANIFEST = 'NEW-CANDIDATE-MANIFEST.md'
MODIFIED = 'setup_windows.bat'

# New member names, appended in this order with forward-slash paths.
ADDITIONS = (
    'Install_OptiScaler_windows.bat',
    'tools/susemi_installer.ps1',
    'tools/susemi_transaction.ps1',
    'tools/susemi_stage_helpers.ps1',
    'INSTALL-ONECLICK.md',
)

# Forbidden path fragments for the addition set (internal tests/evidence).
FORBIDDEN_PATH = ('.omo', 'evidence/', 'journal/', 'tests/')
# rc2's established A-only binary guard.
BAD_BINARY = re.compile(r'(?:sm75|sm86|ampere|nvngx|nvidia|dlssg_for)', re.I)
# Additional NR-model member name guard.
BAD_MODEL = re.compile(r'\.onnx$', re.I)

FIXED_TS = (2026, 9, 27, 22, 36, 44)
FIXED_ATTR = 0o140000000
SIZE_SANITY = 200 * 1024 * 1024  # no single packaged member above 200 MB


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
    """Read additions + modified file from the worktree; return (bytes, shas)."""
    check(root.is_dir(), 'root not a directory: ' + str(root))
    blobs, shas = {}, {}
    for rel in ADDITIONS + (MODIFIED,):
        check(all(frag not in rel for frag in FORBIDDEN_PATH),
              'forbidden path in input set: ' + rel)
        path = root / rel
        check(path.is_file(), 'missing input: ' + rel)
        data = path.read_bytes()
        check(sha(data) == file_sha(path), 'input changed during read: ' + rel)
        blobs[rel] = data
        shas[rel] = sha(data)
    return blobs, shas


def candidate_manifest(base_digest, base_shas, shas, members, changed, additions):
    lines = [
        '# NEW-CANDIDATE-MANIFEST', '',
        'Local A-only installer candidate repacked from a byte-pinned rc2 ZIP.', '',
        '- base-zip: ' + BASE_NAME,
        '- base-sha256: ' + base_digest,
        '- candidate-version: ' + VERSION,
        '- candidate-zip: ' + OUT_NAME,
        '- members: ' + str(members),
        '- changed: ' + str(changed),
        '- additions: ' + str(additions),
        '- core-dll-pin: ' + CORE_MEMBER + ' ' + CORE_SHA,
        '- ual-pin: ' + UAL_MEMBER + ' ' + UAL_SHA, '',
        '## Provenance', '',
        'LOCAL CANDIDATE, NOT PUBLISHED. The version tag is a local placeholder.',
        'Any commit, push, tag, release or announcement requires separate,',
        'explicit owner approval. This file is not a release receipt.', '',
        '## Changed-member set (old -> new SHA-256)', '',
        '| member | change | old sha256 | new sha256 |',
        '| --- | --- | --- | --- |',
    ]
    for rel in (MODIFIED,) + ADDITIONS + (MANIFEST, CANDIDATE_MANIFEST):
        old = base_shas.get(rel, '(absent in base)')
        if rel == MANIFEST:
            new = '(self; verified via ' + MANIFEST + ')'
        elif rel == CANDIDATE_MANIFEST:
            new = '(self; listed in ' + MANIFEST + ')'
        else:
            new = shas[rel]
        kind = 'added' if old == '(absent in base)' else 'modified'
        lines.append('| ' + rel + ' | ' + kind + ' | ' + old + ' | ' + new + ' |')
    lines.append('')
    return ('\n'.join(lines)).encode('utf-8')


def run(base, root, out):
    check(base.is_file(), 'missing base ZIP')
    digest = file_sha(base)
    check(digest == BASE_SHA, 'base rc2 SHA mismatch: ' + digest)
    check(out.name == OUT_NAME, 'output name must be ' + OUT_NAME)
    check(not out.exists(), 'output exists; refusing overwrite')
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
    check(MODIFIED in names, 'base is missing ' + MODIFIED)

    new = dict(raw)
    for rel, data in blobs.items():
        new[rel] = data

    # Final member order: rc2 order (replacements in place) + additions +
    # candidate manifest.
    output_names = list(names)
    for rel in ADDITIONS + (CANDIDATE_MANIFEST,):
        check(rel not in output_names, 'addition already in base: ' + rel)
        output_names.append(rel)
    members = len(output_names)

    # SHA256SUMS.txt lists every member except itself, in archive order. The
    # candidate manifest never contains the manifest's own SHA, so it is built
    # first; SHA256SUMS.txt then records the candidate manifest's SHA.
    changed_set = (MODIFIED,) + ADDITIONS + (MANIFEST, CANDIDATE_MANIFEST)
    base_shas = {n: sha(raw[n]) for n in names}
    new[CANDIDATE_MANIFEST] = candidate_manifest(
        digest, base_shas, shas, members, len(changed_set), len(ADDITIONS) + 1)
    sums = b''.join((sha(new[n]).upper() + ' *' + n + '\r\n').encode('ascii')
                    for n in output_names if n != MANIFEST)
    new[MANIFEST] = sums

    # Re-verify inputs did not drift during the build.
    for rel in ADDITIONS + (MODIFIED,):
        check(sha(new[rel]) == shas[rel], 'input changed during build: ' + rel)
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
        with tempfile.NamedTemporaryFile(prefix='.cand-', suffix='.zip',
                                         dir=out.parent, delete=False) as stream:
            temp = Path(stream.name)
        with zipfile.ZipFile(temp, 'w', allowZip64=True) as z:
            for info in infos:
                entry = copy.copy(info)
                z.writestr(entry, new[entry.filename])
            for rel in ADDITIONS + (CANDIDATE_MANIFEST,):
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

    print('input-sha=' + digest)
    print('output-sha=' + out_digest)
    print('members=' + str(members))
    print('changed=' + str(len(changed_set)))
    print('additions=' + str(len(ADDITIONS) + 1))
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
