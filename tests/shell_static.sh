#!/usr/bin/env bash
set -euo pipefail

# Task 10 owns only kernel/shell.zc and this isolated freestanding check.
# Integration with kernel/kernel.zc and boot_test.sh is performed by root.
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
zc_bin=${ZC:-/home/paulboul/zenc/zc}
cross_prefix=${CROSS_PREFIX:-/home/paulboul/osdev/opt/cross/bin/i686-elf-}
cross_cc=${CROSS_CC:-${cross_prefix}gcc}
cross_nm=${CROSS_NM:-${cross_prefix}nm}
host_cc=${HOST_CC:-gcc}

[[ -x "$zc_bin" ]] || { echo "shell static: zc not found: $zc_bin" >&2; exit 2; }
[[ -x "$cross_cc" ]] || { echo "shell static: cross gcc not found: $cross_cc" >&2; exit 2; }
command -v "$host_cc" >/dev/null || { echo "shell static: host gcc not found" >&2; exit 2; }

out_dir=$(mktemp -d "${TMPDIR:-/tmp}/zos-shell-check.XXXXXX")
trap 'rm -rf "$out_dir"' EXIT

generated="$out_dir/shell.c"
object="$out_dir/shell.o"
"$zc_bin" transpile --freestanding "$repo_root/kernel/shell.zc" -o "$generated"

grep -q 'shell_init' "$repo_root/kernel/shell.zc"
grep -q 'shell_feed_char' "$repo_root/kernel/shell.zc"
grep -q 'SHELL_BUFFER_CAPACITY: u32 = 64' "$repo_root/kernel/shell.zc"
grep -q 'console_clear' "$repo_root/kernel/shell.zc"
grep -q 'timer_ticks' "$repo_root/kernel/shell.zc"
grep -q 'unknown command' "$repo_root/kernel/shell.zc"
! grep -Eq '#include[[:space:]]*[<"](stdlib|string|stdio)\.h' "$repo_root/kernel/shell.zc"

# Cross object check proves that the generated shell remains i686-compatible
# and has no hidden hosted runtime dependency.
"$cross_cc" -std=gnu11 -m32 -ffreestanding -fno-builtin \
    -fno-stack-protector -Wall -Wextra -DZC_FUNC= -DZC_GLOBAL= \
    -c "$generated" -o "$object"
"$cross_nm" -g --defined-only "$object" | grep -Eq '[[:space:]]shell_init$'
"$cross_nm" -g --defined-only "$object" | grep -Eq '[[:space:]]shell_feed_char$'
if "$cross_nm" -u "$object" | grep -Eq '(strcmp|strlen|malloc|free|puts|printf)'; then
    echo "shell static: hosted runtime symbol leaked into shell object" >&2
    exit 1
fi

# Host-side harness exercises command dispatch without hardware.  The shell
# calls only its declared console/timer ABI, so stubs make this deterministic.
"$host_cc" -std=gnu11 -Wall -Wextra -DZC_FUNC= -DZC_GLOBAL= \
    "$generated" -x c -o "$out_dir/harness" - <<'EOF'
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern void shell_init(void);
extern void shell_feed_char(uint8_t ch);

static char log_buffer[4096];
static size_t log_length;
static unsigned clear_calls;

static void log_reset(void) {
    log_length = 0;
    log_buffer[0] = '\0';
    clear_calls = 0;
}

void console_putc(uint8_t ch) {
    if (log_length + 1 < sizeof(log_buffer)) {
        log_buffer[log_length++] = (char)ch;
        log_buffer[log_length] = '\0';
    }
}

void console_write(const char *text) {
    while (text != NULL && *text != '\0') {
        console_putc((uint8_t)*text++);
    }
}

void console_clear(void) {
    clear_calls++;
}

uint32_t timer_ticks(void) {
    return 42;
}

static void feed(const char *text) {
    while (*text != '\0') {
        shell_feed_char((uint8_t)*text++);
    }
}

int main(void) {
    log_reset();
    shell_init();
    assert(strcmp(log_buffer, "zos> ") == 0);

    feed("help\n");
    assert(strstr(log_buffer, "commands: help clear about ticks\n") != NULL);

    log_reset();
    shell_init();
    feed("about\n");
    assert(strstr(log_buffer, "Zenc OS shell\n") != NULL);

    log_reset();
    shell_init();
    feed("ticks\n");
    assert(strstr(log_buffer, "ticks: 42\n") != NULL);

    log_reset();
    shell_init();
    feed("clear\n");
    assert(clear_calls == 1);

    log_reset();
    shell_init();
    feed("ab\b\n");
    assert(strstr(log_buffer, "unknown command\n") != NULL);

    puts("shell harness: PASS");
    return 0;
}
EOF

"$out_dir/harness"
echo "shell static: PASS (freestanding transpile + i686 object + command harness)"
