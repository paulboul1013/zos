/* Check the C boundary on every selected i686 stack. */
.section .text
.code32
.extern __real__task_reap_switched
.extern _task_current_slot
.extern _task_stacks
.extern lifecycle_handoff_error
.extern lifecycle_handoff_count
.globl __wrap__task_reap_switched
.type __wrap__task_reap_switched, @function
__wrap__task_reap_switched:
    movl %esp, %eax
    andl $15, %eax
    cmpl $12, %eax
    je 1f
    movl $1, lifecycle_handoff_error
1:
    pushfl
    popl %eax
    testl $0x200, %eax
    jz 2f
    movl $2, lifecycle_handoff_error
2:
    movl _task_current_slot, %eax
    testl %eax, %eax
    jz 4f
    decl %eax
    shll $12, %eax
    addl $_task_stacks, %eax
    cmpl %eax, %esp
    jb 3f
    addl $4096, %eax
    cmpl %eax, %esp
    jb 4f
3:
    movl $3, lifecycle_handoff_error
4:
    incl lifecycle_handoff_count
    subl $12, %esp
    call __real__task_reap_switched
    addl $12, %esp
    ret
.size __wrap__task_reap_switched, .-__wrap__task_reap_switched
.section .note.GNU-stack,"",@progbits
