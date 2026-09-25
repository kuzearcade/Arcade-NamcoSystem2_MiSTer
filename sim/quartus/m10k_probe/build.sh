#!/bin/bash
# Fit the M10K probe and print each array's M10K count from the fitter's
# per-entity report (the one number Appendix F needs).
cd "$(dirname "$0")" || exit 1
Q=~/intelFPGA_lite_clean/17.0/quartus/bin
$Q/quartus_sh --flow compile m10k_probe > build.log 2>&1
grep -q "Full Compilation was successful" build.log || { echo "BUILD FAILED"; grep -E "^Error|Error \(" build.log | head -n 20; exit 1; }
grep -E "Total RAM Blocks" output_files/m10k_probe.fit.summary
awk -F';' '/Fitter Resource Utilization by Entity/{f=1} f && /^; +\|/ { n=$2; gsub(/ +$/, "", n); if (n ~ /^ +\|(sp|tdp|sdp):/) print $12 "\t" n } /Delay Chain Summary/{f=0}' output_files/m10k_probe.fit.rpt
