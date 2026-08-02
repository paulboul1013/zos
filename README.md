# ZOS (Zenc Operating System)

This directory is the standalone i686 operating-system experiment for the
Zenc compiler.  The source lives outside the Zenc compiler repository; the
compiler is consumed through `ZC` (default: `/home/paulboul/zenc/zc`).

## Current milestone

The current MVP boots a freestanding i686 Multiboot v1 kernel and wires the
first interactive device path:

- VGA text console and COM1 serial output;
- IDT/PIC/PIT interrupt setup with a timer tick;
- PS/2 keyboard scancode translation, Shift handling, and IRQ EOI;
- a fixed-buffer shell with `help`, `clear`, `about`, and `ticks` commands.

`make kernel` produces `build/zenc-os.elf`.  `make iso` packages it with the
static GRUB menu in `iso/boot/grub/grub.cfg` as `build/zenc-os.iso`.

## Prerequisites

The default toolchain paths are the paths used by this workspace:

```text
/home/paulboul/zenc/zc
/home/paulboul/osdev/opt/cross/bin/i686-elf-gcc
/home/paulboul/osdev/opt/cross/bin/i686-elf-nm
grub-file
grub-mkrescue
qemu-system-i386
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
make iso
make test
```

`make test` runs freestanding transpile/object checks for each module, boots
the ELF directly with QEMU, builds a GRUB ISO, and boots that ISO with QEMU.
The ISO test requires all four runtime markers: `Zenc OS booted`,
`keyboard: ready`, `shell: ready`, and `timer: ok`.

For a manual run:

```sh
qemu-system-i386 -cdrom build/zenc-os.iso -serial stdio -display none -monitor none
```

Type `help` at the `zos>` prompt through a QEMU keyboard/monitor setup to
exercise the shell path.
