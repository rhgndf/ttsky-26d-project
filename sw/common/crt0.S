    .section .text
    .globl _start
_start:
    lui  sp, 0x40          # stack top = 0x40000 (end of 256K PSRAM window)
    # zero .bss
    la   t0, _sbss
    la   t1, _ebss
1:  bgeu t0, t1, 2f
    sb   zero, 0(t0)
    addi t0, t0, 1
    j    1b
2:  call main
3:  j    3b
