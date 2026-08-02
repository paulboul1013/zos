# ZOS (Zenc Operating System)

This directory is the standalone i686 operating-system experiment for the
Zenc compiler.  The source lives outside the Zenc compiler repository; the
compiler is consumed through `ZC` (default: `/home/paulboul/zenc/zc`).

## Current milestone

Tasks 1–3 provide a freestanding build foundation:

1. verify the pinned cross toolchain;
2. transpile `kernel/kernel.zc` and verify its C ABI symbol;
3. link a Multiboot v1 kernel ELF with a stack and a safe halt loop.

The kernel currently has no VGA, serial, interrupt, keyboard, or shell code.
Those modules are added by later tasks.  A successful `make kernel` produces
`build/zenc-os.elf`; `grub-file` checks that its Multiboot header is valid.

## Prerequisites

The default toolchain paths are the paths used by this workspace:

```text
/home/paulboul/zenc/zc
/home/paulboul/osdev/opt/cross/bin/i686-elf-gcc
/home/paulboul/osdev/opt/cross/bin/i686-elf-nm
grub-file
```

Override `ZC` or `CROSS_PREFIX` when using a different installation, for
example:

```sh
make ZC=/path/to/zc \
     CROSS_PREFIX=/opt/cross/bin/i686-elf- \
     kernel
```

## Reproducible commands

```sh
make check-tools
make transpile
make check-abi
make kernel
```

`make kernel` runs the transpile, compile, assembly, link, `nm`, and
`grub-file --is-x86-multiboot` checks.  The final GRUB ISO and QEMU test are
introduced after the console, interrupts, keyboard, memory, and shell tasks.
