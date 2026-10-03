/* Exercise transpiled production modules with real suspended C stacks. The
 * architectural boundary emulates per-context IF and pending hardware IRQs;
 * no stub returns to a waiter while another task is current. */
#define _XOPEN_SOURCE 700
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <ucontext.h>
#include <sys/wait.h>
#include <unistd.h>

extern void task_init(void), task_yield(void), task_idle(void), _task_exit(void);
extern void _task_reap_switched(void);
extern uint8_t _task_stacks[12288];
extern uint32_t task_create(void (*)(void)), task_current(void), task_wake(uint32_t);
extern uint8_t task_state(uint32_t), keyboard_read_blocking(void);
extern bool task_block_on_locked(uint32_t), __real_task_block_on_locked(uint32_t);
extern void keyboard_reset(void), keyboard_handle_irq(void);
extern uint8_t keyboard_queue_pop(void);
extern uint32_t keyboard_queue_count(void), keyboard_queue_dropped(void);
extern uint32_t _task_saved_sp[4], _task_wait_channels[4], _task_current_slot;
extern uint8_t _task_states[4];
extern bool _task_initialized;
uint32_t zos_interrupt_depth;

enum { UNUSED, READY, RUNNING, TERMINATED, BLOCKED, INVALID = 0xff };
enum { BEFORE_CHECK, CHECK_BLOCK_GAP, AFTER_SWITCH, RECHECK, IDLE_GAP, IDLE_READY };
static ucontext_t contexts[4];
static char stacks[4][65536];
static void (*entries[4])(void);
static bool context_if[4], irq_enabled, pending;
static unsigned actual, prepared, switches, halts, eois, blocks, completed;
static unsigned mode, phase, worker_progress;
static uint8_t next_scancode;
static bool escape_idle;
static jmp_buf idle_return;

