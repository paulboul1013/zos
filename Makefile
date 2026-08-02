# ZOS i686 freestanding build (Tasks 1–3).

ZC ?= /home/paulboul/zenc/zc
CROSS_PREFIX ?= /home/paulboul/osdev/opt/cross/bin/i686-elf-

CC := $(CROSS_PREFIX)gcc
LD := $(CROSS_PREFIX)ld
NM := $(CROSS_PREFIX)nm
GRUB_FILE ?= grub-file

BUILD := build
KERNEL_ZC := kernel/kernel.zc
KERNEL_C := $(BUILD)/kernel.c
KERNEL_O := $(BUILD)/kernel.o
BOOT_O := $(BUILD)/boot.o
KERNEL_ELF := $(BUILD)/zenc-os.elf

# Module sources are compiled as separate freestanding translation units so
# each agent can own one .zc file without relying on hosted imports.
MODULE_ZC := arch/i686/io.zc kernel/console.zc kernel/serial.zc
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

.PHONY: all check-tools transpile check-abi test-console test boot.o kernel clean

all: kernel

check-tools:
	@set -eu; \
	for tool in "$(ZC)" "$(CC)" "$(LD)" "$(NM)"; do \
		if [ ! -x "$$tool" ]; then echo "missing executable: $$tool" >&2; exit 1; fi; \
		done; \
	command -v "$(GRUB_FILE)" >/dev/null || { echo "missing executable: $(GRUB_FILE)" >&2; exit 1; }; \
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
	unexpected=$$($(NM) -u $(KERNEL_O) | awk '$$2 !~ /^(console_init|console_write|serial_init|serial_write)$$/'); \
	if [ -n "$$unexpected" ]; then \
		echo "unexpected unresolved symbols in $(KERNEL_O):" >&2; \
		echo "$$unexpected" >&2; exit 1; \
	fi
	@echo "ABI check passed: kernel_main is external; only console/serial module symbols remain unresolved"

$(BOOT_O): arch/i686/boot.S arch/i686/linker.ld | $(BUILD)
	$(CC) $(ASFLAGS) -c arch/i686/boot.S -o $@

kernel: check-abi $(BOOT_O) $(MODULE_O) arch/i686/linker.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $(KERNEL_ELF) $(BOOT_O) $(KERNEL_O) $(MODULE_O) -lgcc
	@set -eu; \
	$(NM) -n $(KERNEL_ELF) | awk '$$3 == "_start" { start = 1 } $$3 == "kernel_main" { main = 1 } END { if (!start || !main) exit 1 }'; \
	if $(NM) -u $(KERNEL_ELF) | grep -q .; then \
		echo "unexpected unresolved symbols in $(KERNEL_ELF)" >&2; \
		$(NM) -u $(KERNEL_ELF) >&2; exit 1; \
	fi; \
	$(GRUB_FILE) --is-x86-multiboot $(KERNEL_ELF)
	@echo "linked Multiboot kernel: $(KERNEL_ELF)"

test-console: transpile
	./tests/console_io_smoke.sh

test: kernel test-console
	./tests/boot_test.sh

boot.o: $(BOOT_O)

clean:
	rm -rf $(BUILD)
