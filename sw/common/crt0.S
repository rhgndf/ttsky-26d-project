    .section .text
    .globl _start
    # boots from flash (address 0); copies .data flash->RAM, zeroes .bss
_start:
    lui  sp, %hi(0x0101FE00)
    addi sp, sp, %lo(0x0101FE00)   # stack top = 0x0101FE00 (RAM)
    # copy .data (LMA in flash -> VMA in RAM)
    la   t0, _sidata
    la   t1, _sdata
    la   t2, _edata
1:  bgeu t1, t2, 2f
    lw   t3, 0(t0)
    sw   t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j    1b
    # zero .bss
2:  la   t0, _sbss
    la   t1, _ebss
3:  bgeu t0, t1, 4f
    sb   zero, 0(t0)
    addi t0, t0, 1
    j    3b
4:  call main
5:  j    5b
