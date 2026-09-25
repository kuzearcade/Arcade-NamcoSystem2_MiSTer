#!/bin/bash
# Regenerate rtl/third_party/jt680x's microcode (6805.*, 65c02.*) from the
# YAML beside it, with jtframe's own generator at the deps.lock pin:
#   tools/gen_ucode.sh [JTCORES_CHECKOUT]
# Needs Go (1.21+) and network for the first build. The jtframe tool wants
# JTROOT, JTFRAME, MODULES, CORES and JTBIN set; only MODULES is read here.
set -e
PIN=3eb8fec6ec7db210e952921865a18a66ded8a996
SRC=${1:-$HOME/vendor_src/jtcores_cpu}
OUT=$(cd "$(dirname "$0")/../rtl/third_party/jt680x" && pwd)
if [ ! -d "$SRC/.git" ]; then
	git clone -q --filter=blob:none --sparse https://github.com/jotego/jtcores.git "$SRC"
fi
git -C "$SRC" checkout -q $PIN
git -C "$SRC" sparse-checkout set modules/jt680x modules/jtframe/src modules/jtframe/hdl/sound
TMP=$(mktemp -d)
(cd "$SRC/modules/jtframe/src/jtframe" && go build -o "$TMP/jtframe" .)
mkdir -p "$TMP/work/cores" "$TMP/work/bin"
cd "$TMP/work"
for v in 6805 65c02; do
	JTROOT=$SRC JTFRAME=$SRC/modules/jtframe MODULES=$SRC/modules CORES=$TMP/work/cores JTBIN=$TMP/work/bin \
		"$TMP/jtframe" ucode jt680x $v
	cp $v.uc $v.vh ${v}_param.vh "$OUT/"
done
rm -rf "$TMP"
echo "microcode regenerated in $OUT"
