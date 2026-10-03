/* ZOS i686 cooperative task context switching.
 *
 * A saved context is an EFLAGS word plus the pushal register frame and a
 * return address. Loading another task's ESP and restoring that frame makes
 * `ret` continue the selected task at its previous instruction.
 */

.section .text
.code32

.extern _task_exit
.extern _task_reap_switched

.globl _zos_task_prepare_stack
.type _zos_task_prepare_stack, @function
_zos_task_prepare_stack:
    movl 4(%esp), %eax       /* stack base */
    addl 8(%esp), %eax       /* one byte beyond stack */
    andl $-16, %eax          /* i686 cdecl call-site alignment */

    subl $4, %eax
    movl $_zos_task_exit_trampoline, (%eax)
    subl $4, %eax
    movl 12(%esp), %edx      /* task entry */
    movl %edx, (%eax)
    subl $4, %eax
    movl $0x202, (%eax)      /* reserved bit + interrupts enabled */

    subl $32, %eax           /* pushal frame: eight 32-bit slots */
    movl $0, 0(%eax)         /* EDI */
    movl $0, 4(%eax)         /* ESI */
    movl $0, 8(%eax)         /* EBP */
    movl $0, 12(%eax)        /* saved ESP slot; popal ignores it */
    movl $0, 16(%eax)        /* EBX */
    movl $0, 20(%eax)        /* EDX */
    movl $0, 24(%eax)        /* ECX */
    movl $0, 28(%eax)        /* EAX */
    ret
.size _zos_task_prepare_stack, .-_zos_task_prepare_stack

.globl _zos_task_context_switch
.type _zos_task_context_switch, @function
_zos_task_context_switch:
    pushfl
    pushal

    /* After pushfl + pushal, cdecl args moved from +4/+8 to +40/+44. */
    movl 40(%esp), %eax      /* uint32_t *old_sp */
    movl %esp, (%eax)
    movl 44(%esp), %esp      /* uint32_t new_sp */

    /* Preserve the frame above an aligned C call area on the new stack. */
    movl %esp, %ebx
    andl $-16, %esp
    call _task_reap_switched
    movl %ebx, %esp

    popal
    popfl
    ret
.size _zos_task_context_switch, .-_zos_task_context_switch

/* A task entry returns here with ESP aligned as a normal caller continuation.
 * `call` supplies the return slot expected by the generated cdecl function. */
.type _zos_task_exit_trampoline, @function
_zos_task_exit_trampoline:
    call _task_exit
    cli
1:
    hlt
    jmp 1b
.size _zos_task_exit_trampoline, .-_zos_task_exit_trampoline

.section .note.GNU-stack,"",@progbits
