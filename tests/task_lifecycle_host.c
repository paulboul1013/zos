/* Run production task code on separate host stacks. */
#define _XOPEN_SOURCE 700
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <ucontext.h>
#include <string.h>
#include <setjmp.h>
#include <sys/wait.h>
#include <unistd.h>

extern void task_init(void), task_yield(void), _task_exit(void);
extern void _task_reap_switched(void);
extern uint32_t task_create(void (*)(void)), task_current(void);
extern uint32_t task_count(void), task_live_count(void);
extern uint8_t task_state(uint32_t);
extern uint8_t _task_stacks[12288], _task_states[4];
extern uint32_t _task_saved_sp[4];
extern uint32_t _task_generations[4], _task_wait_channels[4], _task_current_slot;
extern uint32_t _task_created_count, _task_live_count, _task_pending_reap;
extern uint32_t _task_dispatch_count[4], _task_block_count[4], _task_wake_count[4];
extern bool _task_retired[4];
extern bool task_block_on_locked(uint32_t);
extern uint32_t task_wake(uint32_t);
extern void keyboard_reset(void), keyboard_handle_irq(void);
extern uint8_t keyboard_read_blocking(void);
uint32_t zos_interrupt_depth;

static ucontext_t contexts[4];
static char stacks[4][65536];
static void (*entries[4])(void);
static bool saved_if[4], irq_enabled = true;
static unsigned actual, completed, switches;
static bool fail_prepare, expect_panic;
static unsigned diagnostics;
static const char *expected_diagnostic;
static jmp_buf panic_return;
static uint8_t scancode;
uint8_t io_inb(uint16_t port) { return port == 0x60 ? scancode : 0xff; }
void io_outb(uint16_t port, uint8_t value) {
    assert(port == 0x20 && value == 0x20);
}

uint32_t zos_irq_save(void) {
    uint32_t flags = irq_enabled ? 0x202 : 2;
    irq_enabled = false;
    return flags;
}
void zos_irq_restore(uint32_t flags) { irq_enabled = (flags & 0x200) != 0; }
bool zos_irq_enabled(void) { return irq_enabled; }
void zos_cpu_safe_halt(void) { abort(); }
void zos_cpu_halt_forever(void) {
    assert(expect_panic && !irq_enabled && diagnostics == 1);
    longjmp(panic_return, 1);
}
void serial_write(const char *text) {
    assert(expect_panic && !irq_enabled && strcmp(text, expected_diagnostic) == 0);
    ++diagnostics;
}

static void start_context(unsigned slot) {
    assert(actual == slot && !irq_enabled);
    _task_reap_switched();
    irq_enabled = true;
    entries[slot]();
    ++completed;
    _task_exit();
    abort();
}
uint32_t _zos_task_prepare_stack(uint8_t *base, uint32_t size, void (*entry)(void)) {
    unsigned slot = (unsigned)(base - _task_stacks) / 4096 + 1;
    assert(slot < 4 && slot != actual && size == 4096 && entry);
    if (fail_prepare) return 0;
    entries[slot] = entry;
    saved_if[slot] = true;
    assert(getcontext(&contexts[slot]) == 0);
    contexts[slot].uc_stack.ss_sp = stacks[slot];
    contexts[slot].uc_stack.ss_size = sizeof(stacks[slot]);
    contexts[slot].uc_link = NULL;
    makecontext(&contexts[slot], (void (*)(void))start_context, 1, slot);
    return slot + 1;
}
void _zos_task_context_switch(uint32_t *old_sp, uint32_t new_sp) {
    unsigned previous = actual, next = new_sp - 1;
    assert(!irq_enabled && zos_interrupt_depth == 0);
    assert(old_sp == &_task_saved_sp[previous] && next < 4 && next != previous);
    *old_sp = previous + 1;
    saved_if[previous] = irq_enabled;
    actual = next;
    ++switches;
    assert(switches < 1000);
    assert(swapcontext(&contexts[previous], &contexts[next]) == 0);
    assert(actual == previous && !irq_enabled);
    _task_reap_switched();
    irq_enabled = saved_if[previous];
}
static void short_task(void) {
    assert((task_current() & 3) == actual);
    assert(task_state(task_current()) == 2 && task_live_count() == 2);
    volatile uint32_t local = 0x1234abcd;
    task_yield();
    assert(local == 0x1234abcd && irq_enabled);
}
static void test_reuse(void) {
    assert(task_current() == UINT32_MAX && task_state(0) == 0xff);
    assert(task_count() == 0 && task_live_count() == 0);
    task_init();
    uint32_t old = UINT32_MAX;
    for (unsigned i = 0; i < 100; ++i) {
        uint32_t id = task_create(short_task);
        assert(id == (i << 2 | 1));
        assert(task_state(old) == 0xff && task_state(id) == 1);
        task_yield();
        assert(task_state(id) == 1);
        task_yield();
        assert(task_state(id) == 0xff && task_live_count() == 1);
        assert(_task_saved_sp[1] == 0 && _task_states[1] == 0);
        assert(task_count() == i + 2 && completed == i + 1);
        old = id;
    }
    task_init();
    assert(task_count() == 101 && task_live_count() == 1);
    puts("task lifecycle host: PASS (100 returns, stack reuse, stale IDs, counts)");
}

