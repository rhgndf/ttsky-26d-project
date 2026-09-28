#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define REG32(addr)      (*(volatile uint32_t *)(addr))

/* Peripheral bases */
#define SYS_BASE         0x20000000u
#define UART_BASE        0x20000100u
#define TIMER_BASE       0x20000200u
#define SPI_BASE         0x20000300u
#define I2C_BASE         0x20000400u

/* SYS/GPIO */
#define GPIO_OUT         REG32(SYS_BASE + 0x00)
#define GPIO_IN          REG32(SYS_BASE + 0x04)
#define GPIO_ALT         REG32(SYS_BASE + 0x08)
#define MEMCFG           REG32(SYS_BASE + 0x0C)

/* UART */
#define UART_DATA        REG32(UART_BASE + 0x00)
#define UART_STATUS      REG32(UART_BASE + 0x04)
#define UART_DIV         REG32(UART_BASE + 0x08)
#define UART_CTRL        REG32(UART_BASE + 0x0C)

/* Internal SRAM */
#define SRAM_BASE        0x10000000u
#define SRAM_BYTES       256

/* tohost: PSRAM word address 0x3FFF0 */
#define TOHOST           REG32(0x0003FFF0u)
#define TOHOST_PASS      1u

#endif
