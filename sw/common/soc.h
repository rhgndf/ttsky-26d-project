#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define REG32(addr)      (*(volatile uint32_t *)(addr))
#define REG16(addr)      (*(volatile uint16_t *)(addr))
#define REG8(addr)       (*(volatile uint8_t *)(addr))

/* Memory map (SERV bus addresses) */
#define RAM_BASE         0x01000000u   /* PSRAM, 128 KB usable 0x0101FEFF max */
#define FLASH_BASE       0x00000000u   /* W25Q128, read-only */
#define PERIPH_BASE      0x80000000u   /* adr[31] -> peripherals */

/* GPIO 0x00: write[7:0] = uo_out; read[7:0] = ui_in, read[8] = uio[7] pin */
#define GPIO             REG32(PERIPH_BASE)
/* GPIO_IO 0x04: write bit0 = uio[7] out value, bit1 = uio[7] output enable;
 * read = same as GPIO */
#define GPIO_IO          REG32(0x80000004u)
/* TIMER 0x08: free-running 16-bit counter, read-only (0x0C reads it too) */
#define TIMER            REG32(0x80000008u)

/* flash controller: ops are address windows, op addr = a[23:0]
 * FLASH_PROG   0x9000_0000|a  store sb/sh/sw programs 1/2/4 bytes at a
 * FLASH_ERASE  0xA000_0000|a  any store erases the 4 KiB sector at a
 * FLASH_STATUS 0x8000_002C    bit0 TIMEOUT (sticky W1C), bit1 WEN */
#define FLASH_PROG_WIN   0x90000000u
#define FLASH_ERASE_WIN  0xA0000000u
#define FLASH_STATUS     REG32(0x8000002Cu)

/* tohost: PSRAM byte 0x0101FEFC (tb model watches device addr 0x1FEFC) */
#define TOHOST           REG8(0x0101FEFCu)
#define TOHOST_PASS      1u

/* bit-banged UART TX on uo_out[0] */
#define UART_DELAY       1  /* iterations of delay loop per bit cell */

#endif
