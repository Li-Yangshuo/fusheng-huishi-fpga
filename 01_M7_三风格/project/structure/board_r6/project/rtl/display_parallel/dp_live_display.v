//======================================================================
// dp_live_display.v  ——  A15 右半屏显示通道（a9_live_display 的端口替身）
//
//   端口与 a14 `rtl/preproc/a9_live_display.v` 完全一致（含参数名
//   DDR_PROBE/CAPTURE_PROBE/VIEW_X/VIEW_Y），因此顶层只需换模块名。
//
//   内部数据流（全部在 core_clk=100MHz 的 AXI 域）:
//       dp_frame_reader  (DDR 帧 -> 640x480 RGB 像素流, ARID=4'd2)
//         -> dp_scale_nn (640x480 -> 960x720 最近邻)
//         -> dp_async_fifo(24bit x 2048)
//   读侧（pix_clk=148.5MHz）在窗口 x∈[960,1920) y∈[180,900) 内用 FIFO
//   像素替换 i_rgb，窗口外原样透传。窗口正好 960x720，与缩放输出一一对应。
//
//   ★ 每显示帧重启: pix 侧 i_vs 上升沿 -> toggle 同步到 core 域 ->
//     reader/scaler/FIFO 写侧复位，重新发布描述符；FIFO 读侧在 i_vs 后
//     7 个 pix 周期复位。此时正在帧消隐，两侧都不会读写，所以指针同步归零。
//   ★ 背压: FIFO 近满时拉低 scaler 的 out_ready，整条链自然反压到 DDR 读。
//   ★ 写通道不使用，静态拉平。
//   ★ capture_error 恒 0（有意为之）：它接到 a12_frame_metrics 的
//     capture_fault 上，一旦置 1 就会把 OSD 计数冻结，A15 只做显示通道，
//     窗口内 FIFO 空用 underflow + 黑像素表示，不冻结整张 OSD。
//======================================================================
`timescale 1ns/1ps

module dp_live_display #(
    parameter [31:0]  BASE_ADDR     = 32'h0200_0000,
    parameter [31:0]  FRAME_STRIDE  = 32'h0012_C000,
    parameter integer VIEW_X        = 960,
    parameter integer VIEW_Y        = 180,
    parameter integer DDR_PROBE     = 0,
    parameter integer CAPTURE_PROBE = 0,
    // ---- 本模块自己的参数 ----
    parameter integer IN_W          = 640,
    parameter integer IN_H          = 480,
    parameter integer ROW_PITCH     = 2560,     // 行距(字节) = 640*4
    parameter integer OUT_W         = 960,
    parameter integer OUT_H         = 720,
    parameter integer FIFO_AW       = 11,
    parameter integer FIFO_ALMOST   = 1500,
    parameter integer START_CYCLES  = 8,
    parameter [3:0]   ARID          = 4'd2
)(
    // ---- 采集侧（本模块不使用，保留端口兼容）----
    input  wire        cap_clk,
    input  wire        cap_rstn,
    input  wire        cap_de,
    input  wire        cap_sof,
    input  wire [23:0] cap_rgb,

    // ---- AXI（core_clk）----
    input  wire        axi_clk,
    input  wire        axi_rstn,
    input  wire        cal_done,

    output wire [3:0]  awid,
    output wire [3:0]  arid,
    output reg  [31:0] awaddr,
    output wire [31:0] araddr,
    output wire [7:0]  awlen,
    output wire [7:0]  arlen,
    output wire        awvalid,
    output wire        wlast,
    output wire        wvalid,
    output wire        bready,
    output wire        arvalid,
    output wire        rready,
    input  wire        awready,
    input  wire        wready,
    input  wire        bvalid,
    input  wire        arready,
    input  wire        rlast,
    input  wire        rvalid,
    output wire [127:0] wdata,
    input  wire [127:0] rdata,
    input  wire [1:0]  bresp,
    input  wire [1:0]  rresp,

    output reg         init_done,
    output reg         axi_error,
    output reg         capture_error,
    output reg  [31:0] written_frames,

    // ---- 像素侧（pix_clk = 148.5MHz）----
    input  wire        pix_clk,
    input  wire        pix_rstn,
    input  wire        i_de,
    input  wire        i_hs,
    input  wire        i_vs,
    input  wire [23:0] i_rgb,
    output reg         o_de,
    output reg         o_hs,
    output reg         o_vs,
    output reg  [23:0] o_rgb,
    output reg         underflow
);

    // ==================================================================
    // 写通道：不使用，静态拉平
    // ==================================================================
    assign awid    = 4'd2;
    assign awlen   = 8'd15;
    assign awvalid = 1'b0;
    assign wlast   = 1'b0;
    assign wvalid  = 1'b0;
    assign bready  = 1'b1;
    assign wdata   = 128'd0;

    initial begin
        awaddr = 32'd0;
        init_done      = 1'b0;
        axi_error      = 1'b0;
        capture_error  = 1'b0;
        written_frames = 32'd0;
        o_de = 1'b0; o_hs = 1'b0; o_vs = 1'b0; o_rgb = 24'd0;
        underflow = 1'b0;
    end

    // ==================================================================
    // 每显示帧一次的“重启”跨时钟传递（pix -> axi）
    // ==================================================================
    reg vs_d, vs_tog;
    always @(posedge pix_clk or negedge pix_rstn) begin
        if (!pix_rstn) begin
            vs_d   <= 1'b0;
            vs_tog <= 1'b0;
        end else begin
            vs_d <= i_vs;
            if (i_vs & ~vs_d) vs_tog <= ~vs_tog;
        end
    end

    reg [2:0]  tog_sync;
    reg        tog_seen;
    reg [1:0]  ph;               // 0=PH_RUN 1=PH_ABORT 2=PH_RST
    reg        abort_r;
    reg [3:0]  start_cnt;
    reg [31:0] frame_no;

    wire rd_busy_f;

    localparam integer SC = START_CYCLES;
    localparam [1:0] PH_RUN = 2'd0, PH_ABORT = 2'd1, PH_RST = 2'd2;

    wire new_frame = (tog_sync[2] != tog_seen);

    // ★ 换帧必须“先中止、再复位”。
    //   dp_frame_reader 如果在 AXI 读 burst 中途被复位，会把没收完的 burst
    //   丢掉，从机 rvalid 一直拉着、读通道永久死锁（本工程仿真已复现）。
    //   所以先拉 abort 让它把在途 burst 收完回到 IDLE，再复位整条链。
    always @(posedge axi_clk or negedge axi_rstn) begin
        if (!axi_rstn) begin
            tog_sync  <= 3'd0;
            tog_seen  <= 1'b0;
            ph        <= PH_RST;
            abort_r   <= 1'b0;
            start_cnt <= 4'd0;
            frame_no  <= 32'd0;
        end else begin
            tog_sync <= {tog_sync[1:0], vs_tog};
            if (new_frame) tog_seen <= tog_sync[2];

            case (ph)
                PH_RUN: begin
                    if (new_frame) begin
                        ph       <= PH_ABORT;
                        abort_r  <= 1'b1;
                        frame_no <= frame_no + 32'd1;
                    end
                end
                PH_ABORT: begin
                    if (!rd_busy_f) begin        // 在途 burst 已收完
                        abort_r   <= 1'b0;
                        ph        <= PH_RST;
                        start_cnt <= 4'd0;
                    end
                end
                PH_RST: begin
                    if ((start_cnt + 4'd1) >= SC) ph <= PH_RUN;
                    else                          start_cnt <= start_cnt + 4'd1;
                end
                default: ph <= PH_RST;
            endcase
        end
    end

    wire starting  = (ph != PH_RUN);
    // 只在 PH_RST 复位 reader/scaler/FIFO 写侧；PH_ABORT 期间保持运行以便收完 burst，
    // PH_RUN 期间当然也不能复位（这里写成 != PH_RST 而不是 == PH_RST）。
    wire core_rstn = axi_rstn & (ph != PH_RST);

    // ==================================================================
    // 一帧一个的帧描述符
    // ==================================================================
    reg  fr_valid;
    wire fr_ready;

    always @(posedge axi_clk or negedge axi_rstn) begin
        if (!axi_rstn)                 fr_valid <= 1'b0;
        else if (ph == PH_RST)         fr_valid <= 1'b1;   // 复位期间就摆好
        else if (fr_valid && fr_ready) fr_valid <= 1'b0;
    end

    // ==================================================================
    // reader
    // ==================================================================
    wire [15:0] IN_W16 = IN_W[15:0];
    wire [15:0] IN_H16 = IN_H[15:0];

    wire        px_valid, px_sof, px_eol, px_last, px_ready;
    wire [23:0] px_data;
    wire        rd_busy, rd_err, rd_done, rel_valid, rel_ready;
    wire [31:0] rel_id, rd_beats, rd_frames;
    wire [2:0]  ax_size;
    wire [1:0]  ax_burst;
    wire [3:0]  rd_rid;
    assign rd_rid = 4'd0;

    // ★ A15.1：下游跨时钟 FIFO 的写域水位。必须在 reader 实例之前声明 ——
    //   用声明初始化式或前向引用会让 Efinity 综合前端丢掉驱动（VDB-1002）。
    wire [FIFO_AW:0] fifo_wlevel;

    // 发 AR 的闸门：FIFO 里要留出"一整笔 burst（16 拍 x 4 像素 = 64）+ 余量 128" 的空间。
    // 这样 burst 期间 FIFO 不会到 walmost，scaler 不会反压，reader 就绝不会卡在
    // burst 中途不接数、把 AXI 读通道抱着不放（A15 首版上板黑屏无信号的根因之一）。
    localparam [FIFO_AW:0] BURST_ROOM_MAX = FIFO_ALMOST - 128;
    wire reader_burst_room;
    assign reader_burst_room = (fifo_wlevel <= BURST_ROOM_MAX);

    assign rel_ready = 1'b1;

    dp_frame_reader #(
        .AXI_ADDR_WIDTH (32),
        .MAX_BURST_LEN  (16),
        .ARID           (ARID)
    ) u_reader (
        .aclk             (axi_clk),
        .arstn            (core_rstn),
        .frame_valid      (fr_valid),
        .frame_ready      (fr_ready),
        .frame_id         (frame_no),
        .frame_base       (BASE_ADDR),
        .frame_width      (IN_W16),
        .frame_height     (IN_H16),
        .frame_stride     (ROW_PITCH[31:0]),
        .abort            (abort_r),
        .burst_room       (reader_burst_room),
        .release_valid    (rel_valid),
        .release_ready    (rel_ready),
        .release_frame_id (rel_id),
        .busy             (rd_busy_f),
        .err_resp         (rd_err),
        .done_pulse       (rd_done),
        .beats_read       (rd_beats),
        .frames_read      (rd_frames),
        .m_arid           (arid),
        .m_araddr         (araddr),
        .m_arlen          (arlen),
        .m_arsize         (ax_size),
        .m_arburst        (ax_burst),
        .m_arvalid        (arvalid),
        .m_arready        (arready),
        .m_rid            (rd_rid),
        .m_rdata          (rdata),
        .m_rresp          (rresp),
        .m_rlast          (rlast),
        .m_rvalid         (rvalid),
        .m_rready         (rready),
        .px_valid         (px_valid),
        .px_data          (px_data),
        .px_sof           (px_sof),
        .px_eol           (px_eol),
        .px_last          (px_last),
        .px_ready         (px_ready)
    );

    // ==================================================================
    // scaler  640x480 -> 960x720
    // ==================================================================
    wire        sc_valid, sc_sof, sc_eol, sc_ready, sc_busy, sc_done, sc_err;
    wire [23:0] sc_data;
    wire [15:0] sc_x, sc_y;

    dp_scale_nn #(
        .OUT_W     (OUT_W),
        .OUT_H     (OUT_H),
        .AW        (10),
        .MAX_IN_W  (2048),
        .LAW       (11),
        .MAX_REP   (8)
    ) u_scaler (
        .clk        (axi_clk),
        .rstn       (core_rstn),
        .cfg_in_w   (IN_W16),
        .cfg_in_h   (IN_H16),
        .in_valid   (px_valid),
        .in_data    (px_data),
        .in_sof     (px_sof),
        .in_eol     (px_eol),
        .in_ready   (px_ready),
        .out_valid  (sc_valid),
        .out_data   (sc_data),
        .out_sof    (sc_sof),
        .out_eol    (sc_eol),
        .out_ready  (sc_ready),
        .out_x      (sc_x),
        .out_y      (sc_y),
        .busy       (sc_busy),
        .done_pulse (sc_done),
        .err_rep    (sc_err)
    );

    // ==================================================================
    // 跨时钟 FIFO（写侧 axi_clk / 读侧 pix_clk）
    // ==================================================================
    wire        fifo_wfull, fifo_walmost, fifo_rempty;
    wire [23:0] fifo_rdata;
    wire        fifo_winc;
    assign fifo_winc = sc_valid & sc_ready;

    // 背压：近满就让 scaler 停，链条自然反压到 reader 再到 DDR
    assign sc_ready = ~fifo_walmost;

    // 读侧复位：i_vs 之后保持 7 个 pix 周期
    reg [2:0] frst_cnt;
    always @(posedge pix_clk or negedge pix_rstn) begin
        if (!pix_rstn)                       frst_cnt <= 3'd0;
        else if (i_vs & ~vs_d)               frst_cnt <= 3'd7;
        else if (frst_cnt != 3'd0)           frst_cnt <= frst_cnt - 3'd1;
    end
    wire pix_rstn_f;
    assign pix_rstn_f = pix_rstn & (frst_cnt == 3'd0);

    dp_async_fifo #(
        .DW     (24),
        .AW     (FIFO_AW),
        .ALMOST (FIFO_ALMOST)
    ) u_fifo (
        .wclk   (axi_clk),
        .wrstn  (core_rstn),
        .winc   (fifo_winc),
        .wdata  (sc_data),
        .wfull  (fifo_wfull),
        .walmost(fifo_walmost),
        .wlevel (fifo_wlevel),
        .rclk   (pix_clk),
        .rrstn  (pix_rstn_f),
        .rinc   (fifo_rinc),
        .rdata  (fifo_rdata),
        .rempty (fifo_rempty)
    );

    // ==================================================================
    // 读侧：栅格跟踪 + 窗口替换
    // ==================================================================
    localparam [15:0] WX0 = VIEW_X;
    localparam [15:0] WX1 = VIEW_X + OUT_W;
    localparam [15:0] WY0 = VIEW_Y;
    localparam [15:0] WY1 = VIEW_Y + OUT_H;

    reg [15:0] px_x, px_y;
    reg        hs_d2;
    wire       hs_rise = i_hs & ~hs_d2;

    always @(posedge pix_clk or negedge pix_rstn) begin
        if (!pix_rstn) begin
            px_x   <= 16'd0;
            px_y   <= 16'd0;
            hs_d2  <= 1'b0;
        end else begin
            hs_d2 <= i_hs;
            if (i_vs)          begin px_x <= 16'd0; px_y <= 16'd0; end
            else if (hs_rise)  begin px_x <= 16'd0; px_y <= px_y + 16'd1; end
            else if (i_de)     begin px_x <= px_x + 16'd1; end
        end
    end

    wire in_win   = i_de && (px_x >= WX0) && (px_x < WX1)
                          && (px_y >= WY0) && (px_y < WY1);
    // ★ 不要在这里写 & ~fifo_rempty：dp_async_fifo 内部已经有 rinc_ok = rinc & ~rempty，
    //   若这里再用 rempty 去门控 rinc，就构成 rempty->rinc->rbin_nxt->rgray_nxt->rempty
    //   的组合环，iverilog 会零延迟死循环（已踩过）。
    // ★★ 必须写成独立的 assign，不能写成 `wire fifo_rinc = in_win;`：
    //   用 net 声明初始化式时，Efinity 综合前端会报
    //   `dp_live_display.v(331): net 'fifo_rinc' does not have a driver [VDB-1002]`，
    //   把 FIFO 读使能当常量 0 处理 —— 读指针永不前进 -> walmost 常 1 -> scaler 停
    //   -> reader 在 burst 中途不接数 -> 占住 AXI 读通道 -> frame_buffer 读不到 RAW
    //   -> 摄像头通路停摆 -> HDMI 无同步 -> 上板直接黑屏无信号（A15 首版就是这样死的）。
    wire fifo_rinc;
    assign fifo_rinc = in_win;
    wire [23:0] win_pix = fifo_rempty ? 24'h000000 : fifo_rdata;

    always @(posedge pix_clk or negedge pix_rstn) begin
        if (!pix_rstn) begin
            o_de      <= 1'b0;
            o_hs      <= 1'b0;
            o_vs      <= 1'b0;
            o_rgb     <= 24'd0;
            underflow <= 1'b0;
        end else begin
            o_de <= i_de;
            o_hs <= i_hs;
            o_vs <= i_vs;
            o_rgb <= in_win ? win_pix : i_rgb;

            if (i_de && in_win && fifo_rempty) underflow <= 1'b1;
            else if (i_vs)                     underflow <= 1'b0;
        end
    end

    // ==================================================================
    // 状态输出
    // ==================================================================
    always @(posedge axi_clk or negedge axi_rstn) begin
        if (!axi_rstn) begin
            init_done      <= 1'b0;
            axi_error      <= 1'b0;
            written_frames <= 32'd0;
        end else begin
            if (!starting) init_done <= 1'b1;
            if (rd_err || (rresp != 2'b00)) axi_error <= 1'b1;
            written_frames <= rd_frames;
        end
    end

    // capture_error 有意恒 0：见文件头说明（避免冻结 a12_frame_metrics）
    always @(posedge pix_clk or negedge pix_rstn) begin
        if (!pix_rstn) capture_error <= 1'b0;
        else           capture_error <= 1'b0;
    end

endmodule
