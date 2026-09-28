#include "soc.h"
#include "print.h"
#include "tohost.h"

// fail code = (test number << 1) | 1  (odd, never 1)
#define FAIL(n) tohost(((n) << 1) | 1)

volatile uint8_t  *pb = (volatile uint8_t  *)0x10000;   // PSRAM data area, clear of the code image
volatile uint16_t *ph = (volatile uint16_t *)0x10000;
volatile uint32_t *pw = (volatile uint32_t *)0x10000;

int main(void) {
    uart_init(16);
    print("memtest\n");

    // ---- PSRAM byte/half/word stores + loads incl. sign extension
    pb[0] = 0x80; pb[1] = 0x7F; pb[2] = 0xFF; pb[3] = 0x01;
    if ((int8_t)pb[0] != -128) FAIL(1);
    if (pb[1] != 0x7F) FAIL(2);
    if (pw[0] != 0x01FF7F80u) FAIL(3);          // merged write read-back
    ph[2] = 0x8001;               // at 0x10004
    if ((int16_t)ph[2] != -32767) FAIL(4);
    pw[3] = 0xDEADBEEF;           // at 0x1000C
    if (pw[3] != 0xDEADBEEFu) FAIL(5);
    if (*(volatile int8_t *)(0x1000C) != -17) FAIL(6);
    // unaligned-adjacent bytes via sub-word stores
    pb[9]  = 0x55; pb[10] = 0xAA;
    if (pb[9] != 0x55 || pb[10] != 0xAA) FAIL(7);
    if (pw[2] != 0x00AA55FFu && pw[2] != 0xAA5501FFu) { /* half of word at 8 */
    }
    ph[5] = 0x5AA5;               // at 0x1000A
    if (ph[5] != 0x5AA5) FAIL(8);

    // ---- word sweep over a larger span (catches address decode + RMW bugs)
    for (uint32_t i = 0; i < 64; i++) pw[i] = 0xC0DE0000u + i;
    for (uint32_t i = 0; i < 64; i++) if (pw[i] != 0xC0DE0000u + i) FAIL(9);

    print("memtest done\n");
    tohost(TOHOST_PASS);
    return 0;
}
