#!/usr/bin/env bash
#
# Prepare Android sandbox assets in src/android/app/src/main/assets/:
#   1. Fetch the Debian 12 "bookworm" slim aarch64 rootfs straight from the
#      Docker Hub registry (no docker daemon required)
#   2. Bake the base package set into it (needs arm64 execution: native on an
#      aarch64 host, or qemu-aarch64-static on x86_64)
#   3. Configure it for PRoot and repack it as debian-rootfs.tar.gz
#   4. Check that the PRoot binary is present
#
# The PRoot binary (assets/proot-aarch64) is produced by deps/build_proot.sh,
# which must run first.
#
# Why the Docker Hub registry instead of debuerreotype's git artifacts: the
# raw rootfs tarballs under github.com/debuerreotype/docker-debian-artifacts
# are not reachable over plain HTTPS (404 from the HTML path), whereas the
# registry API is a stable, documented, unauthenticated-for-pull interface
# that hands us the exact same layer the official image ships. Pinning is by
# tag + platform, and the resolved manifest digest is written next to the
# asset so a build is reproducible by digest via DEBIAN_DIGEST.
#
# Usage:
#   ./deps/build_proot.sh && ./scripts/prepare_android_sandbox.sh
#
# Options:
#   --no-bake            skip the in-rootfs apt step (produces the bare image;
#                        the sandbox then lacks ps/less/vi/awk/curl/wget)
#   --keep-work          leave the staging tree for inspection
#   --output <path>      write the tarball somewhere other than assets/
#   --tag <tag>          Debian image tag (default: bookworm-slim)
#   --verify             after packing, run the sanity assertions and exit
#   --require-proot      fail if assets/proot-aarch64 is missing (it is built
#                        by deps/build_proot.sh and is not needed to build the
#                        rootfs, so its absence is only a warning by default)
#
# Environment overrides:
#   DEBIAN_TAG, DEBIAN_SUITE, MIRROR_HOST, BASE_PACKAGES, DEBIAN_DIGEST
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_DIR="$PROJECT_ROOT/src/android/app/src/main/assets"

# --- configuration -----------------------------------------------------------

DEBIAN_SUITE="${DEBIAN_SUITE:-bookworm}"
DEBIAN_TAG="${DEBIAN_TAG:-${DEBIAN_SUITE}-slim}"
DEBIAN_PLATFORM_ARCH="arm64"
DEBIAN_PLATFORM_VARIANT="v8"

DEBIAN_REGISTRY="registry-1.docker.io"
DEBIAN_REPOSITORY="library/debian"
DEBIAN_AUTH="https://auth.docker.io/token"

# Base package set baked into the image.
#
# Rationale: the Alpine minirootfs this replaces shipped busybox, which gave
# the sandbox ps/top/free (procps), less, vi, wget, awk and a usable file-
# manipulation set out of the box. debian:bookworm-slim ships none of those:
# coreutils/findutils/grep/sed/tar/gzip/dash/bash/util-linux are there, but
# `ps`, `less`, `vi`, `awk`, `curl`, `wget` and the CA bundle are not. Baking
# these restores functional parity at a measured cost of ~8 MB extracted
# (102.6 MB -> 125.0 MB). python3/pip/git/ripgrep/node are deliberately NOT
# baked in: the Alpine baseline did not ship them either, and the app installs
# them on demand (agent/shell/OnDemandBash.kt,
# assets/default_mount/usr/local/bin/minis-mcp-cli, .../utils/deps.py).
BASE_PACKAGES="${BASE_PACKAGES:-procps less curl wget ca-certificates unzip xz-utils gawk vim-tiny}"

# Optional APT mirror rewrite. Empty = keep the image's own deb822 sources
# (http://deb.debian.org/debian). Set MIRROR_HOST=mirrors.tuna.tsinghua.edu.cn
# to build a China-friendly image; the matching path prefix is /debian and
# /debian-security.
MIRROR_HOST="${MIRROR_HOST:-}"

ROOTFS_ASSET_NAME="debian-rootfs.tar.gz"
ROOTFS_FILE="$ASSETS_DIR/$ROOTFS_ASSET_NAME"
PROOT_FILE="$ASSETS_DIR/proot-aarch64"

