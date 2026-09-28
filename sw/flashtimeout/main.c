#include "soc.h"
#include "print.h"

// fail code = (test number << 1) | 1  (odd, never 1)
#define FAIL(n) do { TOHOST = 0; REG32(0x0101FEF8) = ((n) << 1) | 1; for(;;); } while (0)

int main(void) {
    uart_init(0);
    print("flashtimeout\n");

    FLASH_STATUS = 2;                        // WEN=1
    REG32(FLASH_ERASE_WIN + 0x10000u) = 1;   // flash stuck busy -> TIMEOUT

    // store returned; TIMEOUT must be set
    if ((FLASH_STATUS & 1) == 0) FAIL(1);

    // write-1-clear clears TIMEOUT (also clears WEN via bit1=0)
    FLASH_STATUS = 1;
    if (FLASH_STATUS & 3) FAIL(2);

    // CPU still runs normally after the timeout
    volatile uint32_t *ram = (volatile uint32_t *)RAM_BASE;
    ram[0] = 0xABCD1234u;
    if (ram[0] != 0xABCD1234u) FAIL(3);

    print("flashtimeout done\n");
    TOHOST = TOHOST_PASS;
    return 0;
}
