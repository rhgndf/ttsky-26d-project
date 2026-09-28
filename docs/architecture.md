# RV32I SoC for Tiny Tapeout (ttsky26d) — 1x1 tile design spec (authoritative)

HARD CONSTRAINT: the whole design must harden in a **1x1 tile** (~161 x 111.5 um, ~18,000 um^2 die, with
default src/config.json: PL_TARGET_DENSITY_PCT 60, CLOCK_PERIOD 20). Yosys cell-area budget target
<= ~10,500 um^2 (sky130_fd_sc_hd, scripts/area.sh); the real verdict is a local LibreLane hardening run.
Every flop counts (~20-25 um^2 each). Speed is irrelevant; area is everything.
No internal SRAM (doesn't fit). Verilog-2005, `default_nettype none`, verilator -Wall lint clean, no latches.

Top module `tt_um_rhgndf_rv32i_soc`. info.yaml tiles "1x1".

## Pinout
| pin | function |
|---|---|
| ui_in[0] | SPI MISO |
| ui_in[7:1] | general inputs (GPIO_IN reads ui_in[7:0], unsynchronized) |
| uo_out[0] | UART TX |
| uo_out[1] | SPI SCK |
| uo_out[2] | SPI MOSI |
| uo_out[3] | SPI CS_n |
| uo_out[7:4] | GPIO_OUT[3:0] |
| uio[0] | PSRAM CS_n (out) |
| uio[1] | PSRAM SCK (out) |
| uio[5:2] | PSRAM SD3..SD0 (SD0 = uio[2]; bidir) |
| uio[6] | I2C SDA (open drain: out=0, oe=1 drives low) |
| uio[7] | I2C SCL (open drain) |

## Memory map
- addr[29:28] == 2'b10 -> peripherals (0x2000_0000 + block*0x100, reg = addr[3:2] or [4:2]); everything else -> PSRAM addr[23:0] (mirrored).
- Reset PC = 0x0000_0000. **mtvec is read-only = 0x0000_0004** (crt0 puts `j _start` at 0 and `j trap_entry` at 4; default trap_entry = infinite loop).
- **Register file lives in PSRAM**: x[i] at byte address 0xFF_FF80 + 4*i (top 128 bytes of the 16 MB window; mirrors to the top of any power-of-2 smaller memory, e.g. 0x3FF80 in a 256 KB image). x0 is never read (value 0) nor written. Software must not use that area (linker: RAM 0..0x3FF00; stack top 0x3FE00).
- tb/emulator tohost moves to PSRAM word 0x3FF00 (outside the register area).
- PC is 24 bits (execution only from PSRAM); upper PC bits read as 0 (auipc/jal link values use the 24-bit PC zero-extended).

## PSRAM protocol (unchanged, APS6404L-compatible, fixed 4-byte transactions)
- SCK = clk/2, mode 0. Outputs change when SCK goes low; inputs sampled at the clk edge that raises SCK (drop the late_sample option unless free).
- READ: CS low, 0xEB on SD0 (8 SCK), 24-bit addr quad MSB-nibble first (6 SCK), DUMMY SCK (fixed 6; a MEMCFG register is optional — drop it if it costs area), 8 data nibbles b0hi,b0lo,b1hi,...,b3lo, CS high.
- WRITE: CS low, 0x38 on SD0 (8 SCK), addr quad (6 SCK), 8 data nibbles (same order), CS high. Always 4 bytes, word aligned. Sub-word stores: read-modify-write (see below).
- CS high >= 4 clk between transactions. SD oe only while driving (SD1-3 oe=0 during cmd).

## Recommended microarchitecture (nibble-serial, accumulator style)
- State: PC[23:2] (22 flops), IR[31:0], A[31:0] (accumulator/shift register), B[23:0]+periph flag (effective address / jump target), T[3:0] (nibble temp), small FSM + nibble counter, carry flop, CSR flops.
- ALU is 4 bits wide; A rotates by one nibble per step: A <= {alu(A[3:0], opnd_nib, carry), A[31:4]}; 8 steps per 32-bit op. opnd_nib source mux: incoming PSRAM nibble / immediate nibble (from IR, sign-extended, by counter) / PC nibble / constant.
- Byte-order trick for PSRAM reads (wire order hi,lo per byte; LSB-first datapath): each nibble takes 2 clk (SCK=clk/2). On the hi nibble: T <= nib. On the lo nibble: step A with the lo nibble; on the following clk step A with T. So data streams LSB-first through the ALU as it arrives. rs2 can be combined with A on the fly while it arrives (no rs2 register): R-type = read rs1 into A, stream rs2 through ALU into A, write A to rd.
- Writes: output nibble = A[7:4] (hi) then A[3:0] (lo), rotate A by 8 per byte.
- Address nibble output mux (MSB first): from PC, from B, or {16'hFFFF, 1'b1, idx[4:0], 2'b00} for registers.
- Shifts: one bit per 8-step pass (use neighbour bit A[4] for right shift, carry flop for left shift, saved sign/fill for the top nibble), repeated shamt times. Optionally a 1-clk nibble shift when remaining >= 4.
- SLT/SLTU/branches: subtract pass, derive lt/ltu from final carry + signs (save sign bits as needed).
- Load: A = rs1 + imm; B <= A[23:0] (+periph flag from A[29:28]); read at B into A; then align/extend (rotate by byte offset and sign/zero-extend via passes); write rd. Peripheral read: capture 32-bit periph rdata into A (parallel load or nibble-streamed, whichever is smaller).
- Store: A = rs1 + imm; B <= A; read rs2 into A; rotate A left by 8*offset; if sub-word and PSRAM: RMW = read word at B merging nibble-by-nibble into A (keep A's nibble when its byte strobe is set, else take the memory nibble — a 4-bit mux on the step path), then write A to B. Peripheral store: parallel wdata = A (after alignment; peripherals only need word writes).
- JAL/JALR: target -> B (JALR clears bit0); A = PC+4 -> rd; PC <= B. Branch: compare pass then A = PC + imm_b -> PC. Sequential: PC <= PC+4 (dedicated 22-bit incrementer or ALU pass — choose smaller).
- Skip rs reads when index is 0 (A = 0) and skip the rd write when rd == 0. Skip rs2 read for non-R/B/S types.
- FENCE/FENCE.I/WFI = NOP.
- Traps: ecall (11), ebreak (3), illegal (2 — only cheap-to-detect illegal opcodes are required; unknown funct combinations may execute as something else), misaligned load/store/jump target optional (drop if it costs >~150 um^2). Interrupts: timer (cause 0x8000_0007), external/none. Trap: mepc <= PC (24-bit), MPIE<=MIE, MIE<=0, PC <= 4. MRET: PC <= mepc, MIE<=MPIE, MPIE<=1.
- CSRs: mstatus (MIE b3, MPIE b7, MPP reads 11), mie (MTIE b7, MEIE b11), mip (RO: MTIP, MEIP), mepc (RW, 24-bit, [1:0]=0), mcause (RW-ish: int bit + 4-bit code stored), mtvec (RO 0x4). Everything else reads 0, writes ignored. All six CSR instruction forms.

## Peripherals (tiny; each register 32-bit address slot, unused bits read 0)
- Block 0 GPIO (0x2000_0000): 0x00 OUT [3:0] (rw) -> uo_out[7:4]; 0x04 IN [7:0] = ui_in (ro).
- Block 1 UART TX only (0x2000_0100), 8N1: 0x00 DATA (write starts TX, ignored if busy); 0x04 STATUS [0] busy (ro); 0x08 DIV [11:0] clocks per bit, reset 434. (UART RX only if area remains at the end.)
- Block 2 TIMER (0x2000_0200): 0x00 COUNT [23:0] rw, free-running at clk; 0x04 CMP [23:0] rw (reset all-ones); on COUNT==CMP: COUNT<=0, flag<=1. 0x08 CTRL/STATUS: [0] irq enable (rw), [1] flag (read; write 1 to clear). irq_timer = flag & irq_en (level) -> mip.MTIP.
- Block 3 SPI + Block 4 I2C share ONE serial engine (one 8-bit shift register, bit counter, clock divider; SPI and I2C can't run at the same time; a shared busy bit):
  - SPI (0x2000_0300), mode 0, MSB first: 0x00 DATA (write = start 8-bit full-duplex transfer; read = RX byte); 0x04 CTRL/STATUS: [0] busy (ro), [1] CS_n level (rw, reset 1).
  - I2C (0x2000_0400) master: 0x00 DATA (write TX byte / read RX byte); 0x04 CMD (write, ignored if busy): [0] START, [1] WRITE, [2] READ, [3] send NACK after READ, [4] STOP (executed in that order, any subset); read = STATUS [0] busy, [1] nack received. Open drain, clock stretching optional.
  - Shared DIV (0x2000_0308): [7:0], SPI SCK half period = I2C quarter period = DIV+1 clk, reset 124.
- No other peripherals.

## Software / tests (reuse phase-1 infra)
- sw/common crt0.S: vectors at 0 (`j _start`) and 4 (`j trap_entry`, weak default loops); link.ld per the map above. Regenerate all committed hex.
- psram_model: tohost at 0x3FF00; register area is normal memory. Keep protocol checks.
- Tests: hello (RTL + GL, short), riscv-tests rv32ui (all 41 still must pass; RTL only), memtest (PSRAM only now: byte/half/word stores/loads + sign extension), traptest (ecall/ebreak/illegal/mret/CSRs/timer interrupt), periph tests: timer irq, SPI loopback (tb option: MOSI->MISO), I2C against the tb I2C slave model (write pointer + data, repeated-start read back, NACK on bad address), UART TX decode.