# How the build host executes the rootfs's aarch64 binaries. Set by
# detect_runner(); the two must be declared here because `set -u` is on.
#
# QEMU_IN_ROOTFS: path of the qemu shim inside the rootfs, or empty when the
# host runs aarch64 natively or binfmt_misc handles it transparently.
# RUNNER_DETECTED: 0 until detect_runner() has chosen a mechanism. Tracked
# separately because QEMU_IN_ROOTFS is legitimately empty in two of the three
# mechanisms, so it cannot double as "already detected".
QEMU_IN_ROOTFS=""
RUNNER_DETECTED=0

# --- option parsing ----------------------------------------------------------

DO_BAKE=1
KEEP_WORK=0
DO_VERIFY=0
REQUIRE_PROOT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-bake)   DO_BAKE=0 ;;
        --keep-work) KEEP_WORK=1 ;;
        --verify)    DO_VERIFY=1 ;;
        --require-proot) REQUIRE_PROOT=1 ;;
        --tag)       DEBIAN_TAG="${2:?--tag needs a value}"; shift ;;
        --output)    ROOTFS_FILE="${2:?--output needs a value}"; shift ;;
        -h|--help)
            sed -n '2,40p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# --- helpers -----------------------------------------------------------------

log()  { printf '  %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required (install it first)"
}

# Pick a scratch directory that actually exists and is writable.
#
# Do not trust $TMPDIR. A caller can hand us one that is unusable — e.g. an
# Android host app exporting its own cache path, which does not exist inside
# this container — and every tool that calls mktemp() (tar, apt, dpkg's
# maintainer scripts) then dies with a bare "No such file or directory" that
# says nothing about the real cause. Re-export the value we settle on so
# children inherit a working one.
pick_tmpdir() {
    local candidate
    for candidate in "${TMPDIR:-}" /tmp /var/tmp "${HOME:-/root}/tmp"; do
        [ -n "$candidate" ] || continue
        if [ -d "$candidate" ] && [ -w "$candidate" ]; then
            TMPDIR="$candidate"
            export TMPDIR
            return 0
        fi
    done
    die "no writable temporary directory (tried \$TMPDIR, /tmp, /var/tmp)"
}

# chroot needs root; CI runners have passwordless sudo, local arm64 hosts and
# containers are usually already root.
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else
    command -v sudo >/dev/null 2>&1 || die "chroot needs root, and sudo was not found"
    SUDO="sudo"
fi

WORK_DIR=""
cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        # Never leave a host /proc or /dev bind behind for tar to pick up.
        if mountpoint -q "$WORK_DIR/rootfs/proc" 2>/dev/null; then
            $SUDO umount "$WORK_DIR/rootfs/proc" 2>/dev/null || true
        fi
        if mountpoint -q "$WORK_DIR/rootfs/dev" 2>/dev/null; then
            $SUDO umount "$WORK_DIR/rootfs/dev" 2>/dev/null || true
        fi
        [ "$KEEP_WORK" -eq 1 ] || rm -rf "$WORK_DIR"
        [ "$KEEP_WORK" -eq 1 ] && log "work tree kept at $WORK_DIR"
    fi
}
trap cleanup EXIT

# --- registry access ---------------------------------------------------------

registry_token() {
    # Retries because auth.docker.io is a third party: a CI runner behind a
    # flaky egress proxy hits bare SSLEOFError/5xx here often enough that a
    # single attempt turns into a spurious red build.
    local attempt out
    for attempt in 1 2 3 4 5; do
        out="$(curl -fsSL --retry 3 --retry-all-errors --retry-delay 2 --max-time 60 \
            "$DEBIAN_AUTH?service=registry.docker.io&scope=repository:${DEBIAN_REPOSITORY}:pull" \
            2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])' 2>/dev/null || true)"
        if [ -n "$out" ]; then
            printf '%s' "$out"
            return 0
        fi
        log "registry auth attempt $attempt failed, retrying..."
        sleep 3
    done
    return 1
}

# GET a registry URL with retries, printing the body on stdout.
# curl (not python) because curl's --retry-all-errors covers the TLS resets and
# half-closed connections that a filtered egress connection produces, and a
# bare urllib call turns those into a hard traceback mid-build.
registry_get() {
    local url="$1" accept="$2"
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --max-time 120 \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: $accept" \
        "$url"
}

