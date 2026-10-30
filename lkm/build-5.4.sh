#!/usr/bin/env bash
# Build dfroot.ko for Android 11 / ACK android11-5.4 (5.4.x).
#
# The DDK images used by the top-level Makefile do not cover this KMI, so this
# script builds against a kernel tree that matches the device:
#
#   KDIR=/path/to/android11-5.4 ./lkm/build-5.4.sh
#
# The tree must be configured with the device's .config (the boot image embeds
# it as IKCONFIG) and have a Module.symvers from the same build, because the
# target kernel is built with CONFIG_MODVERSIONS=y.
#
# Optional environment:
#   MAKE_ARGS   extra arguments for the kernel build (default: ARCH=arm64 LLVM=1)
#   OUT         output path (default: app/src/main/jni/ko/dfroot-android11-5.4.ko)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
KDIR=${KDIR:?set KDIR to a kernel tree matching the device}
MAKE_ARGS=${MAKE_ARGS:-ARCH=arm64 LLVM=1}
OUT=${OUT:-$ROOT/app/src/main/jni/ko/dfroot-android11-5.4.ko}

die() { printf '\033[1;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }

[ -f "$KDIR/.config" ] || die "no .config in $KDIR (point KDIR at a configured kernel tree)"
[ -f "$KDIR/include/generated/utsrelease.h" ] || die "$KDIR is not built (missing include/generated/utsrelease.h)"
[ -f "$KDIR/Module.symvers" ] || die "$KDIR has no Module.symvers (CONFIG_MODVERSIONS=y needs it)"

REL=$(sed -n 's/^#define UTS_RELEASE "\(.*\)"$/\1/p' "$KDIR/include/generated/utsrelease.h")
[ -n "$REL" ] || die "cannot read UTS_RELEASE from $KDIR"
info "kernel release: $REL"

# The device kernel reports:
#   5.4.281-qgki-g4273d6fd2de9 SMP preempt mod_unload modversions aarch64
if ! printf '%s' "$REL" | grep -q '5\.4\.'; then
    printf '\033[1;33m⚠ UTS_RELEASE is %s, expected a 5.4.x tree\033[0m\n' "$REL"
fi

info "building module"
make -C "$KDIR" M="$HERE" $MAKE_ARGS DFROOT_KO_5_4=1 modules

[ -f "$HERE/dfroot.ko" ] || die "build did not produce lkm/dfroot.ko"

# Strip the sections the kernel does not need (same set as lkm/Makefile).
# --strip-debug keeps the symbol table, which lkm/Makefile's --strip-unneeded
# path would drop: the 5.4 kernel looks up the "__cfi_check" shim by name and
# panics if the module does not export it.
if command -v llvm-objcopy >/dev/null 2>&1; then
    OBJCOPY=llvm-objcopy
elif command -v aarch64-linux-gnu-objcopy >/dev/null 2>&1; then
    OBJCOPY=aarch64-linux-gnu-objcopy
elif command -v objcopy >/dev/null 2>&1; then
    OBJCOPY=objcopy
else
    die "no objcopy found (install llvm or binutils)"
fi
$OBJCOPY --strip-debug \
    -R .comment -R .note.gnu.property \
    -R .note.Linux -R .note.GNU-stack \
    -R .BTF -R .BTF.base -R .llvm_addrsig \
    -R .hyp.text -R .hyp.bss -R .hyp.rodata -R .hyp.event_ids \
    -R .hyp.patchable_function_entries -R .hyp.data \
    "$HERE/dfroot.ko"

# Sanity check the vermagic. The module must match the running kernel exactly,
# otherwise insmod fails with "version magic ... should be ...".
if command -v modinfo >/dev/null 2>&1; then
    VM=$(modinfo -F vermagic "$HERE/dfroot.ko" 2>/dev/null || true)
else
    VM=$(strings "$HERE/dfroot.ko" | grep -m1 'vermagic=' | sed 's/^vermagic=//' || true)
fi
info "module vermagic: ${VM:-<unknown>}"
printf '%s' "$VM" | grep -q "$REL" || printf '\033[1;33m⚠ vermagic does not contain %s; insmod will reject it\033[0m\n' "$REL"

mkdir -p "$(dirname "$OUT")"
cp "$HERE/dfroot.ko" "$OUT"
ok "wrote $OUT"
info "now rebuild the APK so CMake embeds the blob:  make"
