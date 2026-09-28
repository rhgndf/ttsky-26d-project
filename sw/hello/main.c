#include "soc.h"
#include "print.h"

int main(void) {
    uart_init(0);
    print("Hello RV32I\n");
    GPIO = 0xA5;
    TOHOST = TOHOST_PASS;
    return 0;
}
