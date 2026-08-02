# ZOS i686 freestanding build (Tasks 1–3).

# Discover tools from PATH by default.  Command-line or environment values
# still take precedence, for example:
#   make ZC=/opt/zenc/zc CROSS_PREFIX=/opt/cross/bin/i686-elf- kernel
ZC ?= $(shell command -v zc 2>/dev/null)
I686_GCC := $(shell command -v i686-elf-gcc 2>/dev/null)
CROSS_PREFIX ?= $(if $(I686_GCC),$(dir $(I686_GCC))i686-elf-,i686-elf-)

CC := $(CROSS_PREFIX)gcc
LD := $(CROSS_PREFIX)ld
NM := $(CROSS_PREFIX)nm
CROSS_CC := $(CC)
CROSS_LD := $(LD)
CROSS_NM := $(NM)
export ZC CROSS_PREFIX CROSS_CC CROSS_LD CROSS_NM
GRUB_FILE ?= grub-file
GRUB_MKRESCUE ?= grub-mkrescue
QEMU ?= qemu-system-i386
QEMU_FLAGS ?= -serial stdio

BUILD := build
KERNEL_ZC := kernel/kernel.zc
KERNEL_C := $(BUILD)/kernel.c
KERNEL_O := $(BUILD)/kernel.o
BOOT_O := $(BUILD)/boot.o
KERNEL_ELF := $(BUILD)/zenc-os.elf
ISO_ROOT := iso
ISO_KERNEL := $(ISO_ROOT)/boot/zenc-os.elf
ISO_IMAGE := $(BUILD)/zenc-os.iso
INTERRUPTS_S := arch/i686/interrupts.S
INTERRUPTS_O := $(BUILD)/interrupts.o

# Module sources are compiled as separate freestanding translation units so
# each agent can own one .zc file without relying on hosted imports.
MODULE_ZC := arch/i686/io.zc kernel/console.zc kernel/serial.zc \
	kernel/interrupts.zc kernel/memory.zc kernel/timer.zc kernel/keyboard.zc \
	kernel/shell.zc
MODULE_C := $(patsubst %.zc,$(BUILD)/%.c,$(MODULE_ZC))
MODULE_O := $(patsubst %.zc,$(BUILD)/%.o,$(MODULE_ZC))

# The freestanding Zenc preamble currently emits ZC_FUNC/ZC_GLOBAL markers
# without defining them.  Define the linkage markers at the C boundary; this
# keeps the generated kernel code freestanding and gives kernel_main external
# C linkage for the assembly call.
CPPFLAGS := -DZC_FUNC= -DZC_GLOBAL=
CFLAGS := -std=gnu11 -m32 -ffreestanding -fno-pie -fno-pic \
	-fno-stack-protector -fno-builtin -Wall -Wextra
ASFLAGS := -m32 -ffreestanding -fno-pie -fno-pic -fno-stack-protector
LDFLAGS := -T arch/i686/linker.ld -nostdlib -ffreestanding -fno-pie -m32

.PHONY: all check-tools transpile check-abi test-toolchain test-console test-interrupt-memory \
	test-timer test-keyboard test-shell iso qemu test-iso test boot.o kernel clean

all: kernel

check-tools:
	@set -eu; \
	for tool in "$(ZC)" "$(CC)" "$(LD)" "$(NM)"; do \
		if [ -z "$$tool" ] || ! command -v "$$tool" >/dev/null 2>&1; then echo "missing executable: $$tool" >&2; exit 1; fi; \
		 done; \
	command -v "$(GRUB_FILE)" >/dev/null || { echo "missing executable: $(GRUB_FILE)" >&2; exit 1; }; \
	command -v "$(GRUB_MKRESCUE)" >/dev/null || { echo "missing executable: $(GRUB_MKRESCUE)" >&2; exit 1; }; \
	echo "ZC=$(ZC)"; \
	echo "CC=$(CC)"; \
	echo "LD=$(LD)"; \
	echo "NM=$(NM)"; \
	echo "GRUB_FILE=$(GRUB_FILE)"

$(BUILD):
	mkdir -p $@

