#include "soc.h"
#include "print.h"

// fail code = (test number << 1) | 1  (odd, never 1)
#define FAIL(n) do { TOHOST = 0; REG32(0x0101FEF8) = ((n) << 1) | 1; for(;;); } while (0)

#define FLASH_ADDR   REG32(0x80000020u)
#define FLASH_PROG   REG32(0x80000024u)
#define FLASH_PROG16 REG16(0x80000024u)
#define FLASH_PROG8  REG8(0x80000024u)
#define FLASH_ERASE  REG32(0x80000028u)
#define FLASH_STATUS REG32(0x8000002Cu)

#define SECT 0x10000u   /* sector under test, well above the image */

volatile const uint32_t *fw = (volatile const uint32_t *)(FLASH_BASE + SECT);

int main(void) {
    uart_init(0);
    print("flashtest\n");

    // FLASH_ADDR R/W
    FLASH_ADDR = SECT;
    if (FLASH_ADDR != SECT) FAIL(1);
    if (FLASH_ADDR & 0xFF000000u) FAIL(2);      // reads return {8'b0, fa}

    // STATUS reset state: WEN=0, TIMEOUT=0
    if (FLASH_STATUS != 0) FAIL(3);

    // WEN=0: PROG and ERASE are no-ops (sector still reads 0x00)
    FLASH_PROG  = 0xFFFFFFFFu;
    FLASH_ERASE = 1;
    if (fw[0] != 0x00000000u) FAIL(4);
    if (FLASH_STATUS != 0) FAIL(5);

    // enable writes, erase the sector -> all 0xFF
    FLASH_STATUS = 2;                            // WEN=1
    if ((FLASH_STATUS & 2) == 0) FAIL(6);
    FLASH_ERASE = 1;
    for (int i = 0; i < 4; i++)
        if (fw[i] != 0xFFFFFFFFu) FAIL(7);

    // word program + readback
    FLASH_PROG = 0x0F0F0F0Fu;
    if (fw[0] != 0x0F0F0F0Fu) FAIL(8);

    // AND semantics: 0xF0 over 0x0F -> 0x00
    FLASH_PROG = 0xF0F0F0F0u;
    if (fw[0] != 0x00000000u) FAIL(9);

    // half and byte programs on a fresh erased location
    FLASH_ADDR = SECT + 4;
    FLASH_PROG16 = 0x5AA5u;                       // 2 bytes; upper stay 0xFF
    if (fw[1] != 0xFFFF5AA5u) FAIL(10);
    FLASH_PROG8 = 0xA5u;                          // fa = SECT+4 still; 0xA5&0xA5
    if ((fw[1] & 0xFFu) != 0xA5u) FAIL(11);
    FLASH_ADDR = SECT + 8;
    FLASH_PROG8 = 0x3Cu;                          // byte0; rest stay 0xFF
    if (fw[2] != 0xFFFFFF3Cu) FAIL(12);

    // TIMEOUT stayed clear throughout
    if (FLASH_STATUS & 1) FAIL(13);

    print("flashtest done\n");
    TOHOST = TOHOST_PASS;
    return 0;
}
