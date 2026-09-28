#include "soc.h"
#include "print.h"

// fail code = (test number << 1) | 1  (odd, never 1)
#define FAIL(n) do { TOHOST = 0; REG32(0x0101FEF8) = ((n) << 1) | 1; for(;;); } while (0)

volatile uint8_t  *pb = (volatile uint8_t  *)(RAM_BASE + 0x1000);
volatile uint16_t *ph = (volatile uint16_t *)(RAM_BASE + 0x1000);
volatile uint32_t *pw = (volatile uint32_t *)(RAM_BASE + 0x1000);
volatile const uint32_t *fw = (volatile const uint32_t *)FLASH_BASE;

int main(void) {
    uart_init(0);
    print("memtest\n");

    // ---- flash reads (execute-from region also readable as data)
    if ((fw[0] & 0xFFFFu) == 0 || (fw[0] & 0xFFFFu) == 0xFFFFu) FAIL(1);
    volatile uint8_t fb = *(volatile const uint8_t *)(FLASH_BASE + 1);
    (void)fb;

    // ---- RAM byte/half/word stores + loads incl. sign extension
    pb[0] = 0x80; pb[1] = 0x7F; pb[2] = 0xFF; pb[3] = 0x01;
    if ((int8_t)pb[0] != -128) FAIL(2);
    if (pb[1] != 0x7F) FAIL(3);
    if (pw[0] != 0x01FF7F80u) FAIL(4);
    ph[2] = 0x8001;               // at +4
    if ((int16_t)ph[2] != -32767) FAIL(5);
    pw[3] = 0xDEADBEEF;           // at +0xC
    if (pw[3] != 0xDEADBEEFu) FAIL(6);
    if (*(volatile int8_t *)(RAM_BASE + 0x100C) != -17) FAIL(7);
    pb[9]  = 0x55; pb[10] = 0xAA;
    if (pb[9] != 0x55 || pb[10] != 0xAA) FAIL(8);
    ph[5] = 0x5AA5;               // at +0xA
    if (ph[5] != 0x5AA5) FAIL(9);

    // ---- word sweep over a larger span (address decode bugs)
    for (uint32_t i = 0; i < 64; i++) pw[i] = 0xC0DE0000u + i;
    for (uint32_t i = 0; i < 64; i++) if (pw[i] != 0xC0DE0000u + i) FAIL(10);

    // ---- high end of the software RAM range
    volatile uint32_t *hi = (volatile uint32_t *)0x0101FE00;
    hi[0] = 0x12345678;
    if (hi[0] != 0x12345678u) FAIL(11);

    print("memtest done\n");
    TOHOST = TOHOST_PASS;
    return 0;
}
