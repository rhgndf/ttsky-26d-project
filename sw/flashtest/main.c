#include "soc.h"
#include "print.h"

// fail code = (test number << 1) | 1  (odd, never 1)
#define FAIL(n) do { TOHOST = 0; REG32(0x0101FEF8) = ((n) << 1) | 1; for(;;); } while (0)

#define SECT 0x10000u   /* sector under test, well above the image */

volatile const uint32_t *fw = (volatile const uint32_t *)(FLASH_BASE + SECT);

int main(void) {
    uart_init(0);
    print("flashtest\n");

    // STATUS reset state: WEN=0, TIMEOUT=0
    if (FLASH_STATUS != 0) FAIL(1);

    // WEN=0: PROG and ERASE are no-ops (sector still reads 0x00)
    REG32(FLASH_PROG_WIN + SECT) = 0xFFFFFFFFu;
    REG32(FLASH_ERASE_WIN + SECT) = 1;
    if (fw[0] != 0x00000000u) FAIL(2);
    if (FLASH_STATUS != 0) FAIL(3);

    // enable writes, erase the sector -> all 0xFF
    FLASH_STATUS = 2;                            // WEN=1
    if ((FLASH_STATUS & 2) == 0) FAIL(4);
    REG32(FLASH_ERASE_WIN + SECT) = 1;
    for (int i = 0; i < 4; i++)
        if (fw[i] != 0xFFFFFFFFu) FAIL(5);

    // word program + readback
    REG32(FLASH_PROG_WIN + SECT) = 0x0F0F0F0Fu;
    if (fw[0] != 0x0F0F0F0Fu) FAIL(6);

    // AND semantics: 0xF0 over 0x0F -> 0x00
    REG32(FLASH_PROG_WIN + SECT) = 0xF0F0F0F0u;
    if (fw[0] != 0x00000000u) FAIL(7);

    // half and byte programs on fresh erased locations
    REG16(FLASH_PROG_WIN + SECT + 4) = 0x5AA5u;   // 2 bytes; upper stay 0xFF
    if (fw[1] != 0xFFFF5AA5u) FAIL(8);
    REG8(FLASH_PROG_WIN + SECT + 4) = 0xA5u;      // byte0 again: 0xA5&0xA5
    if ((fw[1] & 0xFFu) != 0xA5u) FAIL(9);
    REG8(FLASH_PROG_WIN + SECT + 8) = 0x3Cu;      // byte0; rest stay 0xFF
    if (fw[2] != 0xFFFFFF3Cu) FAIL(10);

    // TIMEOUT stayed clear throughout
    if (FLASH_STATUS & 1) FAIL(11);

    print("flashtest done\n");
    TOHOST = TOHOST_PASS;
    return 0;
}
