#!/bin/bash
# Regression: compiles and runs every testbench in the project.
# Exits non-zero if any testbench reports a FAIL or does not report
# ALL TESTS PASSED.
set -e
cd "$(dirname "$0")"

SRC="src/mac_engine.v src/fir_filter.v src/vector_engine.v src/bram_sync.v src/control_fsm.v src/accelerator_top.v"
FAIL=0

run_tb () {
    name=$1
    tb=$2
    defs=$3
    echo "=================================================="
    echo "  $name"
    echo "=================================================="
    iverilog -g2012 $defs -o sim/${name}.vvp $SRC tb/${tb} 2>&1
    if ! vvp sim/${name}.vvp | tee /tmp/${name}.log; then
        FAIL=1
    fi
    if ! grep -q "ALL TESTS PASSED" /tmp/${name}.log; then
        echo "*** $name did not report ALL TESTS PASSED ***"
        FAIL=1
    fi
    echo
}

run_tb "mac_engine_tb"          "mac_engine_tb.v"
run_tb "fir_filter_tb"          "fir_filter_tb.v"
run_tb "vector_engine_tb"       "vector_engine_tb.v"
run_tb "accelerator_top_tb"     "accelerator_top_tb.v"
run_tb "accelerator_dataset_seq" "accelerator_dataset_tb.v"
run_tb "accelerator_dataset_par" "accelerator_dataset_tb.v" "-DARCH_PARALLEL"

echo "=================================================="
if [ "$FAIL" -eq 0 ]; then
    echo "REGRESSION: ALL TESTBENCHES PASSED"
else
    echo "REGRESSION: ONE OR MORE TESTBENCHES FAILED"
fi
echo "=================================================="
exit $FAIL
