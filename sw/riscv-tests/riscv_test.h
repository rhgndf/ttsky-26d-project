#ifndef RISCV_TEST_H
#define RISCV_TEST_H
// Custom riscv-tests environment for the SERV-based RV32I SoC.
// Code executes from flash (address 0); RAM is at 0x01000000.
// Pass/fail: write to PSRAM byte 0x0101FEFC (tohost): pass = 1,
// fail = (TESTNUM << 1) | 1.
// WITH_CSR=0: no trap handler needed — rv32ui tests never trap.

#define RVTEST_RV32U
#define RVTEST_RV64U RVTEST_RV32U
#define TESTNUM gp

#define RVTEST_CODE_BEGIN \
    .section .text;        \
    .globl _start;         \
_start:                   \
    lui sp, %hi(0x0101FE00); \
    addi sp, sp, %lo(0x0101FE00); \
    la  t0, _sidata;       \
    la  t1, _sdata;        \
    la  t2, _edata;        \
1:  bgeu t1, t2, 2f;       \
    lw  t3, 0(t0);         \
    sw  t3, 0(t1);         \
    addi t0, t0, 4;        \
    addi t1, t1, 4;        \
    j   1b;                \
2:  li  gp, 0;

#define RVTEST_PASS        \
    li   t0, 0x0101FEFC;   \
    li   t1, 1;            \
    sb   t1, 0(t0);        \
9:  j    9b;

#define RVTEST_FAIL        \
    li   t0, 0x0101FEFC;   \
    slli t1, TESTNUM, 1;   \
    ori  t1, t1, 1;        \
    sb   t1, 0(t0);        \
9:  j    9b;

#define RVTEST_CODE_END
#define RVTEST_DATA_BEGIN  .data
#define RVTEST_DATA_END

#endif
