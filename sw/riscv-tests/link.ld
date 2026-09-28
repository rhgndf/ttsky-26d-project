OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
    PSRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 256K
}
SECTIONS {
    .text : { *(.text*) *(.text.init*) } > PSRAM
    .data : { *(.data*) *(.rodata*) } > PSRAM
    _end = .;
}
