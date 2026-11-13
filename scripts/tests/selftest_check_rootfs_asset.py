#!/usr/bin/env python3
"""Self-test for check_rootfs_asset.py.

A validator whose only observed behaviour is "OK" is indistinguishable from one
that checks nothing. Each case below builds a deliberately broken archive and
asserts that the checker rejects it — and that a clean archive passes, so the
rules cannot all be trivially true.

Two details learned the hard way while writing this:

* Python's `tarfile` defaults to PAX_FORMAT, which emits an `x` extension header
  for EVERY entry. Test archives must be written as USTAR (or with the system
  GNU tar) or they fail the extension-header rule for reasons that have nothing
  to do with the case under test.
* A gzipped tar cannot be appended to with `tarfile.open(mode="a")`, so a
  hardlink has to exist in the tree before the archive is written.

Run: python3 scripts/tests/selftest_check_rootfs_asset.py
"""
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_rootfs_asset.py")

PSEUDO = ("dev", "proc", "sys")


def write_archive(root, out):
    """Pack `root` as ustar + gzip, the way the real asset is packed."""
    with tarfile.open(out, "w:gz", format=tarfile.USTAR_FORMAT) as tf:
        for entry in sorted(os.listdir(root)):
            tf.add(os.path.join(root, entry), arcname="./" + entry, recursive=True)


def build(root, entries):
    """entries: list of (relative path, kind, payload).

    kind is 'file', 'dir', 'symlink' or 'hardlink' (payload = existing path in
    the same tree to link to).
    """
    for name, kind, payload in entries:
        path = os.path.join(root, name)
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        if kind == "file":
            with open(path, "wb") as fh:
                fh.write(payload)
        elif kind == "dir":
            os.makedirs(path, exist_ok=True)
        elif kind == "symlink":
            os.symlink(payload, path)
        elif kind == "hardlink":
            os.link(os.path.join(root, payload), path)
        else:
            raise ValueError(kind)
    for pseudo in PSEUDO:
        os.makedirs(os.path.join(root, pseudo), exist_ok=True)
    write_archive(root, os.path.join(root + ".tar.gz"))


def run_checker(archive):
    proc = subprocess.run(
        [sys.executable, CHECKER, archive],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    return proc.returncode, proc.stdout


CASES = {
    "clean": (
        [("usr/bin/f", "file", b"ok"), ("usr/bin/l", "symlink", "f")],
        0, "structurally shippable",
    ),
    "hardlink": (
        [("usr/bin/f", "file", b"ok"), ("usr/bin/h", "hardlink", "usr/bin/f")],
        1, "hardlink",
    ),
    "l2s_sentinel": (
        [("usr/bin/f", "file", b"ok"), ("usr/bin/.l2s.f0001", "file", b"ok")],
        1, ".l2s.",
    ),
    "pseudo_not_empty": (
        [("usr/bin/f", "file", b"ok"), ("dev/null", "file", b"junk")],
        1, "/dev, /proc and /sys must be empty",
    ),
}


def main():
    work = tempfile.mkdtemp(prefix="assetcheck-")
    failures = []
    try:
        for name, (entries, expected_rc, expected_text) in CASES.items():
            root = os.path.join(work, name)
            os.makedirs(root, exist_ok=True)
            build(root, entries)
            rc, out = run_checker(root + ".tar.gz")
            ok = rc == expected_rc and expected_text in out
            print(f"[{'PASS' if ok else 'FAIL'}] {name}: rc={rc} (expected {expected_rc})")
            if not ok:
                failures.append(name)
                for line in out.splitlines():
                    print("      " + line)

        # A >255-byte path can only be represented with a GNU/PAX extension
        # header, and only GNU tar produces that with the flags we care about.
        root = os.path.join(work, "longname")
        deep = os.path.join(root, "d" * 120, "e" * 120)
        os.makedirs(deep, exist_ok=True)
        with open(os.path.join(deep, "f"), "wb") as fh:
            fh.write(b"ok")
        for pseudo in PSEUDO:
            os.makedirs(os.path.join(root, pseudo), exist_ok=True)
        archive = root + ".tar.gz"
        subprocess.run(["tar", "-czf", archive, "-C", root, "."], check=True)
        rc, out = run_checker(archive)
        ok = rc == 1 and ("extension header" in out or "unsupported raw entry type" in out)
        print(f"[{'PASS' if ok else 'FAIL'}] longname: rc={rc} (expected 1)")
        if not ok:
            failures.append("longname")
            for line in out.splitlines():
                print("      " + line)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print()
    if failures:
        print(f"{len(failures)} self-test case(s) failed: {failures}")
        return 1
    print("all self-test cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
