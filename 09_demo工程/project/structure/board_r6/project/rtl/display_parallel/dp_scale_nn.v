//======================================================================
// dp_scale_nn.v  ——  display_parallel 工作包第 1 层
//
// 最近邻(nearest neighbour)缩放：任意输入尺寸 -> 固定 OUT_W x OUT_H。
// 输入是 dp_frame_reader 的像素流(24bit {R,G,B}，in_sof/in_eol 定界)，
// 输出是固定尺寸的像素流，顶层再把它放到右半屏 960x1080 的居中位置。
//
// 结构：in_line 行缓存(存**原始**输入行, 最多 MAX_IN_W 个像素) + 输出侧 DDA。
//   * S_FILL  把一个源行原样写进 in_line(不做任何水平处理)。
//   * S_EMIT  逐个产生输出像素：第 j 个输出像素取 in_line[src(j)]，
//             其中 src(j) = floor(j * in_w / out_w)  —— 标准"输出驱动"最近邻规则。
//   纵向同理：第 r 个输出行取源行 floor(r * in_h / out_h)，同一个源行重放
//   多次(放大)或整行丢弃(缩小)，源行只从 DDR 读一次。
//
// 【曾经写错过，务必不要回退】当初用的是"输入驱动"计数：
//   n_i = floor((i+1)*OUT_W/in_w) - floor(i*OUT_W/in_w)
// 它等价于另一套取整相位，对 3->8 给出 0,0,1,1,1,2,2,2，
// 而标准 floor 规则给出 0,0,0,1,1,1,2,2 —— 两者都"看起来像"最近邻，但不一样，
// 对 640->960 会得到不同的重复相位。现在统一采用输出驱动 floor 规则，
// 由 tb_dp_scale_nn.sv 用 floor 公式逐像素比对。
//
// 本模块是 backpressure 的：填充/输出期间把 in_ready 拉低，上游必须等。
//======================================================================
`timescale 1ns/1ps
module dp_scale_nn #(
    parameter integer OUT_W    = 960,
    parameter integer OUT_H    = 720,
    parameter integer AW       = 10,     // 2**AW  >= OUT_W
    parameter integer MAX_IN_W = 2048,   // 行缓存深度(输入行最大像素数)
    parameter integer LAW      = 11,     // 2**LAW >= MAX_IN_W
    parameter integer MAX_REP  = 8       // DDA 单步最多跨几个源像素(综合静态界)
)(
    input  wire        clk,
    input  wire        rstn,

    // 本帧输入尺寸(由帧描述给出，帧开始前保持稳定)
    input  wire [15:0] cfg_in_w,
    input  wire [15:0] cfg_in_h,

    // ---- 输入像素流(源分辨率) ----
    input  wire        in_valid,
    input  wire [23:0] in_data,
    input  wire        in_sof,
    input  wire        in_eol,
    output wire        in_ready,

    // ---- 输出像素流(OUT_W x OUT_H) ----
    output reg         out_valid,
    output reg  [23:0] out_data,
    output wire        out_sof,
    output wire        out_eol,
    input  wire        out_ready,

    // ---- 观测 ----
    output reg  [15:0] out_x,
    output reg  [15:0] out_y,
    output reg         busy,
    output reg         done_pulse,
    output reg         err_rep      // DDA 未在 MAX_REP 内收敛，参数配置有问题
);

    localparam S_IDLE = 2'd0,
               S_FILL = 2'd1,
               S_EMIT = 2'd2,
               S_DONE = 2'd3;

    localparam [15:0]   OW16  = OUT_W[15:0];
    localparam [15:0]   OH16  = OUT_H[15:0];
    localparam [AW-1:0] JLAST = OUT_W - 1;   // 本输出行最后一个像素的序号

    reg [1:0]     state;
    reg [23:0]    in_line [0:MAX_IN_W-1];

    reg [LAW-1:0] waddr;        // 行缓存写指针
    reg [AW-1:0]  raddr;        // 本输出行已产生像素数
    reg [AW-1:0]  jsel;         // 当前呈现在 out_data 上的输出像素序号
    reg [15:0]    src;          // 当前输出像素对应的源像素序号
    reg [31:0]    hacc;         // 水平 DDA 余量
    reg [31:0]    vacc;         // 垂直 DDA 余量
    reg [15:0]    have_row;     // in_line 里装的是源第几行
    reg [15:0]    next_row;     // 下一个要从输入流读的源行序号
    reg [15:0]    need_row;     // 下一个输出行需要的源行序号
    reg           keep;         // 本源行是否要存进行缓存(纵向缩小时整行丢弃)

    // ---------------- 水平 DDA：从 j 推进到 j+1 ----------------
    integer    k;
    reg [31:0] hacc_t;
    reg [15:0] src_t;
    reg        hovf_t;
    always @(*) begin
        hacc_t = hacc + {16'd0, cfg_in_w};
        src_t  = src;
        hovf_t = 1'b0;
        for (k = 0; k < MAX_REP; k = k + 1) begin
            if (hacc_t >= {16'd0, OW16}) begin
                hacc_t = hacc_t - {16'd0, OW16};
                src_t  = src_t + 16'd1;
            end
        end
        if (hacc_t >= {16'd0, OW16}) hovf_t = 1'b1;   // 未收敛
    end

    // ---------------- 垂直 DDA：从 r 推进到 r+1 ----------------
    reg [31:0] vacc_t;
    reg [15:0] need_t;
    reg        vovf_t;
    always @(*) begin
        vacc_t = vacc + {16'd0, cfg_in_h};
        need_t = need_row;
        vovf_t = 1'b0;
        for (k = 0; k < MAX_REP; k = k + 1) begin
            if (vacc_t >= {16'd0, OH16}) begin
                vacc_t = vacc_t - {16'd0, OH16};
                need_t = need_t + 16'd1;
            end
        end
        if (vacc_t >= {16'd0, OH16}) vovf_t = 1'b1;
    end

    // ---------------- 握手 ----------------
    wire in_hs = in_valid && in_ready;
    assign in_ready = (state == S_FILL);

    // 行边界标志由组合逻辑给出，保证被背压保持时不会丢一拍
    assign out_sof = out_valid && (out_y == 16'd0) && (jsel == {AW{1'b0}});
    assign out_eol = out_valid && (jsel == JLAST);

    always @(posedge clk) begin
        if (!rstn) begin
            state      <= S_IDLE;
            waddr      <= {LAW{1'b0}};
            raddr      <= {AW{1'b0}};
            jsel       <= {AW{1'b0}};
            src        <= 16'd0;
            hacc       <= 32'd0;
            vacc       <= 32'd0;
            have_row   <= 16'd0;
            next_row   <= 16'd0;
            need_row   <= 16'd0;
            keep       <= 1'b1;
            out_valid  <= 1'b0;
            out_data   <= 24'd0;
            out_x      <= 16'd0;
            out_y      <= 16'd0;
            busy       <= 1'b0;
            done_pulse <= 1'b0;
            err_rep    <= 1'b0;
        end else begin
            out_valid  <= 1'b0;
            done_pulse <= 1'b0;

            case (state)
            // ---------------- 等帧开始 ----------------
            S_IDLE: begin
                if (in_valid && in_sof) begin
                    waddr    <= {LAW{1'b0}};
                    raddr    <= {AW{1'b0}};
                    jsel     <= {AW{1'b0}};
                    src      <= 16'd0;
                    hacc     <= 32'd0;
                    vacc     <= 32'd0;
                    have_row <= 16'd0;
                    next_row <= 16'd0;
                    need_row <= 16'd0;
                    keep     <= 1'b1;
                    out_x    <= 16'd0;
                    out_y    <= 16'd0;
                    busy     <= 1'b1;
                    state    <= S_FILL;
                end
            end

            // ---------------- 原样收一个源行(按需存储) ----------------
            S_FILL: begin
                if (in_hs) begin
                    if (keep) in_line[waddr] <= in_data;
                    waddr <= waddr + {{(LAW-1){1'b0}}, 1'b1};
                    if (in_eol) begin
                        if (keep) begin
                            have_row <= next_row;
                            next_row <= next_row + 16'd1;
                            waddr    <= {LAW{1'b0}};
                            raddr    <= {AW{1'b0}};
                            jsel     <= {AW{1'b0}};
                            src      <= 16'd0;
                            hacc     <= 32'd0;
                            state    <= S_EMIT;
                        end else begin
                            // 纵向缩小：本源行整行丢弃，继续找下一行
                            next_row <= next_row + 16'd1;
                            waddr    <= {LAW{1'b0}};
                            keep     <= ((next_row + 16'd1) == need_row);
                        end
                    end
                end
            end

            // ---------------- 产生一个输出行 ----------------
            S_EMIT: begin
                if (out_valid && out_ready && (jsel == JLAST)) begin
                    // 本输出行最后一个像素已被接收
                    out_valid <= 1'b0;
                    out_y     <= out_y + 16'd1;
                    raddr     <= {AW{1'b0}};
                    jsel      <= {AW{1'b0}};
                    src       <= 16'd0;
                    hacc      <= 32'd0;
                    vacc      <= vacc_t;
                    need_row  <= need_t;
                    if (vovf_t) err_rep <= 1'b1;
                    if (out_y + 16'd1 >= OH16) begin
                        state      <= S_DONE;
                        busy       <= 1'b0;
                        done_pulse <= 1'b1;
                    end else if (need_t == have_row) begin
                        // 同一个源行再重放一次(纵向放大)
                    end else begin
                        state <= S_FILL;
                        keep  <= (next_row == need_t);
                    end
                end else if (!out_valid || out_ready) begin
                    // 装载/推进一个输出像素
                    out_valid <= 1'b1;
                    out_data  <= in_line[src[LAW-1:0]];
                    jsel      <= raddr;
                    out_x     <= {{(16-AW){1'b0}}, raddr};
                    raddr     <= raddr + {{(AW-1){1'b0}}, 1'b1};
                    src       <= src_t;
                    hacc      <= hacc_t;
                    if (hovf_t) err_rep <= 1'b1;
                end else begin
                    out_valid <= 1'b1;      // 保持当前像素等待 out_ready
                end
            end

            S_DONE: begin
                busy <= 1'b0;
                if (in_valid && in_sof) begin
                    // 直接开始下一帧
                    waddr    <= {LAW{1'b0}};
                    raddr    <= {AW{1'b0}};
                    jsel     <= {AW{1'b0}};
                    src      <= 16'd0;
                    hacc     <= 32'd0;
                    vacc     <= 32'd0;
                    have_row <= 16'd0;
                    next_row <= 16'd0;
                    need_row <= 16'd0;
                    keep     <= 1'b1;
                    out_x    <= 16'd0;
                    out_y    <= 16'd0;
                    busy     <= 1'b1;
                    state    <= S_FILL;
                end
            end
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
