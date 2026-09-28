#include "soc.h"
#include "print.h"
#include "tohost.h"

int main(void) {
    uart_init(16);                 // fast baud for simulation
    print("Hello RV32I\n");
    GPIO_OUT = 0xA5;               // visible GPIO write for the smoke test
    tohost(TOHOST_PASS);
    return 0;
}
