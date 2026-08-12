#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
elf=${KERNEL_ELF:-"$repo_root/build/zenc-os.elf"}
qemu=${QEMU:-qemu-system-i386}
timeout_s=${QEMU_TIMEOUT:-5}

[[ -f "$elf" ]] || {
    echo "task boot test: missing kernel ELF: $elf" >&2
    exit 2
}
command -v "$qemu" >/dev/null || {
    echo "task boot test: missing QEMU executable: $qemu" >&2
    exit 2
}

output=$(mktemp "${TMPDIR:-/tmp}/zos-task-boot.XXXXXX")
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

if [[ "$qemu_status" -ne 0 && "$qemu_status" -ne 124 ]]; then
    echo "task boot test: QEMU failed with status $qemu_status" >&2
    sed -n '1,160p' "$output" >&2
    exit 1
fi

if ! awk '
    /task A1/ && state == 0 { state = 1; next }
    /task B1/ && state == 1 { state = 2; next }
    /task A2/ && state == 2 { state = 3; next }
    /task B2/ && state == 3 { state = 4; next }
    /tasks: done/ && state == 4 { state = 5; next }
    END { exit state == 5 ? 0 : 1 }
' "$output"; then
    echo "task boot test: cooperative task marker order not found" >&2
    sed -n '1,160p' "$output" >&2
    exit 1
fi

echo "task boot test: PASS (A1 -> B1 -> A2 -> B2 -> done)"
