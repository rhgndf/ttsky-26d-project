OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
    FLASH (rx) : ORIGIN = 0x00000000, LENGTH = 1M
    RAM  (rwx) : ORIGIN = 0x01000000, LENGTH = 0x1FF00
}
SECTIONS {
    .text : { *(.text*) *(.text.init*) } > FLASH
    . = ALIGN(4);
    _sidata = .;
    .data : AT(_sidata) {
        _sdata = .;
        *(.data*) *(.sdata*) *(.rodata*)
        . = ALIGN(4);
        _edata = .;
    } > RAM
    _end = .;
}
