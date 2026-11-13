#!/usr/bin/env python3
"""Re-implementation of RootfsManager.extractTar (Kotlin) to prove the asset
produced by scripts/prepare_android_sandbox.sh extracts correctly on device.

The Kotlin parser reads 512-byte POSIX headers and understands exactly:
  type '0' / NUL -> regular file
  type '5' / 'D' -> directory
  type '2'       -> symlink
  type '1'       -> hard link (copies the target if it already exists,
                    silently skips otherwise)
  anything else  -> skipped (data blocks discarded)

It also honours the ustar `prefix` field (bytes 345..500) for long names.
Any entry type outside that set would be silently dropped on a real device, so
this script reports them instead of skipping quietly.
"""
import gzip
import os
import sys

TYPES_SEEN = {}
DROPPED = []
HARDLINK_MISSING = []


def cstr(buf, off, length):
    end = min(off + length, len(buf))
    stop = off
    for i in range(off, end):
        if buf[i] == 0:
            break
        stop = i + 1
    return bytes(buf[off:stop]).decode("utf-8", "replace")


def read_exact(f, n):
    out = bytearray()
    while len(out) < n:
        chunk = f.read(n - len(out))
        if not chunk:
            break
        out += chunk
    return bytes(out)


def extract(tar_path, target):
    # The app wraps the asset stream in GZIPInputStream when the asset name
    # ends in ".gz" (RootfsManager.installIfNeeded), so mirror that.
    opener = gzip.open if tar_path.endswith(".gz") else open
    with opener(tar_path, "rb") as f:
        while True:
            header = read_exact(f, 512)
            if len(header) < 512:
                break
            if header == b"\0" * 512:
                break

            name = cstr(header, 0, 100)
            mode = int((cstr(header, 100, 8).strip() or "0"), 8)
            size = int((cstr(header, 124, 12).strip() or "0"), 8)
            typeflag = chr(header[156]) if header[156] else "\0"
            linkname = cstr(header, 157, 100)
            prefix = cstr(header, 345, 155)

            TYPES_SEEN[typeflag] = TYPES_SEEN.get(typeflag, 0) + 1

            full = name
            if prefix:
                full = prefix + "/" + full
            if not full:
                break
            out = os.path.join(target, full)

            if typeflag in ("5", "D"):
                os.makedirs(out, exist_ok=True)
            elif typeflag == "2":
                os.makedirs(os.path.dirname(out) or target, exist_ok=True)
                if os.path.lexists(out):
                    os.remove(out)
                os.symlink(linkname, out)
            elif typeflag in ("0", "\0"):
                os.makedirs(os.path.dirname(out) or target, exist_ok=True)
                with open(out, "wb") as o:
                    left = size
                    while left > 0:
                        chunk = f.read(min(8192, left))
                        if not chunk:
                            break
                        o.write(chunk)
                        left -= len(chunk)
                if mode & 0o111:
                    os.chmod(out, os.stat(out).st_mode | 0o755)
                rem = size % 512
                if rem:
                    f.read(512 - rem)
                continue
            elif typeflag == "1":
                os.makedirs(os.path.dirname(out) or target, exist_ok=True)
                src = os.path.join(target, linkname.lstrip("./"))
                # Mirrors the Kotlin: copy only if the target already exists.
                if os.path.exists(src):
                    with open(src, "rb") as s, open(out, "wb") as o:
                        o.write(s.read())
                else:
                    HARDLINK_MISSING.append(full)
            else:
                DROPPED.append((typeflag, full))

            if typeflag not in ("0", "\0") and size > 0:
                f.read(((size + 511) // 512) * 512)


if __name__ == "__main__":
    tar_path, target = sys.argv[1], sys.argv[2]
    os.makedirs(target, exist_ok=True)
    extract(tar_path, target)

    print("entry types encountered:", {repr(k): v for k, v in sorted(TYPES_SEEN.items())})
    if DROPPED:
        print("DROPPED (would vanish on device):", DROPPED[:10], "...", len(DROPPED), "total")
    if HARDLINK_MISSING:
        print("HARDLINK TARGET MISSING (silently skipped on device):",
              HARDLINK_MISSING[:10], "...", len(HARDLINK_MISSING), "total")
    if not DROPPED and not HARDLINK_MISSING:
        print("OK: every entry is one the Kotlin parser handles")
    sys.exit(1 if (DROPPED or HARDLINK_MISSING) else 0)
