# RV32I SoC for Tiny Tapeout (ttsky26d) — design spec (authoritative)

Top module: `tt_um_rhgndf_rv32i_soc` (file src/tt_um_rhgndf_rv32i_soc.v). Remove src/project.v / tt_um_example.
Verilog-2005 only (iverilog + yosys + TT linter (verilator lint) must be clean; `default_nettype none` in every file).
Target clock: 50 MHz (config.json CLOCK_PERIOD 20, leave config.json alone unless timing forces it).
Area is the main constraint: prefer small over fast everywhere (memory is ~60 clk per access anyway).

## Pinout
| pin | function |
|---|---|
| ui_in[0] | SPI MISO |
| ui_in[6:1] | general input (readable via GPIO_IN, which returns all ui_in[7:0]) |
| ui_in[7] | UART RX |
| uo_out[0] | UART TX (alt fn) |
| uo_out[1] | SPI SCK (alt fn) |
| uo_out[2] | SPI MOSI (alt fn) |
| uo_out[3] | SPI CS_n (alt fn) |
| uo_out[4] | Timer PWM (alt fn) |
| uo_out[7:5] | GPIO out |
| uio[0] | PSRAM CS_n (output) |
| uio[1] | PSRAM SCK (output) |
| uio[2] | PSRAM SD0 (bidir; MOSI in cmd phase) |
| uio[3] | PSRAM SD1 (bidir) |
| uio[4] | PSRAM SD2 (bidir) |
| uio[5] | PSRAM SD3 (bidir) |
| uio[6] | I2C SDA (open drain: uio_out=0, uio_oe=1 to pull low) |
| uio[7] | I2C SCL (open drain, same) |
uo_out[i] = GPIO_ALT[i] ? alt_fn[i] : GPIO_OUT[i]; GPIO_ALT resets to 8'h1F. For bits 5..7 alt_fn = 0.
SD0..SD3 are contiguous (uio[2..5]) on purpose so the RP2350 PIO can use `in/out pins, 4`.

