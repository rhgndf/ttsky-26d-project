    .section .text
    .globl _start
    # mtvec = 4: word at 0 is `j _start`, word at 4 is `j trap_entry`
    j    _start
    j    trap_entry
_start:
    lui  sp, %hi(0x3FE00)
    addi sp, sp, %lo(0x3FE00)   # stack top = 0x3FE00
    # zero .bss
    la   t0, _sbss
    la   t1, _ebss
1:  bgeu t0, t1, 2f
    sb   zero, 0(t0)
    addi t0, t0, 1
    j    1b
2:  call main
3:  j    3b

    # weak default trap handler: infinite loop (programs may override)
    .weak trap_entry
trap_entry:
4:  j    4b
