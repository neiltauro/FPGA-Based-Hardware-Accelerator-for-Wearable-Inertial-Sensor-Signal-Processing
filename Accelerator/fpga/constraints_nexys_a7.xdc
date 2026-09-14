# =============================================================================
# constraints_nexys_a7.xdc
#
# Timing and pin constraints for board_top.v on a Digilent Nexys A7-100T
# (Xilinx xc7a100tcsg324-1), matching Section 12.1 of the project proposal.
#
# Pin assignments below match Digilent's published Nexys A7-100T Master XDC.
# Verify against your board revision's official master XDC before use --
# pin assignments are not expected to change across revisions, but always
# confirm against the current file from Digilent for the exact part/revision
# you have. For a different Artix-7/Spartan-7 board, only this file needs
# to change; board_top.v and everything under src/ is board-independent.
# =============================================================================

# ---------------- Clock: 100 MHz onboard oscillator ----------------
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports CLK100MHZ]
create_clock -add -name sys_clk_pin -period 10.000 -waveform {0 5} [get_ports CLK100MHZ]

# ---------------- Reset (active-low pushbutton) ----------------
set_property -dict { PACKAGE_PIN C12 IOSTANDARD LVCMOS33 } [get_ports CPU_RESETN]

# ---------------- Start button (center pushbutton, momentary) ----------------
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports BTNC]

# ---------------- LEDs ----------------
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports {LED[0]}]
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports {LED[1]}]
set_property -dict { PACKAGE_PIN J13 IOSTANDARD LVCMOS33 } [get_ports {LED[2]}]
set_property -dict { PACKAGE_PIN N14 IOSTANDARD LVCMOS33 } [get_ports {LED[3]}]
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports {LED[4]}]
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports {LED[5]}]
set_property -dict { PACKAGE_PIN U17 IOSTANDARD LVCMOS33 } [get_ports {LED[6]}]
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports {LED[7]}]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports {LED[8]}]
set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS33 } [get_ports {LED[9]}]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {LED[10]}]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports {LED[11]}]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports {LED[12]}]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports {LED[13]}]
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports {LED[14]}]
set_property -dict { PACKAGE_PIN V11 IOSTANDARD LVCMOS33 } [get_ports {LED[15]}]

# ---------------- False paths ----------------
# BTNC/CPU_RESETN are asynchronous, mechanical-switch inputs; board_top.v
# synchronizes BTNC internally, and CPU_RESETN feeds only async-reset ports,
# so no additional timing constraint is required for either signal beyond
# the input delay left at its default (unconstrained-but-synchronized).
