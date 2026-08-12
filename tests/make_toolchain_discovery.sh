#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
make_bin=${MAKE:-make}
command -v "$make_bin" >/dev/null || {
    echo "make toolchain discovery: make not found: $make_bin" >&2
    exit 2
}

out_dir=$(mktemp -d "${TMPDIR:-/tmp}/zos-make-tools.XXXXXX")
trap 'rm -rf "$out_dir"' EXIT

tool_dir="$out_dir/tools"
mkdir -p "$tool_dir"
for tool in zc i686-elf-gcc i686-elf-ld i686-elf-nm grub-file grub-mkrescue qemu-system-i386; do
    touch "$tool_dir/$tool"
    chmod 755 "$tool_dir/$tool"
done

output=$(env -u MAKEFLAGS -u MFLAGS -u MAKEOVERRIDES \
    -u ZC -u CROSS_PREFIX -u CROSS_CC -u CROSS_LD -u CROSS_NM \
    PATH="$tool_dir:/usr/bin:/bin" "$make_bin" \
    --no-print-directory -C "$repo_root" -n check-tools)

for expected in \
    "ZC=$tool_dir/zc" \
    "CC=$tool_dir/i686-elf-gcc" \
    "LD=$tool_dir/i686-elf-ld" \
    "NM=$tool_dir/i686-elf-nm"; do
    grep -Fq "$expected" <<<"$output" || {
        echo "make toolchain discovery: missing $expected" >&2
        echo "$output" >&2
        exit 1
    }
done

echo "make toolchain discovery: PASS"
