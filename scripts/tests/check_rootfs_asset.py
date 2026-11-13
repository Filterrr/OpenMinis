#!/usr/bin/env python3
"""Structural validation of the Android sandbox rootfs asset.

The asset is extracted on device by `RootfsManager.extractTar`, a hand-rolled
POSIX tar reader. It understands exactly three entry types and silently ignores
everything else, so an archive that looks fine to `tar` can still produce a
broken sandbox. Every rule below exists because of a specific way that parser
loses or mangles data.

Run in CI right after building `debian-rootfs.tar.gz`; also runnable by hand:

    python3 scripts/tests/check_rootfs_asset.py <asset.tar.gz>

Exit status is 0 when the archive is shippable, 1 otherwise, with one
`::error::` line per failed rule (GitHub Actions annotations).
"""
import gzip
import io
import sys
import tarfile

# The type flags RootfsManager.extractTar actually handles. NUL is the legacy
# spelling of a regular file, 'D' a GNU directory.
HANDLED = {"0", "\0", "5", "D", "2", "1"}
NAME_OF = {
    "0": "regular",
    "\0": "regular",
    "5": "directory",
    "D": "directory",
    "2": "symlink",
    "1": "hardlink",
    "3": "char-device",
    "4": "block-device",
    "6": "fifo",
    "7": "contiguous",
    "L": "GNU-longname",
    "K": "GNU-longlink",
    "x": "pax-header",
    "g": "pax-global-header",
    "A": "solaris-ACL",
    "X": "solaris-xattr",
    "S": "sparse",
}

# PRoot is launched with `-b /dev -b /proc -b /sys`, so the host's trees are
# bound over these directories. Anything baked in is dead weight at best and,
# if it is a device node, a type the parser cannot extract.
PSEUDO_DIRS = ("./dev", "./proc", "./sys")


def scan_raw_typeflags(stream):
    """Walk the raw 512-byte headers and count typeflags.

    This is the only way to see GNU/PAX extension entries: Python's tarfile
    *consumes* a long-name header and reports the following member under the
    resolved long name, so the extension entry never appears in `tf`.

    The Kotlin parser skips unknown types by seeking past their data using the
    size field — which for an extension entry means it consumes the extension
    body correctly but never learns the long name, so the entry that follows is
    read under a truncated name (or garbage). Either way the file lands in the
    wrong place or nowhere, so any extension header disqualifies the archive.
    """
    counts = {}
    while True:
        header = stream.read(512)
        if len(header) < 512 or header == b"\0" * 512:
            break
        typeflag = chr(header[156]) if header[156] else "\0"
        size_field = header[124:136].split(b"\0", 1)[0].strip()
        try:
            size = int(size_field or b"0", 8)
        except ValueError:
            size = 0
        counts[typeflag] = counts.get(typeflag, 0) + 1
        # Consume the data area, rounded up to a block boundary.
        if size:
            stream.seek(((size + 511) // 512) * 512, io.SEEK_CUR)
    return counts


def check(path):
    errors = []
    raw_counts = {}
    handled_counts = {}
    bad_types = []
    sentinels = []
    long_names = []
    pseudo = []

    with gzip.open(path, "rb") as raw:
        raw_counts = scan_raw_typeflags(raw)

    with tarfile.open(path, "r:gz") as tf:
        for member in tf:
            handled_counts[member.type] = handled_counts.get(member.type, 0) + 1

            if member.type not in (tarfile.REGTYPE, tarfile.DIRTYPE, tarfile.SYMTYPE):
                # A hardlink is the dangerous case: extractTar copies the link
                # target only if it has already been extracted, so a hardlink
                # whose target sorts later is silently skipped and the binary
                # is simply absent inside the sandbox. The packer passes
                # --hard-dereference to make that impossible.
                bad_types.append((NAME_OF.get(
                    {tarfile.REGTYPE: "0", tarfile.DIRTYPE: "5", tarfile.SYMTYPE: "2",
                     tarfile.LNKTYPE: "1", tarfile.CHRTYPE: "3", tarfile.BLKTYPE: "4",
                     tarfile.FIFOTYPE: "6"}.get(member.type), repr(member.type)), member.name))

            # PRoot link2symlink sentinels are build-host artefacts. They are
            # mutually referential, which is why tar itself aborts on them.
            if ".l2s." in member.name:
                sentinels.append(member.name)

            # extractTar reads the 100-byte name field plus the 155-byte ustar
            # prefix field — and nothing else. Beyond that there is no
            # mechanism: the name simply comes out wrong.
            if member.pax_headers or len(member.name) > 255:
                long_names.append((len(member.name), member.name))

            name = member.name.rstrip("/")
            if name in PSEUDO_DIRS:
                if member.type != tarfile.DIRTYPE:
                    pseudo.append(member.name)
            elif any(member.name.startswith(d + "/") for d in PSEUDO_DIRS):
                pseudo.append(member.name)

    print("raw header types:")
    for key, value in sorted(raw_counts.items(), key=lambda kv: -kv[1]):
        mark = "" if key in HANDLED else "   <-- unsupported"
        print(f"  {NAME_OF.get(key, repr(key)):<18} {value}{mark}")

    unsupported_raw = {k: v for k, v in raw_counts.items() if k not in HANDLED}
    if unsupported_raw:
        described = ", ".join(f"{NAME_OF.get(k, repr(k))}×{v}" for k, v in unsupported_raw.items())
        errors.append(f"unsupported raw entry type(s): {described}")
    if bad_types:
        errors.append(
            f"{len(bad_types)} entry type(s) the app's parser cannot extract: {bad_types[:5]}"
        )
    if sentinels:
        errors.append(f"{len(sentinels)} .l2s.* sentinel(s) leaked into the archive: {sentinels[:5]}")
    if long_names:
        errors.append(f"{len(long_names)} name(s) need a tar extension header: {long_names[:5]}")
    if pseudo:
        errors.append(f"/dev, /proc and /sys must be empty, found: {pseudo[:5]}")

    return errors


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    path = sys.argv[1]
    try:
        errors = check(path)
    except (OSError, EOFError, tarfile.TarError) as exc:
        print(f"::error::cannot read {path}: {exc}")
        return 1

    for error in errors:
        print(f"::error::{error}")
    if errors:
        return 1

    print(f"OK: {path} is structurally shippable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
