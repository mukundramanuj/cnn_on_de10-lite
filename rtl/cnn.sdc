# ============================================================================
# cnn.sdc  --  timing constraints for de10lite_top on DE10-Lite (MAX10 -C7).
# 50 MHz single-clock synchronous design; only the clock needs a real budget.
# ============================================================================

# 50 MHz reference clock (20 ns period)
create_clock -name clk -period 20.000 [get_ports MAX10_CLK1_50]

# account for PLL/clock-tree uncertainty in Timing Analyzer
derive_clock_uncertainty

# Asynchronous board inputs are 2-FF synchronised inside the wrapper; they have
# no timing relationship to the clock, so cut them from analysis.
set_false_path -from [get_ports {SW[*]}]  -to [all_registers]
set_false_path -from [get_ports {KEY[*]}] -to [all_registers]

# Seven-segment and LED outputs are static/human-speed; not timing critical.
set_false_path -from [all_registers] -to [get_ports {HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*] LEDR[*]}]
