OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
    FLASH (rx) : ORIGIN = 0x00000000, LENGTH = 1M
    RAM  (rwx) : ORIGIN = 0x01000000, LENGTH = 0x1FF00 /* RF mirrors 0x7FFF00+ */
}
SECTIONS {
    .text : { *(.text*) } > FLASH
    .rodata : { *(.rodata*) *(.srodata*) } > FLASH
    . = ALIGN(4);
    _sidata = .;
    .data : AT(_sidata) {
        _sdata = .;
        *(.data*) *(.sdata*)
        . = ALIGN(4);
        _edata = .;
    } > RAM
    _sbss = .;
    .bss : { *(.bss*) *(.sbss*) *(COMMON) } > RAM
    _ebss = .;
    _end = .;
}
