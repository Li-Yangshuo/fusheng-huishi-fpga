
/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2021 Efinix Inc. All rights reserved.
//
// Description:
// Example top file for ti60f225 dev kit OOB design
//
// Language:  Verilog 2001
//Ti60f225_sc431hai2hdmi_v6：
//使用了最新版本的framebuffer_v3;
// ------------------------------------------------------------------------------

/////////////////////////////////////////////////////////////////////////////////
//`define SOFT_TAP 1
`include "ddr3_controller/ddr3_parameter.vh"
// `include "define.v"

module ti60f225_oob_top #(
 parameter WB_R_TRIM_Q8=256,WB_G_TRIM_Q8=256,WB_B_TRIM_Q8=256,
 parameter ASSET_FILE="board_assets.mem",ASSET_WORDS=1124,
 parameter [31:0] ASSET_CRC=32'h837cf680,MODEL0=32'h50503031,MODEL1=32'h54473031,
 parameter [255:0] BASES=256'h0000015400000138000000fe000000b0000000620000002e0000001500000000,
 parameter [127:0] COUNTS=128'h03070008000e00120012000e00080005,

	parameter                       RANK_RATIO         = 1,       // # of unique CS outputs per rank
	parameter                       ASYN_AXI_CLK       = `ASYN_AXI_CLK, 
	parameter                       RANKS              = `RANKS,
	parameter                       CK_WIDTH           = `CK_WIDTH,       // # of CK/CK# outputs to memory   
	parameter                       CKE_WIDTH          = `CKE_WIDTH,       // # of cke outputs
	parameter                       CS_WIDTH           = `CS_WIDTH,       // # of unique CS outputs
	parameter                       BANK_WIDTH         = `BANK_WIDTH,       // # of bank bits
	parameter                       ROW_WIDTH          = `ROW_WIDTH,       // DRAM address bus width
	parameter                       COL_WIDTH          = `COL_WIDTH,      // column address width
	parameter                       DM_WIDTH           = `DM_WIDTH,       // # of DM (data mask)
	parameter                       DQS_WIDTH          = `DQS_WIDTH,       // # of DQS (strobe)
	parameter                       DQ_WIDTH           = `DQ_WIDTH,      // # of DQ (data)
	parameter                       ODT_WIDTH          = `ODT_WIDTH,
	parameter                       DQ_CNT_WIDTH       = `DQ_CNT_WIDTH,       // = ceil(log2(DQ_WIDTH))
	parameter                       DQS_CNT_WIDTH      = `DQS_CNT_WIDTH,       // = ceil(log2(DQS_WIDTH))  
	parameter                       DRAM_WIDTH         = `DRAM_WIDTH,       // # of DQ per DQS   
	parameter                       DATA_WIDTH         = `DATA_WIDTH,
	parameter                       ADDR_WIDTH         = `ADDR_WIDTH,    
	parameter                       AXI_ID_WIDTH       = `AXI_ID_WIDTH,
	parameter                       AXI_ADDR_WIDTH     = `AXI_ADDR_WIDTH,
	parameter                       AXI_DATA_WIDTH     = `AXI_DATA_WIDTH
)
(


   //Clocks 
	input	wire	i_arstn,
    input wire i_control_uart_rx,
    output wire o_control_uart_tx,
    output wire o_boot_flash_clk,o_boot_flash_cs,o_boot_flash_mosi,
    input wire i_boot_flash_miso,
    input wire i_style_key_n, // KEY2 N14/GPIOR_21, manual mapping after N13 failed
    input wire i_view_key_n, // KEY1 / SW1, P14 / GPIOR_22, active low
    input	wire	i_mipi_rx_pclk,
    input wire  vid_clk_dvi2,
    input wire hdmi_tx_slow_clk,
    input wire CLK_5M,
    input  wire CLK_25M,
	output  wire    pll_inst1_RSTN,
	input	wire	i_pll_locked,
	input 	wire  	pll_locked,
	output  wire    pll_inst4_RSTN,
	input   wire    pll_inst4_LOCKED,
	output  wire  	USER_PLL_RSTN,
    output 	wire 	DDR3_PLL_RSTN,
	input 	wire  	user_pll_locked,
    //CSI Interface
    input	 wire		io_cam_sda_IN,
    output wire   io_cam_sda_OUT,
    output wire		io_cam_sda_OE,

    output io_cam_scl_OUT,
    input io_cam_scl_IN,
    output io_cam_scl_OE,

    output	wire		o_cam_rst_p,
    
    input	wire		i_cam_ck_LP_P_IN,
    input	wire		i_cam_ck_LP_N_IN,
    output	wire		o_cam_ck_HS_TERM,
    output	wire		o_cam_ck_HS_ENA,
    input	wire		i_cam_ck_CLKOUT,
    
    input	wire	[7:0]			cam_d0_HS_IN,
    input	  wire		      cam_d0_LP_P_IN,
    input	  wire		      cam_d0_LP_N_IN,
    output	wire		      cam_d0_HS_TERM,
    output	wire		      cam_d0_HS_ENA,
    output	wire		      cam_d0_RST,
    output	wire		      cam_d0_FIFO_RD,
    input	  wire		      cam_d0_FIFO_EMPTY,
    
    input 	wire	[7:0]			cam_d1_HS_IN,
    input	  wire		        cam_d1_LP_P_IN,
    input	  wire		        cam_d1_LP_N_IN,
    output	wire		        cam_d1_HS_TERM,
    output	wire		        cam_d1_HS_ENA,
    output	wire		        cam_d1_RST,
    output	wire		        cam_d1_FIFO_RD,
    input	  wire		        cam_d1_FIFO_EMPTY,
    
    input 	wire	[7:0]			cam_d2_HS_IN,
    input	  wire		        cam_d2_LP_P_IN,
    input	  wire		        cam_d2_LP_N_IN,
    output	wire		        cam_d2_HS_TERM,
    output	wire		        cam_d2_HS_ENA,
    output	wire		        cam_d2_RST,
    output	wire		        cam_d2_FIFO_RD,
    input	  wire		        cam_d2_FIFO_EMPTY,  
   
    input 	wire	[7:0]			cam_d3_HS_IN,
    input	  wire		        cam_d3_LP_P_IN,
    input	  wire		        cam_d3_LP_N_IN,
    output	wire		        cam_d3_HS_TERM,
    output	wire		        cam_d3_HS_ENA,
    output	wire		        cam_d3_RST,
    output	wire		        cam_d3_FIFO_RD,
    input	  wire		        cam_d3_FIFO_EMPTY,

	
	input 					tx_cal_clk_90edge,
  	input 					rx_cal_clk,
  	input 					tx_cal_clk,
	input                              core_clk,     // CORE CLK @ 100MHz
	input                              sdram_clk,    // SDRAM CK @ 400MHz
	// PLL status flags  
	output [2:0]                       pll_shift,  
	output [4:0]                       pll_shift_sel,
	output                             pll_shift_ena,  
	// memory interface ports
	output                             ddr_ck_hi,
	output                             ddr_ck_lo,
	output                             ddr_reset_n,
	output [CKE_WIDTH-1:0]             ddr_cke,     
	output [ROW_WIDTH-1:0]             ddr_addr,
	output [BANK_WIDTH-1:0]            ddr_ba,
	output                             ddr_cas_n,
 
	output [CS_WIDTH*RANK_RATIO-1:0]   ddr_cs_n,
	output                             ddr_ras_n,
	output                             ddr_we_n,
	
	input  [DQS_WIDTH-1:0]             ddr_dqs_in_hi,
	input  [DQS_WIDTH-1:0]             ddr_dqs_in_lo,
	input  [DQ_WIDTH-1:0]              ddr_dq_in_hi,
	input  [DQ_WIDTH-1:0]              ddr_dq_in_lo,
	
	output [DQS_WIDTH-1:0]             ddr_dqs_oe,
	output [DQS_WIDTH-1:0]             ddr_dqs_oe_n,
	output [DQ_WIDTH-1:0]              ddr_dq_oe,  
	output [DQS_WIDTH-1:0]             ddr_dqs_out_hi,
	output [DQS_WIDTH-1:0]             ddr_dqs_out_lo,
	output [DQ_WIDTH-1:0]              ddr_dq_out_hi,
	output [DQ_WIDTH-1:0]              ddr_dq_out_lo,
	output [DM_WIDTH-1:0]              ddr_dm_hi,
	output [DM_WIDTH-1:0]              ddr_dm_lo,
	output [ODT_WIDTH-1:0]             ddr_odt,

       //LED
       output [7:0] led,

       // MIPI DSI
       input	wire	                     i_mipi_tx_pclk		,
       output	wire	                     mipi_dp_clk_LP_P_OUT		,
       output	wire	                     mipi_dp_clk_LP_N_OUT		,
       output	wire	[7:0] 	              mipi_dp_clk_HS_OUT		,
       output	wire	                     mipi_dp_clk_HS_OE		,
       output	wire	                     mipi_dp_data3_LP_P_OUT	,
       output	wire	                     mipi_dp_data2_LP_P_OUT	,
       output	wire	                     mipi_dp_data1_LP_P_OUT	,
       output	wire	                     mipi_dp_data0_LP_P_OUT	,
       output	wire	                     mipi_dp_data3_LP_N_OUT	,
       output	wire	                     mipi_dp_data2_LP_N_OUT	,
       output	wire	                     mipi_dp_data1_LP_N_OUT	,
       output	wire	                     mipi_dp_data0_LP_N_OUT	,
       output	wire	[7:0] 	              mipi_dp_data0_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data1_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data2_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data3_HS_OUT	       ,
       output	wire	                     mipi_dp_data3_HS_OE		,
       output	wire	                     mipi_dp_data2_HS_OE		,
       output	wire	                     mipi_dp_data1_HS_OE		,
       output	wire	                     mipi_dp_data0_HS_OE		,

       output	wire	                     mipi_dp_clk_RST		,
       output	wire	                     mipi_dp_data0_RST		,
       output	wire	                     mipi_dp_data1_RST		,
       output	wire	                     mipi_dp_data2_RST		,
       output	wire	                     mipi_dp_data3_RST		,
       output	wire	                     mipi_dp_clk_LP_P_OE		,
       output	wire	                     mipi_dp_clk_LP_N_OE		,
       output	wire	                     mipi_dp_data3_LP_P_OE	,
       output	wire	                     mipi_dp_data3_LP_N_OE	,
       output	wire	                     mipi_dp_data2_LP_P_OE	,
       output	wire	                     mipi_dp_data2_LP_N_OE	,
       output	wire	                     mipi_dp_data1_LP_P_OE	,
       output	wire	                     mipi_dp_data1_LP_N_OE	,
       output	wire	                     mipi_dp_data0_LP_P_OE	,
       output	wire	                     mipi_dp_data0_LP_N_OE	,

       input  wire	                     mipi_dp_data0_LP_P_IN	,
       input  wire	                     mipi_dp_data0_LP_N_IN	,
       output	wire	                     LCD_RST_P			,
       output wire                        LCD_POWER			,

       // hdmi interface

    output tmds_tx_clk_TX_OE,
    output [9:0] tmds_tx_clk_TX_DATA,
    output tmds_tx_clk_TX_RST,
    output tmds_tx_data0_TX_OE,
    output [9:0] tmds_tx_data0_TX_DATA,
    output tmds_tx_data0_TX_RST,
    output tmds_tx_data1_TX_OE,
    output [9:0] tmds_tx_data1_TX_DATA,
    output tmds_tx_data1_TX_RST,
    output tmds_tx_data2_TX_OE,
    output [9:0] tmds_tx_data2_TX_DATA,
    output tmds_tx_data2_TX_RST


);


