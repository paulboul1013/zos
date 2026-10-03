/* Test-only tasks installed around production kernel_main's shell creation. */
#include <stdint.h>
#include <stdbool.h>
extern uint32_t __real_task_create(void (*entry)(void));
extern void task_yield(void);
extern uint8_t task_state(uint32_t);
extern uint32_t task_wake(uint32_t);
extern bool zos_irq_enabled(void);
extern uint32_t event_context_probe(void);
volatile uint32_t event_context_result;
volatile uint32_t event_worker_progress;
volatile uint32_t event_worker_error;
static void context_task(void) {
    volatile uint32_t locals[16];
    for (uint32_t i = 0; i < 16; ++i) locals[i] = 0xabc00000 + i;
    uint32_t ok = event_context_probe();
    for (uint32_t i = 0; i < 16; ++i)
        if (locals[i] != 0xabc00000 + i) ok = 0;
    event_context_result = ok && zos_irq_enabled() ? 1 : 2;
}
static void worker_task(void) {
    for (uint32_t i = 0; i < 64; ++i) {
        if (task_state(1) != 4 || task_state(2) != 4 || !zos_irq_enabled())
            event_worker_error = 1;
        ++event_worker_progress;
        task_yield();
    }
    if (task_wake(0x74657374) != 1) event_worker_error = 2;
}
uint32_t __wrap_task_create(void (*entry)(void)) {
    uint32_t shell = __real_task_create(entry);
    if (__real_task_create(context_task) != 2 ||
        __real_task_create(worker_task) != 3) event_worker_error = 3;
    return shell;
}
