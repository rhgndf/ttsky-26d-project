OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
    PSRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 256K
}
SECTIONS {
    .text : { *(.text*) } > PSRAM
    .rodata : { *(.rodata*) *(.srodata*) } > PSRAM
    .data : { *(.data*) *(.sdata*) } > PSRAM
    _sbss = .;
    .bss : { *(.bss*) *(.sbss*) *(COMMON) } > PSRAM
    _ebss = .;
    _end = .;
}
