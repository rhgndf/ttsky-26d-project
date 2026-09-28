#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define REG32(addr)      (*(volatile uint32_t *)(addr))

/* Peripheral bases */
#define GPIO_BASE        0x20000000u
#define UART_BASE        0x20000100u
#define TIMER_BASE       0x20000200u
#define SPI_BASE         0x20000300u
#define I2C_BASE         0x20000400u

/* GPIO */
#define GPIO_OUT         REG32(GPIO_BASE + 0x00)
#define GPIO_IN          REG32(GPIO_BASE + 0x04)

/* UART (TX only, 8N1) */
#define UART_DATA        REG32(UART_BASE + 0x00)
#define UART_STATUS      REG32(UART_BASE + 0x04)  /* [0] busy */
#define UART_DIV         REG32(UART_BASE + 0x08)  /* [11:0], reset 434 */

/* TIMER (16-bit) */
#define TIMER_COUNT      REG32(TIMER_BASE + 0x00) /* [15:0] */
#define TIMER_CMP        REG32(TIMER_BASE + 0x04) /* [15:0] */
#define TIMER_CTRL       REG32(TIMER_BASE + 0x08) /* [0] irq_en, [1] flag (w1c) */

/* SPI (mode 0, MSB first) */
#define SPI_DATA         REG32(SPI_BASE + 0x00)
#define SPI_CTRL         REG32(SPI_BASE + 0x04)   /* [0] busy, [1] CS_n */
#define SERIAL_DIV       REG32(SPI_BASE + 0x08)   /* shared SPI/I2C divider, reset 124 */

/* I2C master */
#define I2C_DATA         REG32(I2C_BASE + 0x00)
#define I2C_CMD          REG32(I2C_BASE + 0x04)   /* w: [0]START [1]WRITE [2]READ [3]NACK [4]STOP
                                                   r: [0] busy, [1] nack */
#define I2C_CMD_START    0x01
#define I2C_CMD_WRITE    0x02
#define I2C_CMD_READ     0x04
#define I2C_CMD_NACK     0x08
#define I2C_CMD_STOP     0x10

/* tohost: PSRAM word address 0x3FF00 */
#define TOHOST           REG32(0x0003FF00u)
#define TOHOST_PASS      1u

#endif
