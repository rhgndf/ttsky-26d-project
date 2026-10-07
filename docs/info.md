## How it works

The chip is a complete 32-bit RISC-V SoC built around [SERV](https://github.com/olofk/serv), the bit-serial RV32I CPU, vendored here at release 1.4.0 (no CSR, no compressed extension). Code executes directly out of an external QSPI flash chip over command 0xEB (quad fast read) and data is stored in an external QSPI PSRAM chip, written with command 0x38 (quad write enable mode). Both chips share one SPI bus; the PSRAM also holds the register file — registers x1..x31 are stored at PSRAM address 0x7FFF00..0x7FFF7C, and a dedicated engine streams them to/from SERV's serial register interface on top of normal memory traffic.

Memory map (addresses with bit 31 clear go to the QSPI bus; bit 31 set selects on-chip peripherals):

| Address | Function |
|---------|----------|
| `0x0000_0000`+ | QSPI flash, CS0. Read-only to software; holds the program image, linked at 0x0 |
| `0x0100_0000`+ | QSPI PSRAM, CS1. 128 KB data RAM (loads/stores) plus the register file at `0x0101_FF00` |
| `0x8000_0000` | `GPIO` data register: write `uo_out[7:0]`; read `[7:0]=ui_in`, `[8]=uio[7]` pin |
| `0x8000_0004` | `GPIO_IO`: write bit0 = `uio[7]` output value, bit1 = `uio[7]` output enable; read = same as `GPIO` |
| `0x8000_0008` | `TIMER`: free-running 16-bit counter, read-only (`0x8000_000C` reads it too) |
| `0x8000_002C` | `FLASH_STATUS`: bit0 `TIMEOUT` (sticky, write-1-to-clear), bit1 `WEN` (write enable, resets to 0) |
| `0x9000_0000+a` | `FLASH_PROG` window: a `sb`/`sh`/`sw` store quad-programs 1/2/4 bytes at flash address `a` |
| `0xA000_0000+a` | `FLASH_ERASE` window: any store erases the 4 KiB sector containing `a` |

Flash program/erase is performed in hardware by the same serial engine that serves the bus: the store stalls until the controller has issued WREN + 0x20 (sector erase) or 0x32 (quad page program) on CS0 and polled the flash status register (0x05) until BUSY clears, with a bounded retry limit that sets `TIMEOUT` instead of hanging. A `PROG`/`ERASE` store while `WEN=0` is acknowledged and ignored. Software should treat `WEN` as a per-operation arming bit and check `TIMEOUT` afterwards.

Pin use: `uio[7:0]` is the shared SPI bus — uio0 CS0 (flash), uio1..2 SD0..SD1, uio3 SCK, uio4..5 SD2..SD3 (quad I/O), uio6 CS1 (PSRAM), uio7 bidirectional GPIO (input after reset; the Pmod's CS2 position — leave as input/high if a second RAM is fitted). `uo[0]` doubles as a software UART TX (the provided `sw/common/print.c` bit-bangs 115200 8N1 through GPIO). All programs are linked at address `0x0` and boot from flash via `crt0.S`.

**Requirement:** the flash chip must have its QE (quad enable) bit set for 0xEB reads and 0x32 quad programming — standard on most QSPI parts (e.g. the TT QSPI Pmod's W25Q128, where QE is in status register 2).

## How to test

Firmware lives in `sw/`: `make` builds each program into `test/fw/<name>.hex` (RISC-V, linked at 0x0). In simulation, `cd test && make HEX=fw/hello.hex` runs the cocotb testbench with behavioral flash/PSRAM models; `make test-progs` runs the whole suite (41 riscv-tests + hello, memtest, rftest, traptest, flashtest, flashtimeout, periphtest).

On hardware, connect a QSPI flash+PSRAM Pmod to `uio[7:0]` (CS0 flash, CS1 PSRAM, uio7 available as GPIO), or emulate both chips with an RP2350. Load any `fw/*.hex` image into the flash at offset 0. `hello` prints over the software UART on `uo[0]`; `flashtest` exercises the FLASH_PROG/ERASE windows and FLASH_STATUS on sector `0x10000` — watch the UART output (or scope `uo[0]`) for the PASS/FAIL banner.

## External hardware

- Tiny Tapeout QSPI flash+PSRAM Pmod (e.g. W25Q128 flash + APS6404 PSRAM), or an RP2350 emulating both chips on the same bus
- UART on `uo[0]` via GPIO (115200 8N1, software bit-bang) for firmware console output
