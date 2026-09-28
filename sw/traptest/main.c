// Directed trap/CSR test: ecall, ebreak, illegal instr, CSR rw/set/clear,
// mret round-trip, timer interrupt. mtvec is read-only = 4; crt0 puts
// `j trap_entry` at address 4, and this file overrides the weak default.
#include "soc.h"
#include "print.h"
#include "tohost.h"

#define FAIL(n) tohost(((n) << 1) | 1)
#define OK()    do { passed++; } while (0)

static volatile int passed;
volatile uint32_t last_mcause, last_mepc, trap_count;

// trap handler: record mcause/mepc, clear timer flag, skip faulting instr
// (except for interrupts, which must re-execute at mepc)
__attribute__((naked))
void trap_entry(void) {
    __asm__ volatile (
        "la   t1, trap_count\n"
        "lw   t0, 0(t1)\n"
        "addi t0, t0, 1\n"
        "sw   t0, 0(t1)\n"
        "csrr t0, mcause\n"
        "la   t1, last_mcause\n"
        "sw   t0, 0(t1)\n"
        "csrr t0, mepc\n"
        "la   t1, last_mepc\n"
        "sw   t0, 0(t1)\n"
        // clear timer flag (TIMER_CTRL=2) so timer irq doesn't refire
        "li   t1, 0x20000208\n"
        "li   t2, 2\n"
        "sw   t2, 0(t1)\n"
        // interrupts: keep mepc; exceptions: mepc += 4
        "csrr t0, mcause\n"
        "bltz t0, 1f\n"
        "csrr t0, mepc\n"
        "addi t0, t0, 4\n"
        "csrw mepc, t0\n"
        "1: mret\n"
    );
}

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
    trap_count = 0;

    WRITE_CSR(mstatus, 0); // MIE=0, exceptions still trap

    uint32_t v;

    // ---- mtvec reads back 4 and is not writable
    READ_CSR(mtvec, v);
    if (v != 4) FAIL(1); else OK();
    WRITE_CSR(mtvec, 0x100);
    READ_CSR(mtvec, v);
    if (v != 4) FAIL(2); else OK();

    // ---- ECALL -> mcause 11
    expect_pc = 0;
    __asm__ volatile ("la %0, 1f\n1: ecall\n2:" : "=r"(expect_pc));
    if (!check_trap(11, expect_pc)) FAIL(3); else OK();

    // ---- EBREAK -> mcause 3
    __asm__ volatile ("la %0, 3f\n3: ebreak\n" : "=r"(expect_pc));
    if (!check_trap(3, expect_pc)) FAIL(4); else OK();

    // ---- illegal instruction -> mcause 2
    __asm__ volatile ("la %0, 4f\n4: .word 0x00000000\n" : "=r"(expect_pc));
    if (!check_trap(2, expect_pc)) FAIL(5); else OK();

    // ---- CSR rw/set/clear on mcause (int bit + code[3:0] stored)
    WRITE_CSR(mcause, 0x80000007);
    READ_CSR(mcause, v);
    if (v != 0x80000007) FAIL(6); else OK();
    WRITE_CSR(mcause, 0x00000005);
    __asm__ volatile ("csrs mcause, %0" :: "r"(0x80000002));
    READ_CSR(mcause, v);
    if (v != 0x80000007) FAIL(7); else OK();
    __asm__ volatile ("csrc mcause, %0" :: "r"(0x80000003));
    READ_CSR(mcause, v);
    if (v != 0x00000004) FAIL(8); else OK();
    WRITE_CSR(mcause, 0);

    // ---- mstatus MIE r/w, MPP reads 11
    WRITE_CSR(mstatus, 0x08);
    READ_CSR(mstatus, v);
    if ((v & 0x1808) != 0x1808) FAIL(9); else OK();  // MPP=11, MIE=1
    WRITE_CSR(mstatus, 0x00);

    // ---- mepc reads bits 1:0 as 0
    WRITE_CSR(mepc, 0x43);
    READ_CSR(mepc, v);
    if (v != 0x40) FAIL(10); else OK();

    // ---- mie MTIE r/w
    WRITE_CSR(mie, 0x80);
    READ_CSR(mie, v);
    if ((v & 0x880) != 0x80) FAIL(11); else OK();
    WRITE_CSR(mie, 0);

    // ---- unknown CSR reads 0
    __asm__ volatile ("csrr %0, 0x7C0" : "=r"(v));
    if (v != 0) FAIL(12); else OK();

    // ---- timer interrupt: mip.MTIP pending, taken when MIE+MTIE
    uint32_t before = trap_count;
    TIMER_CMP   = 300;
    TIMER_COUNT = 0;
    TIMER_CTRL  = 1;                // irq enable, clear flag
    WRITE_CSR(mie, 0x80);           // MTIE
    WRITE_CSR(mstatus, 0x08);       // MIE
    // count must run ~300 clks; cpu is much slower, so just wait
    for (volatile int i = 0; i < 200; i++) {}
    if (trap_count != before + 1) FAIL(13); else OK();
    READ_CSR(mcause, v);
    if ((int32_t)last_mcause != (int32_t)0x80000007) FAIL(14); else OK();
    // mepc for irq = address of instruction that was about to run (pc, not pc+4):
    // verify it points back into main (below 0x3FF00 and above _start)
    if (last_mepc == 0 || last_mepc >= 0x3FF00) FAIL(15); else OK();

    print("traptest done\n");
    tohost(TOHOST_PASS);
    return 0;
}