static void invariant(void) {
    unsigned running = 0;
    assert(task_current() == actual);
    for (unsigned i = 0; i < 4; ++i) {
        running += _task_states[i] == RUNNING;
        if (_task_states[i] == BLOCKED) assert(_task_wait_channels[i] != 0);
        else assert(_task_wait_channels[i] == 0);
    }
    assert(running == 1 && _task_states[actual] == RUNNING);
}
uint8_t io_inb(uint16_t port) { return port == 0x60 ? next_scancode : 0xff; }
void io_outb(uint16_t port, uint8_t value) {
    assert(port == 0x20 && value == 0x20);
    ++eois;
}
static void deliver(void) {
    if (!irq_enabled || !pending) return;
    pending = false;
    unsigned before = switches;
    bool saved = irq_enabled;
    irq_enabled = false;
    ++zos_interrupt_depth;
    keyboard_handle_irq();
    --zos_interrupt_depth;
    assert(!irq_enabled && switches == before);
    irq_enabled = saved; /* iret */
    invariant();
}
static void irq(uint8_t scancode) {
    assert(!pending);
    next_scancode = scancode;
    pending = true;
    deliver();
}
uint32_t zos_irq_save(void) {
    uint32_t flags = irq_enabled ? 0x202 : 2;
    irq_enabled = false;
    return flags;
}
bool zos_irq_enabled(void) { return irq_enabled; }
void zos_irq_restore(uint32_t flags) {
    irq_enabled = (flags & 0x200) != 0;
    if (mode == RECHECK && actual == 1 && phase == 1 && irq_enabled) {
        phase = 2;
        irq(0x1e);
    }
    deliver();
}
void zos_cpu_safe_halt(void) {
    assert(actual == 0 && !irq_enabled);
    invariant();
    for (unsigned i = 1; i < 4; ++i) assert(task_state(i) != READY);
    ++halts;
    assert(mode == IDLE_GAP && phase == 0);
    phase = 1;
    irq(0x1e); /* event after final ready-check, masked until sti; hlt */
    assert(pending && eois == 0);
    irq_enabled = true;
    deliver();
}
void serial_write(const char *text) { fputs(text, stderr); }
void zos_cpu_halt_forever(void) { abort(); }
static void start_context(unsigned id) {
    assert(actual == id && !irq_enabled);
    _task_reap_switched();
    irq_enabled = true;
    invariant();
    deliver();
    entries[id]();
    ++completed;
    if (escape_idle) longjmp(idle_return, 1);
    _task_exit();
    abort();
}
uint32_t _zos_task_prepare_stack(uint8_t *base, uint32_t size, void (*entry)(void)) {
    assert(base && size == 4096 && entry);
    unsigned id = (unsigned)(base - _task_stacks) / 4096 + 1;
    ++prepared;
    assert(id < 4);
    entries[id] = entry;
    context_if[id] = true;
    assert(getcontext(&contexts[id]) == 0);
    contexts[id].uc_stack.ss_sp = stacks[id];
    contexts[id].uc_stack.ss_size = sizeof(stacks[id]);
    contexts[id].uc_link = NULL;
    makecontext(&contexts[id], (void (*)(void))start_context, 1, id);
    return id + 1;
}
void _zos_task_context_switch(uint32_t *old_sp, uint32_t new_sp) {
    unsigned previous = actual, next = new_sp - 1;
    assert(!irq_enabled && zos_interrupt_depth == 0);
    assert(old_sp == &_task_saved_sp[previous] && next < 4 && next != previous);
    *old_sp = previous + 1;
    context_if[previous] = irq_enabled;
    actual = next;
    ++switches;
    assert(switches < 200);
    invariant();
    assert(swapcontext(&contexts[previous], &contexts[next]) == 0);
    _task_reap_switched();
    irq_enabled = context_if[previous];
    assert(actual == previous && task_current() == previous);
    assert(!irq_enabled); /* resume precisely inside the original critical section */
    invariant();
}
bool __wrap_task_block_on_locked(uint32_t channel) {
    ++blocks;
    if (mode == CHECK_BLOCK_GAP && actual == 1 && phase == 0) {
        assert(!irq_enabled && keyboard_queue_count() == 0);
        phase = 1;
        irq(0x1e);
        assert(pending && eois == 0);
    }
    return __real_task_block_on_locked(channel);
}
static void reset(void) {
    actual = prepared = switches = halts = eois = blocks = completed = phase = 0;
    irq_enabled = true;
    pending = escape_idle = false;
    zos_interrupt_depth = 0;
    mode = AFTER_SWITCH;
    memset(context_if, 0, sizeof(context_if));
    task_init();
    keyboard_reset();
    invariant();
    assert(irq_enabled);
}
static void reader(void) {
    volatile uint32_t local = 0x1234abcd;
    unsigned before = switches;
    assert(keyboard_read_blocking() == 'a');
    assert(local == 0x1234abcd && irq_enabled && actual == 1);
    assert(keyboard_queue_count() == 0);
    if (mode == BEFORE_CHECK) assert(switches == before && blocks == 0);
    invariant();
}
static void drive_until_done(void) {
    for (unsigned tries = 0; completed == 0 && tries < 10; ++tries) task_yield();
    assert(completed == 1 && task_state(1) == INVALID);
    invariant();
}
static void test_interleaving(unsigned scenario) {
    reset();
    mode = scenario;
    assert(task_create(reader) == 1);
    if (scenario == BEFORE_CHECK) irq(0x1e);
    task_yield();
    if (scenario == AFTER_SWITCH || scenario == RECHECK) {
        assert(task_state(1) == BLOCKED && completed == 0 && blocks == 1);
        assert(task_wake(0) == 0 && task_wake(0xdead) == 0);
        if (scenario == RECHECK) {
            phase = 1;
            assert(task_wake(_task_wait_channels[1]) == 1);
        } else irq(0x1e);
    }
    drive_until_done();
    assert(eois == 1 && !pending && halts == 0);
}
static void test_spurious(void) {
    reset();
    task_create(reader);
    task_yield();
    uint32_t channel = _task_wait_channels[1];
    assert(task_wake(channel) == 1);
    assert(task_wake(channel) == 0);
    task_yield();
    assert(task_state(1) == BLOCKED && completed == 0 && blocks == 2);
    irq(0x1e);
    drive_until_done();
    assert(eois == 1);
}
static void channel_waiter(void) {
    uint32_t flags = zos_irq_save();
    uint32_t channel = actual == 3 ? 99 : 77;
    assert(task_block_on_locked(channel));
    assert(!irq_enabled && _task_wait_channels[actual] == 0);
    zos_irq_restore(flags);
    assert(irq_enabled);
}
static void test_channels(void) {
    reset();
    for (unsigned i = 1; i < 4; ++i) assert(task_create(channel_waiter) == i);
    task_yield();
    for (unsigned i = 1; i < 4; ++i) assert(task_state(i) == BLOCKED);
    assert(task_wake(0) == 0 && task_wake(123) == 0);
    unsigned before = switches;
    uint32_t flags = zos_irq_save();
    assert(task_wake(77) == 2 && !irq_enabled);
    zos_irq_restore(flags);
    assert(irq_enabled && switches == before && task_state(3) == BLOCKED);
    assert(task_wake(77) == 0);
    task_yield();
    assert(completed == 2 && task_state(1) == INVALID && task_state(2) == INVALID);
    assert(task_wake(77) == 0 && task_wake(99) == 1);
    task_yield();
    assert(completed == 3 && task_state(3) == INVALID);
}
static void rejected(uint32_t channel) {
    uint8_t states[4];
    uint32_t channels[4], saved_sp[4];
    memcpy(states, _task_states, sizeof(states));
    memcpy(channels, _task_wait_channels, sizeof(channels));
    memcpy(saved_sp, _task_saved_sp, sizeof(saved_sp));
    unsigned before = switches, current = task_current();
    assert(!task_block_on_locked(channel));
    assert(memcmp(states, _task_states, sizeof(states)) == 0);
    assert(memcmp(channels, _task_wait_channels, sizeof(channels)) == 0);
    assert(memcmp(saved_sp, _task_saved_sp, sizeof(saved_sp)) == 0);
    assert(switches == before && task_current() == current);
}
static void invalid_reader(void) {
    rejected(77); /* IF=1 */
    uint32_t flags = zos_irq_save();
    rejected(0);
    zos_interrupt_depth = 1;
    rejected(77);
    zos_interrupt_depth = 0;
    assert(keyboard_read_blocking() == 0); /* IF=0, even with buffered input */
    assert(!irq_enabled && keyboard_queue_count() == 1);
    _task_states[1] = READY;
    rejected(77);
    _task_states[1] = RUNNING;
    _task_states[0] = BLOCKED;
    _task_wait_channels[0] = 7;
    rejected(77); /* no fallback */
    _task_states[0] = READY;
    _task_wait_channels[0] = 0;
    zos_irq_restore(flags);
    zos_interrupt_depth = 1;
    assert(keyboard_read_blocking() == 0);
    assert(irq_enabled && keyboard_queue_count() == 1);
    zos_interrupt_depth = 0;
    _task_states[1] = READY;
    assert(keyboard_read_blocking() == 0);
    assert(irq_enabled && keyboard_queue_count() == 1);
    _task_states[1] = RUNNING;
    _task_current_slot = 4;
    assert(keyboard_read_blocking() == 0);
    assert(irq_enabled && keyboard_queue_count() == 1);
    _task_current_slot = 1;
}
static void test_invalid_and_flags(void) {
    reset();
    irq(0x1e);
    _task_initialized = false;
    rejected(77);
    assert(keyboard_read_blocking() == 0);
    _task_initialized = true;
    assert(keyboard_read_blocking() == 0); /* idle cannot consume */
    assert(keyboard_queue_count() == 1 && irq_enabled);
    uint32_t outer = zos_irq_save(), inner = zos_irq_save();
    rejected(77); /* task 0 */
    _task_current_slot = 4;
    rejected(77); /* invalid current ID must not index outside task table */
    _task_current_slot = 0;
    zos_irq_restore(inner);
    assert(!irq_enabled);
    zos_irq_restore(outer);
    assert(irq_enabled);
    task_create(invalid_reader);
    drive_until_done();
    assert(keyboard_queue_pop() == 'a' && keyboard_queue_count() == 0);
}
static void test_idle(unsigned scenario) {
    reset();
    mode = scenario;
    task_create(reader);
    if (scenario == IDLE_GAP) {
        task_yield();
        assert(task_state(1) == BLOCKED);
    } else irq(0x1e);
    escape_idle = true;
    if (setjmp(idle_return) == 0) task_idle();
    assert(completed == 1 && eois == 1 && !pending);
    assert(halts == (scenario == IDLE_GAP ? 1U : 0U));
}
static void buffered_reader(void) {
    unsigned before = switches;
    assert(keyboard_read_blocking() == 'a');
    assert(keyboard_read_blocking() == 'b');
    assert(keyboard_read_blocking() == 'c');
    assert(blocks == 0 && switches == before && irq_enabled);
}
static void worker(void) {
    for (unsigned i = 0; i < 3; ++i) {
        assert(task_state(1) == BLOCKED);
        ++worker_progress;
        task_yield();
    }
    irq(0x1e);
    assert(task_state(1) == READY);
}
static void test_worker_and_buffered(void) {
    reset();
    task_create(buffered_reader);
    irq(0x1e); irq(0x30); irq(0x2e);
    drive_until_done();
    assert(eois == 3 && keyboard_queue_count() == 0);
}
static void test_worker(void) {
    reset();
    worker_progress = 0;
    task_create(reader);
    task_create(worker);
    for (unsigned tries = 0; completed != 2 && tries < 10; ++tries) task_yield();
    assert(completed == 2 && worker_progress == 3 && halts == 0);
    assert(task_state(1) == INVALID && task_state(2) == INVALID);
    invariant();
}
static void test_queue(void) {
    reset();
    irq(0x2a); irq(0xaa); irq(0x9e);
    assert(keyboard_queue_count() == 0 && eois == 3);
    for (unsigned i = 0; i < 63; ++i) irq(0x1e);
    irq(0x30);
    assert(keyboard_queue_count() == 63 && keyboard_queue_dropped() == 1);
    for (unsigned i = 0; i < 40; ++i) assert(keyboard_queue_pop() == 'a');
    for (unsigned i = 0; i < 40; ++i) irq(0x30);
    for (unsigned i = 0; i < 23; ++i) assert(keyboard_queue_pop() == 'a');
    for (unsigned i = 0; i < 40; ++i) assert(keyboard_queue_pop() == 'b');
    assert(keyboard_queue_pop() == 0 && eois == 107 && switches == 0);
}
static void isolated(void (*test)(void)) {
    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) { test(); exit(0); }
    int status;
    assert(waitpid(pid, &status, 0) == pid);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}
static void before_check(void) { test_interleaving(BEFORE_CHECK); }
static void check_gap(void) { test_interleaving(CHECK_BLOCK_GAP); }
static void after_switch(void) { test_interleaving(AFTER_SWITCH); }
static void recheck(void) { test_interleaving(RECHECK); }
static void idle_ready(void) { test_idle(IDLE_READY); }
static void idle_gap(void) { test_idle(IDLE_GAP); }
int main(void) {
    void (*tests[])(void) = {test_invalid_and_flags, test_channels, before_check,
        check_gap, after_switch, recheck, test_spurious, idle_ready, idle_gap,
        test_queue, test_worker_and_buffered, test_worker};
    for (unsigned i = 0; i < sizeof(tests) / sizeof(tests[0]); ++i) isolated(tests[i]);
    puts("event wait host: PASS (IF, invalid calls, channels, IRQ windows, idle, FIFO/EOI)");
    return 0;
}
