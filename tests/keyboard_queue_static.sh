#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
zc_bin=${ZC:-$(command -v zc || true)}
host_cc=${HOST_CC:-gcc}
keyboard_source="$repo_root/kernel/keyboard.zc"

[[ -n "$zc_bin" && -x "$zc_bin" ]] || {
    echo "keyboard queue: zc executable not found: $zc_bin" >&2
    exit 2
}
command -v "$host_cc" >/dev/null || {
    echo "keyboard queue: host compiler not found: $host_cc" >&2
    exit 2
}

grep -q 'KEYBOARD_QUEUE_CAPACITY: u32 = 64' "$keyboard_source"
grep -q 'fn keyboard_handle_irq()' "$keyboard_source"
grep -q 'fn keyboard_queue_pop() -> u8' "$keyboard_source"
grep -q 'fn keyboard_queue_count() -> u32' "$keyboard_source"
grep -q 'fn keyboard_queue_dropped() -> u32' "$keyboard_source"

out_dir=$(mktemp -d "${TMPDIR:-/tmp}/zos-keyboard-queue.XXXXXX")
trap 'rm -rf "$out_dir"' EXIT
generated="$out_dir/keyboard.c"

"$zc_bin" transpile --freestanding "$keyboard_source" -o "$generated"

"$host_cc" -std=gnu11 -Wall -Wextra -DZC_FUNC= -DZC_GLOBAL= \
    "$generated" -x c -o "$out_dir/harness" - <<'EOF'
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

extern void keyboard_reset(void);
extern void keyboard_handle_irq(void);
extern uint8_t keyboard_handle_scancode(uint8_t scancode);
extern uint8_t keyboard_queue_pop(void);
extern uint32_t keyboard_queue_count(void);
extern uint32_t keyboard_queue_dropped(void);

uint32_t zos_interrupt_depth;
static uint32_t irq_flags = 0x202;
uint32_t zos_irq_save(void) {
    uint32_t saved = irq_flags;
    irq_flags &= ~0x200U;
    return saved;
}
void zos_irq_restore(uint32_t flags) { irq_flags = flags; }
bool zos_irq_enabled(void) { return (irq_flags & 0x200U) != 0; }
uint32_t task_current(void) { return 1; }
uint8_t task_state(uint32_t id) { (void)id; return 2; }
bool task_block_on_locked(uint32_t channel) {
    (void)channel;
    assert(!"queue test must not block");
    return false;
}
static unsigned wake_count;
uint32_t task_wake(uint32_t channel) {
    assert(channel != 0);
    assert(keyboard_queue_count() != 0); /* publish data before notifying */
    wake_count++;
    return 0;
}

static uint8_t next_scancode;
static unsigned eoi_count;

uint8_t io_inb(uint16_t port) {
    if (port == 0x60U) {
        return next_scancode;
    }
    return 0xffU;
}

void io_outb(uint16_t port, uint8_t value) {
    if (port == 0x20U && value == 0x20U) {
        eoi_count++;
    }
}

static void irq_scancode(uint8_t scancode) {
    next_scancode = scancode;
    keyboard_handle_irq();
}

static void reset_fixture(void) {
    keyboard_reset();
    eoi_count = 0;
    wake_count = 0;
}

static void test_empty_queue(void) {
    reset_fixture();
    assert(keyboard_queue_count() == 0);
    assert(keyboard_queue_pop() == 0);
    assert(keyboard_queue_dropped() == 0);
}

static void test_irq_fifo_and_eoi(void) {
    reset_fixture();
    irq_scancode(0x1eU); /* a */
    irq_scancode(0x30U); /* b */
    irq_scancode(0x2eU); /* c */
    assert(eoi_count == 3);
    assert(wake_count == 3);
    assert(keyboard_queue_count() == 3);
    assert(keyboard_queue_pop() == (uint8_t)'a');
    assert(keyboard_queue_pop() == (uint8_t)'b');
    assert(keyboard_queue_pop() == (uint8_t)'c');
    assert(keyboard_queue_pop() == 0);
}

static void test_modifier_is_not_queued_but_gets_eoi(void) {
    reset_fixture();
    irq_scancode(0x2aU); /* left Shift make */
    assert(eoi_count == 1);
    assert(wake_count == 0);
    assert(keyboard_queue_count() == 0);
}

static void test_wraparound_preserves_fifo(void) {
    unsigned index;

    reset_fixture();
    for (index = 0; index < 40; ++index) {
        irq_scancode(0x1eU); /* a */
    }
    for (index = 0; index < 30; ++index) {
        assert(keyboard_queue_pop() == (uint8_t)'a');
    }
    for (index = 0; index < 30; ++index) {
        irq_scancode(0x30U); /* b, wraps head */
    }
    assert(keyboard_queue_count() == 40);
    for (index = 0; index < 10; ++index) {
        assert(keyboard_queue_pop() == (uint8_t)'a');
    }
    for (index = 0; index < 30; ++index) {
        assert(keyboard_queue_pop() == (uint8_t)'b');
    }
}

static void test_full_queue_drops_newest(void) {
    unsigned index;

    reset_fixture();
    for (index = 0; index < 63; ++index) {
        irq_scancode(0x1eU); /* a */
    }
    assert(keyboard_queue_count() == 63);
    irq_scancode(0x30U); /* b is dropped */
    assert(keyboard_queue_count() == 63);
    assert(keyboard_queue_dropped() == 1);
    for (index = 0; index < 63; ++index) {
        assert(keyboard_queue_pop() == (uint8_t)'a');
    }
    assert(keyboard_queue_pop() == 0);
    assert(eoi_count == 64);
    assert(wake_count == 63);
}

static void test_set1_ascii_rows(void) {
    static const uint8_t letter_starts[] = {0x10U, 0x1eU, 0x2cU};
    static const char *letter_rows[] = {"qwertyuiop", "asdfghjkl", "zxcvbnm"};
    static const char number_row[] = "1234567890";
    static const char shifted_number_row[] = "!@#$%^&*()";
    size_t row;
    size_t index;

    reset_fixture();
    for (row = 0; row < 3; ++row) {
        for (index = 0; letter_rows[row][index] != '\0'; ++index) {
            assert(keyboard_handle_scancode(
                (uint8_t)(letter_starts[row] + index)) ==
                (uint8_t)letter_rows[row][index]);
        }
    }
    for (index = 0; number_row[index] != '\0'; ++index) {
        assert(keyboard_handle_scancode((uint8_t)(0x02U + index)) ==
               (uint8_t)number_row[index]);
    }

    assert(keyboard_handle_scancode(0x2aU) == 0); /* Shift make */
    assert(keyboard_handle_scancode(0x10U) == (uint8_t)'Q');
    for (index = 0; shifted_number_row[index] != '\0'; ++index) {
        assert(keyboard_handle_scancode((uint8_t)(0x02U + index)) ==
               (uint8_t)shifted_number_row[index]);
    }
    assert(keyboard_handle_scancode(0xaaU) == 0); /* Shift break */
}

int main(void) {
    test_empty_queue();
    test_irq_fifo_and_eoi();
    test_modifier_is_not_queued_but_gets_eoi();
    test_wraparound_preserves_fifo();
    test_full_queue_drops_newest();
    test_set1_ascii_rows();
    puts("keyboard queue harness: PASS");
    return 0;
}
EOF

"$out_dir/harness"
echo "keyboard queue static: PASS (FIFO + wrap + overflow + EOI)"