struct table_snapshot {
    uint32_t sp[4], generations[4], channels[4], dispatch[4], block[4], wake[4];
    uint8_t states[4];
    bool retired[4];
    uint32_t created, live, current, pending;
};
static struct table_snapshot snapshot(void) {
    struct table_snapshot s = {0};
    memcpy(s.sp, _task_saved_sp, sizeof(s.sp));
    memcpy(s.generations, _task_generations, sizeof(s.generations));
    memcpy(s.channels, _task_wait_channels, sizeof(s.channels));
    memcpy(s.states, _task_states, sizeof(s.states));
    memcpy(s.retired, _task_retired, sizeof(s.retired));
    memcpy(s.dispatch, _task_dispatch_count, sizeof(s.dispatch));
    memcpy(s.block, _task_block_count, sizeof(s.block));
    memcpy(s.wake, _task_wake_count, sizeof(s.wake));
    s.created = _task_created_count;
    s.live = _task_live_count;
    s.current = _task_current_slot;
    s.pending = _task_pending_reap;
    return s;
}
static void unchanged(struct table_snapshot before) {
    struct table_snapshot after = snapshot();
    assert(memcmp(&before, &after, sizeof(before)) == 0);
}
static void empty_task(void) {}
static void queries_preserve_if(void) {
    bool before = irq_enabled;
    assert(task_current() == 0 && task_state(0) == 2);
    assert(task_count() >= 1 && task_live_count() >= 1);
    assert(task_state(4) == 0xff && task_state(0xfffffffd) == 0xff);
    assert(irq_enabled == before);
}
static void test_errors(void) {
    for (unsigned enabled = 0; enabled < 2; ++enabled) {
        irq_enabled = enabled;
        assert(task_current() == UINT32_MAX && task_state(0) == 0xff);
        assert(task_count() == 0 && task_live_count() == 0);
        assert(task_create(empty_task) == UINT32_MAX && irq_enabled == enabled);
    }
    task_init();
    for (unsigned enabled = 0; enabled < 2; ++enabled) {
        irq_enabled = enabled;
        queries_preserve_if();
        struct table_snapshot before = snapshot();
        assert(task_create(NULL) == UINT32_MAX);
        unchanged(before);
        fail_prepare = true;
        assert(task_create(empty_task) == UINT32_MAX);
        fail_prepare = false;
        unchanged(before);
        zos_interrupt_depth = 1;
        assert(task_create(empty_task) == UINT32_MAX);
        queries_preserve_if();
        assert(task_wake(77) == 0);
        zos_interrupt_depth = 0;
        unchanged(before);
        assert(irq_enabled == enabled);
        assert(task_create(empty_task) == enabled + 1 && irq_enabled == enabled);
        before = snapshot();
        task_init();
        unchanged(before);
        assert(irq_enabled == enabled);
    }
    assert(task_create(empty_task) == 3);
    struct table_snapshot before = snapshot();
    assert(task_create(empty_task) == UINT32_MAX);
    unchanged(before);
}
static void reused_reader(void) {
    assert(task_current() == 5 && irq_enabled);
    keyboard_reset();
    scancode = 0x1e;
    keyboard_handle_irq();
    assert(keyboard_read_blocking() == 'a' && irq_enabled);
}
static void first_start_creator(void) {
    assert(task_current() == 2 && task_state(1) == 0xff);
    assert(task_live_count() == 3 && _task_saved_sp[1] == 0);
    assert(task_create(reused_reader) == 5);
    assert(_task_wait_channels[1] == 0 && task_wake(77) == 0);
    assert(_task_dispatch_count[1] == 0 && _task_block_count[1] == 0);
    assert(_task_wake_count[1] == 0 && irq_enabled);
}
static void test_first_start_capacity(void) {
    task_init();
    assert(task_create(empty_task) == 1);
    assert(task_create(first_start_creator) == 2);
    assert(task_create(empty_task) == 3);
    _task_dispatch_count[1] = _task_block_count[1] = _task_wake_count[1] = 99;
    task_yield();
    while (task_live_count() != 1) task_yield();
    assert(completed == 4 && task_count() == 5);
    assert(task_state(1) == 0xff && task_state(5) == 0xff);
}
static void waiter(void) {
    uint32_t flags = zos_irq_save();
    volatile uint32_t local = 0xf00d1234;
    assert(task_block_on_locked(77));
    assert(!irq_enabled && local == 0xf00d1234);
    zos_irq_restore(flags);
    task_yield();
}
static void next_waiter(void) {
    uint32_t flags = zos_irq_save();
    assert(task_current() == 5 && _task_wait_channels[1] == 0);
    assert(task_block_on_locked(99));
    zos_irq_restore(flags);
}
static void test_channels(void) {
    task_init();
    assert(task_create(waiter) == 1);
    task_yield();
    assert(task_state(1) == 4 && task_live_count() == 2);
    struct table_snapshot before = snapshot();
    task_init();
    unchanged(before);
    assert(task_wake(77) == 1);
    task_yield();
    task_yield();
    assert(task_state(1) == 0xff && _task_wait_channels[1] == 0);
    assert(task_create(next_waiter) == 5);
    assert(_task_dispatch_count[1] == 0 && _task_block_count[1] == 0);
    assert(_task_wake_count[1] == 0);
    task_yield();
    assert(task_state(5) == 4 && task_state(1) == 0xff);
    assert(task_wake(77) == 0 && task_state(5) == 4);
    assert(task_wake(99) == 1);
    task_yield();
    assert(task_state(5) == 0xff && completed == 2);
    assert(_task_dispatch_count[0] != 0);
}
static void last_generation_task(void) {
    assert((task_current() >> 2) == 0x3ffffffe);
    assert(task_current() != UINT32_MAX && task_state(task_current()) == 2);
}
static void test_exhaustion(void) {
    task_init();
    for (unsigned i = 1; i < 4; ++i) _task_generations[i] = 0x3ffffffe;
    _task_created_count = 0xbffffffb;
    for (unsigned i = 1; i < 4; ++i)
        assert(task_create(last_generation_task) == (0xfffffff8U | i));
    assert(task_count() == 0xbffffffe && task_live_count() == 4);
    assert(task_create(empty_task) == UINT32_MAX);
    task_yield();
    assert(completed == 3 && task_live_count() == 1);
    for (unsigned i = 1; i < 4; ++i) {
        assert(_task_retired[i] && _task_generations[i] == 0x3ffffffe);
        assert(task_state(0xfffffff8U | i) == 0xff && task_state(i) == 0xff);
        assert(task_state(0xfffffffcU | i) == 0xff);
    }
    struct table_snapshot before = snapshot();
    task_init();
    assert(task_create(empty_task) == UINT32_MAX);
    unchanged(before);
    assert(task_count() == 0xbffffffe);
}
static void test_retired_selection(void) {
    task_init();
    _task_generations[1] = 0x3ffffffe;
    assert(task_create(last_generation_task) == 0xfffffff9);
    task_yield();
    assert(task_create(empty_task) == 2);
    assert(task_state(0xfffffff9) == 0xff);
}
static void remove_fallback(void) { _task_states[0] = 4; }
static void test_boot_exit(void) {
    task_init();
    expect_panic = true;
    expected_diagnostic = "task exit: invalid context\n";
    if (setjmp(panic_return) == 0) _task_exit();
    assert(!irq_enabled && diagnostics == 1 && completed == 0);
}
static void test_no_fallback(void) {
    task_init();
    task_create(remove_fallback);
    expect_panic = true;
    expected_diagnostic = "task exit: no ready fallback\n";
    if (setjmp(panic_return) == 0) task_yield();
    assert(!irq_enabled && diagnostics == 1 && completed == 1);
}
int main(void) {
    void (*tests[])(void) = {test_reuse, test_errors, test_first_start_capacity,
        test_channels, test_exhaustion, test_retired_selection,
        test_boot_exit, test_no_fallback};
    for (unsigned i = 0; i < sizeof(tests) / sizeof(tests[0]); ++i) {
        pid_t pid = fork();
        assert(pid >= 0);
        if (pid == 0) { tests[i](); exit(0); }
        int status;
        assert(waitpid(pid, &status, 0) == pid);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    puts("task lifecycle host: PASS (capacity, IF, failure, channels, exhaustion, fatal exits)");
}