ACCEPT_MANIFEST_ANY="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
ACCEPT_MANIFEST_IMAGE="application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

# Prints the arm64/v8 child-manifest digest for a multi-arch image tag.
resolve_manifest_digest() {
    registry_get "https://$DEBIAN_REGISTRY/v2/$DEBIAN_REPOSITORY/manifests/$DEBIAN_TAG" \
        "$ACCEPT_MANIFEST_ANY" \
        | python3 -c '
import json, sys
want_arch, want_variant = sys.argv[1], sys.argv[2]
doc = json.load(sys.stdin)
if "manifests" not in doc:
    sys.exit("expected a multi-arch index for this tag")
for entry in doc["manifests"]:
    platform = entry.get("platform") or {}
    if platform.get("architecture") != want_arch:
        continue
    if want_variant and platform.get("variant") not in (None, want_variant):
        continue
    print(entry["digest"])
    break
else:
    sys.exit("no %s/%s manifest in the index" % (want_arch, want_variant))
' "$DEBIAN_PLATFORM_ARCH" "$DEBIAN_PLATFORM_VARIANT"
}

# Prints "<layer-digest> <layer-size>" for an image manifest.
resolve_layer() {
    registry_get "https://$DEBIAN_REGISTRY/v2/$DEBIAN_REPOSITORY/manifests/$1" \
        "$ACCEPT_MANIFEST_IMAGE" \
        | python3 -c '
import json, sys
layers = json.load(sys.stdin).get("layers") or []
if len(layers) != 1:
    sys.exit("expected exactly one layer for debian:*-slim, got %d" % len(layers))
print(layers[0]["digest"], layers[0]["size"])
'
}

fetch_layer() {
    local digest="$1" out="$2"
    # --retry-all-errors matters: a filtered egress connection fails in the
    # middle of the body with a TLS reset, and plain --retry only covers
    # connection setup, so the build dies on a transient blip.
    curl -fSL --retry 5 --retry-all-errors --retry-delay 2 --max-time 900 \
        -H "Authorization: Bearer $TOKEN" \
        "https://$DEBIAN_REGISTRY/v2/$DEBIAN_REPOSITORY/blobs/$digest" \
        -o "$out"
}

# --- in-rootfs execution -----------------------------------------------------

# Runs "$@" inside $ROOTFS as a login-free root shell with a CLEAN environment.
#
# The clean environment is not cosmetic: the host's TMPDIR leaks into the
# chroot otherwise, and Debian maintainer scripts call mktemp() — wh h TMPDIR
# points at a host-only path that doesn't exist inside the rootfs, mktemp
# fails and apt aborts mid-transaction, leaving packages half-configured
# (observed: ca-certificates left in state "iF" with no CA bundle installed).
chroot_run() {
    local root="$1"; shift
    $SUDO chroot "$root" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root TMPDIR=/tmp TERM=dumb LC_ALL=C LANG=C \
        DEBIAN_FRONTEND=noninteractive \
        "$@"
}

# Picks how to execute aarch64 binaries inside the rootfs. Three ways exist in
# the wild and the choice is made by probing, not by assuming:
#
#   1. the host IS aarch64 — nothing to do;
#   2. an explicit `qemu-aarch64-static` is on PATH — copy it into the rootfs
#      and exec through it, the way `debootstrap --foreign` does. Self-contained
#      and does not need binfmt_misc registered;
#   3. binfmt_misc already routes aarch64 — probed by actually running a binary,
#      because that is the only honest test. This is how GitHub runners work
#      now: on ubuntu-26.04 there is no `qemu-user-static` package at all
#      (`qemu-user` ships a dynamically linked /usr/bin/qemu-aarch64 that cannot
#      be copied into a rootfs), and the supported route is
#      docker/setup-qemu-action, which registers handlers with static binaries
#      on the host kernel.
#
# Runners moved from 24.04 to 26.04 and silently broke the old assumption, so
# the failure mode here is deliberately explicit rather than a guess.
detect_runner() {
    local root="$1"

    case "$(uname -m)" in
        aarch64|arm64)
            log "host is $(uname -m) — executing the rootfs natively"
            QEMU_IN_ROOTFS=""
            RUNNER_DETECTED=1
            return 0
            ;;
    esac

    if command -v qemu-aarch64-static >/dev/null 2>&1; then
        log "host is $(uname -m) — using qemu-aarch64-static to execute aarch64 binaries"
        $SUDO install -m 0755 "$(command -v qemu-aarch64-static)" \
            "$root/usr/bin/qemu-aarch64-static"
        QEMU_IN_ROOTFS="/usr/bin/qemu-aarch64-static"
        RUNNER_DETECTED=1
        return 0
    fi

    if binfmt_handles_aarch64 "$root"; then
        log "host is $(uname -m) — binfmt_misc handles aarch64, using a plain chroot"
        QEMU_IN_ROOTFS=""
        RUNNER_DETECTED=1
        return 0
    fi

    cat >&2 <<'EOF'
