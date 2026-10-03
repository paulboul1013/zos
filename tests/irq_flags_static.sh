#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cc=${CROSS_CC:-i686-elf-gcc}
"$cc" -m32 -c "$root/arch/i686/interrupts.S" -o "$out/irq.o"
objdump -d "$out/irq.o" > "$out/irq.asm"
python3 - "$out/irq.asm" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
def ops(name):
    m = re.search(r'<'+name+r'>:\n(.*?)(?=\n\n|\Z)', s, re.S)
    assert m, name
    return [line.split('\t')[2].split()[0] for line in m[1].splitlines() if len(line.split('\t')) > 2]
assert ops('zos_irq_save') == ['pushf', 'pop', 'cli', 'ret']
assert ops('zos_irq_restore') == ['testl', 'je', 'sti', 'ret', 'cli', 'ret']
assert ops('zos_cpu_safe_halt') == ['sti', 'hlt', 'ret']
assert ops('zos_irq_enabled') == ['pushf', 'pop', 'shr', 'and', 'ret']
print('IRQ flags: PASS (save, IF-only restore, adjacent sti/hlt)')
PY
