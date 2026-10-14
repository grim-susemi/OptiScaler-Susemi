#!/usr/bin/env python3
"""Build the v11.4 installer-bundled package from the published v11.3-installer-a2 ZIP.

Every a2 member is kept byte-exact EXCEPT:
  * OptiScaler.dll            -> replaced by the R3 core build (pinned below)
  * tools/susemi_installer.ps1 -> worktree copy (core pin updated to the R3 core)
  * SHA256SUMS.txt            -> regenerated (every member except itself, archive order)
Other worktree-owned members (installer scripts, setup/launcher bats, one-click guide)
are re-read from the worktree and must be byte-identical to a2 unless listed in
ALLOWED_CHANGED. Kept members keep their original ZipInfo, so identical inputs give a
byte-identical ZIP. Never publishes anything. Exit 0 ok / 1 refused / 2 bad invocation.
"""
import argparse, hashlib, subprocess, sys, tempfile, zipfile
from pathlib import Path

BASE_SHA = '08b07e87b3f484d8c4310279532546432f7aed1fd41aded3a249f99b3a781bb2'
BASE_NAME = 'OptiScaler-NR-v11.3-installer-a2.zip'
BASE_MEMBERS = 27
OUT_NAME = 'OptiScaler-NR-v11.4.zip'
MANIFEST = 'SHA256SUMS.txt'
CORE_MEMBER = 'OptiScaler.dll'
OLD_CORE_SHA = '0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60'
NEW_CORE_SHA = '22f3677f922969a7dab3f3332075f74f64488fbffb8b98b929b8851c8b5fbcff'
UAL_MEMBER = 'tools/asi-loader/Ultimate-ASI-Loader-x64.dll'
UAL_SHA = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'
GUIDE_SOURCE = 'docs/INSTALL-ONECLICK-v11.4.md'
GUIDE_MEMBER = 'INSTALL-ONECLICK.md'
WORKTREE_MEMBERS = ('Install_OptiScaler_windows.bat', 'setup_windows.bat',
                    'tools/susemi_installer.ps1', 'tools/susemi_transaction.ps1', 'tools/susemi_stage_helpers.ps1')
ALLOWED_CHANGED = {'tools/susemi_installer.ps1'}


def sha(b):
    return hashlib.sha256(b).hexdigest()


def check(ok, msg):
    if not ok:
        raise ValueError(msg)


def blob(root, rev, rel):
    """Committed bytes (no autocrlf conversion), so the ZIP is reproducible from git."""
    res = subprocess.run(['git', '-C', str(root), 'show', rev + ':' + rel], capture_output=True)
    check(res.returncode == 0, 'git show failed for ' + rel)
    return res.stdout


def run(base, core, root, out, rev):
    status = subprocess.run(['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=no', '--'] + list(WORKTREE_MEMBERS) + [GUIDE_SOURCE], capture_output=True, text=True).stdout.strip()
    check(not status, 'uncommitted changes in package inputs: ' + status)
    check(out.name == OUT_NAME, 'output name must be ' + OUT_NAME)
    check(sha(base.read_bytes()) == BASE_SHA, 'base a2 ZIP sha mismatch')
    core_bytes = core.read_bytes()
    check(sha(core_bytes) == NEW_CORE_SHA, 'R3 core sha mismatch')
    with zipfile.ZipFile(base) as z:
        infos = z.infolist()
        check(len(infos) == BASE_MEMBERS, 'base is not the 27-member a2 layout')
        raw = {i.filename: z.read(i.filename) for i in infos}
    check(sha(raw[CORE_MEMBER]) == OLD_CORE_SHA, 'base core is not the rc2 core')
    check(sha(raw[UAL_MEMBER]) == UAL_SHA, 'base UAL pin mismatch')
    new = dict(raw)
    new[CORE_MEMBER] = core_bytes
    changed = [CORE_MEMBER]
    for rel in WORKTREE_MEMBERS:
        data = blob(root, rev, rel)
        check(rel in raw, 'worktree member absent from a2 layout: ' + rel)
        # a2 stores .bat members with CRLF and .ps1 members with LF; line endings alone are not a change
        if data.replace(b'\r\n', b'\n') != raw[rel].replace(b'\r\n', b'\n'):
            check(rel in ALLOWED_CHANGED, 'unexpected change vs a2: ' + rel)
            new[rel] = data
            changed.append(rel)
    new[GUIDE_MEMBER] = blob(root, rev, GUIDE_SOURCE)
    changed.append(GUIDE_MEMBER)
    inst = new['tools/susemi_installer.ps1'].decode('utf-8-sig')
    check(("$CoreSha       = '" + NEW_CORE_SHA + "'") in inst, 'installer does not pin the R3 core')
    names = [i.filename for i in infos]
    new[MANIFEST] = b''.join((sha(new[n]).upper() + ' *' + n + '\r\n').encode('ascii') for n in names if n != MANIFEST)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    with tempfile.NamedTemporaryFile(prefix='.v114-', suffix='.zip', dir=out.parent, delete=False) as t:
        tmp = Path(t.name)
    try:
        with zipfile.ZipFile(tmp, 'w', allowZip64=True) as z:
            for info in infos:
                zi = zipfile.ZipInfo(info.filename, info.date_time)
                zi.compress_type = info.compress_type
                zi.external_attr = info.external_attr
                zi.create_system = info.create_system
                z.writestr(zi, new[info.filename])
        with zipfile.ZipFile(tmp) as z:
            check(z.testzip() is None, 'output ZIP failed integrity test')
            check([i.filename for i in z.infolist()] == names, 'member order drifted')
        tmp.replace(out)
    finally:
        if tmp.exists():
            tmp.unlink()
    print('source-rev=' + subprocess.run(['git', '-C', str(root), 'rev-parse', rev], capture_output=True, text=True).stdout.strip())
    print('base-sha=' + BASE_SHA)
    print('output-sha=' + sha(out.read_bytes()))
    print('members=' + str(len(names)))
    print('changed=' + ','.join(changed + [MANIFEST]))
    return 0


def main(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base', required=True, type=Path)
    p.add_argument('--core', required=True, type=Path, help='R3 OptiScaler.asi/.dll build')
    p.add_argument('--root', required=True, type=Path, help='worktree root')
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--rev', default='HEAD', help='git revision the package inputs are read from')
    a = p.parse_args(argv)
    try:
        return run(a.base, a.core, a.root, a.out, a.rev)
    except (ValueError, OSError, zipfile.BadZipFile) as e:
        print('refused: ' + str(e))
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
