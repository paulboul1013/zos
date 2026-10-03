/* Exercise the actual scheduler switch with callee-saved registers, ESP, IF. */
.section .text
.global event_context_probe
.type event_context_probe, @function
event_context_probe:
    pushl %ebp
    pushl %edi
    pushl %esi
    pushl %ebx
    subl $12, %esp
    call zos_irq_save
    movl %eax, 0(%esp)
    movl %esp, 4(%esp)
    movl $1, 8(%esp)
    movl $0x11223344, %ebx
    movl $0x55667788, %esi
    movl $0x12345678, %edi
    movl $0x76543210, %ebp
    subl $12, %esp
    pushl $0x74657374
    call task_block_on_locked
    addl $16, %esp
    testb %al, %al
    jz 1f
    cmpl 4(%esp), %esp
    jne 1f
    cmpl $0x11223344, %ebx
    jne 1f
    cmpl $0x55667788, %esi
    jne 1f
    cmpl $0x12345678, %edi
    jne 1f
    cmpl $0x76543210, %ebp
    jne 1f
    call zos_irq_enabled
    testb %al, %al
    jz 2f
1:  movl $0, 8(%esp)
2:  movl 0(%esp), %eax
    subl $12, %esp
    pushl %eax
    call zos_irq_restore
    addl $16, %esp
    movl 8(%esp), %eax
    addl $12, %esp
    popl %ebx
    popl %esi
    popl %edi
    popl %ebp
    ret
.size event_context_probe, .-event_context_probe
.section .note.GNU-stack,"",@progbits
