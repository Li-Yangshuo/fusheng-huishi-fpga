//======================================================================
// dp_frame_reader.v  ——  display_parallel 工作包第 1 层
//
// 按"帧描述"从 DDR 独立读出一帧，输出 RGB888x 像素流。
// 只读已由写方发布(锁定)的帧；读事务全部结束后才归还(release)。
//
// 帧描述接口（进度文档冻结版；本文不声称是已定案 APB 寄存器）：
//   frame_valid/frame_ready  完整帧描述交接握手
//   frame_id                 关联原图/处理结果/丢帧，不作地址
//   frame_base               本帧 DDR 基址（本帧第 0 行第 0 像素）
//   frame_width/height       本帧实际像素尺寸
//   frame_stride_bytes       相邻两行起始地址之差（行距，必须显式传入）
//   frame_format             第一版仅 RGB888x，内存字节升序 00,B,G,R
//   release_valid/ready + release_frame_id  读事务全部完成后归还
//
// 重要区分（依源码核对，写入 report 供集成人确认）：
//   现有写手 fb640_wr 的参数 "FRAME_STRIDE=0x12C000" 是【整帧字节数/缓冲推进量】，
//   不是行距；640 宽紧凑布局的行距是 640*4 = 2560 B。本接口的
//   frame_stride_bytes 是【行距】。发布者必须自己完成这个换算。
//
// 内存字到像素：128bit 拍 = 4 个 32bit 字；每字内存升序 00,B,G,R
//   Verilog 小端取字 -> w[31:24]=R, w[23:16]=G, w[15:8]=B, w[7:0]=00
//   输出 px_data[23:0] = {R,G,B}
//======================================================================
`timescale 1ns/1ps
module dp_frame_reader #(
    parameter integer AXI_ADDR_WIDTH = 32,
    parameter integer MAX_BURST_LEN  = 4,      // 一个 burst 最多 4 拍 x 16B = 64B = 16 像素
                                               // ★ 必须 ≤ 内部弹性缓冲深度 QDEPTH（见下面 A15.1 说明）
    parameter [3:0]   ARID           = 4'd2    // AXI 读主机 ID（须与仲裁器约定一致：a9_live_display 用 4'd2）
)(
    input  wire                      aclk,
    input  wire                      arstn,

    // ---- 帧描述输入（frame_ready 拉高前必须保持稳定） ----
    input  wire                      frame_valid,
    output wire                      frame_ready,
    input  wire [31:0]               frame_id,
    input  wire [31:0]               frame_base,
    input  wire [15:0]               frame_width,
    input  wire [15:0]               frame_height,
    input  wire [31:0]               frame_stride,
    input  wire                      abort,        // A15: 中止当前帧。会先把在途 burst 收完再回 IDLE，
                                                  // 绝不带着未完成的 AXI 读事务复位（否则从机会一直占着 R 通道）

    // ---- 归还 ----
    output reg                       release_valid,
    input  wire                      release_ready,
    output reg  [31:0]               release_frame_id,

    // ---- 状态观测（上板探针/VIO 用） ----
    output reg                       busy,
    output reg                       err_resp,     // 收到非 OKAY 的 RRESP
    output reg                       done_pulse,   // 一帧读完
    output reg  [31:0]               beats_read,
    output reg  [31:0]               frames_read,

    // ---- AXI 读主机 ----
    output wire [3:0]                m_arid,
    output wire [AXI_ADDR_WIDTH-1:0] m_araddr,
    output wire [7:0]                m_arlen,
    output wire [2:0]                m_arsize,
    output wire [1:0]                m_arburst,
    output wire                      m_arvalid,
    input  wire                      m_arready,
    input  wire [3:0]                m_rid,
    input  wire [127:0]              m_rdata,
    input  wire [1:0]                m_rresp,
    input  wire                      m_rlast,
    input  wire                      m_rvalid,
    output wire                      m_rready,

    // ---- 像素流输出（axi_clk 域，一拍 px_data 一个像素） ----
    output wire                      px_valid,
    output wire [23:0]               px_data,
    output wire                      px_sof,
    output wire                      px_eol,
    output wire                      px_last,
    input  wire                      px_ready,
    // ---- A15.1：发 AR 的闸门。下游必须为"一整笔 burst + 余量"留出空间才允许发 AR ----
    input  wire                      burst_room
);
    localparam [1:0] S_IDLE = 2'd0, S_AR = 2'd1, S_R = 2'd2, S_REL = 2'd3;
    localparam [7:0] MAXB   = MAX_BURST_LEN[7:0];

    reg [1:0]  state;
    reg [31:0] base_r, stride_r, id_r;
    reg [15:0] w_r, h_r;
    reg [31:0] line_addr;      // 本行第 0 拍地址
    reg [31:0] cur_addr;       // 本次 burst 地址
    reg [15:0] line_idx;       // 地址域：当前行号
    reg [15:0] beat_in_line;   // 行内第几个 128bit 拍
    reg [7:0]  rem_beats;      // 本次已受理 burst 还剩几拍未收

    // 像素域（只随像素被接走而前进）
    reg [95:0] px_reg;
    reg [2:0]  px_cnt;
    reg        px_v;
    reg [15:0] px_in_line;
    reg [15:0] px_line;

    assign frame_ready = (state == S_IDLE);
    assign m_arid      = ARID;
    assign m_arsize    = 3'd4;          // 16 字节/拍
    assign m_arburst   = 2'b01;         // INCR

    // 本行需要的 128bit 拍数 = ceil(width/4)
    wire [15:0] beats_line = w_r[15:2] + (|w_r[1:0] ? 16'd1 : 16'd0);
    wire [15:0] beats_left = beats_line - beat_in_line;
    wire [7:0]  want_len   = (beats_left > MAX_BURST_LEN) ? MAXB
                                                          : beats_left[7:0];

    // 关键：AR 通道必须真正握手后才算受理；arlen 用组合逻辑直接给出，
    // 不能像早先版本那样用寄存器（寄存器会在握手那一拍还是上一次的值，
    // 且 S_AR 无条件跳 S_R 会让一次被 arready 拖住的 AR 被静默丢弃）。
    assign m_araddr  = cur_addr[AXI_ADDR_WIDTH-1:0];
    assign m_arlen   = want_len - 8'd1;
    // ★ A15.1：只有下游缓冲还放得下一整笔 burst（留足余量）才发 AR。
    //   一旦 AR 被受理，AXI 互联就要等这笔 burst 收满才把读通道让出去（axi2_arbiter
    //   的老缺陷：要等 m_rvalid & m_rready & m_rlast 同时成立才释放）。所以必须保证
    //   受理之后这 16 拍能连续收完 —— 办法是让下游在发 AR 之前就留出"一整笔 burst +
    //   余量"的空间，这样 burst 期间下游不会反压，reader 绝不会卡在 burst 中途不接数。
    //   缓冲不够时停在 S_AR：**此时不持有任何总线**，视频链可以正常跑，从而打破
    //   "reader 占住读通道 -> 摄像头读不到 RAW -> 显示不抽 -> 缓冲更满"的自环
    //   （A15 首版上板直接黑屏无信号，根因之一就是它）。
    assign m_arvalid = (state == S_AR) && (beats_left != 16'd0) && burst_room;

    // 只接收"本次已受理 burst"尚未收完的拍，绝不吞掉上一次 burst 的残留拍。
    // px_cnt==0 表示上一组 4 像素已被下游接走；burst_room 已保证下游有余量，
    // 所以 burst 内的这个等待是有界的。
    assign m_rready  = (state == S_R) && (rem_beats != 8'd0) && ((px_cnt == 3'd0) || abort);

    wire [31:0] w0 = m_rdata[31:0];
    wire [31:0] w1 = m_rdata[63:32];
    wire [31:0] w2 = m_rdata[95:64];
    wire [31:0] w3 = m_rdata[127:96];
    wire [95:0] pack4 = {w3[31:8], w2[31:8], w1[31:8], w0[31:8]};

    // 本拍有几个像素有效（受行宽限制）
    wire [15:0] px_left  = w_r - px_in_line;
    wire [2:0]  px_avail = (px_left >= 16'd4) ? 3'd4 : px_left[2:0];

    wire beat_load = (state == S_R) && m_rvalid && m_rready;
    wire px_pop    = px_v && px_ready;
    wire line_last = px_pop && (px_in_line == w_r - 16'd1);

    assign px_valid = px_v;
    assign px_data  = px_reg[23:0];
    assign px_sof   = px_v && (px_line == 16'd0) && (px_in_line == 16'd0);
    assign px_eol   = px_v && (px_in_line == w_r - 16'd1);
    assign px_last  = px_eol && (px_line == h_r - 16'd1);

    always @(posedge aclk or negedge arstn) begin
        if (!arstn) begin
            state <= S_IDLE;
            base_r <= 0; stride_r <= 0; id_r <= 0; w_r <= 0; h_r <= 0;
            line_addr <= 0; cur_addr <= 0; line_idx <= 0; beat_in_line <= 0;
            rem_beats <= 0;
            px_reg <= 0; px_cnt <= 0; px_v <= 0; px_in_line <= 0; px_line <= 0;
            release_valid <= 0; release_frame_id <= 0;
            busy <= 0; err_resp <= 0; done_pulse <= 0; beats_read <= 0; frames_read <= 0;
        end else begin
            done_pulse <= 1'b0;

            // ---------------- 像素输出级 ----------------
            if (px_pop) begin
                px_reg <= {8'h00, px_reg[95:24]};
                if (px_cnt == 3'd1) begin
                    px_cnt <= 3'd0;
                    px_v   <= 1'b0;
                end else begin
                    px_cnt <= px_cnt - 3'd1;
                end
                if (line_last) begin
                    px_in_line <= 16'd0;
                    px_line    <= px_line + 16'd1;
                end else begin
                    px_in_line <= px_in_line + 16'd1;
                end
            end
            if (beat_load) begin
                px_reg <= pack4;
                px_cnt <= px_avail;
                px_v   <= 1'b1;
            end

            // ---------------- 读控制 FSM ----------------
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (frame_valid) begin
                        base_r   <= frame_base;
                        stride_r <= frame_stride;
                        w_r      <= frame_width;
                        h_r      <= frame_height;
                        id_r     <= frame_id;
                        line_addr    <= frame_base;
                        cur_addr     <= frame_base;
                        line_idx     <= 16'd0;
                        beat_in_line <= 16'd0;
                        px_in_line   <= 16'd0;
                        px_line      <= 16'd0;
                        px_cnt       <= 3'd0;
                        px_v         <= 1'b0;
                        rem_beats    <= 8'd0;
                        beats_read   <= 32'd0;
                        err_resp     <= 1'b0;
                        busy         <= 1'b1;
                        state        <= S_AR;
                    end
                end

                S_AR: begin
                    // 必须等 AR 真正握手，否则本次 AR 会被静默丢弃、地址却已前进
                    if (m_arvalid && m_arready) begin
                        rem_beats <= want_len;
                        state     <= S_R;
                    end else if (abort) begin
                        // 还没有在途 burst，可以立刻回 IDLE
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                S_R: begin
                    if (beat_load) begin
                        beats_read   <= beats_read + 32'd1;
                        if (m_rresp != 2'b00) err_resp <= 1'b1;
                        rem_beats    <= rem_beats - 8'd1;
                        if (abort) begin
                            // 丢弃模式（换帧中止）：只把当前 burst 收完，不推进地址/像素。
                            // 绝不能在这里直接回 IDLE —— 那会把在途 burst 丢给从机，
                            // rvalid 不平、读通道永久死锁。
                            if (rem_beats == 8'd1) begin
                                busy  <= 1'b0;
                                state <= S_IDLE;
                            end
                        end else begin
                            beat_in_line <= beat_in_line + 16'd1;
                            cur_addr     <= cur_addr + 32'd16;
                            if (beat_in_line + 16'd1 >= beats_line) begin
                                // 本行最后一拍已收
                                if (line_idx + 16'd1 >= h_r) begin
                                    state            <= S_REL;
                                    done_pulse       <= 1'b1;
                                    frames_read      <= frames_read + 32'd1;
                                    release_valid    <= 1'b1;
                                    release_frame_id <= id_r;
                                end else begin
                                    line_idx     <= line_idx + 16'd1;
                                    beat_in_line <= 16'd0;
                                    line_addr    <= line_addr + stride_r;
                                    cur_addr     <= line_addr + stride_r;
                                    state        <= S_AR;
                                end
                            end else if (rem_beats == 8'd1) begin
                                // 本 burst 收完但本行未完 -> 再发一个 burst
                                // （必须留在 S_R 把整个 burst 收满，否则会在 AR 上死锁）
                                state <= S_AR;
                            end
                        end
                    end
                end

                S_REL: begin
                    if (abort) begin
                        release_valid <= 1'b0;
                        busy          <= 1'b0;
                        state         <= S_IDLE;
                    end else if (release_ready) begin
                        release_valid <= 1'b0;
                        busy          <= 1'b0;
                        state         <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
