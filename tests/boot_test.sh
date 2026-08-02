#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
elf=${KERNEL_ELF:-"$repo_root/build/zenc-os.elf"}
qemu=${QEMU:-qemu-system-i386}
timeout_s=${QEMU_TIMEOUT:-5}
marker=${BOOT_MARKER:-"Zenc OS booted"}

if [[ ! -f "$elf" ]]; then
    echo "boot test: missing kernel ELF: $elf" >&2
    exit 2
fi
command -v "$qemu" >/dev/null || {
    echo "boot test: missing QEMU executable: $qemu" >&2
    exit 2
}

output=$(mktemp "${TMPDIR:-/tmp}/zos-boot.XXXXXX")
trap 'rm -f "$output"' EXIT

set +e
timeout "${timeout_s}s" "$qemu" \
    -kernel "$elf" \
    -serial stdio \
    -display none \
    -monitor none \
    >"$output" 2>&1
qemu_status=$?
set -e

# A working MVP intentionally halts forever, so timeout(124) is expected.
# An early QEMU exit is allowed only if the marker was already emitted.
if ! grep -Fq "$marker" "$output"; then
    echo "boot test: marker not found: $marker" >&2
    sed -n '1,120p' "$output" >&2
    exit 1
fi

if [[ "$qemu_status" -ne 0 && "$qemu_status" -ne 124 ]]; then
    echo "boot test: QEMU failed with status $qemu_status" >&2
    sed -n '1,120p' "$output" >&2
    exit 1
fi

echo "boot test: PASS ($marker; qemu status $qemu_status)"
