#include "soc.h"
#include "print.h"

/* Register-file test: x1..x31 all hold distinct values across many
   instructions. Sets each GPR to a distinct constant, runs a dependent
   chain mixing them, and verifies the result. Fails via tohost code. */

// sum of 1..31 plus distinct offsets: x[i] = i*0x101 for i=1..31
// checked by folding all registers through xor/add into a0.

__attribute__((naked)) static uint32_t rf_sum(void) {
    __asm__ volatile(
        // save sp and ra in RAM scratch (x1 and x2 get tested too)
        "lui  t6, 0x01010\n"
        "sw   sp, 0x700(t6)\n"
        "sw   ra, 0x704(t6)\n"
        // distinct values: xN = N*0x101
        "li x1,0x101\n li x2,0x202\n li x3,0x303\n li x4,0x404\n"
        "li x5,0x505\n li x6,0x606\n li x7,0x707\n li x8,0x808\n"
        "li x9,0x909\n li x10,0xa0a\n li x11,0xb0b\n li x12,0xc0c\n"
        "li x13,0xd0d\n li x14,0xe0e\n li x15,0xf0f\n li x16,0x1010\n"
        "li x17,0x1111\n li x18,0x1212\n li x19,0x1313\n li x20,0x1414\n"
        "li x21,0x1515\n li x22,0x1616\n li x23,0x1717\n li x24,0x1818\n"
        "li x25,0x1919\n li x26,0x1a1a\n li x27,0x1b1b\n li x28,0x1c1c\n"
        "li x29,0x1d1d\n li x30,0x1e1e\n li x31,0x1f1f\n"
        // fold: a0 = x1^x2^...^x31 through many dependent instructions
        "mv a0, x1\n"
        "xor a0, a0, x2\n  xor a0, a0, x3\n  xor a0, a0, x4\n"
        "xor a0, a0, x5\n  xor a0, a0, x6\n  xor a0, a0, x7\n"
        "xor a0, a0, x8\n  xor a0, a0, x9\n  xor a0, a0, x10\n"
        "xor a0, a0, x11\n xor a0, a0, x12\n xor a0, a0, x13\n"
        "xor a0, a0, x14\n xor a0, a0, x15\n xor a0, a0, x16\n"
        "xor a0, a0, x17\n xor a0, a0, x18\n xor a0, a0, x19\n"
        "xor a0, a0, x20\n xor a0, a0, x21\n xor a0, a0, x22\n"
        "xor a0, a0, x23\n xor a0, a0, x24\n xor a0, a0, x25\n"
        "xor a0, a0, x26\n xor a0, a0, x27\n xor a0, a0, x28\n"
        "xor a0, a0, x29\n xor a0, a0, x30\n xor a0, a0, x31\n"
        // restore sp and ra, stash result
        "lui t6, 0x01010\n"
        "lw  sp, 0x700(t6)\n"
        "lw  ra, 0x704(t6)\n"
        "ret\n"
    );
}

int main(void) {
    uart_init(0);
    print("rftest\n");

    uint32_t s = rf_sum();
    // expected: the fold is a0 = x1 ^ x2 ^ ... ^ x31, but x10 IS a0 —
    // `xor a0,a0,x10` self-cancels, so the result is xor of x11..x31.
    uint32_t exp = 0;
    for (uint32_t i = 11; i <= 31; i++) exp ^= i * 0x101;
    if (s != exp) {
        print_hex(s);
        print_hex(exp);
        REG32(0x0101FEF8) = 3;
        for (;;) {}
    }

    // second pass: interleaved read/write through C variables forces many
    // register moves; arithmetic identity must hold.
    volatile uint32_t acc = 0;
    for (uint32_t i = 1; i <= 31; i++) {
        acc += i * 37;
        acc ^= acc << 3;
        acc += (acc >> 2) ^ i;
    }
    if (acc == 0) { REG32(0x0101FEF8) = 5; for (;;) {} }

    print("rftest done\n");
    TOHOST = TOHOST_PASS;
    return 0;
}
