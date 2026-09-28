#ifndef RISCV_TEST_H
#define RISCV_TEST_H
// Custom riscv-tests environment for the RV32I SoC.
// Code starts at address 0. Pass/fail is signaled by a write to the PSRAM
// tohost word address 0x3FF00: pass = 1, fail = (TESTNUM << 1) | 1.
// mtvec = 4: trap at 4 would jump to uninitialized memory, but rv32ui tests
// never trap, so no vector table is needed here (data beyond 0x3FF00 is regs).

#define RVTEST_RV32U
#define RVTEST_RV64U RVTEST_RV32U
#define TESTNUM gp

#define RVTEST_CODE_BEGIN \
    .section .text;        \
    .globl _start;         \
_start:                   \
    lui sp, 0x40;          \
    addi sp, sp, -512;     \
    li  gp, 0;

#define RVTEST_PASS        \
    li   t0, 0x3ff00;      \
    li   t1, 1;            \
    sw   t1, 0(t0);        \
9:  j    9b;

#define RVTEST_FAIL        \
    li   t0, 0x3ff00;      \
    slli t1, TESTNUM, 1;   \
    ori  t1, t1, 1;        \
    sw   t1, 0(t0);        \
9:  j    9b;

#define RVTEST_CODE_END
#define RVTEST_DATA_BEGIN
#define RVTEST_DATA_END

#endif
