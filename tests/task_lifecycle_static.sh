#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out_dir=$(mktemp -d "${TMPDIR:-/tmp}/zos-lifecycle.XXXXXX")
trap 'rm -rf "$out_dir"' EXIT
zc_bin=${ZC:-zc}
host_cc=${HOST_CC:-gcc}
"$zc_bin" transpile --freestanding "$repo_root/kernel/task.zc" -o "$out_dir/task.c"
"$zc_bin" transpile --freestanding "$repo_root/kernel/keyboard.zc" -o "$out_dir/keyboard.c"
for optimization in -O0 -O2; do
    "$host_cc" -std=gnu11 "$optimization" -Wall -Wextra -Werror -Wno-unused-variable \
        -DZC_FUNC= -DZC_GLOBAL= -DZOS_EVENT_WAIT_TEST "$out_dir/task.c" "$out_dir/keyboard.c" \
        "$repo_root/tests/task_lifecycle_host.c" -o "$out_dir/harness"
    timeout 15s "$out_dir/harness"
    echo "task lifecycle: PASS ($optimization, production task module)"
done
cross_cc=${CROSS_CC:-i686-elf-gcc}
"$cross_cc" -m32 -c "$repo_root/arch/i686/tasks.S" -o "$out_dir/tasks.o"
"$cross_cc" -m32 -c "$repo_root/arch/i686/interrupts.S" -o "$out_dir/interrupts.o"
objdump -dr "$out_dir/tasks.o" > "$out_dir/tasks.asm"
objdump -dr "$out_dir/interrupts.o" > "$out_dir/interrupts.asm"
python3 - "$out_dir/tasks.asm" "$out_dir/interrupts.asm" <<'PY'
import re
import sys
tasks, interrupts = [open(path).read() for path in sys.argv[1:]]
switch = tasks.split('<_zos_task_context_switch>:', 1)[1].split('\n\n', 1)[0]
assert switch.index('mov    0x2c(%esp),%esp') < switch.index('_task_reap_switched')
assert switch.index('_task_reap_switched') < switch.index('popa') < switch.index('popf')
assert 'mov    %esp,%ebx' in switch and 'and    $0xfffffff0,%esp' in switch
assert 'mov    %ebx,%esp' in switch
halt = interrupts.split('<zos_cpu_halt_forever>:', 1)[1].split('\n\n', 1)[0]
ops = [line.split('\t')[2].split()[0] for line in halt.splitlines() if len(line.split('\t')) > 2]
assert ops == ['cli', 'hlt', 'jmp'], ops
assert re.search(r'jmp\s+[0-9a-f]+ <zos_cpu_halt_forever\+0x1>', halt)
print('task lifecycle objects: PASS (new ESP, aligned helper, frame restore, permanent halt)')
PY