transpile: $(KERNEL_C) $(MODULE_C)

$(KERNEL_C): $(KERNEL_ZC) | $(BUILD)
	$(ZC) transpile --freestanding $< -o $@

$(BUILD)/%.c: %.zc | $(BUILD)
	mkdir -p $(dir $@)
	$(ZC) transpile --freestanding $< -o $@

$(BUILD)/%.o: $(BUILD)/%.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

check-abi: $(KERNEL_O)
	@set -eu; \
	$(NM) -g --defined-only $(KERNEL_O) | awk '$$3 == "kernel_main" { found = 1 } END { exit !found }'; \
	unexpected=$$($(NM) -u $(KERNEL_O) | awk '$$2 !~ /^(console_init|console_write|serial_init|serial_write|zos_memory_init|interrupts_init|zos_interrupts_enable|timer_init|keyboard_init|shell_init|__kernel_end|__heap_end)$$/'); \
	if [ -n "$$unexpected" ]; then \
		echo "unexpected unresolved symbols in $(KERNEL_O):" >&2; \
		echo "$$unexpected" >&2; exit 1; \
	fi
	@echo "ABI check passed: kernel_main is external; only console/serial module symbols remain unresolved"

$(BOOT_O): arch/i686/boot.S arch/i686/linker.ld | $(BUILD)
	$(CC) $(ASFLAGS) -c arch/i686/boot.S -o $@

$(INTERRUPTS_O): $(INTERRUPTS_S) | $(BUILD)
	$(CC) $(ASFLAGS) -c $(INTERRUPTS_S) -o $@

kernel: check-abi $(BOOT_O) $(INTERRUPTS_O) $(MODULE_O) arch/i686/linker.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $(KERNEL_ELF) $(BOOT_O) $(INTERRUPTS_O) $(KERNEL_O) $(MODULE_O) -lgcc
	@set -eu; \
	$(NM) -n $(KERNEL_ELF) | awk '$$3 == "_start" { start = 1 } $$3 == "kernel_main" { main = 1 } END { if (!start || !main) exit 1 }'; \
	if $(NM) -u $(KERNEL_ELF) | grep -q .; then \
		echo "unexpected unresolved symbols in $(KERNEL_ELF)" >&2; \
		$(NM) -u $(KERNEL_ELF) >&2; exit 1; \
	fi; \
	$(GRUB_FILE) --is-x86-multiboot $(KERNEL_ELF)
	@echo "linked Multiboot kernel: $(KERNEL_ELF)"

iso: kernel | $(BUILD)
	mkdir -p $(dir $(ISO_KERNEL))
	cp $(KERNEL_ELF) $(ISO_KERNEL)
	$(GRUB_MKRESCUE) -o $(ISO_IMAGE) $(ISO_ROOT)
	$(GRUB_FILE) --is-x86-multiboot $(ISO_KERNEL)
	@echo "built GRUB ISO: $(ISO_IMAGE)"

# Launch the official GRUB ISO in an interactive QEMU window.  Override
# QEMU_FLAGS for headless runs, for example:
#   make qemu QEMU_FLAGS='-serial stdio -display none -monitor none'
qemu: iso
	@command -v "$(QEMU)" >/dev/null || { echo "missing executable: $(QEMU)" >&2; exit 1; }
	$(QEMU) -cdrom $(ISO_IMAGE) $(QEMU_FLAGS)

test-console: transpile
	./tests/console_io_smoke.sh

test-interrupt-memory: transpile
	./tests/interrupt_memory_static.sh

test-timer: transpile
	./tests/timer_static.sh

test-keyboard: transpile
	./tests/keyboard_static.sh

test-shell: transpile
	./tests/shell_static.sh

test-toolchain:
	./tests/make_toolchain_discovery.sh

test-iso: iso
	./tests/iso_test.sh

test: kernel test-toolchain test-console test-interrupt-memory test-timer test-keyboard test-shell test-iso
	./tests/boot_test.sh

boot.o: $(BOOT_O)

clean:
	rm -rf $(BUILD) $(ISO_KERNEL)
