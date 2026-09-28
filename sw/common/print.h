#ifndef PRINT_H
#define PRINT_H
#include <stdint.h>
void uart_init(uint16_t div);
void uart_putc(char c);
void print(const char *s);
void print_hex(uint32_t v);
#endif
