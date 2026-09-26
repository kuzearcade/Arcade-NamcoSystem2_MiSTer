#!/bin/bash
# ./build.sh map | fit   (Quartus 17.0 Lite, as the siblings)
cd "$(dirname "$0")" || exit 1
Q=~/intelFPGA_lite_clean/17.0/quartus/bin
if [ "$1" = "fit" ]; then $Q/quartus_sh --flow compile core_top > build.log 2>&1
else $Q/quartus_map core_top > build.log 2>&1; fi
grep -E "^Error|Error \(" build.log | head -n 20
grep -E "Logic utilization|ALMs|Total block memory bits|Total RAM Blocks|M10K|Total registers" output_files/core_top.*.summary 2>/dev/null
