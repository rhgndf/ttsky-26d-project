#!/usr/bin/env bash
# Area estimate for the RV32I SoC against sky130_fd_sc_hd.
# Usage: ./scripts/area.sh   (requires yosys + $LIB liberty, see ~/env.sh)
set -e
cd "$(dirname "$0")/.."
LIB=${LIB:?Set LIB to the sky130_fd_sc_hd liberty (source ~/env.sh)}

SOURCES="src/rv32i_core.v src/qspi_psram.v src/sram.v src/uart.v src/tt_um_rhgndf_rv32i_soc.v"

# Per-module area: synthesize each leaf module alone (sram uses its own param).
per_module() {
    local top=$1; shift
    local files="$@"
    yosys -p "read_verilog $files; synth -top $top; dfflibmap -liberty $LIB; abc -liberty $LIB; stat -liberty $LIB" 2>/dev/null \
        | awk '/Chip area for/ {print $NF}' | tail -1
}

echo "== Per-module cell area (sky130_fd_sc_hd) =="
printf "%-28s %s\n" "rv32i_core (incl. regfile)" "$(per_module rv32i_core src/rv32i_core.v)"
printf "%-28s %s\n" "qspi_psram"               "$(per_module qspi_psram src/qspi_psram.v)"
printf "%-28s %s\n" "sram (SRAM_BYTES=256)"    "$(per_module sram src/sram.v)"
printf "%-28s %s\n" "uart"                     "$(per_module uart src/uart.v)"

echo "== Whole SoC =="
yosys -p "read_verilog $SOURCES; synth -top tt_um_rhgndf_rv32i_soc -flatten; dfflibmap -liberty $LIB; abc -liberty $LIB; stat -liberty $LIB" 2>/dev/null \
    | awk '/Number of cells|Chip area/ {print}'
