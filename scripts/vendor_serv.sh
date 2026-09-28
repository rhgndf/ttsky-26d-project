#!/usr/bin/env bash
# Vendor SERV RTL into src/serv/ via FuseSoC.
# SERV is used UNMODIFIED per docs/architecture.md:
#   upstream: github.com/olofk/serv, tag 1.4.0
#   FuseSoC core: award-winning:serv:serv:1.4.0
# Local clone used for the export: $SERV_DIR (default ~/tools/serv @ 1.4.0);
# its parent dir is passed to fusesoc --cores-root.
set -e
cd "$(dirname "$0")/.."
export PATH="$HOME/venv/bin:$PATH"

SERV_DIR=${SERV_DIR:-$HOME/tools/serv}
TAG=1.4.0
VLNV=award-winning:serv:serv:$TAG
COMMIT=$(git -C "$SERV_DIR" rev-list -n1 "$TAG")
echo "SERV tag $TAG commit $COMMIT"

# FuseSoC export: --setup materialises the core's filesets into the build
# tree; the RTL lands under src/<vlnv>/rtl/.
EXPORT=$(mktemp -d)
trap 'rm -rf "$EXPORT"' EXIT
fusesoc --cores-root="$(dirname "$SERV_DIR")" run --target=lint --setup \
        --build-root="$EXPORT" "$VLNV" 2>&1 | tail -2
RTL_DIR=$(find "$EXPORT" -type d -name rtl | head -1)
[ -d "$RTL_DIR" ] || { echo "FuseSoC export produced no rtl/ dir"; exit 1; }

OUT=src/serv
mkdir -p "$OUT"
rm -f "$OUT"/serv_*.v
cp "$RTL_DIR"/serv_*.v "$OUT/"
cp "$SERV_DIR/data/verilator_waiver.vlt" "$OUT/" 2>/dev/null || true
cp "$SERV_DIR/LICENSE" "$OUT/"
cat > "$OUT/README" <<EOF
SERV — the world's smallest RISC-V CPU
Upstream : https://github.com/olofk/serv
Tag      : $TAG
Commit   : $COMMIT
License  : ISC (see LICENSE in this directory)

These files are vendored verbatim by scripts/vendor_serv.sh (FuseSoC export
of $VLNV); do not edit.
SERV is instantiated UNMODIFIED (serv_top) inside tt_um_rhgndf_rv32i_soc.
EOF
echo "Exported $(ls $OUT/serv_*.v | wc -l) files to $OUT"