## Memory map (CPU bus, 32-bit address)
- 0x0000_0000–0x0FFF_FFFF: external QSPI PSRAM, addr[23:0] used (16 MB window, mirrored). Reset PC = 0x0000_0000. Holds code (ROM image, preloaded by emulator) and data.
- 0x1000_0000–0x1FFF_FFFF: internal SRAM (single-cycle, size parameter SRAM_BYTES, mirrored). Can hold code or data.
- 0x2000_0000–0x2FFF_FFFF: peripherals; addr[11:8] selects block, addr[7:2] selects register. Unmapped reads return 0, writes ignored.
- Others: mirror of above by addr[29:28] (don't decode addr[31:30]) — cheapest.

## CPU bus (core <-> SoC), picorv32-style
`mem_valid, mem_addr[31:0], mem_wdata[31:0], mem_wstrb[3:0] (0 = read), mem_rdata[31:0], mem_ready`.
Core holds valid/addr/wdata/wstrb stable until the cycle mem_ready=1 (1-cycle pulse); then drops valid. Reads are always of the aligned word; core extracts/sign-extends bytes/halves. wstrb for stores is contiguous and aligned (1111, 0011/1100, single bit) with wdata already lane-shifted.

## CPU core (src/rv32i_core.v)
- Multi-cycle, non-pipelined FSM. RV32I + minimal Zicsr. Area first.
- Regfile x1..x31 as 31x32 flops, no reset, SINGLE read port: read rs1 and rs2 in consecutive cycles into operand regs. x0 reads 0.
- Shared adder for add/sub/compare/branch/address; shifts done serially 1 bit/cycle (counter) to avoid a barrel shifter.
- FENCE, FENCE.I, WFI = NOP.
- Traps (mcause): instr addr misaligned 0 (jump/branch target with bit1 set; checked at the jump), illegal instr 2, ebreak 3, load misaligned 4, store misaligned 6, ecall 11. Interrupts: machine timer 0x8000_0007, machine external 0x8000_000B. Interrupts are taken only at an instruction boundary (before fetch) when mstatus.MIE && (mie & mip) != 0; mepc = PC of the next (not yet executed) instruction.
- Trap entry: mepc <= pc (faulting instr for exceptions), mcause <= cause, mstatus.MPIE <= MIE, MIE <= 0, pc <= {mtvec[31:2],2'b00} (direct mode only). MRET: pc <= mepc, MIE <= MPIE, MPIE <= 1.
- CSRs implemented: mstatus 0x300 (only MIE bit3, MPIE bit7; MPP reads 2'b11 at bits 12:11), misa 0x301 (RO 0x4000_0100), mie 0x304 (MTIE bit7, MEIE bit11), mtvec 0x305, mscratch 0x340, mepc 0x341 (bits 1:0 read 0), mcause 0x342 (store {bit31, 4-bit code} only), mtval 0x343 (RO 0), mip 0x344 (RO: MTIP bit7, MEIP bit11 from SoC), mhartid 0xF14 (RO 0). All CSRRW/RS/RC/RWI/RSI/RCI. Any other CSR: reads 0, writes ignored (no trap).
- Inputs: irq_timer, irq_ext (level).

## QSPI PSRAM controller (src/qspi_psram.v)
Compatible with APS6404L in SPI mode (so a real PSRAM on CS works too) and designed to be easy for an RP2350 PIO emulator.
- SCK = clk/2, SPI mode 0 (idle low). Each SCK period = 2 clk: "low" clk then "high" clk. Outputs change only when SCK goes low. 
- Input sampling: default at the clk edge that raises SCK (data launched by the slave on the previous falling edge has 1 clk). MEMCFG.late_sample=1: sample at the clk edge that next lowers SCK (2 clk).
- READ (every CPU read / fetch from PSRAM): CS_n low; cmd 0xEB MSB-first on SD0 only (8 SCK, SD1-3 oe=0); addr[23:0] quad, MSB nibble first on SD[3:0] (6 SCK), addr is word-aligned (addr[1:0]=0); then DUMMY SCK cycles with all SD oe=0 (MEMCFG.dummy, reset 6); then 8 nibbles of data: byte at addr first, high nibble first => bytes b0,b1,b2,b3 -> rdata = {b3,b2,b1,b0}; CS_n high.
- WRITE: CS_n low; cmd 0x38 on SD0 (8 SCK); addr quad (6 SCK); 8 data nibbles quad (b0 hi, b0 lo, b1 hi, ...), CS_n high. ALWAYS exactly 4 bytes, word aligned. For sub-word stores (wstrb != 4'b1111) the controller does read-modify-write: a READ transaction, merge bytes by wstrb, then a WRITE transaction. (Fixed 4-byte transactions let the emulator avoid tracking CS during data.)
- CS_n high time between transactions >= 4 clk (enforce in controller).
- oe for SD lines only asserted while CS_n low and in cmd/addr/write-data phases. SD1-3 oe=0 in cmd phase.
- CS_n and SCK are always outputs (uio_oe=1).

## Peripherals (base 0x2000_0000 + block*0x100); all regs 32-bit, word access, 1-cycle ready
### 0: SYS/GPIO (0x2000_0000)
- 0x00 GPIO_OUT rw [7:0] reset 0
- 0x04 GPIO_IN ro [7:0] = ui_in (2-FF synchronized)
- 0x08 GPIO_ALT rw [7:0] reset 0x1F
- 0x0C MEMCFG rw: [3:0] dummy cycles (reset 6), [4] late_sample (reset 0)
### 1: UART (0x2000_0100), 8N1
- 0x00 DATA: write = start TX of [7:0] (ignored if busy); read = last RX byte, clears rx_valid.
- 0x04 STATUS ro: [0] tx_busy, [1] rx_valid, [2] rx_overrun (cleared on DATA read)
- 0x08 DIV rw [15:0]: clocks per bit, reset 434 (115200 @ 50 MHz)
- 0x0C CTRL rw: [0] rx interrupt enable (irq_ext source = rx_valid & en)
- RX: 2-FF sync, start bit detect, sample mid-bit.
### 2: TIMER (0x2000_0200)
- 0x00 COUNT rw [31:0]
- 0x04 CMP rw [31:0] (reset 0xFFFF_FFFF)
- 0x08 CTRL rw: [0] enable, [1] irq enable
- 0x0C STATUS: [0] match flag, write 1 to clear
- 0x10 PRESC rw [15:0]: tick every PRESC+1 clk
- 0x14 PWM rw [31:0]: pwm_out = (COUNT < PWM)
- On tick: if COUNT == CMP {COUNT <= 0; flag <= 1} else COUNT++. irq_timer = flag & irq_en.
### 3: SPI master (0x2000_0300), 8-bit, MSB first
- 0x00 DATA: write starts full-duplex transfer (ignored if busy); read = RX byte of last transfer
- 0x04 STATUS ro: [0] busy
- 0x08 CTRL rw: [7:0] div (SCK half period = div+1 clk, reset 3), [8] CPOL, [9] CPHA, [10] CS_n level (reset 1; software controlled)
### 4: I2C master (0x2000_0400)
- 0x00 DATA: write = TX byte; read = last RX byte
- 0x04 CMD (write triggers, ignored if busy): [0] START (or repeated start), [1] WRITE byte (DATA), [2] READ byte, [3] ack value to send after READ (0=ACK,1=NACK), [4] STOP. Executed in order START -> WRITE/READ -> STOP; any subset.
- 0x08 STATUS ro: [0] busy, [1] nack (ACK bit received after last WRITE)
- 0x0C DIV rw [15:0]: quarter SCL period in clk, reset 125 (100 kHz @ 50 MHz)
- Open drain on SDA/SCL (drive low via oe, release = input). Supports clock stretching (wait while SCL released but reads low). Inputs 2-FF synchronized.

## Internal SRAM (src/sram.v)
Word-organized 32-bit with byte write enables, parameter SRAM_BYTES (power of 2). Size chosen late to fill spare area. Start with flop array; may switch to a latch array later.

## Software (sw/)
- sw/common: crt0.S (set sp, zero .bss, copy nothing (data lives in PSRAM with code), call main, then loop), link.ld (PSRAM origin 0, LENGTH 256K; stack top 0x40000), soc.h (register defines), small uart/print helpers.
- gcc flags: -march=rv32i_zicsr -mabi=ilp32 -Os -nostdlib -ffreestanding. Output .hex for $readmemh (byte-wide, `objcopy -O verilog`) and .bin (for emulator).
- Prebuilt hex files for tests are committed (CI has no RISC-V toolchain); `make -C sw` regenerates.

## Testbench (test/)
- test/psram_model.v: Verilog behavioral model of the PSRAM as specified (0xEB/0x38, dummy count param/plusarg, 256 KB, $readmemh from +HEX plusarg / parameter), asserts protocol errors ($display "PSRAM_ERROR" + flag) e.g. unknown cmd or write length != 4 bytes. Response launched on SCK falling edge.
- test/i2c_slave_model.v: simple I2C slave (7-bit addr 0x50, EEPROM-like: first written byte = register pointer, subsequent write/read bytes at pointer++), with pullups modeled.
- tb.v wires the PSRAM model and I2C slave to uio (with pullup/tri-state resolution), and optionally SPI loopback MOSI->MISO controlled from cocotb.
- cocotb tests (test.py): short smoke test (hello over UART + GPIO) that must also run in the GL test (GATES=yes); longer tests (riscv-tests rv32ui, peripherals, interrupts, SRAM, sub-word PSRAM stores) skipped when GATES=yes.

## Emulator (emulator/) — RP2350 / Pico 2, pico-sdk
PIO QSPI slave matching the protocol above (fixed 4-byte data phases), CPU loop serving reads/writes from a 256 KB RAM image preloaded with an embedded program; optional TT clock output + reset pin; USB CDC loader + UART bridge. Pins configurable via #defines.
