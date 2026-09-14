## =============================================================================
## build.tcl
##
## Non-project-mode Vivado build flow for board_top.v, run once per
## architecture to produce the resource/timing data needed for Table 3 of
## the project proposal (Architecture A vs. Architecture B comparison).
##
## Usage (from the rtl/ directory, with Vivado's bin/ on PATH):
##   vivado -mode batch -source fpga/build.tcl -tclargs seq
##   vivado -mode batch -source fpga/build.tcl -tclargs par
##
## Each invocation writes checkpoints and reports into a dedicated
## reports/<arch>/ directory so the two runs never overwrite each other.
## Requires Vivado (with Artix-7 device support installed); this script
## cannot be executed in the RTL development sandbox used to build and
## simulate this project, only authored for the user's own Vivado
## installation.
## =============================================================================

set arch [lindex $argv 0]
if {$arch eq "par"} {
    set num_macs_filt 8
    set num_macs_vec  3
    set arch_name     "Architecture_B_parallel"
} else {
    set arch     "seq"
    set num_macs_filt 1
    set num_macs_vec  1
    set arch_name     "Architecture_A_sequential"
}

set part      "xc7a100tcsg324-1"
set top       "board_top"
set out_dir   "reports/${arch}"
set proj_dir  "build/${arch}"

file mkdir $out_dir
file mkdir $proj_dir

puts "=========================================================="
puts " Building $arch_name  (NUM_MACS_FILT=$num_macs_filt, NUM_MACS_VEC=$num_macs_vec)"
puts "=========================================================="

# ---------------- Read sources ----------------
read_verilog -sv [glob ../src/*.v]
read_verilog -sv board_top.v
read_xdc constraints_nexys_a7.xdc

# ---------------- Synthesis ----------------
synth_design -top $top -part $part \
    -generic NUM_MACS_FILT=$num_macs_filt \
    -generic NUM_MACS_VEC=$num_macs_vec

write_checkpoint -force ${proj_dir}/post_synth.dcp
report_utilization -file ${out_dir}/post_synth_utilization.rpt
report_timing_summary -file ${out_dir}/post_synth_timing.rpt

# ---------------- Implementation ----------------
opt_design
place_design
route_design

write_checkpoint -force ${proj_dir}/post_route.dcp
report_utilization -file ${out_dir}/post_route_utilization.rpt
report_timing_summary -file ${out_dir}/post_route_timing.rpt
report_timing -delay_type max -max_paths 10 -file ${out_dir}/post_route_timing_paths.rpt
report_power -file ${out_dir}/post_route_power.rpt

# ---------------- Bitstream (optional) ----------------
# Uncomment to also generate a bitstream for on-board bring-up:
# write_bitstream -force ${out_dir}/${arch_name}.bit

puts "=========================================================="
puts " $arch_name complete. Reports written to ${out_dir}/"
puts " Key files for Table 3 of the proposal:"
puts "   ${out_dir}/post_route_utilization.rpt  (LUTs, FFs, DSPs, BRAM)"
puts "   ${out_dir}/post_route_timing.rpt       (Fmax / WNS)"
puts "=========================================================="
