#include "soc.h"
#include "print.h"

// fail code = (test number << 1) | 1  (odd, never 1)
#define FAIL(n) do { TOHOST = 0; REG32(0x0101FEF8) = ((n) << 1) | 1; for(;;); } while (0)

int main(void) {
    uart_init(0);
    print("periphtest\n");

    // timer: 3 reads, each consecutive delta nonzero
    uint16_t t0 = (uint16_t)TIMER;
    uint16_t t1 = (uint16_t)TIMER;
    uint16_t t2 = (uint16_t)TIMER;
    if ((uint16_t)(t1 - t0) == 0) FAIL(1);
    if ((uint16_t)(t2 - t1) == 0) FAIL(2);

    // uio[7]: external pull-up in tb -> bit8 reads 1 while oe=0
    if (((GPIO >> 8) & 1) != 1) FAIL(3);

    // drive it: oe=1, out=0 -> 0; out=1 -> 1
    GPIO_IO = 2;
    if (((GPIO >> 8) & 1) != 0) FAIL(4);
    GPIO_IO = 3;
    if (((GPIO >> 8) & 1) != 1) FAIL(5);

    // release -> pull-up again
    GPIO_IO = 0;
    if (((GPIO >> 8) & 1) != 1) FAIL(6);

    print("periphtest done\n");
    TOHOST = TOHOST_PASS;
    return 0;
}
