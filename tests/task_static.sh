#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
zc_bin=${ZC:-$(command -v zc || true)}
cross_cc=${CROSS_CC:-$(command -v i686-elf-gcc || true)}
cross_ld=${CROSS_LD:-$(command -v i686-elf-ld || true)}
cross_nm=${CROSS_NM:-$(command -v i686-elf-nm || true)}
host_cc=${HOST_CC:-gcc}

for tool in "$zc_bin" "$cross_cc" "$cross_ld" "$cross_nm"; do
    [[ -n "$tool" && -x "$tool" ]] || {
        echo "task static: missing executable: $tool" >&2
        exit 2
    }
done
command -v "$host_cc" >/dev/null || {
    echo "task static: host compiler not found: $host_cc" >&2
    exit 2
}

task_source="$repo_root/kernel/task.zc"
switch_source="$repo_root/arch/i686/tasks.S"
[[ -f "$task_source" ]] || {
    echo "task static: missing source: $task_source" >&2
    exit 1
}
[[ -f "$switch_source" ]] || {
    echo "task static: missing source: $switch_source" >&2
    exit 1
}

out_dir=$(mktemp -d "${TMPDIR:-/tmp}/zos-task-check.XXXXXX")
trap 'rm -rf "$out_dir"' EXIT

generated="$out_dir/task.c"
task_object="$out_dir/task.o"
switch_object="$out_dir/tasks.o"
reloc_object="$out_dir/task-reloc.o"

"$zc_bin" transpile --freestanding "$task_source" -o "$generated"

grep -q 'TASK_MAX: u32 = 4' "$task_source"
grep -q 'TASK_STACK_SIZE: u32 = 4096' "$task_source"
grep -q 'TASK_INVALID_ID: u32 = (u32)0xFFFFFFFF' "$task_source"
grep -q 'task_init' "$task_source"
grep -q 'task_create' "$task_source"
grep -q 'task_yield' "$task_source"
grep -q '_zos_task_context_switch' "$task_source"
grep -q '_zos_task_prepare_stack' "$task_source"
! grep -Eq '#include[[:space:]]*[<"](stdlib|string|stdio)\.h' "$task_source"

"$cross_cc" -std=gnu11 -m32 -ffreestanding -fno-builtin \
    -fno-stack-protector -Wall -Wextra -DZC_FUNC= -DZC_GLOBAL= \
    -c "$generated" -o "$task_object"
"$cross_cc" -m32 -ffreestanding -fno-stack-protector \
    -c "$switch_source" -o "$switch_object"
"$cross_ld" -r "$task_object" "$switch_object" -o "$reloc_object"

for symbol in task_init task_create task_yield task_current task_count task_live_count task_state; do
    "$cross_nm" -g --defined-only "$task_object" | \
        grep -Eq "[[:space:]]$symbol$"
done
for symbol in _zos_task_context_switch _zos_task_prepare_stack; do
    "$cross_nm" -g --defined-only "$switch_object" | \
        grep -Eq "[[:space:]]$symbol$"
done
if "$cross_nm" -u "$reloc_object" | grep -Eq \
    '(malloc|free|memcpy|memset|printf|puts|__stack_chk)'; then
    echo "task static: hosted runtime symbol leaked into task objects" >&2
    exit 1
fi

# Hosted scheduler model: architecture helpers are stubs, allowing task-table
# and Round-Robin state transitions to be verified without changing host ESP.
"$host_cc" -std=gnu11 -Wall -Wextra -DZC_FUNC= -DZC_GLOBAL= \
    "$generated" -x c -o "$out_dir/harness" - <<'EOF'
#include <assert.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

extern void task_init(void);
extern uint32_t task_create(void (*entry)(void));
extern void task_yield(void);
extern uint32_t task_current(void);
extern uint32_t task_count(void);
extern uint8_t task_state(uint32_t id);

enum {
    TASK_UNUSED = 0,
    TASK_READY = 1,
    TASK_RUNNING = 2,
    TASK_INVALID_STATE = 0xff
};

uint32_t zos_interrupt_depth;
static uint32_t irq_flags = 0x202;
uint32_t zos_irq_save(void) {
    uint32_t saved = irq_flags;
    irq_flags &= ~0x200U;
    return saved;
}
void zos_irq_restore(uint32_t flags) { irq_flags = flags; }
bool zos_irq_enabled(void) { return (irq_flags & 0x200U) != 0; }
void zos_cpu_safe_halt(void) { assert(!"unexpected idle halt"); }
void zos_cpu_halt_forever(void) { assert(!"unexpected permanent halt"); }
void serial_write(const char *text) { (void)text; }

static unsigned prepare_calls;
static unsigned switch_calls;
static uint32_t last_new_sp;

uint32_t _zos_task_prepare_stack(uint8_t *base, uint32_t size,
                                 void (*entry)(void)) {
    assert(base != NULL);
    assert(size == 4096);
    assert(entry != NULL);
    prepare_calls++;
    return 0x1000U + prepare_calls * 0x100U;
}

void _zos_task_context_switch(uint32_t *old_sp, uint32_t new_sp) {
    assert(old_sp != NULL);
    *old_sp = 0x80000000U + switch_calls;
    last_new_sp = new_sp;
    switch_calls++;
}

static void task_a(void) {}
static void task_b(void) {}
static void task_c(void) {}

int main(void) {
    uint32_t id_a;
    uint32_t id_b;
    uint32_t id_c;

    task_init();
    assert(task_count() == 1);
    assert(task_current() == 0);
    assert(task_state(0) == TASK_RUNNING);
    assert(task_state(1) == TASK_INVALID_STATE);

    task_yield();
    assert(switch_calls == 0);
    assert(task_current() == 0);

    assert(task_create(NULL) == 0xFFFFFFFFU);
    assert(task_count() == 1);

    id_a = task_create(task_a);
    id_b = task_create(task_b);
    id_c = task_create(task_c);
    assert(id_a == 1 && id_b == 2 && id_c == 3);
    assert(task_create(task_a) == 0xFFFFFFFFU);
    assert(task_count() == 4);
    assert(prepare_calls == 3);
    assert(task_state(id_a) == TASK_READY);
    assert(task_state(id_b) == TASK_READY);
    assert(task_state(id_c) == TASK_READY);
    assert(task_state(99) == TASK_INVALID_STATE);

    task_yield();
    assert(task_current() == 1);
    assert(task_state(0) == TASK_READY);
    assert(task_state(1) == TASK_RUNNING);
    assert(last_new_sp == 0x1100U);

    task_yield();
    assert(task_current() == 2);
    task_yield();
    assert(task_current() == 3);
    task_yield();
    assert(task_current() == 0);
    assert(switch_calls == 4);
    return 0;
}
EOF

"$out_dir/harness"
echo "task static: PASS (scheduler model + i686 context ABI)"
