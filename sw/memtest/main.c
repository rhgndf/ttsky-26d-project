#include "soc.h"
#include "print.h"
#include "tohost.h"

// fail code = (test number << 1) | 1  (odd, never 1)
#define FAIL(n) tohost(((n) << 1) | 1)

volatile uint8_t  *pb = (volatile uint8_t  *)0x10000;   // PSRAM data area, clear of the code image
volatile uint16_t *ph = (volatile uint16_t *)0x10000;
volatile uint32_t *pw = (volatile uint32_t *)0x10000;

// copied into internal SRAM and executed there
__attribute__((noinline))
static uint32_t sram_fn(uint32_t x) {
    return x * 3 + 7;
}

int main(void) {
    uart_init(16);
    print("memtest\n");

    // ---- PSRAM byte/half/word stores + loads incl. sign extension
    pb[0] = 0x80; pb[1] = 0x7F; pb[2] = 0xFF; pb[3] = 0x01;
    if ((int8_t)pb[0] != -128) FAIL(1);
    if (pb[1] != 0x7F) FAIL(2);
    ph[2] = 0x8001;               // at 0x10004
    if ((int16_t)ph[2] != -32767) FAIL(3);
    pw[3] = 0xDEADBEEF;           // at 0x1000C
    if (pw[3] != 0xDEADBEEFu) FAIL(4);
    if (*(volatile int8_t *)(0x1000C) != -17) FAIL(5);

    // ---- internal SRAM byte/half/word
    volatile uint8_t  *sb = (volatile uint8_t  *)SRAM_BASE;
    volatile uint16_t *sh = (volatile uint16_t *)SRAM_BASE;
    volatile uint32_t *sw = (volatile uint32_t *)SRAM_BASE;
    sb[0] = 0x80; sb[1] = 0x7F; sb[2] = 0xFF; sb[3] = 0x01;
    if ((int8_t)sb[0] != -128) FAIL(6);
    if (sw[0] != 0x01FF7F80u) FAIL(7);
    sh[2] = 0xCAFE;
    if ((int16_t)sh[2] != -0x3502) FAIL(8);
    sw[4] = 0x12345678;
    if (sw[4] != 0x12345678u) FAIL(9);

    // ---- execute from internal SRAM
    uint8_t *dst = (uint8_t *)(SRAM_BASE + 0x80);
    uint8_t *src = (uint8_t *)&sram_fn;
    for (int i = 0; i < 64; i++) dst[i] = src[i];
    uint32_t (*fn)(uint32_t) = (uint32_t (*)(uint32_t))dst;
    if (fn(10) != 37) FAIL(10);

    print("memtest done\n");
    tohost(TOHOST_PASS);
    return 0;
}
