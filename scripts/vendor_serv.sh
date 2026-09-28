#!/usr/bin/env bash
# Vendor SERV RTL into src/serv/ via FuseSoC.
# SERV is used UNMODIFIED per docs/architecture.md:
#   upstream: github.com/olfk/serv (oLoFoK? -> olofk/serv), tag 1.4.0
#   FuseSoC core: award-winning:serv:serv:1.4.0
# Local clone used for the export: $SERV_DIR (default ~/tools/serv @ 1.4.0)
set -e
cd "$(dirname "$0")/.."
export PATH="$HOME/venv/bin:$PATH"

SERV_DIR=${SERV_DIR:-$HOME/tools/serv}
TAG=1.4.0
COMMIT=$(git -C "$SERV_DIR" rev-list -n1 "$TAG")
echo "SERV tag $TAG commit $COMMIT"

OUT=src/serv
mkdir -p "$OUT"
# Files from serv.core fileset "core" (verilogSource only)
for f in serv_bufreg serv_bufreg2 serv_alu serv_csr serv_ctrl serv_decode \
         serv_immdec serv_mem_if serv_rf_if serv_rf_ram_if serv_rf_ram \
         serv_state serv_debug serv_top serv_rf_top serv_aligner serv_compdec; do
  cp "$SERV_DIR/rtl/$f.v" "$OUT/"
done
cp "$SERV_DIR/data/verilator_waiver.vlt" "$OUT/" 2>/dev/null || true
cp "$SERV_DIR/LICENSE" "$OUT/"
cat > "$OUT/README" <<EOF
SERV — the world's smallest RISC-V CPU
Upstream : https://github.com/olofk/serv
Tag      : $TAG
Commit   : $COMMIT
License  : ISC (see LICENSE in this directory)

These files are vendored verbatim by scripts/vendor_serv.sh; do not edit.
SERV is instantiated UNMODIFIED (serv_top) inside tt_um_rhgndf_rv32i_soc.
EOF
echo "Exported $(ls $OUT/*.v | wc -l) files to $OUT"