// New R9 board candidate. Original AB05 top is retained in source package.
wire base_rstn=i_arstn & i_pll_locked & pll_locked & user_pll_locked;
wire axi_rstn,cam_rstn,pix_rstn;
wire cal_done;
wire camera_configured,camera_config_error,diag_rstn,monitor_rstn,cpu_trap;
wire[31:0] cpu_debug_pc,cpu_debug_trap_value;wire[3:0] cpu_debug_trap_cause;
ab09_reset_release diag_reset(.clk(hdmi_tx_slow_clk),.arstn(i_arstn & user_pll_locked),.rstn(diag_rstn));
ab09_reset_release monitor_reset(.clk(core_clk),.arstn(i_arstn & i_pll_locked),.rstn(monitor_rstn));
assign pll_inst1_RSTN=i_arstn;
assign USER_PLL_RSTN=i_arstn;
assign DDR3_PLL_RSTN=i_arstn;
assign pll_inst4_RSTN=i_arstn;
ab09_reset_release sys_reset(.clk(core_clk),.arstn(base_rstn & cal_done),.rstn(axi_rstn));
ab09_reset_release cam_reset(.clk(i_mipi_rx_pclk),.arstn(base_rstn & cal_done & camera_configured),.rstn(cam_rstn));
ab09_reset_release pix_reset(.clk(hdmi_tx_slow_clk),.arstn(base_rstn & cal_done),.rstn(pix_rstn));
wire i_mipi_clk=core_clk;
wire [63:0] w_mipi_rx_data;
wire w_mipi_rx_vs,w_mipi_rx_hs,w_mipi_rx_de;
wire [15:0] mipi_debug_out;
assign cam_d0_RST=0;assign cam_d1_RST=0;assign cam_d2_RST=0;assign cam_d3_RST=0;
		csi_rx_controller inst_efx_csi2_rx
		(
              .reset_n			(base_rstn),
              .clk				(i_mipi_clk),
              .reset_byte_HS_n	(base_rstn),
              .clk_byte_HS		  (i_cam_ck_CLKOUT),
              .reset_pixel_n		(cam_rstn),
              .clk_pixel			  (i_mipi_rx_pclk),
              
              .Rx_LP_CLK_P		  (i_cam_ck_LP_P_IN),
              .Rx_LP_CLK_N		  (i_cam_ck_LP_N_IN),
              .Rx_HS_enable_C		(o_cam_ck_HS_ENA),
              .LVDS_termen_C		(o_cam_ck_HS_TERM),
              
              .Rx_LP_D_P			({cam_d3_LP_P_IN, cam_d2_LP_P_IN, cam_d1_LP_P_IN, cam_d0_LP_P_IN}),//(r_mipi_rx_data_LP_P_IN_2P),
              .Rx_LP_D_N			({cam_d3_LP_N_IN, cam_d2_LP_N_IN, cam_d1_LP_N_IN, cam_d0_LP_N_IN}),//(r_mipi_rx_data_LP_N_IN_2P),
              .Rx_HS_D_0			(cam_d0_HS_IN),//(r_mipi_rx_data_HS_IN_2P[0*8+:8]),
              .Rx_HS_D_1			(cam_d1_HS_IN),//(r_mipi_rx_data_HS_IN_2P[1*8+:8]),
              .Rx_HS_D_2			(cam_d2_HS_IN),
              .Rx_HS_D_3			(cam_d3_HS_IN),
              .Rx_HS_D_4			(),
              .Rx_HS_D_5			(),
              .Rx_HS_D_6			(),
              .Rx_HS_D_7			(),
              .Rx_HS_enable_D		({cam_d3_HS_ENA    ,cam_d2_HS_ENA    ,cam_d1_HS_ENA    ,cam_d0_HS_ENA    }),//( w_cam_d_HS_ENA),
              .LVDS_termen_D		({cam_d3_HS_TERM   ,cam_d2_HS_TERM   ,cam_d1_HS_TERM   ,cam_d0_HS_TERM   }),
              .fifo_rd_enable		({cam_d3_FIFO_RD   ,cam_d2_FIFO_RD   ,cam_d1_FIFO_RD   ,cam_d0_FIFO_RD   }),
              .fifo_rd_empty		({cam_d3_FIFO_EMPTY,cam_d2_FIFO_EMPTY,cam_d1_FIFO_EMPTY,cam_d0_FIFO_EMPTY}),
              .DLY_enable_D		       (),
              .DLY_inc_D			(),
              .u_dly_enable_D		(),
              .u_dly_inc_D		       (),
              
              .axi_clk			(1'b0),
              .axi_reset_n		       (1'b0),
              .axi_awaddr			(6'b0),
              .axi_awvalid		       (1'b0),
              .axi_awready		       (),
              .axi_wdata			(32'b0),
              .axi_wvalid			(1'b0),
              .axi_wready			(),
              
              .axi_bvalid			(),
              .axi_bready			(1'b0),
              .axi_araddr			(6'b0),
              .axi_arvalid		       (1'b0),
              .axi_arready		       (),
              .axi_rdata			(),
              .axi_rvalid			(),
              .axi_rready			(1'b1),
              
              .hsync_vc0			(w_mipi_rx_hs),
              .hsync_vc1			(),
              .hsync_vc2			(),
              .hsync_vc3			(),
              .vsync_vc0			(w_mipi_rx_vs),
              .vsync_vc1			(),
              .vsync_vc2			(),
              .vsync_vc3			(),
              .vc				(),
              .word_count			(),
              .shortpkt_data_field        (),
              .datatype			(),
              .pixel_per_clk		(),
              .pixel_data			(w_mipi_rx_data),
              .pixel_data_valid	       (w_mipi_rx_de),
              .irq				(),
              .mipi_debug_out(mipi_debug_out)
		);


reg [12:0] i2c_rst_cnt;
always @(posedge CLK_5M or negedge base_rstn)
 if(!base_rstn)i2c_rst_cnt<=0;else if(!i2c_rst_cnt[12])i2c_rst_cnt<=i2c_rst_cnt+1'b1;
wire scl_padoen_o,sda_padoen_o;
i2c_master_ctrl_top camera_config(.clk(CLK_5M),.rst_n(i2c_rst_cnt[12]),
 .scl_pad_i(io_cam_scl_IN),.scl_pad_o(io_cam_scl_OUT),.scl_padoen_o(scl_padoen_o),
 .sda_pad_i(io_cam_sda_IN),.sda_pad_o(io_cam_sda_OUT),.sda_padoen_o(sda_padoen_o),.configured(camera_configured),.config_error(camera_config_error));
assign io_cam_scl_OE=~scl_padoen_o;assign io_cam_sda_OE=~sda_padoen_o;
assign o_cam_rst_p=~base_rstn;
wire [15:0] raw_pair;
wire raw_vs,raw_de,raw_fault,raw_start;
wire [31:0] raw_frame_id;
ab09_raw4_pair #(.FIFO_AW(10)) raw_input(
 .wclk(i_mipi_rx_pclk),.wrstn(cam_rstn),.in_vs(w_mipi_rx_vs),
 .in_de(w_mipi_rx_de&w_mipi_rx_hs),
 .in_raw({w_mipi_rx_data[39:32],w_mipi_rx_data[29:22],w_mipi_rx_data[19:12],w_mipi_rx_data[9:2]}),
 .rclk(core_clk),.rrstn(axi_rstn),.out_vs(raw_vs),.out_de(raw_de),.out_raw(raw_pair),
 .out_frame_id(raw_frame_id),.frame_start(raw_start),.fault(raw_fault));
wire rgb_vs,rgb_hs,rgb_de,rgb_valid;
wire [47:0] rgb_pair;wire [15:0] unused_r,unused_g,unused_b;
debayer_top_2to1 sensor_debayer(.in_pclk(core_clk),.in_rstn(axi_rstn),
 .raw_vs_i(raw_vs),.raw_hs_i(raw_de),.raw_de_i(raw_de),.raw_valid_i(raw_de),.raw_datax4_i(raw_pair),
 .r_gain(16'd256),.g_gain(16'd256),.b_gain(16'd256),.i_bayer_sel(2'd1),.i_byte_swap(1'b0),
 .rgb_vs_o(rgb_vs),.rgb_hs_o(rgb_hs),.rgb_de_o(rgb_de),.rgb_valid_o(rgb_valid),
 .rgb_datax2_o(rgb_pair),.rgb_bout(unused_b),.rgb_gout(unused_g),.rgb_rout(unused_r));
// Basic contest path: sensor 1920x1080 -> 1280x720 frontend -> inference 640x480.
// The source is unthrottled; malformed source frames latch basic_vga_fault.
wire native_valid,native_sof,native_eol;wire [23:0] native_pixel;wire [31:0] native_frame_id;
wire cam_valid,cam_sof,cam_eol,cam_eof;wire [23:0] cam_pixel;wire [31:0] cam_frame_id;
wire source_fault,sink_fault;wire [3:0] source_error_code;
capture720_legacy_frontend #(.FIFO_AW(10)) native_input(.wclk(core_clk),.wrstn(axi_rstn),
 .in_vs(rgb_vs),.in_de(rgb_valid),.bgr_datax2(rgb_pair),.source_frame_id(raw_frame_id),
 .rclk(core_clk),.rrstn(axi_rstn),.out_valid(native_valid),.out_sof(native_sof),.out_eol(native_eol),
 .out_rgb(native_pixel),.out_source_frame_id(native_frame_id),.source_fault(source_fault),
 .sink_fault(sink_fault),.source_error_code(source_error_code));
wire basic_vga_fault;wire [3:0] basic_vga_error_code;
wire pre_cam_valid,pre_cam_sof,pre_cam_eol,pre_cam_eof;
wire [23:0] pre_cam_pixel;wire [31:0] pre_cam_frame_id;
ab720_capture_guard native_guard(.clk(core_clk),.rstn(axi_rstn),.in_valid(native_valid),.in_sof(native_sof),.in_eol(native_eol),.in_rgb(native_pixel),.in_frame_id(native_frame_id),
 .out_valid(pre_cam_valid),.out_sof(pre_cam_sof),.out_eol(pre_cam_eol),.out_eof(pre_cam_eof),.out_rgb(pre_cam_pixel),.out_frame_id(pre_cam_frame_id),.fault(basic_vga_fault),.error_code(basic_vga_error_code));
// PP2 neutral RGB preprocessing is shared by the original and learned views.
pp2_white_balance #(.TRIM_R_Q8(WB_R_TRIM_Q8),.TRIM_G_Q8(WB_G_TRIM_Q8),.TRIM_B_Q8(WB_B_TRIM_Q8)) white_balance(
 .clk(core_clk),.rstn(axi_rstn),.i_valid(pre_cam_valid),.i_sof(pre_cam_sof),.i_eol(pre_cam_eol),.i_eof(pre_cam_eof),
 .i_rgb(pre_cam_pixel),.i_frame_id(pre_cam_frame_id),.o_valid(cam_valid),.o_sof(cam_sof),.o_eol(cam_eol),.o_eof(cam_eof),
 .o_rgb(cam_pixel),.o_frame_id(cam_frame_id),.gain_r_q8(),.gain_g_q8(),.gain_b_q8(),.calibrated(),.last_sample_count());
wire capture_ready,cam_armed;
reg[63:0] time_ticks;
always @(posedge core_clk or negedge axi_rstn)if(!axi_rstn)time_ticks<=0;else time_ticks<=time_ticks+1'b1;
wire catalog_ready,loader_error,service_error,network_busy;
wire[7:0] loader_error_code,ownership_error_code,network_stream_error_code;
wire[72:0] network_error_code;
wire[3:0] capture_error_code,watchdog_trips;
wire[31:0] capture_commits,nn_commits,left_scans,right_scans,blocked,miss_left,miss_right,skipped,selected;
wire[15:0] in_mask,out_mask;
wire [15:0] cpu_paddr;wire cpu_psel,cpu_penable,cpu_pwrite;wire[31:0] cpu_pwdata,cpu_prdata;
wire[31:0] cpu_local_addr,cpu_local_wdata;wire cpu_local_write;
reg capture_enable;reg[31:0] cfg_model;reg[7:0] result_fps;
wire [7:0] camera_fps_measured,nn_fps_measured;
reg[31:0] snapshot_index;reg snapshot_request,snapshot_complete;
// KEY1: original -> half render -> full render -> full-height pair -> original.
 wire [1:0] demo_mode;wire key_sync,key_press;
 demo_key #(.MODES(4)) view_key(.clk(core_clk),.rstn(axi_rstn),.key_n(i_view_key_n),.mode(demo_mode),.key_sync(key_sync),.press(key_press));
 wire view_key_mode=demo_mode!=1;
 wire [1:0] style_mode;wire style_key_sync,style_key_press;
 demo_key #(.MODES(2)) style_key(.clk(core_clk),.rstn(axi_rstn),.key_n(i_style_key_n),.mode(style_mode),.key_sync(style_key_sync),.press(style_key_press));
 wire [31:0] active_model=style_mode[0]?MODEL0:MODEL1;
 wire [31:0] right_pixel_model,nn_result_model;wire nn_result_valid;
wire snapshot_busy,snapshot_valid;wire[639:0] snapshot_data;
wire[31:0] status={23'd0,raw_fault,source_fault|basic_vga_fault,sink_fault,service_error,loader_error,network_busy,capture_enable,catalog_ready,cal_done};
assign cpu_prdata=cpu_paddr==0?32'h41425239:cpu_paddr==4?active_model:
 cpu_paddr==8?{31'd0,capture_enable}:cpu_paddr==16?status:
 cpu_paddr==20?capture_commits:cpu_paddr==24?nn_commits:
 cpu_paddr==28?{8'd0,loader_error_code,ownership_error_code,capture_error_code,watchdog_trips}:
 cpu_paddr==36?{30'd0,snapshot_complete,snapshot_busy}:
 cpu_paddr==44&&snapshot_index<20?snapshot_data[32*snapshot_index+:32]:
 cpu_paddr==48?time_ticks[31:0]:cpu_paddr==52?time_ticks[63:32]:
 cpu_paddr==56?{24'd0,nn_fps_measured}:cpu_paddr==60?ASSET_CRC:
 cpu_paddr==64?network_error_code[31:0]:cpu_paddr==68?network_error_code[63:32]:cpu_paddr==72?{23'd0,network_error_code[72:64]}:
 cpu_paddr==76?{27'd0,style_key_sync,style_mode[0],demo_mode,key_sync}:32'd0;
always @(posedge core_clk or negedge axi_rstn)begin
 if(!axi_rstn)begin capture_enable<=0;cfg_model<=MODEL0;snapshot_index<=0;snapshot_request<=0;snapshot_complete<=0;result_fps<=0;end
 else begin
  snapshot_request<=0;
  if(snapshot_valid)snapshot_complete<=1;
  if(cpu_psel&&cpu_penable&&cpu_pwrite)case(cpu_paddr)
   4:if(!network_busy&&!capture_enable&&(cpu_pwdata==MODEL0||cpu_pwdata==MODEL1))cfg_model<=cpu_pwdata;
   8:capture_enable<=cpu_pwdata[0];
   32:if(!snapshot_busy)begin snapshot_request<=1;snapshot_complete<=0;end
   40:snapshot_index<=cpu_pwdata;
   56:result_fps<=cpu_pwdata[7:0];
  endcase
 end
end
// This firmware is ROM-only and has no DDR/cache aliases. The CPU DDR port is
// disconnected from fabric; a stray request cannot touch a feature/frame pool.
ab10_cpu cpu(.clk(core_clk),.rstn(axi_rstn),.rx(i_control_uart_rx),.tx(o_control_uart_tx),.dual_mode(1'b1),.toggle(cpu_trap),
 .debug_pc(cpu_debug_pc),.debug_trap_cause(cpu_debug_trap_cause),.debug_trap_value(cpu_debug_trap_value),
 .paddr(cpu_paddr),.psel(cpu_psel),.penable(cpu_penable),.pwrite(cpu_pwrite),.pwdata(cpu_pwdata),
 .pready(1'b1),.pslverr(1'b0),.prdata(cpu_prdata),.local_addr(cpu_local_addr),.local_wdata(cpu_local_wdata),
 .local_write(cpu_local_write),.local_rdata(128'd0),.flash_clk(o_boot_flash_clk),.flash_cs(o_boot_flash_cs),
 .flash_mosi(o_boot_flash_mosi),.flash_miso(i_boot_flash_miso),
 .awid(),.awaddr(),.awlen(),.awvalid(),.awready(1'b0),.wvalid(),.wready(1'b0),
 .wdata(),.wstrb(),.wlast(),.bready(),.bid(4'd0),.bresp(2'd3),.bvalid(1'b0),
 .arid(),.araddr(),.arlen(),.arvalid(),.arready(1'b0),.rready(),.rid(4'd0),.rdata(128'd0),.rresp(2'd3),.rlast(1'b0),.rvalid(1'b0));
wire[3:0] s_axi_awid,s_axi_arid,s_axi_bid,s_axi_rid;
wire[31:0] s_axi_awaddr,s_axi_araddr;
wire[7:0] s_axi_awlen,s_axi_arlen;
wire[2:0] s_axi_awsize,s_axi_arsize;wire[1:0] s_axi_awburst,s_axi_arburst,s_axi_bresp,s_axi_rresp;
wire s_axi_awvalid,s_axi_awready,s_axi_wvalid,s_axi_wready,s_axi_wlast,s_axi_bvalid,s_axi_bready;
wire s_axi_arvalid,s_axi_arready,s_axi_rvalid,s_axi_rready,s_axi_rlast;
wire[127:0] s_axi_wdata,s_axi_rdata;wire[15:0] s_axi_wstrb;
wire left_boundary,right_boundary;
wire left_pixel_valid,left_pixel_ready,right_pixel_valid,right_pixel_ready;
wire[23:0] left_pixel_rgb,right_pixel_rgb;wire[31:0] left_pixel_frame_id,right_pixel_frame_id;
wire[10:0] left_pixel_x,right_pixel_x;wire[9:0] left_pixel_y,right_pixel_y;
wire left_pixel_sof,left_pixel_eol,left_pixel_eof,right_pixel_sof,right_pixel_eol,right_pixel_eof;
a_b_video_renderer_shared #(.WIDTH(1280),.HEIGHT(720),.SLOTS(4),.BB(32),.CAP_FIFO_AW(10),.MEM_BYTES(268435456),.ASSET_FILE(ASSET_FILE),.ASSET_WORDS(ASSET_WORDS),
 .ASSET_CRC(ASSET_CRC),.MODEL0(MODEL0),.MODEL1(MODEL1),.BASES(BASES),.COUNTS(COUNTS)) service(
 .axi_clk(core_clk),.axi_rstn(axi_rstn),.core_clk(core_clk),.core_rstn(axi_rstn),.cam_clk(core_clk),.cam_rstn(axi_rstn),
 .capture_valid(raw_start&&capture_enable&&!raw_fault),.capture_ready(capture_ready),
 .capture_id(raw_frame_id),.capture_timestamp(time_ticks),.cam_valid(cam_valid),.cam_sof(cam_sof),
 .cam_eol(cam_eol),.cam_eof(cam_eof),.cam_pixel(cam_pixel),.cam_frame_id(cam_frame_id),.cam_armed(cam_armed),
 .cfg_model(active_model),.right_pixel_model(right_pixel_model),.nn_result_valid(nn_result_valid),.nn_result_model(nn_result_model),.left_boundary(left_boundary),.right_boundary(right_boundary),
 .external_fault(raw_fault||source_fault||sink_fault||basic_vga_fault||cfg_err_sync[1]),.error(service_error),.catalog_ready(catalog_ready),
 .loader_error(loader_error),.loader_error_code(loader_error_code),.network_busy(network_busy),
 .network_error_code(network_error_code),.network_stream_error_code(network_stream_error_code),
 .ownership_error_code(ownership_error_code),.capture_error_code(capture_error_code),
 .input_allocated_mask(in_mask),.output_allocated_mask(out_mask),.capture_commits(capture_commits),.nn_commits(nn_commits),
 .left_scans(left_scans),.right_scans(right_scans),.capture_blocked_cycles(blocked),
 .missed_left_ticks(miss_left),.missed_right_ticks(miss_right),.watchdog_trips(watchdog_trips),
 .camera_skipped_frames(skipped),.camera_selected_frames(selected),
 .left_pixel_valid(left_pixel_valid),.left_pixel_ready(left_pixel_ready),.left_pixel_rgb(left_pixel_rgb),
 .left_pixel_frame_id(left_pixel_frame_id),.left_pixel_x(left_pixel_x),.left_pixel_y(left_pixel_y),
 .left_pixel_sof(left_pixel_sof),.left_pixel_eol(left_pixel_eol),.left_pixel_eof(left_pixel_eof),
 .right_pixel_valid(right_pixel_valid),.right_pixel_ready(right_pixel_ready),.right_pixel_rgb(right_pixel_rgb),
 .right_pixel_frame_id(right_pixel_frame_id),.right_pixel_x(right_pixel_x),.right_pixel_y(right_pixel_y),
 .right_pixel_sof(right_pixel_sof),.right_pixel_eol(right_pixel_eol),.right_pixel_eof(right_pixel_eof),
 .arid(s_axi_arid),.araddr(s_axi_araddr),.arlen(s_axi_arlen),.arsize(s_axi_arsize),.arburst(s_axi_arburst),
 .arvalid(s_axi_arvalid),.arready(s_axi_arready),.rid(s_axi_rid),.rdata(s_axi_rdata),.rresp(s_axi_rresp),
 .rlast(s_axi_rlast),.rvalid(s_axi_rvalid),.rready(s_axi_rready),.awid(s_axi_awid),.awaddr(s_axi_awaddr),
 .awlen(s_axi_awlen),.awsize(s_axi_awsize),.awburst(s_axi_awburst),.awvalid(s_axi_awvalid),.awready(s_axi_awready),
 .wdata(s_axi_wdata),.wstrb(s_axi_wstrb),.wlast(s_axi_wlast),.wvalid(s_axi_wvalid),.wready(s_axi_wready),
 .bid(s_axi_bid),.bresp(s_axi_bresp),.bvalid(s_axi_bvalid),.bready(s_axi_bready));
wire app_sr_active,app_ref_ack,app_zq_ack;
wire[7:0] wrlvl_dq_check,rd_level_dqs_check;wire[6:0] init_cur_state;
wire idelay_ld,mpr_rdlvl_dly;
ddr3_top u_ddr3_top
(

.axi_clk                (core_clk            ),
.core_clk               (core_clk            ),
.sdram_clk              (sdram_clk           ),  
.rx_cal_clk             (rx_cal_clk          ),
.tx_cal_clk             (tx_cal_clk          ),
.tx_cal_clk_90edge      (tx_cal_clk_90edge   ),
.rstn                   (base_rstn             ),      
.pll_shift              (pll_shift           ),
.pll_shift_sel          (pll_shift_sel       ),
.pll_shift_ena          (pll_shift_ena       ),       
///////////////DDR BUS
.ddr_ck_hi              (ddr_ck_hi           ),
.ddr_ck_lo              (ddr_ck_lo           ),
.ddr_cke                (ddr_cke             ),    
.ddr_reset_n            (ddr_reset_n         ),
.ddr_cs_n               (ddr_cs_n            ),
.ddr_ras_n              (ddr_ras_n           ),
.ddr_cas_n              (ddr_cas_n           ),
.ddr_we_n               (ddr_we_n            ),     
.ddr_addr               (ddr_addr            ),
.ddr_ba                 (ddr_ba              ),

.ddr_dqs_oe             (ddr_dqs_oe          ),
.ddr_dqs_oe_n           (ddr_dqs_oe_n        ),
.ddr_dq_oe              (ddr_dq_oe           ),
.ddr_dqs_in_hi          (ddr_dqs_in_hi       ),
.ddr_dqs_in_lo          (ddr_dqs_in_lo       ),
.ddr_dq_in_hi           (ddr_dq_in_hi        ),
.ddr_dq_in_lo           (ddr_dq_in_lo        ),

.ddr_dqs_out_hi         (ddr_dqs_out_hi      ),
.ddr_dqs_out_lo         (ddr_dqs_out_lo      ),
.ddr_dq_out_hi          (ddr_dq_out_hi       ),
.ddr_dq_out_lo          (ddr_dq_out_lo       ),

.ddr_dm_hi              (ddr_dm_hi           ),
.ddr_dm_lo              (ddr_dm_lo           ),
.ddr_odt                (ddr_odt             ),

// Application interface ports
.app_sr_req                     (1'b0),
.app_ref_req                    (1'b0),
.app_zq_req                     (1'b0),
.app_sr_active                  (app_sr_active),
.app_ref_ack                    (app_ref_ack),
.app_zq_ack                     (app_zq_ack),

// Slave Interface Write Address Ports
.s_axi_awid                     (s_axi_awid        ),
.s_axi_awaddr                   (s_axi_awaddr      ),
.s_axi_awlen                    (s_axi_awlen       ),
.s_axi_awsize                   (3'd4              ),
.s_axi_awburst                  (2'b01             ),
.s_axi_awlock                   (1'b0              ),
.s_axi_awcache                  (4'h0              ),
.s_axi_awprot                   (3'h0              ),
.s_axi_awqos                    (4'h0              ),
.s_axi_awvalid                  (s_axi_awvalid     ),
.s_axi_awready                  (s_axi_awready     ),
// Slave Interface Write Data Ports
.s_axi_wdata                    (s_axi_wdata       ),
.s_axi_wstrb                    (s_axi_wstrb       ),
.s_axi_wlast                    (s_axi_wlast       ),
.s_axi_wvalid                   (s_axi_wvalid      ),
.s_axi_wready                   (s_axi_wready      ),
// Slave Interface Write Response Ports
.s_axi_bid                      (s_axi_bid         ),
.s_axi_bresp                    (s_axi_bresp       ),
.s_axi_bvalid                   (s_axi_bvalid      ),
.s_axi_bready                   (s_axi_bready      ),
// Slave Interface Read Address Ports
.s_axi_arid                     (s_axi_arid        ),
.s_axi_araddr                   (s_axi_araddr      ),
.s_axi_arlen                    (s_axi_arlen       ),
.s_axi_arsize                   (s_axi_arsize      ),
.s_axi_arburst                  (s_axi_arburst     ),
.s_axi_arlock                   (1'b0              ),
.s_axi_arcache                  (4'h0              ),
.s_axi_arprot                   (3'h0              ),
.s_axi_arqos                    (4'h0              ),
.s_axi_arvalid                  (s_axi_arvalid     ),
.s_axi_arready                  (s_axi_arready     ),
// Slave Interface Read Data Ports
.s_axi_rid                      (s_axi_rid         ),
.s_axi_rdata                    (s_axi_rdata       ),
.s_axi_rresp                    (s_axi_rresp       ),
.s_axi_rlast                    (s_axi_rlast       ),
.s_axi_rvalid                   (s_axi_rvalid      ),
.s_axi_rready                   (s_axi_rready      ),
//DEBUG       
.wrlvl_dq_check                 (wrlvl_dq_check    ) ,
.rd_level_dqs_check             (rd_level_dqs_check) ,
.init_cur_state                 (init_cur_state    ) ,
.idelay_ld                      (idelay_ld         ) ,
.mpr_rdlvl_dly                  (mpr_rdlvl_dly     ) ,
.cal_done                       (cal_done          ) 
);


(* async_reg="true" *) reg [1:0] cfg_err_sync;
always @(posedge core_clk or negedge monitor_rstn)
 if(!monitor_rstn)cfg_err_sync<=0;else cfg_err_sync<={cfg_err_sync[0],camera_config_error};
wire fs,hs,vs,de;wire[11:0] px,py;
wire[23:0] hdmi_rgb;wire hdmi_hs,hdmi_vs,hdmi_de;
ab05_hdmi_timing #(.H_ACTIVE(1280),.H_FP(110),.H_SYNC(40),.H_BP(220),.V_ACTIVE(720),.V_FP(5),.V_SYNC(5),.V_BP(20)) timing(
 .pix_clk(hdmi_tx_slow_clk),.pix_rstn(diag_rstn),.frame_start(fs),.hs(hs),.vs(vs),.de(de),.x(px),.y(py));
wire [1:0] mode_sync;
reg [1:0] mode_pix;
ab09_fps_cdc #(.WIDTH(2)) mode_cdc(.sclk(core_clk),.srstn(axi_rstn),.sdata(demo_mode),.dclk(hdmi_tx_slow_clk),.drstn(diag_rstn),.ddata(mode_sync));
always @(posedge hdmi_tx_slow_clk or negedge diag_rstn)
 if(!diag_rstn)mode_pix<=0;else if(fs)mode_pix<=mode_sync;
wire [31:0] tagged_right_id={1'b1,right_pixel_frame_id[30:0]};
ab05_dual_preview_hdmi #(.VIEW_W(640),.VIEW_H(360),.SMALL_H(720),.FIFO_AW(11),.ACTIVE_W(1280),.ACTIVE_H(720),.X0(0),.Y0(0),.MIN_START_PIXELS(640)) display(
 .axi_clk(core_clk),.axi_rstn(axi_rstn),.pix_clk(hdmi_tx_slow_clk),.pix_rstn(pix_rstn),.demo_mode(mode_pix),
 .frame_start(fs),.pix_hs(hs),.pix_vs(vs),.pix_de(de),.pix_x(px),.pix_y(py),
 .left_pixel_valid(left_pixel_valid),.left_pixel_ready(left_pixel_ready),.left_pixel_rgb(left_pixel_rgb),.left_pixel_frame_id(left_pixel_frame_id),.left_pixel_x(left_pixel_x),.left_pixel_y(left_pixel_y),.left_pixel_sof(left_pixel_sof),.left_pixel_eol(left_pixel_eol),.left_pixel_eof(left_pixel_eof),
 .right_pixel_valid(right_pixel_valid),.right_pixel_ready(right_pixel_ready),.right_pixel_rgb(right_pixel_rgb),.right_pixel_frame_id(tagged_right_id),.right_pixel_x(right_pixel_x),.right_pixel_y(right_pixel_y),.right_pixel_sof(right_pixel_sof),.right_pixel_eol(right_pixel_eol),.right_pixel_eof(right_pixel_eof),
 .left_boundary(left_boundary),.right_boundary(right_boundary),.hdmi_rgb(hdmi_rgb),.hdmi_hs(hdmi_hs),.hdmi_vs(hdmi_vs),.hdmi_de(hdmi_de),
 .left_display_frame_id(),.right_display_frame_id(),.left_fifo_high_water(),.right_fifo_high_water(),.left_pix_available(),.right_pix_available(),
 .snapshot_request(snapshot_request),.snapshot_busy(snapshot_busy),.snapshot_valid(snapshot_valid),.snapshot_data(snapshot_data));
wire [7:0] cam_fps,pp_fps,ink_fps;wire [9:0] ink_fps_x10,fps_pix;
demo_fps fps_meter(.clk(core_clk),.rstn(axi_rstn),.camera_eof(cam_valid&&cam_eof),.pp_done(nn_result_valid&&nn_result_model==MODEL0),.ink_done(nn_result_valid),.cam_fps(cam_fps),.pp_fps(pp_fps),.ink_fps(ink_fps),.ink_fps_x10(ink_fps_x10));
assign camera_fps_measured=cam_fps;assign nn_fps_measured=ink_fps;
ab09_fps_cdc #(.WIDTH(10)) fps_cdc(.sclk(core_clk),.srstn(axi_rstn),.sdata(ink_fps_x10),.dclk(hdmi_tx_slow_clk),.drstn(diag_rstn),.ddata(fps_pix));
reg [11:0] dx1,dy1,dx2,dy2;reg fs1,fs2;
always @(posedge hdmi_tx_slow_clk or negedge diag_rstn)
 if(!diag_rstn)begin dx1<=0;dy1<=0;dx2<=0;dy2<=0;fs1<=0;fs2<=0;end
 else begin dx1<=px;dy1<=py;dx2<=dx1;dy2<=dy1;fs1<=fs;fs2<=fs1;end
wire [23:0] osd_rgb;wire osd_de,osd_hs,osd_vs;
demo_osd osd(.clk(hdmi_tx_slow_clk),.rstn(diag_rstn),.frame_start(fs2),.x(dx2),.y(dy2),.de(hdmi_de),.hs(hdmi_hs),.vs(hdmi_vs),.rgb(hdmi_rgb),
 .fps(fps_pix),.o_rgb(osd_rgb),.o_de(osd_de),.o_hs(osd_hs),.o_vs(osd_vs));
wire[9:0] tmds_data0,tmds_data1,tmds_data2,tmds_clk;
dvi_encoder hdmi(.pixelclk(hdmi_tx_slow_clk),.rst_p(!diag_rstn),.i_bdata(osd_rgb[7:0]),.i_gdata(osd_rgb[15:8]),.i_rdata(osd_rgb[23:16]),.i_de(osd_de),.i_hs(osd_hs),.i_vs(osd_vs),.video_format(2'd0),.video_VIC(7'd4),
 .audio_L(24'd0),.audio_R(24'd0),.audio_valid(1'b0),.audio_N(20'd6144),.audio_CTS(20'd74250),.audio_sample_frequency(3'd2),.audio_word_length(4'd11),.tmds_data0(tmds_data0),.tmds_data1(tmds_data1),.tmds_data2(tmds_data2),.tmds_clk(tmds_clk));
assign tmds_tx_clk_TX_DATA=~tmds_clk;assign tmds_tx_data0_TX_DATA=~tmds_data0;
assign tmds_tx_data1_TX_DATA=~tmds_data1;assign tmds_tx_data2_TX_DATA=~tmds_data2;
assign tmds_tx_clk_TX_OE=1;assign tmds_tx_data0_TX_OE=1;assign tmds_tx_data1_TX_OE=1;assign tmds_tx_data2_TX_OE=1;
assign tmds_tx_clk_TX_RST=0;assign tmds_tx_data0_TX_RST=0;assign tmds_tx_data1_TX_RST=0;assign tmds_tx_data2_TX_RST=0;
// Unused DSI outputs are held inactive. The original factory DSI path remains in
// the immutable AB05 reference; R9 HDMI candidate has no DSI payload owner.
assign LCD_POWER=0;assign LCD_RST_P=1;
assign mipi_dp_clk_LP_P_OUT=0;assign mipi_dp_clk_LP_N_OUT=0;assign mipi_dp_clk_HS_OUT=0;assign mipi_dp_clk_HS_OE=0;
assign mipi_dp_data0_LP_P_OUT=0;assign mipi_dp_data1_LP_P_OUT=0;assign mipi_dp_data2_LP_P_OUT=0;assign mipi_dp_data3_LP_P_OUT=0;
assign mipi_dp_data0_LP_N_OUT=0;assign mipi_dp_data1_LP_N_OUT=0;assign mipi_dp_data2_LP_N_OUT=0;assign mipi_dp_data3_LP_N_OUT=0;
assign mipi_dp_data0_HS_OUT=0;assign mipi_dp_data1_HS_OUT=0;assign mipi_dp_data2_HS_OUT=0;assign mipi_dp_data3_HS_OUT=0;
assign mipi_dp_data0_HS_OE=0;assign mipi_dp_data1_HS_OE=0;assign mipi_dp_data2_HS_OE=0;assign mipi_dp_data3_HS_OE=0;
assign mipi_dp_clk_RST=1;assign mipi_dp_data0_RST=1;assign mipi_dp_data1_RST=1;assign mipi_dp_data2_RST=1;assign mipi_dp_data3_RST=1;
assign mipi_dp_clk_LP_P_OE=0;assign mipi_dp_clk_LP_N_OE=0;
assign mipi_dp_data0_LP_P_OE=0;assign mipi_dp_data1_LP_P_OE=0;assign mipi_dp_data2_LP_P_OE=0;assign mipi_dp_data3_LP_P_OE=0;
assign mipi_dp_data0_LP_N_OE=0;assign mipi_dp_data1_LP_N_OE=0;assign mipi_dp_data2_LP_N_OE=0;assign mipi_dp_data3_LP_N_OE=0;
assign led={service_error,raw_fault|source_fault|sink_fault,loader_error,cal_done,nn_commits[4],capture_commits[4],catalog_ready,capture_enable};

endmodule
