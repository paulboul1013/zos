/*
 * Multiboot v1 entry point.
 *
 * GRUB enters this routine in 32-bit protected mode with interrupts disabled
 * or enabled depending on the loader.  We install a private stack before
 * calling the C ABI-compatible Zenc kernel_main().  The returned path is
 * deliberately a halt loop until the interrupt/console tasks are integrated.
 */

.set MULTIBOOT_MAGIC,    0x1BADB002
.set MULTIBOOT_FLAGS,    0x00000003       /* align modules, request mem info */
.set MULTIBOOT_CHECKSUM, -(MULTIBOOT_MAGIC + MULTIBOOT_FLAGS)

.section .multiboot
.align 4
.long MULTIBOOT_MAGIC
.long MULTIBOOT_FLAGS
.long MULTIBOOT_CHECKSUM

.section .bss
.align 16
.global stack_bottom
stack_bottom:
.skip 16384
.global stack_top
stack_top:

.section .text
.global _start
.type _start, @function
_start:
    movl $stack_top, %esp
    movl $0, %ebp

    /* kernel_main has a void(void) ABI; preserve no boot arguments yet. */
    call kernel_main

    cli
1:
    hlt
    jmp 1b
.size _start, .-_start