Error: this host is not aarch64, and neither qemu-aarch64-static nor a binfmt_misc
       handler for aarch64 is available, so the base package set cannot be baked
       into an aarch64 rootfs.

       Pick whichever fits the host:
         * GitHub Actions:  use docker/setup-qemu-action@v3 (recommended; the
           `qemu-user-static` package no longer exists on ubuntu-26.04)
         * Debian/Ubuntu:   sudo apt-get install -y qemu-user-static
                            (or qemu-user-binfmt on newer releases)
         * Build on an arm64 runner or an Apple Silicon Mac.

       Or pass --no-bake to produce the bare rootfs (the sandbox will then be
       missing ps/less/vi/awk/curl/wget until the agent installs them).
EOF
    return 1
}

# The only honest test for emulation: run an aarch64 binary and see if it works.
# /bin/true exists in every Debian image and does nothing.
binfmt_handles_aarch64() {
    local root="$1"
    [ -x "$root/bin/true" ] || return 1
    $SUDO chroot "$root" /bin/true >/dev/null 2>&1
}

chroot_exec() { # chroot_exec <root> <cmd...>
    local root="$1"; shift
    if [ -n "${QEMU_IN_ROOTFS:-}" ]; then
        chroot_run "$root" "$QEMU_IN_ROOTFS" "$@"
    else
        chroot_run "$root" "$@"
    fi
}

# --- stages ------------------------------------------------------------------

check_prerequisites() {
    step "Checking prerequisites"
    pick_tmpdir
    need curl
    need tar
    need python3
    need gzip
    log "curl, tar, python3, gzip present"
    log "scratch space: $TMPDIR"

    # Fail fast: this one is not a tool we can install for you, and it is
    # pointless to spend minutes building a rootfs we then refuse to ship.
    #
    # A warning, not an error, because the two assets are independent: the
    # rootfs tarball does not depend on PRoot at all, and CI builds them in
    # separate jobs (then merges them). Pass --require-prroto / --require-proot
    # when you want a missing binary to fail the run.
    if [ -f "$PROOT_FILE" ]; then
        log "PRoot binary present: $PROOT_FILE ($(du -h "$PROOT_FILE" | cut -f1))"
    elif [ "$REQUIRE_PROOT" -eq 1 ]; then
        echo "Error: $PROOT_FILE is missing (--require-proot)." >&2
        echo "       It is built from source by ./deps/build_proot.sh — run that first." >&2
        exit 1
    else
        log "note: $PROOT_FILE is absent — run ./deps/build_proot.sh before packaging the app"
    fi
}

resolve_image() {
    step "Resolving $DEBIAN_REPOSITORY:$DEBIAN_TAG ($DEBIAN_PLATFORM_ARCH/$DEBIAN_PLATFORM_VARIANT)"
    TOKEN="$(registry_token || true)"
    [ -n "$TOKEN" ] || die "registry authentication failed (auth.docker.io unreachable after 5 attempts)"

    if [ -n "${DEBIAN_DIGEST:-}" ]; then
        MANIFEST_DIGEST="$DEBIAN_DIGEST"
        log "using pinned manifest digest from DEBIAN_DIGEST"
    else
        MANIFEST_DIGEST="$(resolve_manifest_digest)"
    fi
    [ -n "$MANIFEST_DIGEST" ] || die "could not resolve a manifest for $DEBIAN_TAG"

    read -r LAYER_DIGEST LAYER_SIZE <<EOF
$(resolve_layer "$MANIFEST_DIGEST")
EOF
    [ -n "$LAYER_DIGEST" ] || die "could not resolve the rootfs layer"

    log "manifest: $MANIFEST_DIGEST"
    log "layer:    $LAYER_DIGEST ($((LAYER_SIZE / 1024 / 1024)) MB compressed)"
}

