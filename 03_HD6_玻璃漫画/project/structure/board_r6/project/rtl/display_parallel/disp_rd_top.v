// ============================================================================
// disp_rd_top.v — A 线 B 分支显示读出顶层：DDR 读帧 → 行缓存 → 最近邻放大 →
// 右屏窗口显示 的集成壳。
//
// 组成：frm_rd（axi_clk 域读帧主/帧描述/验证发布）+ linebuf_dc（双时钟双行
// 乒乓缓存）+ disp_win（pclk 域窗口扫描/放大）。
//
// AXI 读主口：ID 固定 4'd3，接仲裁器 S3；arvalid/arready、rvalid/rready 严格
// 握手（无授权时 arvalid=0，非收数态 rready=0）。
// 时钟/复位：axi_clk/axi_rstn、pclk/prstn 各自域内同步复位。
// ============================================================================
module disp_rd_top #(
    parameter integer AW     = 10,
    parameter integer WIN_X0 = 960,
    parameter integer WIN_Y0 = 180,
    parameter integer WIN_W  = 960,
    parameter integer WIN_H  = 720,
    parameter [3:0]   ARID   = 4'd3,
    parameter integer MAX_BURST_BEATS = 16,
    parameter integer R_WDOG = 100000,
    parameter integer MIRROR_LEFT = 0
)(
    input  wire        axi_clk,
    input  wire        axi_rstn,
    input  wire        pclk,
    input  wire        prstn,

    // 帧描述接口（ready/valid，axi_clk 域）
    input  wire        frame_valid,
    output wire        frame_ready,
    input  wire [31:0] frame_id,
    input  wire [31:0] frame_base,
    input  wire [15:0] frame_width,
    input  wire [15:0] frame_height,
    input  wire [31:0] frame_stride_bytes,

    // 归还接口（axi_clk 域）
    output wire        release_valid,
    input  wire        release_ready,
    output wire [31:0] release_frame_id,

    // AXI4 读主口（ID 固定 ARID）
    output wire [3:0]  m_axi_arid,
    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [3:0]  m_axi_rid,
    input  wire [127:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    // pclk 域视频时序（1080p 时序由集成方 tap）
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,

    // 窗口输出（与 in_de 恒定 2 拍延迟对齐）
    output wire [23:0] out_rgb,
    output wire        out_active,

    // 状态（pclk 域）
    output wire [31:0] curr_frame_id,
    output wire        frm_err,
    output wire [15:0] underrun_cnt,
    output wire [31:0] timing_dbg,miss_expected_slot0,miss_slot1_flags,
    output wire        underrun_sticky
);

// frm_rd -> linebuf_dc 写侧
wire        lb_we;
wire        lb_wslot;
wire [AW-1:0] lb_waddr;
wire [23:0] lb_wdata;

// disp_win -> linebuf_dc 读侧
wire [AW-1:0] lb_raddr0, lb_raddr1;
wire        lb_re0, lb_re1;
wire [23:0] lb_rdata0, lb_rdata1;

// 槽位握手
wire        wr_tgl0, wr_tgl1, rd_tgl0, rd_tgl1;
wire [15:0] slot_line0, slot_line1;
wire [31:0]  slot_fid0, slot_fid1;

// 帧发布/切帧回执
wire        pub_valid, pub_tgl, disp_sw_tgl;
wire [31:0] pub_id;
wire [15:0] pub_width, pub_height;

wire        frm_err_axi;
wire [31:0] act_id_dbg;
wire validation_pause;

frm_rd #(
    .AW     (AW),
    .MAX_BURST_BEATS(MAX_BURST_BEATS),
    .ARID   (ARID),
    .R_WDOG (R_WDOG), .DISP_W(WIN_W), .DISP_H(WIN_H)
) u_frm_rd (
    .axi_clk            (axi_clk),
    .axi_rstn           (axi_rstn),
    .frame_valid        (frame_valid),
    .frame_ready        (frame_ready),
    .frame_id           (frame_id),
    .frame_base         (frame_base),
    .frame_width        (frame_width),
    .frame_height       (frame_height),
    .frame_stride_bytes (frame_stride_bytes),
    .release_valid      (release_valid),
    .release_ready      (release_ready),
    .release_frame_id   (release_frame_id),
    .m_axi_arid         (m_axi_arid),
    .m_axi_araddr       (m_axi_araddr),
    .m_axi_arlen        (m_axi_arlen),
    .m_axi_arsize       (m_axi_arsize),
    .m_axi_arburst      (m_axi_arburst),
    .m_axi_arvalid      (m_axi_arvalid),
    .m_axi_arready      (m_axi_arready),
    .m_axi_rid          (m_axi_rid),
    .m_axi_rdata        (m_axi_rdata),
    .m_axi_rresp        (m_axi_rresp),
    .m_axi_rlast        (m_axi_rlast),
    .m_axi_rvalid       (m_axi_rvalid),
    .m_axi_rready       (m_axi_rready),
    .lb_we              (lb_we),
    .lb_wslot           (lb_wslot),
    .lb_waddr           (lb_waddr),
    .lb_wdata           (lb_wdata),
    .wr_tgl0            (wr_tgl0),
    .wr_tgl1            (wr_tgl1),
    .slot_line0         (slot_line0),
    .slot_line1         (slot_line1),
    .slot_fid0          (slot_fid0),
    .slot_fid1          (slot_fid1),
    .rd_tgl0            (rd_tgl0),
    .rd_tgl1            (rd_tgl1),
    .disp_sw_tgl        (disp_sw_tgl),
    .pub_valid          (pub_valid),
    .pub_tgl            (pub_tgl),
    .pub_id             (pub_id),
    .pub_width          (pub_width),
    .pub_height         (pub_height),
    .frm_err            (frm_err_axi),
    .timing_dbg(timing_dbg),
    .validation_pause_async(validation_pause),
    .act_id_dbg         (act_id_dbg)
);

