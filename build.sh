#!/bin/bash
# Build the NamcoS2 .rbf and REFUSE to report success unless Quartus says the
# full compilation succeeded: the stale .rbf is removed first, so a failed
# build can never be mistaken for a good one (MS1BCD's lesson, 2026-09-22).
#   ./build.sh LOGFILE           full compile
#   ./build.sh LOGFILE map       analysis and synthesis only (the M10K check)
cd "$(dirname "$0")" || exit 1
LOG="${1:-build.log}"
# PROJ=NamcoS2_MH ./build.sh ...: the other bitstreams (their .qsf; output_files_<suffix>)
P="${PROJ:-NamcoS2}"
case "$P" in NamcoS2) OUT=output_files ;; *) OUT=output_files_${P#NamcoS2_} ;; esac
Q=~/intelFPGA_lite_clean/17.0/quartus/bin
# fx68k's microcode, where its $readmemb looks (the project directory)
cp rtl/third_party/fx68k/microrom.mem rtl/third_party/fx68k/nanorom.mem .
if [ "$2" = "map" ]; then
  # build_id.tcl only runs inside a flow; write what it would
  printf '`define BUILD_DATE "%s"' "$(date +%y%m%d)" > build_id.v
  $Q/quartus_map $P > "$LOG" 2>&1; rc=$?
  grep -E "^Error|Error \(" "$LOG" | head -n 25
  grep -E "Analysis & Synthesis was successful|Total block memory bits|Total RAM" "$LOG" $OUT/$P.map.summary 2>/dev/null
  exit $rc
fi
rm -f $OUT/$P.rbf
$Q/quartus_sh --flow compile $P > "$LOG" 2>&1
rc=$?
if grep -q "Full Compilation was successful" "$LOG" && [ -f $OUT/$P.rbf ]; then
  echo "BUILD OK (rc=$rc)"
  grep -E "Logic utilization \(in ALMs\)|Total RAM Blocks|Total registers" $OUT/$P.fit.rpt | head -n 3
  grep -c "Timing requirements not met" $OUT/$P.sta.rpt | sed 's/^/timing-not-met lines: /'
  md5sum $OUT/$P.rbf
else
  echo "BUILD FAILED (rc=$rc)"
  grep -E "^Error|Error \(" "$LOG" | head -n 25
  exit 1
fi
