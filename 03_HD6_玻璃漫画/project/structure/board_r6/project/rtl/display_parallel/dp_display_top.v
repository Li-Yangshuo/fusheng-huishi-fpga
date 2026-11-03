//======================================================================
// dp_display_top.v  ——  display_parallel 工作包第 1 层
//
// 右半屏合成器：把 dp_scale_nn 输出的 CNT_W x CNT_H (默认 960x720) 画面
// 放到 OUT_W x OUT_H (默认 960x1080) 半屏的**居中**位置，上下补黑边。
// 项目要求(进度文档第 114 行)：最终右半屏尽量利用空间、左右显示同一取景
// 范围；4:3 内容在 960x1080 半屏内用 960x720 居中显示 => y 偏移 180。
//
// 工作方式：
//   * 本模块是栅格主控，逐行扫描 1080 行。
//   * 落在内容带(y=180..899)的显示行，先从缩放器拉一整行(CNT_W 个像素)
//     存进 line_buf，再逐像素输出；其余显示行直接输出背景色。
//   * 缩放器在不需要行的时候被 s_ready=0 顶住(backpressure)，不会丢像素。
//   * 行末给 hs，帧末进入 S_VB 给 vs 并翻页。
//
// 注意：这里的 hs/vs 只是"有节奏的占位脉冲"，真正的 HDMI 时序(前肩/后肩/
// 像素时钟/148.5MHz)属于后续与既有 hdmi_tx 顶层集成的一步，不在这里假装
// 已经定死。dx/dy 是给波形和板上 OSD 用的行/列号。
//======================================================================
`timescale 1ns/1ps
module dp_display_top #(
    parameter integer OUT_W  = 960,      // 半屏宽(像素)
    parameter integer OUT_H  = 1080,     // 半屏高(行)
    parameter integer CNT_W  = 960,      // 缩放后内容宽
    parameter integer CNT_H  = 720,      // 缩放后内容高
    parameter integer Y_OFF  = 180,      // 内容垂直居中偏移 (1080-720)/2
    parameter integer LAW    = 10,       // 2**LAW >= CNT_W   行缓存地址位宽
    parameter integer AW     = 10,       // 2**AW  >= OUT_W   列计数位宽
    parameter integer HS_LEN = 8,        // 行消隐占位长度
    parameter integer VS_LEN = 8,        // 帧消隐占位长度
    parameter [23:0]  BG     = 24'h000000
)(
    input  wire        clk,
    input  wire        rstn,

    // ---- 缩放后像素流(来自 dp_scale_nn) ----
    input  wire        s_valid,
    input  wire [23:0] s_data,
    input  wire        s_sof,
    input  wire        s_eol,
    output wire        s_ready,

    // ---- 显示栅格(送 HDMI TX) ----
    input  wire        disp_ready,
    output reg         de,
    output reg  [23:0] dout,
    output reg         hs,
    output reg         vs,
    output reg  [15:0] dx,
    output reg  [15:0] dy,

    // ---- 观测 ----
    output reg         busy,
    output reg         done_pulse,   // 每帧一个脉冲
    output reg  [15:0] frames,
    output reg         err_row       // 缩放器行边界与 CNT_W 对不上
);

    localparam S_LINE = 3'd0,
               S_LOAD = 3'd1,
               S_EMIT = 3'd2,
               S_HB   = 3'd3,
               S_VB   = 3'd4;

    localparam [15:0] OW16  = OUT_W[15:0];
    localparam [15:0] OH16  = OUT_H[15:0];
    localparam [15:0] CW16  = CNT_W[15:0];
    localparam [15:0] Y0    = Y_OFF[15:0];
    localparam [15:0] Y1    = (Y_OFF + CNT_H);   // 不含
    localparam [AW-1:0] XLAST = OUT_W - 1;
    localparam [3:0]  HSL  = HS_LEN[3:0];
    localparam [3:0]  VSL  = VS_LEN[3:0];

    reg [2:0]     state;
    reg [23:0]    line_buf [0:CNT_W-1];

    reg [15:0]    y;         // 当前显示行
    reg [AW-1:0]  x;         // 当前显示列
    reg [LAW-1:0] waddr;     // 行缓存写指针
    reg           blank_line;
    reg [3:0]     hb_cnt, vb_cnt;

    wire in_band = (y >= Y0) && (y < Y1);

    wire [AW-1:0] xn = x + {{(AW-1){1'b0}}, 1'b1};

    assign s_ready = (state == S_LOAD);

    always @(posedge clk) begin
        if (!rstn) begin
            state      <= S_LINE;
            y          <= 16'd0;
            x          <= {AW{1'b0}};
            waddr      <= {LAW{1'b0}};
            blank_line <= 1'b0;
            hb_cnt     <= 4'd0;
            vb_cnt     <= 4'd0;
            de         <= 1'b0;
            dout       <= 24'd0;
            hs         <= 1'b0;
            vs         <= 1'b0;
            dx         <= 16'd0;
            dy         <= 16'd0;
            busy       <= 1'b1;
            done_pulse <= 1'b0;
            frames     <= 16'd0;
            err_row    <= 1'b0;
        end else begin
            done_pulse <= 1'b0;

            case (state)
            // ---------------- 决定这一显示行怎么走 ----------------
            S_LINE: begin
                if (y >= OH16) begin
                    // 一帧结束，走帧消隐
                    state      <= S_VB;
                    vb_cnt     <= 4'd0;
                    vs         <= 1'b1;
                    de         <= 1'b0;
                    done_pulse <= 1'b1;
                    frames     <= frames + 16'd1;
                end else if (in_band) begin
                    waddr <= {LAW{1'b0}};
                    state <= S_LOAD;
                end else begin
                    blank_line <= 1'b1;
                    x          <= {AW{1'b0}};
                    state      <= S_EMIT;
                end
            end

            // ---------------- 从缩放器拉一整行 ----------------
            S_LOAD: begin
                if (s_valid && s_ready) begin
                    line_buf[waddr] <= s_data;
                    waddr <= waddr + {{(LAW-1){1'b0}}, 1'b1};
                    // 行边界自检：最后像素应带 s_eol
                    if ((waddr + 1 == CW16[LAW-1:0]) && !s_eol) err_row <= 1'b1;
                    if (s_eol && (waddr + 1 != CW16[LAW-1:0])) err_row <= 1'b1;
                    if (waddr + 1 == CW16[LAW-1:0]) begin
                        blank_line <= 1'b0;
                        x          <= {AW{1'b0}};
                        state      <= S_EMIT;
                    end
                end
            end

            // ---------------- 输出一行 OUT_W 个像素 ----------------
            // de 高表示 dx/dy/dout 上的像素有效，必须一直保持到 disp_ready 才允许换下一个。
            // 最后一个像素被接收后才拉低 de 并转行消隐 —— 否则下游反压时该像素会丢。
            S_EMIT: begin
                if (!de) begin
                    // 进入本行的第一个像素，先摆上总线
                    de   <= 1'b1;
                    dx   <= {{(16-AW){1'b0}}, x};
                    dy   <= y;
                    dout <= blank_line ? BG : line_buf[x[LAW-1:0]];
                end else if (disp_ready) begin
                    if (x == XLAST) begin
                        // 最后一个像素已被接收
                        de     <= 1'b0;
                        state  <= S_HB;
                        hb_cnt <= 4'd0;
                    end else begin
                        x    <= xn;
                        dx   <= {{(16-AW){1'b0}}, xn};
                        dout <= blank_line ? BG : line_buf[xn[LAW-1:0]];
                    end
                end
            end

            // ---------------- 行消隐(hs) ----------------
            S_HB: begin
                de <= 1'b0;
                hs <= 1'b1;
                hb_cnt <= hb_cnt + 4'd1;
                if (hb_cnt + 4'd1 == HSL) begin
                    hs    <= 1'b0;
                    y     <= y + 16'd1;
                    state <= S_LINE;
                end
            end

            // ---------------- 帧消隐(vs) ----------------
            S_VB: begin
                de <= 1'b0;
                vs <= 1'b1;
                vb_cnt <= vb_cnt + 4'd1;
                if (vb_cnt + 4'd1 == VSL) begin
                    vs    <= 1'b0;
                    y     <= 16'd0;
                    state <= S_LINE;
                end
            end

            default: state <= S_LINE;
            endcase
        end
    end

endmodule
