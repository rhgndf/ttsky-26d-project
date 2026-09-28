#include "soc.h"
#include "print.h"

void uart_init(uint16_t div) {
    UART_DIV = div;
}

void uart_putc(char c) {
    while (UART_STATUS & 1) {}
    UART_DATA = (uint8_t)c;
}

void print(const char *s) {
    while (*s) uart_putc(*s++);
}

void print_hex(uint32_t v) {
    print("0x");
    for (int i = 7; i >= 0; i--) {
        int d = (v >> (i * 4)) & 0xf;
        uart_putc(d < 10 ? '0' + d : 'a' + d - 10);
    }
}
