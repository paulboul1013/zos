/* Verify task lifetimes in the production i686 kernel. */
#include <stdint.h>
#include <stdbool.h>

extern uint32_t __real_task_create(void (*)(void));
extern void __real_task_idle(void), __real_timer_handle_irq(void);
extern void task_init(void), task_yield(void), _task_exit(void);
extern uint32_t task_current(void), task_count(void), task_live_count(void);
extern uint8_t task_state(uint32_t);
extern uint32_t task_wake(uint32_t), zos_irq_save(void);
extern void zos_irq_restore(uint32_t), zos_cpu_safe_halt(void), zos_cpu_halt_forever(void);
extern bool zos_irq_enabled(void);
extern uint32_t event_context_probe(void);
extern volatile uint32_t event_context_result, event_worker_progress, event_worker_error;
extern uint32_t _task_saved_sp[4], _task_generations[4], _task_wait_channels[4];
extern uint32_t _task_dispatch_count[4], _task_block_count[4], _task_wake_count[4];
extern uint8_t _task_states[4], _task_stacks[12288];
extern bool _task_retired[4];
extern uint32_t zos_interrupt_depth;

volatile uint32_t lifecycle_result, lifecycle_error, lifecycle_progress;
volatile uint32_t lifecycle_capacity_result, lifecycle_irq_result, lifecycle_boundary_result;
volatile uint32_t lifecycle_handoff_error, lifecycle_handoff_count;
static bool test_irq;
static uint32_t capacity_old_id, capacity_new_id;

static void check(bool condition, uint32_t code) {
    if (condition) return;
    lifecycle_error = code;
    zos_cpu_halt_forever();
}
static void empty_task(void) {}
static void replacement_task(void) {
    check(task_current() == capacity_new_id && zos_irq_enabled(), 1);
}
static void first_start_creator(void) {
    uintptr_t sp;
    __asm__ volatile("movl %%esp, %0" : "=r"(sp));
    uintptr_t base = (uintptr_t)&_task_stacks[8192];
    check(sp >= base && sp < base + 4096 && zos_irq_enabled(), 2);
    check(task_state(capacity_old_id) == 0xff && _task_saved_sp[2] == 0, 3);
    check(task_live_count() == 3, 4);
    capacity_new_id = __real_task_create(replacement_task);
    check(capacity_new_id == capacity_old_id + 4, 5);
    check(_task_wait_channels[2] == 0 && task_wake(0x74657374) == 0, 6);
    check(_task_dispatch_count[2] == 0 && _task_block_count[2] == 0 &&
          _task_wake_count[2] == 0, 7);
    lifecycle_capacity_result = 1;
}
static void short_task(void) {
    volatile uint32_t locals[16];
    uint32_t id = task_current();
    check((id & 3) == 2 && id > 3 && task_state(id) == 2, 8);
    for (uint32_t i = 0; i < 16; ++i) locals[i] = 0xabc00000 + i;
    task_yield();
    check(event_context_probe() == 1 && zos_irq_enabled(), 9);
    for (uint32_t i = 0; i < 16; ++i) check(locals[i] == 0xabc00000 + i, 10);
    check(task_current() == id, 11);
    ++lifecycle_progress;
}
static void drain(uint32_t id) {
    for (uint32_t tries = 0; task_state(id) != 0xff && tries < 8; ++tries) {
        if (task_state(id) == 4) check(task_wake(0x74657374) == 1, 12);
        task_yield();
    }
    check(task_state(id) == 0xff, 13);
}
static void last_generation_task(void) {
    check((task_current() >> 2) == 0x3ffffffe && task_current() != 0xffffffff, 14);
}
static void no_fallback_task(void) { _task_states[0] = 4; }

