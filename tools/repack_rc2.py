#!/usr/bin/env python3
"""Pinned local A-only rc1 -> rc2 repack; Python 3.10+; no publishing."""
import argparse
import copy
import hashlib
import os
import posixpath
from pathlib import Path
import re
import sys
import tempfile
import zipfile

RC1 = '95e8384c51ab965444cc13116b0965e8da4f60febd32520740422a59e676e5fc'
REPAIR = '8e79a7c59fb4bea573b115c2d25734306e52c53104c16c7d0f3586ca734408d4'
MANIFEST_SHA = 'e8ecd126e84bd7fc54910579f74e754673b17fd019802c30485cdecedb4cb168'
CORE = '0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60'
UAL = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'
OLD_SCRIPT = '7e164676d984a86e044efc6843dfaa0f9a9abc79d36911b19d7faea2dee92f52'
MANIFEST = 'SHA256SUMS.txt'
INSTALLER = 'tools/asi_loader_install.ps1'
README = 'README.md'
INSTALL_KO = 'INSTALL-KO.md'
OLD_NOTES = 'docs/RELEASE-v11.2-rc1.md'
NOTES = 'docs/RELEASE-v11.2-rc2.md'
README_SHA = '1826317ff25fc1964841ffce18b92838812175245016046130a9f587a1b56e71'
NOTES_SHA = '85886a8d4b8464ecafd893c57e3746db15d30c06d96c83783a95e65117cdf0de'
INSTALL_SHA = '43561ba77254edb37037cff9cc7cb53afec1f72a7de65a74b0ec3d7a1ae72e57'
CHANGED = {INSTALLER, README, INSTALL_KO, OLD_NOTES, MANIFEST}
BAD_BINARY = re.compile(r'(?:sm75|sm86|ampere|nvngx|nvidia|dlssg_for)', re.I)


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


def names_of(infos):
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
              'forbidden B/NVIDIA binary: ' + n)
    return names


def parse_manifest(data):
    rows = data.splitlines(keepends=True)
    check(len(rows) == 53, 'manifest must contain 53 rows')
    result = {}
    for row in rows:
        m = re.fullmatch(rb'([0-9A-F]{64}) \*([^\r\n]+)\r\n', row)
        check(m is not None, 'invalid manifest row')
        n = m[2].decode('ascii')
        check(n not in result, 'duplicate manifest row: ' + n)
        result[n] = m[1].decode('ascii').lower()
    return result


def doc_scan(contents):
    """Scan all shipped text, verify Markdown relative links against archive members.

    Historical source-only links that were already dead in rc1 are recorded by
    the caller as baseline; any newly dead reference fails the repack.
    """
    names = set(contents)
    dead, old_current, removed_note, references = set(), [], [], []
    link = re.compile('(?<!!)\\[([^\\[\\]\\r\\n]+)\\]\\(([^)]+)\\)')
    text_ext = ('.md', '.txt', '.ini', '.bat', '.ps1', '.sh', '.json')
    for name, data in contents.items():
        if not name.lower().endswith(text_ext):
            continue
        text = data.decode('utf-8-sig', errors='replace')
        for line_no, line in enumerate(text.splitlines(), 1):
            if re.search(r'v11\.2-rc[12]|releases/(?:tag/|latest)', line, re.I):
                references.append((name, line_no))
            if name != MANIFEST and 'RELEASE-v11.2-rc1.md' in line:
                removed_note.append((name, line_no))
        if not name.lower().endswith('.md'):
            continue
        for match in link.finditer(text):
            label, raw = match.groups()
            target = raw.split(' "', 1)[0].split('#', 1)[0].split('?', 1)[0].strip()
            line_no = text.count(chr(10), 0, match.start()) + 1
            if 'v11.2-rc1' in raw and re.search(r'experimental|current|candidate|실험판|새 후보', label, re.I):
                old_current.append((name, line_no, label))
            if not target or re.match(r'(?i)(?:[a-z][a-z0-9+.-]*:|//|#)', target):
                continue
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
            if resolved not in names and not any(n.startswith(resolved.rstrip('/') + '/') for n in names):
                dead.add((name, target))
    return dead, old_current, removed_note, references


def check_docs(old, new):
    before, _, _, _ = doc_scan(old)
    after, stale, removed, references = doc_scan(new)
    check(not stale, 'rc1 advertised as current: ' + repr(stale))
    check(not removed, 'removed rc1 note referenced: ' + repr(removed))
    check(not (after - before), 'new dead internal document link: ' + repr(sorted(after - before)))
    check(not any(n == INSTALL_KO for n, _ in after),
          'installation entry point contains dead internal links')
    check('docs/RELEASE-v11.2-rc2.md' in new and
          'https://github.com/grim-susemi/OptiScaler-Susemi/releases/tag/v11.2-rc2' in
          new[INSTALL_KO].decode('utf-8-sig'), 'rc2 installation release pointer missing')
    return len(references), len(before), len(after)

