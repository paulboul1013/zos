/* ZOS i686 interrupt entry points (Task 6).
 *
 * This file is intentionally linkable before the IDT builder exists.  Each
 * vector stub normalizes the two hardware entry shapes (with/without CPU
 * error code) and calls the Zenc-generated cdecl symbol `zos_isr_dispatch`.
 * The common path discards the normalized vector/error pair and returns with
 * iret.  Task 6's IDT installation code can point gates at zos_isr0..31 and
 * zos_irq0..15 without changing the C ABI.
 */

.section .text
.code32
.extern zos_isr_dispatch

.globl zos_cpu_cli
.type zos_cpu_cli, @function
zos_cpu_cli:
    cli
    ret
.size zos_cpu_cli, .-zos_cpu_cli

.globl zos_cpu_sti
.type zos_cpu_sti, @function
zos_cpu_sti:
    sti
    ret
.size zos_cpu_sti, .-zos_cpu_sti

/* External calls also act as compiler memory boundaries for generated C.
 * Restore only IF: arithmetic flags belong to the caller's instruction flow. */
.globl zos_irq_save
.type zos_irq_save, @function
zos_irq_save:
    pushfl
    popl %eax
    cli
    ret
.size zos_irq_save, .-zos_irq_save

.globl zos_irq_restore
.type zos_irq_restore, @function
zos_irq_restore:
    testl $0x200, 4(%esp)
    jz 1f
    sti
    ret
1:
    cli
    ret
.size zos_irq_restore, .-zos_irq_restore

.globl zos_irq_enabled
.type zos_irq_enabled, @function
zos_irq_enabled:
    pushfl
    popl %eax
    shrl $9, %eax
    andl $1, %eax
    ret
.size zos_irq_enabled, .-zos_irq_enabled

.globl zos_cpu_safe_halt
.type zos_cpu_safe_halt, @function
zos_cpu_safe_halt:
    sti
    hlt
    ret
.size zos_cpu_safe_halt, .-zos_cpu_safe_halt

.globl zos_cpu_halt_forever
.type zos_cpu_halt_forever, @function
zos_cpu_halt_forever:
    cli
1:
    hlt
    jmp 1b
.size zos_cpu_halt_forever, .-zos_cpu_halt_forever

/* Return the selector currently used by the executing code segment.  GRUB
 * and QEMU's direct -kernel loader do not promise the same GDT layout, so
 * IDT gates must target the active CS instead of assuming selector 0x08. */
.globl zos_cpu_cs
.type zos_cpu_cs, @function
zos_cpu_cs:
    xorl %eax, %eax
    movw %cs, %ax
    ret
.size zos_cpu_cs, .-zos_cpu_cs

/* Load an IDT descriptor supplied by the kernel (cdecl: idtr at 4(%esp)). */
.globl zos_idt_load
.type zos_idt_load, @function
zos_idt_load:
    lidt 4(%esp)
    ret
.size zos_idt_load, .-zos_idt_load

/* Vectors with a CPU-pushed error code.  The stub only pushes its vector;
 * common_entry reads the original error code at 8(%esp). */
.macro ISR_ERROR n
.globl zos_isr\n
.type zos_isr\n, @function
zos_isr\n:
    pushl $\n
    jmp zos_interrupt_common_error
.size zos_isr\n, .-zos_isr\n
.endm

/* Vectors without a CPU-pushed error code get a synthetic zero so the common
 * C ABI is identical for all exceptions and IRQs. */
.macro ISR_NO_ERROR n
.globl zos_isr\n
.type zos_isr\n, @function
zos_isr\n:
    pushl $0
    pushl $\n
    call zos_interrupt_common_no_error
    addl $8, %esp
    iret
.size zos_isr\n, .-zos_isr\n
.endm

/* Error-code exceptions: after pushal, ret/vector/error are at +32/+36/+40. */
zos_interrupt_common_error:
    pushal
    pushl 40(%esp)      /* error_code */
    pushl 40(%esp)      /* vector (offset grows after first push) */
    call zos_isr_dispatch
    addl $8, %esp
    popal
    addl $4, %esp       /* normalized vector; CPU error remains for iret */
    iret

/* Synthetic-error exceptions: after pushal, ret/vector/zero are +32/+36/+40. */
zos_interrupt_common_no_error:
    pushal
    pushl 40(%esp)      /* synthetic error code */
    pushl 40(%esp)      /* vector (offset grows after first push) */
    call zos_isr_dispatch
    addl $8, %esp
    popal
    ret

/* CPU exceptions whose architectural frame includes an error code. */
ISR_ERROR 8
ISR_ERROR 10
ISR_ERROR 11
ISR_ERROR 12
ISR_ERROR 13
ISR_ERROR 14
ISR_ERROR 17

/* Remaining CPU exceptions use the synthetic zero error code. */
ISR_NO_ERROR 0
ISR_NO_ERROR 1
ISR_NO_ERROR 2
ISR_NO_ERROR 3
ISR_NO_ERROR 4
ISR_NO_ERROR 5
ISR_NO_ERROR 6
ISR_NO_ERROR 7
ISR_NO_ERROR 9
ISR_NO_ERROR 15
ISR_NO_ERROR 16
ISR_NO_ERROR 18
ISR_NO_ERROR 19
ISR_NO_ERROR 20
ISR_NO_ERROR 21
ISR_NO_ERROR 22
ISR_NO_ERROR 23
ISR_NO_ERROR 24
ISR_NO_ERROR 25
ISR_NO_ERROR 26
ISR_NO_ERROR 27
ISR_NO_ERROR 28
ISR_NO_ERROR 29
ISR_NO_ERROR 30
ISR_NO_ERROR 31

/* IRQ stubs 0..15 map to vectors 32..47.  They use the same synthetic
 * zero-error ABI; timer/keyboard modules can later chain from dispatch. */
.macro IRQ n
.globl zos_irq\n
.type zos_irq\n, @function
zos_irq\n:
    pushl $0
    pushl $(32 + \n)
    call zos_interrupt_common_no_error
    addl $8, %esp
    iret
.size zos_irq\n, .-zos_irq\n
.endm

IRQ 0
IRQ 1
IRQ 2
IRQ 3
IRQ 4
IRQ 5
IRQ 6
IRQ 7
IRQ 8
IRQ 9
IRQ 10
IRQ 11
IRQ 12
IRQ 13
IRQ 14
IRQ 15