void __wrap_timer_handle_irq(void) {
    if (test_irq && lifecycle_irq_result == 0) {
        uint32_t count = task_count(), live = task_live_count(), current = task_current();
        uint32_t generations[4], saved_sp[4], channels[4];
        uint8_t states[4];
        for (uint32_t i = 0; i < 4; ++i) {
            generations[i] = _task_generations[i];
            saved_sp[i] = _task_saved_sp[i];
            channels[i] = _task_wait_channels[i];
            states[i] = _task_states[i];
        }
        check(!zos_irq_enabled() && zos_interrupt_depth != 0, 15);
        check(__real_task_create(empty_task) == 0xffffffff, 16);
        check(task_current() == current && task_state(current) == 2 && task_wake(0) == 0, 17);
        check(task_count() == count && task_live_count() == live && !zos_irq_enabled(), 18);
        for (uint32_t i = 0; i < 4; ++i)
            check(generations[i] == _task_generations[i] && saved_sp[i] == _task_saved_sp[i] &&
                  channels[i] == _task_wait_channels[i] && states[i] == _task_states[i], 19);
        lifecycle_irq_result = 1;
    }
    __real_timer_handle_irq();
}
void __wrap_task_idle(void) {
    while (task_live_count() > 2) task_yield();
    check(event_context_result == 1 && event_worker_progress == 64 && event_worker_error == 0, 20);
#if ZOS_LIFECYCLE_PANIC == 1
    _task_exit();
#elif ZOS_LIFECYCLE_PANIC == 2
    check(__real_task_create(no_fallback_task) != 0xffffffff, 21);
    task_yield();
#else
    (void)no_fallback_task;
    uint32_t count = task_count();
    capacity_old_id = __real_task_create(empty_task);
    check((capacity_old_id & 3) == 2, 22);
    check((__real_task_create(first_start_creator) & 3) == 3, 23);
    check(__real_task_create(empty_task) == 0xffffffff && task_count() == count + 2, 24);
    drain(capacity_old_id);
    drain(capacity_new_id);
    check(lifecycle_capacity_result == 1 && task_live_count() == 2, 25);
    uint32_t old = capacity_old_id;
    for (uint32_t i = 0; i < 100; ++i) {
        uint32_t id = __real_task_create(short_task);
        check((id & 3) == 2 && task_state(old) == 0xff, 26);
        check(_task_dispatch_count[2] == 0 && _task_block_count[2] == 0 &&
              _task_wake_count[2] == 0 && _task_wait_channels[2] == 0, 27);
        drain(id);
        check(task_wake(0x74657374) == 0 && _task_saved_sp[2] == 0, 28);
        check(task_count() == count + 4 + i && task_live_count() == 2, 29);
        old = id;
    }
    uint32_t flags = zos_irq_save();
    _task_generations[2] = 0x3ffffffe;
    uint32_t id = __real_task_create(last_generation_task);
    check(id == 0xfffffffa && !zos_irq_enabled(), 30);
    task_init();
    check(task_state(id) == 1 && _task_generations[2] == 0x3ffffffe && !zos_irq_enabled(), 31);
    zos_irq_restore(flags);
    drain(id);
    check(_task_retired[2] && _task_generations[2] == 0x3ffffffe, 32);
    _task_generations[3] = 0x3ffffffe;
    id = __real_task_create(last_generation_task);
    check(id == 0xfffffffb, 33);
    drain(id);
    count = task_count();
    check(_task_retired[3] && __real_task_create(empty_task) == 0xffffffff, 34);
    check(task_count() == count && task_live_count() == 2, 35);
    check(task_state(0xfffffffa) == 0xff && task_state(0xfffffffb) == 0xff, 36);
    check(task_state(4) == 0xff && task_state(0xfffffffd) == 0xff &&
          task_state(0xfffffffe) == 0xff && task_state(0xffffffff) == 0xff, 37);
    lifecycle_boundary_result = 1;
    test_irq = true;
    while (lifecycle_irq_result == 0) {
        zos_irq_save();
        zos_cpu_safe_halt();
    }
    lifecycle_result = 1;
    __real_task_idle();
#endif
    check(false, 38);
}