def run(rc1, installer, readme, notes, install_ko, out):
    sums = out.parent / MANIFEST
    check(all(p.is_file() for p in (rc1, installer, readme, notes, install_ko)), 'missing input')
    check(not out.exists() and not sums.exists(), 'output exists; refusing overwrite')
    check(out.name == 'OptiScaler-NR-v11.2-rc2.zip', 'output name must be rc2 A ZIP')
    check(file_sha(rc1) == RC1, 'rc1 SHA mismatch')
    check(file_sha(installer) == REPAIR, 'repaired installer SHA mismatch')
    check(file_sha(readme) == README_SHA, 'S2 README SHA mismatch')
    check(file_sha(notes) == NOTES_SHA, 'S2 rc2 notes SHA mismatch')
    check(file_sha(install_ko) == INSTALL_SHA, 'S2 installation guide SHA mismatch')
    with zipfile.ZipFile(rc1) as z:
        infos = z.infolist()
        names = names_of(infos)
        check(len(names) == 54 and MANIFEST in names, 'missing/extra ZIP members')
        old = {n: z.read(n) for n in names}
        check(z.comment == b'' and sha(old[MANIFEST]) == MANIFEST_SHA,
              'rc1 ZIP comment or manifest changed')
    expected = parse_manifest(old[MANIFEST])
    check(set(expected) | {MANIFEST} == set(names), 'missing/extra manifest members')
    for n, digest in expected.items():
        check(sha(old[n]) == digest, 'rc1 member hash mismatch: ' + n)
    check(OLD_NOTES in expected and NOTES not in expected and
          README in expected and INSTALL_KO in expected,
          'rc1 docs name set changed')
    check(expected['OptiScaler.dll'] == CORE and
          expected['tools/asi-loader/Ultimate-ASI-Loader-x64.dll'] == UAL and
          expected[INSTALLER] == OLD_SCRIPT, 'runtime/loader/old installer pin mismatch')
    new = dict(old)
    new[INSTALLER] = installer.read_bytes()
    check(sha(new[INSTALLER]) == REPAIR, 'installer changed during read')
    new[README] = readme.read_bytes()
    new[INSTALL_KO] = install_ko.read_bytes()
    new.pop(OLD_NOTES)
    new[NOTES] = notes.read_bytes()
    check(sha(new[README]) == README_SHA and sha(new[NOTES]) == NOTES_SHA and
          sha(new[INSTALL_KO]) == INSTALL_SHA,
          'S2 documentation changed during read')
    output_names = [NOTES if n == OLD_NOTES else n for n in names]
    check(len(output_names) == 54 and len(set(output_names)) == 54 and
          set(output_names) == (set(names) - {OLD_NOTES}) | {NOTES},
          'output names must replace rc1 note exactly')
    output_manifest = [NOTES if n == OLD_NOTES else n for n in expected]
    new[MANIFEST] = b''.join(
        (sha(new[n]).upper() + ' *' + n + chr(13) + chr(10)).encode('ascii') for n in output_manifest)
    check(len(new) == 54 and len(parse_manifest(new[MANIFEST])) == 53,
          'new manifest membership invalid')
    check(set(new) == set(output_names), 'missing/extra output member')
    scan_stats = check_docs(old, new)
    for n in names:
        if n not in CHANGED:
            check(new[n] == old[n], 'untouched member changed: ' + n)
    check(sha(new['OptiScaler.dll']) == CORE and
          sha(new['tools/asi-loader/Ultimate-ASI-Loader-x64.dll']) == UAL,
          'runtime/UAL changed')
    out.parent.mkdir(parents=True, exist_ok=True)
    temp = None
    try:
        with tempfile.NamedTemporaryFile(prefix='.rc2-', suffix='.zip',
                                         dir=out.parent, delete=False) as stream:
            temp = Path(stream.name)
        with zipfile.ZipFile(temp, 'w', allowZip64=True) as z:
            for info in infos:
                entry = copy.copy(info)
                if info.filename == OLD_NOTES:
                    entry.filename = NOTES
                z.writestr(entry, new[entry.filename])
        with zipfile.ZipFile(temp) as z:
            check(names_of(z.infolist()) == output_names and z.testzip() is None,
                  'output ZIP name/order/CRC mismatch')
            actual = {n: z.read(n) for n in output_names}
            check(actual == new and parse_manifest(actual[MANIFEST]) ==
                  {n: sha(actual[n]) for n in output_names if n != MANIFEST},
                  'output member/manifest mismatch')
            check(check_docs(old, actual) == scan_stats, 'archive document scan changed')
        digest = file_sha(temp)
        check(not out.exists() and not sums.exists(), 'output appeared during build')
        os.rename(temp, out)
        temp = None
        with sums.open('x', encoding='ascii', newline='\n') as f:
            f.write(f'{digest} *{out.name}\n')
        print('rc1 SHA256', RC1, '\nrepair SHA256', REPAIR)
        print('rc2 SHA256', digest, '\nmanifest SHA256', sha(new[MANIFEST]))
        print('members 54; manifest entries 53; rc1 note replaced with rc2 note; modified:',
              ', '.join((INSTALLER, README, INSTALL_KO, MANIFEST)))
        print('archive-wide text scan: release-reference lines', scan_stats[0],
              'inherited dead Markdown links', scan_stats[2],
              'new dead links 0; stale rc1-current links 0; removed-note links 0')
    finally:
        if temp is not None:
            temp.unlink(missing_ok=True)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for arg in ('rc1', 'installer', 'readme', 'notes', 'install-ko', 'out'):
        p.add_argument('--' + arg, required=True, type=Path)
    a = p.parse_args()
    try:
        run(a.rc1, a.installer, a.readme, a.notes, a.install_ko, a.out)
    except (OSError, ValueError, zipfile.BadZipFile, UnicodeError) as e:
        print('REFUSED:', e, file=sys.stderr)
        sys.exit(1)