unpack_rootfs() {
    local root="$1"
    step "Downloading and unpacking the rootfs layer"
    mkdir -p "$(dirname "$root")"
    mkdir -p "$root"

    local layer_file="$WORK_DIR/layer.tar.gz"
    fetch_layer "$LAYER_DIGEST" "$layer_file"
    log "downloaded $(du -h "$layer_file" | cut -f1)"

    # The official debian:*-slim images are a single layer, so this is the
    # whole rootfs. Never trust the archive's ownership metadata.
    $SUDO tar -xzf "$layer_file" -C "$root" --no-same-owner
    rm -f "$layer_file"
    log "unpacked $(du -sh "$root" | cut -f1)"
}

bake_base_packages() {
    local root="$1"
    [ "$DO_BAKE" -eq 1 ] || { log "--no-bake: skipping the base package set"; return 0; }

    step "Baking the base package set"
    detect_runner "$root" || die "cannot execute aarch64 binaries on this host"

    # apt writes DNS + temporary files; give it both.
    $SUDO cp -f /etc/resolv.conf "$root/etc/resolv.conf" 2>/dev/null || true

    # Best-effort /proc and /dev: a few maintainer scripts look at them. Both
    # are unmounted again in cleanup(); the tar step also wipes their contents.
    $SUDO mount -t proc proc "$root/proc" 2>/dev/null || true
    $SUDO mount --bind /dev "$root/dev" 2>/dev/null || true

    log "packages: $BASE_PACKAGES"
    chroot_exec "$root" /bin/bash -eu -c "
        # Keep the image small: no docs, no man pages, no translated apt
        # indexes. Written before any install so the very first apt run obeys
        # it, and left in place so later in-sandbox installs inherit it.
        mkdir -p /etc/dpkg/dpkg.cfg.d /etc/apt/apt.conf.d
        printf 'path-exclude=/usr/share/doc/*\npath-exclude=/usr/share/man/*\npath-exclude=/usr/share/info/*\npath-include=/usr/share/doc/*/copyright\n' \
            > /etc/dpkg/dpkg.cfg.d/01-nodoc
        printf 'Acquire::Languages { \"none\"; };\nAcquire::Retries \"3\";\n' \
            > /etc/apt/apt.conf.d/99minis

        apt-get update -qq
        apt-get install -y -qq --no-install-recommends $BASE_PACKAGES

        # Drop the indexes and caches: the sandbox fetches its own when the
        # agent runs apt-get, and they cost ~10 MB here.
        apt-get clean
        rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin
        rm -rf /tmp/* /var/tmp/*
    "
    log "base packages installed ($(du -sh "$root" | cut -f1) extracted)"

    $SUDO umount "$root/dev" 2>/dev/null || true
    $SUDO umount "$root/proc" 2>/dev/null || true
}

# Removes the qemu shim (if any) so it never ends up in the shipped asset.
drop_qemu() {
    local root="$1"
    if [ -n "${QEMU_IN_ROOTFS:-}" ]; then
        $SUDO rm -f "$root/usr/bin/qemu-aarch64-static"
        QEMU_IN_ROOTFS=""
    fi
}

# Iteratively empty a directory: a plain `rm -rf` is not always enough.
# Device nodes (and the hardlink sentinels PRoot's link2symlink leaves behind)
# can survive the first pass, so repeat on whatever is named and report what,
# if anything, refuses to go.
empty_dir() {
    local d="$1" pass name rest
    [ -d "$d" ] || return 0
    for pass in 1 2 3; do
        $SUDO find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
        rest="$(ls -A "$d" 2>/dev/null || true)"
        [ -z "$rest" ] && return 0
        # shellcheck disable=SC2086
        for name in $rest; do
            $SUDO rm -rf -- "$d/$name" 2>/dev/null || $SUDO unlink "$d/$name" 2>/dev/null || true
        done
    done
    rest="$(ls -A "$d" 2>/dev/null || true)"
    [ -z "$rest" ] || log "warning: could not empty $d (left: $rest)"
}

configure_rootfs() {
    local root="$1"
    step "Configuring the rootfs for PRoot"

    # PRoot is launched with `-b /dev -b /proc -b /sys`, so the guest sees the
    # HOST's device and kernel trees. These must therefore be EMPTY
    # directories in the image: anything left here (a stray /dev/null created
    # by an apt run, a mounted proc) would either shadow the host bind or be
    # baked into the asset.
    for d in dev proc sys run/lock tmp var/tmp; do
        $SUDO mkdir -p "$root/$d"
    done
    for d in dev proc sys; do
        empty_dir "$root/$d"
    done

    # The image is built for a container: hostname is "debuerreotype".
    printf 'minis\n' | $SUDO tee "$root/etc/hostname" >/dev/null

    # Belt and braces — the host overwrites this on every boot and on every
    # network change (RootfsManager.refreshDns), but a rootfs without it makes
    # the very first `apt-get` after a cold install fail with a name error.
    printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' | $SUDO tee "$root/etc/resolv.conf" >/dev/null

    if [ -n "$MIRROR_HOST" ]; then
        log "rewriting apt sources to $MIRROR_HOST"
        $SUDO tee "$root/etc/apt/sources.list.d/debian.sources" >/dev/null <<EOF
Types: deb
URIs: https://$MIRROR_HOST/debian
Suites: $DEBIAN_SUITE ${DEBIAN_SUITE}-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://$MIRROR_HOST/debian-security
Suites: ${DEBIAN_SUITE}-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    fi

    # Same motd banner the Alpine image shipped, retargeted to Debian.
    $SUDO tee "$root/etc/motd" >/dev/null <<'EOF'

  __  __ _       _        _    _ _
 |  \/  (_)_ __ (_)___   | |  (_) |_ ___
 | |\/| | | '_ \| / __|  | |  | | __/ _ \
 | |  | | | | | | \__ \  | |__| | ||  __/
 |_|  |_|_|_| |_|_|___/  |____|_|\__\___|

 Welcome to Minis Linux Shell
 Debian GNU/Linux 12 (bookworm) aarch64 on PRoot

EOF

    # The app overlays assets/default_mount/ on every boot, so /etc/profile.d
    # and the URL wrappers are NOT written here — they would be overwritten
    # anyway. Only image-level state belongs in the asset.

    log "apt sources: $(ls "$root/etc/apt/sources.list.d/" 2>/dev/null | tr '\n' ' ')"
}

# Last thing done to the staging tree before it is packed.
#
# /dev, /proc and /sys must ship EMPTY: PRoot launches the guest with
# `-b /dev -b /proc -b /sys`, so the host's trees are bound on top of these
# directories. Anything baked in here is either shadowed at runtime (dead
# weight) or, if it is a device node, an entry type the app's own tar parser
# cannot extract.
#
# This runs AFTER verify, not before, because the checks themselves execute
# aarch64 binaries inside the rootfs and some environments materialise
# /dev/null as a regular file the moment a process redirects into it (observed
# when the build host is itself a PRoot container, where mknod is impossible).
# Wiping last makes the guarantee independent of whatever the checks did.
finalize_rootfs() {
    local root="$1"
    step "Finalising (host binds need empty /dev, /proc, /sys)"
    for d in dev proc sys; do
        $SUDO mkdir -p "$root/$d"
        empty_dir "$root/$d"
    done

    local stray
    stray="$({ ls -A "$root/dev"; ls -A "$root/proc"; ls -A "$root/sys"; } 2>/dev/null | head -5)"
    if [ -n "$stray" ]; then
        printf '%s\n' "$stray" >&2
        die "/dev, /proc and /sys must be empty in the shipped image"
    fi
    log "ok   /dev, /proc, /sys are empty"
}

pack_rootfs() {
    local root="$1"
    step "Packing $ROOTFS_ASSET_NAME"
    $SUDO mkdir -p "$(dirname "$ROOTFS_FILE")"
    rm -f "$ROOTFS_FILE"

    # --numeric-owner: the asset is extracted by the app's own POSIX tar
    #   parser, which does not do name lookups; 0/0 is what it expects.
    # --sort=name + no atime/ctime: byte-stable output across runs so a rebuilt
    #   identical image does not churn the asset in git.
    # --exclude='.l2s.*': PRoot's link2symlink extension rewrites every kernel
    #   hardlink into a `.<name>` symlink plus a `.l2s.<name>` copy of the
    #   content. Those sentinels are build-host artefacts, not image content —
    #   and they are mutually referential, so tar aborts on them with
    #   "Symbolic link loop". They must never ship; the image must contain the
    #   real files. (See warn_if_traced() — a PRoot build host is not a valid
    #   source for a shippable asset in the first place.)
    local extra=""
    if tar --version 2>/dev/null | head -1 | grep -q 'GNU tar'; then
        # --hard-dereference: store hardlinked files as independent copies.
        #
        # The app extracts the asset with its own hand-rolled POSIX tar parser
        # (RootfsManager.extractTar). For a type-'1' entry it does
        # `File(targetDir, linkName).copyTo(outFile)` ONLY IF the link target
        # already exists — otherwise it silently skips the entry. That makes
        # every hardlink in the image depend on tar happening to emit the
        # target before the link. Debian has several (gunzip→gzip,
        # uncompress→gunzip, zipinfo→unzip, perl5.36.0→perl), and a silently
        # missing binary inside the sandbox is not a failure anyone would
        # attribute to the packer. Dereferencing costs a few MB and removes the
        # whole class of problem, so the archive never contains a type-'1'
        # entry at all.
        extra="--hard-dereference --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 --no-acls --no-xattrs"
    fi

    # shellcheck disable=SC2086
    $SUDO tar $extra -czf "$ROOTFS_FILE" -C "$root" \
        --exclude='./.l2s.*' --exclude='.l2s.*' \
        .

    # The app's extractor only understands regular files ('-'), directories
    # ('d') and symlinks ('l'). Anything else — hardlinks ('h'), device nodes,
    # fifos, GNU/PAX long-name extension headers — is either mis-extracted or
    # dropped without a word, so refuse to ship such an asset.
    local weird
    weird="$($SUDO tar -tvzf "$ROOTFS_FILE" 2>/dev/null | grep -vE '^[-dl]' | head -5 || true)"
    if [ -n "$weird" ]; then
        printf '%s\n' "$weird" >&2
        die "the archive contains entry types the app's tar parser cannot extract"
    fi

    log "$ROOTFS_FILE ($(du -h "$ROOTFS_FILE" | cut -f1))"
}

write_provenance() {
    local root="$1"
    local meta="$ASSETS_DIR/debian-rootfs.version"
    [ "$(dirname "$ROOTFS_FILE")" = "$ASSETS_DIR" ] || return 0
    local packages=""
    if [ "$DO_BAKE" -eq 1 ]; then
        packages="$(chroot_exec "$root" /usr/bin/dpkg-query -W -f='${Package} ' 2>/dev/null || true)"
    fi
    cat > "$meta" <<EOF
# Generated by scripts/prepare_android_sandbox.sh — do not edit by hand.
image=$DEBIAN_REPOSITORY:$DEBIAN_TAG
platform=linux/$DEBIAN_PLATFORM_ARCH/$DEBIAN_PLATFORM_VARIANT
manifest_digest=$MANIFEST_DIGEST
layer_digest=$LAYER_DIGEST
layer_bytes=$LAYER_SIZE
baked_base_packages=$([ "$DO_BAKE" -eq 1 ] && echo "$BASE_PACKAGES" || echo "(none)")
mirror_host=${MIRROR_HOST:-(upstream)}
package_count=$(printf '%s' "$packages" | wc -w | tr -d ' ')
EOF
    log "provenance written to $meta"
}

verify_asset() {
    local root="$1"
    step "Verifying the built rootfs"
    # Verification executes aarch64 binaries too, and with --no-bake nothing has
    # set the runner up yet. QEMU_IN_ROOTFS being empty is NOT a reliable
    # "already detected" signal — binfmt mode legitimately leaves it empty — so
    # track detection explicitly instead of inferring it.
    if [ "$RUNNER_DETECTED" -eq 0 ]; then
        detect_runner "$root" || die "cannot execute aarch64 binaries on this host"
    fi
    local failures=0
    check() { # check <description> <test-cmd...>
        local desc="$1"; shift
        if chroot_exec "$root" "$@" >/dev/null 2>&1; then
            log "ok   $desc"
        else
            printf '  FAIL %s\n' "$desc" >&2
            failures=$((failures + 1))
        fi
    }
    check "/etc/os-release reports Debian 12 (bookworm)" \
        /bin/bash -c 'grep -q "Debian GNU/Linux 12 (bookworm)" /etc/os-release'
    check "/bin/bash is present and runs" /bin/bash -c 'test -x /bin/bash'
    check "/bin/sh is dash" /bin/bash -c '[ "$(readlink -f /bin/sh)" = "/usr/bin/dash" ]'
    check "apt-get and dpkg are present" /bin/bash -c 'command -v apt-get >/dev/null && command -v dpkg >/dev/null'
    check "no apk / busybox left behind" /bin/bash -c '! command -v apk >/dev/null && [ ! -e /bin/busybox ]'
    check "resolv.conf present" /bin/bash -c 'test -s /etc/resolv.conf'
    check "deb822 apt sources present" /bin/bash -c 'ls /etc/apt/sources.list.d/*.sources >/dev/null'

    if [ "$DO_BAKE" -eq 1 ]; then
        check "procps baked in (ps/top)" /bin/bash -c 'command -v ps >/dev/null && command -v top >/dev/null'
        check "less, curl, wget, gawk, unzip, xz, vi baked in" \
            /bin/bash -c 'for c in less curl wget gawk unzip xz vi; do command -v "$c" >/dev/null || exit 1; done'
        check "CA bundle installed" /bin/bash -c 'test -s /etc/ssl/certs/ca-certificates.crt'
    fi

    if [ "$failures" -ne 0 ]; then
        die "$failures verification check(s) failed"
    fi
    log "all checks passed"
}

# --- main --------------------------------------------------------------------

# A build host that is itself a PRoot container cannot produce a shippable
# asset: PRoot's link2symlink extension rewrites kernel hardlinks, so the
# staging tree the host sees is not the tree the image contains (hardlinked
# binaries appear as symlink + `.l2s.<name>` copy instead of one inode with
# two names). We still build — the result is useful for testing — but say so
# loudly instead of handing over a subtly wrong tarball in silence.
warn_if_traced() {
    local tracer comm=""
    tracer="$(awk '/^TracerPid:/ {print $2}' /proc/self/status 2>/dev/null || true)"
    [ -n "$tracer" ] && [ "$tracer" != "0" ] || return 0
    [ -r "/proc/$tracer/comm" ] && comm="$(cat "/proc/$tracer/comm" 2>/dev/null || true)"
    # Fall back to a PRoot-only variable when /proc is not readable.
    case "$comm$PROOT_READONLY_PATHS${PROOT_NO_SECCOMP:-}" in
        *proot*|*READONLY_PATHS*) ;;
        *) return 0 ;;
    esac
    cat >&2 <<'EOF'

  ┌─ WARNING ────────────────────────────────────────────────────────────────┐
  │ This build host is running under PRoot (tracer: proot).                   │
  │ Hardlinks in the staging tree have been rewritten by link2symlink, so the │
  │ `debian-rootfs.tar.gz` produced here is NOT a shippable release asset —   │
  │ hardlinked binaries (gunzip→gzip, unzip→zipinfo, perl→perl5.x) can end up │
  │ as dangling symlinks. The structure, package set and configuration are    │
  │ still valid for review and CI dry runs.                                   │
  │ Build the release asset on a plain Linux host or in GitHub Actions.       │
  └───────────────────────────────────────────────────────────────────────────┘

EOF
}

main() {
    echo
    echo "============================================================"
    echo "  Debian rootfs preparation for the Android (PRoot) sandbox"
    echo "  Image: $DEBIAN_REPOSITORY:$DEBIAN_TAG ($DEBIAN_PLATFORM_ARCH)"
    echo "============================================================"
    warn_if_traced

    check_prerequisites
    resolve_image

    WORK_DIR="$(mktemp -d "$TMPDIR/minis-debian-rootfs.XXXXXX")"
    local root="$WORK_DIR/rootfs"

    unpack_rootfs "$root"
    bake_base_packages "$root"
    configure_rootfs "$root"
    if [ "$DO_VERIFY" -eq 1 ]; then
        verify_asset "$root"
    fi
    drop_qemu "$root"
    finalize_rootfs "$root"
    pack_rootfs "$root"
    write_provenance "$root"

    echo
    echo "Assets ready in: $ASSETS_DIR"
    ls -lh "$ASSETS_DIR"
}

main "$@"
