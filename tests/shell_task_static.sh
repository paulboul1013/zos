#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
interrupt_source="$repo_root/kernel/interrupts.zc"
shell_source="$repo_root/kernel/shell.zc"
kernel_source="$repo_root/kernel/kernel.zc"

# IRQ dispatch may invoke the keyboard producer, but shell, console, and task
# scheduling must stay outside interrupt context.
! grep -Eq 'shell_feed_char|console_(putc|write|clear)|task_yield' \
    "$interrupt_source"

grep -q 'fn shell_task()' "$shell_source"
grep -q 'keyboard_queue_pop' "$shell_source"
grep -q 'task_yield' "$shell_source"
grep -q 'task_create(shell_task)' "$kernel_source"
grep -q 'shell task: ready' "$kernel_source"
grep -q 'shell task: running' "$kernel_source"
! grep -Eq '_task_demo_|task A[12]|task B[12]|tasks: done' "$kernel_source"

# The idle loop must offer READY tasks CPU time before halting until an IRQ.
awk '
    /while true/ { in_loop = 1 }
    in_loop && /task_yield\(\)/ { saw_yield = 1 }
    in_loop && /"hlt"/ && saw_yield { saw_hlt_after_yield = 1 }
    END { exit saw_hlt_after_yield ? 0 : 1 }
' "$kernel_source"

echo "shell task static: PASS (IRQ boundary + task integration + idle loop)"
