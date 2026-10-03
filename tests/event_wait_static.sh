#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
zc_bin=${ZC:-$(command -v zc || true)}
host_cc=${HOST_CC:-gcc}
[[ -n "$zc_bin" && -x "$zc_bin" ]] || { echo 'event wait: missing zc' >&2; exit 2; }
out_dir=$(mktemp -d "${TMPDIR:-/tmp}/zos-event-wait.XXXXXX")
trap 'rm -rf "$out_dir"' EXIT
for module in task keyboard; do
    "$zc_bin" transpile --freestanding "$repo_root/kernel/$module.zc" -o "$out_dir/$module.c"
done
for optimization in -O0 -O2; do
    "$host_cc" -std=gnu11 "$optimization" -Wall -Wextra -Werror -Wno-unused-variable \
        -DZC_FUNC= -DZC_GLOBAL= "$out_dir/task.c" "$out_dir/keyboard.c" \
        "$repo_root/tests/event_wait_host.c" -Wl,--wrap=task_block_on_locked \
        -o "$out_dir/harness"
    timeout 15s "$out_dir/harness"
    echo "event wait: PASS ($optimization production modules, actual host contexts)"
done
