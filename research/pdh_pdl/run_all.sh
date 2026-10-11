#!/bin/bash
# Re-runs the whole study. Needs the M1 data in $PDH_DATA (see fetch_data.sh).
set -e
cd "$(dirname "$0")"
mkdir -p results
OUT=${PDH_OUT:-/tmp}
python3 grid.py 1.0 && python3 summarize_grid.py $OUT/grid.pkl > results/1_entry_methods.txt
python3 diag.py > results/2_one_variable_tests.txt
python3 sens.py > results/3_filter_sensitivity.txt
python3 cand.py > results/4_candidate.txt
python3 placebo.py > results/5_placebo_long_short.txt
python3 fixed_tests.py > results/6_fixed_sl_confirmation_trailing.txt
