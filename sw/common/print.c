#include "soc.h"
#include "print.h"

/* Bit-banged UART TX (8N1) on uo_out[0] via GPIO. The tb measures the actual
   bit width from the first start bit, so the exact rate doesn't matter as
   long as it's roughly constant. */
static void uart_delay(void) {
    for (volatile int i = 0; i < UART_DELAY; i++) {}
}

void uart_init(uint16_t div) {
    (void)div;
    GPIO = 1;  /* idle high */
}

void uart_putc(char c) {
    /* start bit, 8 data bits LSB first, stop bit; identical work per bit */
    uint32_t frame = ((uint32_t)(uint8_t)c << 1) | 0x200u;
    for (int i = 0; i < 10; i++) {
        GPIO = frame & 1u;
        frame >>= 1;
        uart_delay();
    }
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
