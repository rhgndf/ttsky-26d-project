# Firmware build for the RV32I SoC tests. Requires xpack riscv-none-elf-gcc.
CROSS   ?= riscv-none-elf-
CC      = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
CFLAGS  = -march=rv32i_zicsr -mabi=ilp32 -Os -nostdlib -ffreestanding \
          -Icommon -T common/link.ld
COMMON  = common/crt0.S common/print.c

OUT = ../test/fw

PROGS = hello memtest rftest flashtest flashtimeout
# riscv-tests vendored from riscv-software-src/riscv-tests @ bcffa2b3
# (isa/rv32ui/*.S incl. ../rv64ui bodies, isa/macros/scalar/test_macros.h)
RVTESTS = $(patsubst %.S,rv32ui-p-%,$(notdir $(wildcard riscv-tests/rv32ui/*.S)))

all: $(PROGS:%=$(OUT)/%.hex) $(RVTESTS:%=$(OUT)/%.hex)

$(OUT):
	mkdir -p $@

$(OUT)/%.elf: %/main.c $(COMMON) | $(OUT)
	$(CC) $(CFLAGS) common/crt0.S common/print.c $< -o $@
	$(OBJCOPY) -O binary $@ $@.bin

$(OUT)/%.hex: $(OUT)/%.elf
	$(OBJCOPY) -O verilog --verilog-data-width=1 $< $@

# riscv-tests: code at 0, tohost pass/fail convention
$(OUT)/rv32ui-p-%.elf: riscv-tests/rv32ui/%.S riscv-tests/riscv_test.h riscv-tests/test_macros.h | $(OUT)
	$(CC) -march=rv32i_zicsr_zifencei -mabi=ilp32 -Os -nostdlib -ffreestanding \
	    -Iriscv-tests -T riscv-tests/link.ld $< -o $@

$(OUT)/rv32ui-p-%.hex: $(OUT)/rv32ui-p-%.elf
	$(OBJCOPY) -O verilog --verilog-data-width=1 $< $@

clean:
	rm -rf $(OUT)
.PHONY: all clean
