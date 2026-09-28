#!/usr/bin/env bash
# Area estimate for the SERV-based RV32I SoC against sky130_fd_sc_hd.
# Usage: ./scripts/area.sh   (requires yosys + $LIB liberty, see ~/env.sh)
set -e
cd "$(dirname "$0")/.."
LIB=${LIB:?Set LIB to the sky130_fd_sc_hd liberty (source ~/env.sh)}

SERV_SRCS="src/serv/serv_bufreg.v src/serv/serv_bufreg2.v src/serv/serv_alu.v \
src/serv/serv_csr.v src/serv/serv_ctrl.v src/serv/serv_decode.v \
src/serv/serv_immdec.v src/serv/serv_mem_if.v src/serv/serv_rf_if.v \
src/serv/serv_rf_ram_if.v src/serv/serv_rf_ram.v src/serv/serv_state.v \
src/serv/serv_debug.v src/serv/serv_aligner.v src/serv/serv_compdec.v \
src/serv/serv_top.v"

SOURCES="$SERV_SRCS src/qspi_rf.v src/gpio.v src/tt_um_rhgndf_rv32i_soc.v"

# Per-module area: synthesize each block alone.
per_module() {
    local top=$1; shift
    local files="$@"
    yosys -p "read_verilog $files; synth -top $top; dfflibmap -liberty $LIB; abc -liberty $LIB; stat -liberty $LIB" 2>/dev/null \
        | awk '/Chip area for/ {print $NF}' | tail -1
}

echo "== Per-module cell area (sky130_fd_sc_hd) =="
printf "%-28s %s\n" "serv_top"     "$(per_module serv_top $SERV_SRCS)"
printf "%-28s %s\n" "qspi_rf"      "$(per_module qspi_rf src/qspi_rf.v)"
printf "%-28s %s\n" "gpio"         "$(per_module gpio src/gpio.v)"

echo "== Whole SoC =="
yosys -p "read_verilog $SOURCES; synth -top tt_um_rhgndf_rv32i_soc -flatten; dfflibmap -liberty $LIB; abc -liberty $LIB; stat -liberty $LIB" 2>/dev/null \
    | awk '/Number of cells|Chip area/ {print}'
