# R17 timing constraints v2 (2026-10-28).  Derived from r9_clocks.sdc.
# Change vs r9: declare the display pixel domain asynchronous to core_clk.
#
# Why this is justified (verified structurally, not a blanket false_path):
#   * The only core_clk <-> hdmi_tx_slow_clk data crossings are
#       - display/*/pixels   : ab05_display_async_stream (34b Gray-pointer FIFO)
#       - display/*/requests : ab05_display_async_stream (1b  Gray-pointer FIFO)
#       - display/counters   : ab05_display_snapshot (pix->axi request/ack)
#     All pointer pairs carry (* async_reg="true" *) and are 2-FF synchronized;
#     cdc.rpt reports "No Synchronizer warnings".
#   * The reset paths that STA flags (pix_rstn/axi_rstn -> async SR/RST pins of
#     the other domain) are asynchronous reset distribution, not data.  Each side
#     gates its logic behind a 2-FF arun/prun release chain, so de-assertion is
#     not consumed until two rclk/wclk edges after release.
#   * No other cross-domain data path exists between these two clocks.
# The remaining same-domain violations are fixed in RTL, not hidden here.
#
# Still NOT constrained here: camera (i_mipi_rx_pclk), DDR (sdram/tx_cal/rx_cal)
# and MIPI TX domains keep their original per-clock constraints so that their
# real synchronous relationships stay analyzed.
create_clock -period 10.000 -name core_clk [get_ports {core_clk}]
create_clock -period 20.000 -name i_mipi_rx_pclk [get_ports {i_mipi_rx_pclk}]
create_clock -period 6.734007 -name hdmi_tx_slow_clk [get_ports {hdmi_tx_slow_clk}]
create_clock -period 13.468013 -name vid_clk_dvi2 [get_ports {vid_clk_dvi2}]
create_clock -period 200.000 -name CLK_5M [get_ports {CLK_5M}]
create_clock -period 40.000 -name CLK_25M [get_ports {CLK_25M}]
create_clock -period 2.500 -name sdram_clk [get_ports {sdram_clk}]
create_clock -period 2.500 -name rx_cal_clk [get_ports {rx_cal_clk}]
create_clock -period 2.500 -name tx_cal_clk [get_ports {tx_cal_clk}]
create_clock -period 2.500 -name tx_cal_clk_90edge [get_ports {tx_cal_clk_90edge}]
create_clock -period 10.000 -name i_cam_ck_CLKOUT [get_ports {i_cam_ck_CLKOUT}]
create_clock -period 8.000 -name i_mipi_tx_pclk [get_ports {i_mipi_tx_pclk}]

# Display pixel domain is asynchronous to the AXI/NN core domain (see header).
set_clock_groups -asynchronous -group {core_clk} -group {hdmi_tx_slow_clk}
