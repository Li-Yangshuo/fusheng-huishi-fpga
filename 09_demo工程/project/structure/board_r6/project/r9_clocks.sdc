# R9 candidate clocks only. No blanket false_path or clock_groups.
# Gray bit skew/mailbox held-data path binding is deliberately an OPEN PNR gate.
# This file is sufficient for synthesis exploration, not physical signoff.
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
