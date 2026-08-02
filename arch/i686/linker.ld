/* Link a 32-bit Multiboot kernel at the conventional 1 MiB load address. */
ENTRY(_start)

SECTIONS
{
    . = 1M;

    /* Keep the header first so GRUB can find it in the first 8 KiB. */
    .text : ALIGN(16)
    {
        KEEP(*(.multiboot))
        *(.text*)
    }

    .rodata : ALIGN(16)
    {
        *(.rodata*)
    }

    .data : ALIGN(16)
    {
        *(.data*)
    }

    .bss : ALIGN(16)
    {
        *(COMMON)
        *(.bss*)
    }

    . = ALIGN(16);
    __kernel_end = .;

    /* The first stack is reserved by boot.S in .bss. */
    __stack_bottom = stack_bottom;
    __stack_top = stack_top;

    /* A bounded identity-mapped arena for the first bump allocator. */
    __heap_start = ALIGN(__kernel_end, 16);
    __heap_end = __heap_start + 0x10000;

    /DISCARD/ :
    {
        *(.comment)
        *(.eh_frame)
        *(.note*)
    }
}
