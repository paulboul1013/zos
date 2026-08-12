#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
iso_image=${ISO_IMAGE:-"$repo_root/build/zenc-os.iso"}
qemu=${QEMU:-qemu-system-i386}
timeout_s=${QEMU_TIMEOUT:-6}
markers=(
    "${BOOT_MARKER:-Zenc OS booted}"
    "keyboard: ready"
    "shell task: ready"
    "shell task: running"
    "timer: ok"
)

if [[ ! -f "$iso_image" ]]; then
    echo "ISO test: missing image: $iso_image" >&2
    exit 2
fi
command -v "$qemu" >/dev/null || {
    echo "ISO test: missing QEMU executable: $qemu" >&2
    exit 2
}

output=$(mktemp "${TMPDIR:-/tmp}/zos-iso.XXXXXX")
trap 'rm -f "$output"' EXIT

set +e
timeout "${timeout_s}s" "$qemu" \
    -cdrom "$iso_image" \
    -serial stdio \
    -display none \
    -monitor none \
    >"$output" 2>&1
qemu_status=$?
set -e

for marker in "${markers[@]}"; do
    if ! grep -Fq "$marker" "$output"; then
        echo "ISO test: marker not found: $marker" >&2
        sed -n '1,160p' "$output" >&2
        exit 1
    fi
done

if [[ "$qemu_status" -ne 0 && "$qemu_status" -ne 124 ]]; then
    echo "ISO test: QEMU failed with status $qemu_status" >&2
    sed -n '1,160p' "$output" >&2
    exit 1
fi

echo "ISO test: PASS (boot/device markers; qemu status $qemu_status)"
