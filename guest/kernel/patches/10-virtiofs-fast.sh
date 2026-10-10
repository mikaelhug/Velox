#!/bin/sh
# Kernel source patch, applied by Scripts/build-kernel.sh inside the kernel tree before config
# (every `guest/kernel/patches/*.sh` runs, in name order). Anchors are checked: if upstream moves
# the code this edits, the BUILD FAILS LOUDLY — so a weekly version-watch kernel bump can never
# ship with the patch silently dropped (CI compiles the kernel before it releases).
#
# virtiofs "fast" mode — enabled by `virtiofs.velox_fast=1` on the kernel cmdline (Velox's
# VMConfiguration sets it; `=0` turns it off). Apple's VirtioFS server costs 11 synchronous
# FUSE round trips per extracted file vs OrbStack's 5 (traced, 2026-10-10). Three of them buy
# nothing on Apple's server, so the guest stops sending them:
#   1. FLUSH on close        — answered synchronously by Apple, one full round trip per
#                              close(). Writes are synchronous (no writeback cache), so there is
#                              no dirty data for FLUSH to push. This is the same state the kernel
#                              enters by itself when a server answers FLUSH with ENOSYS (no_flush).
#   2. security.capability   — every write and chown asks whether the file carries file
#      lookups                 capabilities (killpriv); Apple answers ENODATA, which FUSE does
#                              not cache: 2 GETXATTR round trips per written file. File
#                              capabilities on a Mac bind mount are not a thing.
#   3. chown                 — Apple's VirtioFS accepts chown and ignores it (the guest keeps
#                              seeing the old owner), so it is a pure round trip — two: chown sets
#                              ATTR_KILL_SUID|SGID, which makes fuse_setattr GETATTR first.
#                              Mode/time/size changes are still sent.
# Measured: busybox untar of 8,001 files into a bind mount 2.45 s → 1.67 s (requests per file
# 11 → 6); open+close 79 → 62 µs, open+write 4 KiB+close 122 → 90 µs.
# Idempotent on the persistent build volume: build-kernel.sh restores every *.velox-orig before
# any patch runs, so this script only has to save each original the first time.
set -e
for f in fs/fuse/fuse_i.h fs/fuse/virtio_fs.c fs/fuse/xattr.c fs/fuse/dir.c; do
    [ -f "$f.velox-orig" ] || cp "$f" "$f.velox-orig"
done
need() { grep -q "$2" "$1" || { echo "kpatch: anchor not found in $1: $2" >&2; exit 1; }; }

need fs/fuse/fuse_i.h 'unsigned no_flush:1;'
perl -0pi -e 's/(unsigned no_flush:1;)/$1\n\n\t\/** Velox: virtiofs fast mode (no FLUSH, no security.capability lookups) *\/\n\tunsigned velox_fast:1;/' fs/fuse/fuse_i.h

need fs/fuse/virtio_fs.c 'static LIST_HEAD(virtio_fs_instances);'
perl -0pi -e 's/(static LIST_HEAD\(virtio_fs_instances\);)/$1\n\nstatic bool velox_fast;\nmodule_param(velox_fast, bool, 0444);\nMODULE_PARM_DESC(velox_fast, "Velox: skip FLUSH and security.capability lookups");/' fs/fuse/virtio_fs.c
need fs/fuse/virtio_fs.c 'fc->delete_stale = true;'
perl -0pi -e 's/(fc->delete_stale = true;)/$1\n\tif (velox_fast) {\n\t\tfc->no_flush = 1;\n\t\tfc->velox_fast = 1;\n\t}/' fs/fuse/virtio_fs.c

need fs/fuse/xattr.c 'ssize_t fuse_getxattr('
perl -0pi -e 's/(ssize_t fuse_getxattr\([^)]*\)\n\{\n(?:[^\n]*\n)*?)(\tif \(fm->fc->no_getxattr\))/$1\tif (fm->fc->velox_fast \&\& !strcmp(name, "security.capability"))\n\t\treturn -ENODATA;\n\n$2/' fs/fuse/xattr.c
grep -q 'velox_fast' fs/fuse/xattr.c || { echo "kpatch: xattr.c edit did not apply" >&2; exit 1; }

# 3. chown (see the header): return before fuse_setattr's GETATTR when only owner/kill bits change.
need fs/fuse/dir.c 'static int fuse_setattr('
perl -0pi -e 's/(static int fuse_setattr\([^)]*\)\n\{\n(?:[^\n]*\n)*?\tstruct fuse_conn \*fc = get_fuse_conn\(inode\);\n)/$1\tif (fc->velox_fast \&\& !(attr->ia_valid \& ~(ATTR_UID | ATTR_GID | ATTR_KILL_SUID | ATTR_KILL_SGID | ATTR_KILL_PRIV | ATTR_CTIME | ATTR_FORCE)))\n\t\treturn 0;\n/' fs/fuse/dir.c
grep -q 'velox_fast' fs/fuse/dir.c || { echo "kpatch: dir.c edit did not apply" >&2; exit 1; }
echo "kpatch: virtiofs fast mode wired (fuse_i.h, virtio_fs.c, xattr.c, dir.c)"
