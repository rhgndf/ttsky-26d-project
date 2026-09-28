// Directed trap/CSR test: ecall, ebreak, illegal instr, misaligned load/store,
// CSR rw/set/clear, mret round-trip, mepc/mcause checks.
#include "soc.h"
#include "print.h"
#include "tohost.h"

#define FAIL(n) tohost(((n) << 1) | 1)
#define OK()    do { passed++; } while (0)

static volatile int passed;

// trap handler: record mcause/mepc, skip faulting instr (+4), return
__attribute__((naked))
static void trap_handler(void) {
    __asm__ volatile (
        "csrr t0, mcause\n"
        "la   t1, last_mcause\n"
        "sw   t0, 0(t1)\n"
        "csrr t0, mepc\n"
        "la   t1, last_mepc\n"
        "sw   t0, 0(t1)\n"
        "addi t0, t0, 4\n"
        "csrw mepc, t0\n"
        "mret\n"
    );
}

volatile uint32_t last_mcause, last_mepc;

#define READ_CSR(csr, v) __asm__ volatile ("csrr %0, " #csr : "=r"(v))
#define WRITE_CSR(csr, v) __asm__ volatile ("csrw " #csr ", %0" :: "r"(v))

static uint32_t expect_pc;

static int check_trap(uint32_t cause, uint32_t expc) {
    if (last_mcause != cause) return 0;
    if (expc && last_mepc != expc) return 0;
    return 1;
}

int main(void) {
    uart_init(16);
    print("traptest\n");
    passed = 0;

    WRITE_CSR(mtvec, (uint32_t)trap_handler);
    WRITE_CSR(mstatus, 0); // MIE=0, exceptions still trap

    uint32_t v;

    // ---- ECALL -> mcause 11
    expect_pc = 0;
    __asm__ volatile ("la %0, 1f\n1: ecall\n2:" : "=r"(expect_pc));
    // note: 1f is the ecall address... expect_pc holds address of '1:' label
    if (!check_trap(11, expect_pc)) FAIL(1); else OK();

    // ---- EBREAK -> mcause 3
    __asm__ volatile ("la %0, 3f\n3: ebreak\n" : "=r"(expect_pc));
    if (!check_trap(3, expect_pc)) FAIL(2); else OK();

    // ---- illegal instruction -> mcause 2
    __asm__ volatile ("la %0, 4f\n4: .word 0x00000000\n" : "=r"(expect_pc));
    if (!check_trap(2, expect_pc)) FAIL(3); else OK();

    // ---- misaligned load -> mcause 4 (asm: GCC splits C unaligned loads)
    last_mcause = 0xFFFFFFFF;
    __asm__ volatile ("lw %0, 2(%1)" : "=r"(v) : "r"(SRAM_BASE));
    if (!check_trap(4, 0)) FAIL(4); else OK();

    // ---- misaligned store -> mcause 6
    last_mcause = 0xFFFFFFFF;
    __asm__ volatile ("sw %0, 2(%1)" :: "r"(0), "r"(SRAM_BASE));
    if (!check_trap(6, 0)) FAIL(5); else OK();

    // ---- CSR rw/set/clear on mscratch
    WRITE_CSR(mscratch, 0x12345678);
    READ_CSR(mscratch, v);
    if (v != 0x12345678) FAIL(6); else OK();
    __asm__ volatile ("csrs mscratch, %0" :: "r"(0xFF));
    READ_CSR(mscratch, v);
    if (v != 0x123456FF) FAIL(7); else OK();
    __asm__ volatile ("csrc mscratch, %0" :: "r"(0xFF00FF));
    READ_CSR(mscratch, v);
    if (v != 0x12005600) FAIL(8); else OK();

    // ---- mstatus MIE r/w, MPIE set by trap entry
    WRITE_CSR(mstatus, 0x08);
    READ_CSR(mstatus, v);
    if ((v & 0x88) != 0x08 && (v & 0x08) != 0x08) FAIL(9); else OK();

    // ---- mepc reads bits 1:0 as 0
    WRITE_CSR(mepc, 0x43);
    READ_CSR(mepc, v);
    if (v != 0x40) FAIL(10); else OK();

    // ---- unknown CSR reads 0
    __asm__ volatile ("csrr %0, 0x7C0" : "=r"(v));
    if (v != 0) FAIL(11); else OK();

    print("traptest done\n");
    tohost(TOHOST_PASS);
    return 0;
}