linebuf_dc #(
    .MAX_W  (1 << AW),
    .AW     (AW)
) u_linebuf (
    .wclk   (axi_clk),
    .we     (lb_we),
    .wslot  (lb_wslot),
    .waddr  (lb_waddr),
    .wdata  (lb_wdata),
    .rclk   (pclk),
    .re0    (lb_re0),
    .re1    (lb_re1),
    .raddr0 (lb_raddr0),
    .raddr1 (lb_raddr1),
    .rdata0 (lb_rdata0),
    .rdata1 (lb_rdata1)
);

disp_win #(
    .WIN_X0 (WIN_X0),
    .WIN_Y0 (WIN_Y0),
    .WIN_W  (WIN_W),
    .WIN_H  (WIN_H),
    .AW     (AW), .MIRROR_LEFT(MIRROR_LEFT)
) u_disp_win (
    .pclk           (pclk),
    .prstn          (prstn),
    .in_vs          (in_vs),
    .in_hs          (in_hs),
    .in_de          (in_de),
    .lb_raddr0      (lb_raddr0),
    .lb_raddr1      (lb_raddr1),
    .lb_re0         (lb_re0),
    .lb_re1         (lb_re1),
    .lb_rdata0      (lb_rdata0),
    .lb_rdata1      (lb_rdata1),
    .wr_tgl0        (wr_tgl0),
    .wr_tgl1        (wr_tgl1),
    .slot_line0     (slot_line0),
    .slot_line1     (slot_line1),
    .slot_fid0      (slot_fid0),
    .slot_fid1      (slot_fid1),
    .rd_tgl0        (rd_tgl0),
    .rd_tgl1        (rd_tgl1),
    .pub_valid      (pub_valid),
    .pub_tgl        (pub_tgl),
    .pub_id         (pub_id),
    .pub_width      (pub_width),
    .pub_height     (pub_height),
    .disp_sw_tgl    (disp_sw_tgl),
    .frm_err_async  (frm_err_axi),
    .out_rgb        (out_rgb),
    .out_active     (out_active),
    .curr_frame_id  (curr_frame_id),
    .frm_err        (frm_err),
    .underrun_cnt   (underrun_cnt),
    .miss_expected_slot0(miss_expected_slot0),.miss_slot1_flags(miss_slot1_flags),
    .underrun_sticky(underrun_sticky),
    .validation_pause(validation_pause)
);

endmodule
