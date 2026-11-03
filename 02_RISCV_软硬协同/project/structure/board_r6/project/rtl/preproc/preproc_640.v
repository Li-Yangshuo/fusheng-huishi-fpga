// ============================================================================
// preproc_640.v — RGB 域降采样：1920x1080 → 640x480
//
// 数据流（设计文档 docs/A3_分辨率梳理设计.md）：
//   1. 垂直裁剪：丢上下各 CROP_TOP 行（1080 → 960），规避 1080/480=2.25 非整数比
//   2. 水平 3:1 平均：1920 → 640（输入 2px/clk，3 拍 = 6px → 2 个输出像素）
//   3. 垂直 2:1 平均：960 → 480（行缓冲 640x24bit，奇偶行相加 >>1）
//
// 输入：74.25MHz 域，2px/clk，din = {b,g,r, b,g,r}（低 24bit = 左像素/偶数 x）
// 输出：同域，1px/clk 脉冲式 out_de，dout = {r,g,b}，帧首打 out_sof
// ============================================================================
module preproc_640 #(
    parameter integer IN_W       = 1920,
    parameter integer IN_H       = 1080,
    parameter integer CROP_TOP   = 60,     // 丢掉的顶部行数（底部同样丢 IN_H-CROP_TOP-CROP_LINES）
    parameter integer CROP_LINES = 960,    // 保留行数（偶数）
    parameter integer OUT_W      = 640,
    parameter integer OUT_H      = 480
)(
    input  wire        clk,          // vid_clk_dvi2 (74.25MHz)
    input  wire        rstn,

    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,        // 高 = 当前拍有一对有效像素
    input  wire [47:0] din,          // {b,g,r(右px), b,g,r(左px)}

    output reg         out_vs,
    output reg         out_hs,       // 每输出行结束打一拍
    output reg         out_de,       // 高 = dout 有效
    output reg         out_sof,      // 帧首像素同拍拉高
    output reg  [23:0] dout          // {r,g,b}
);

// ---------------------------------------------------------------------------
// 行计数：vs 上升沿清零，de 上升沿（行首）+1
// ---------------------------------------------------------------------------
reg        vs_d, de_d;
wire       vs_pos =  in_vs & ~vs_d;
wire       line_start = in_de & ~de_d;
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        vs_d <= 1'b0;
        de_d <= 1'b0;
    end else begin
        vs_d <= in_vs;
        de_d <= in_de;
    end
end

reg [11:0] line_cnt;
wire       line_end = ~in_de & de_d;   // de 下降沿 = 行尾（此时该行数据已处理完）
always @(posedge clk or negedge rstn) begin
    if (!rstn)          line_cnt <= 12'd0;
    else if (vs_pos)    line_cnt <= 12'd0;
    else if (line_end)  line_cnt <= line_cnt + 1'b1;   // 行尾计数：行体期间 line_cnt=当前行号
end

wire        line_keep  = (line_cnt >= CROP_TOP) && (line_cnt < CROP_TOP + CROP_LINES);
wire [11:0] kept_line  = line_cnt - CROP_TOP;          // 0..959
wire        pair_phase = kept_line[0];                 // 0=存（偶行） 1=平均+输出（奇行）

// ---------------------------------------------------------------------------
// 水平 3:1 平均：输入 2px/拍，3 拍一循环 → 每循环出 2 个像素
//   beat0: acc_a = px0+px1（暂存）
//   beat1: acc_a += px2 → out0；acc_b = px3
//   beat2: acc_b += px4+px5 → out1
// 每通道独立：除以 3 用 (sum*85+128)>>8（85/256≈1/3，含四舍五入）
// ---------------------------------------------------------------------------
reg [1:0]  beat;                       // 0/1/2 拍相位，行首归零

wire [7:0] lb = din[23:16];            // 左像素 b
wire [7:0] lg = din[15:8];
wire [7:0] lr = din[7:0];
wire [7:0] rb = din[47:40];            // 右像素 b
wire [7:0] rg = din[39:32];
wire [7:0] rr = din[31:24];

reg [9:0] acc_a_r, acc_a_g, acc_a_b;   // 3px 累加（最大 765）
reg [9:0] acc_b_r, acc_b_g, acc_b_b;

wire beat_active = in_de & line_keep;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        beat    <= 2'd0;
        acc_a_r <= 10'd0; acc_a_g <= 10'd0; acc_a_b <= 10'd0;
        acc_b_r <= 10'd0; acc_b_g <= 10'd0; acc_b_b <= 10'd0;
    end else if (!in_de) begin
        beat    <= 2'd0;             // 行间隙归位，等下一行首拍直接进 beat0
        acc_a_r <= 10'd0; acc_a_g <= 10'd0; acc_a_b <= 10'd0;
        acc_b_r <= 10'd0; acc_b_g <= 10'd0; acc_b_b <= 10'd0;
    end else if (beat_active) begin
        case (beat)
            2'd0: begin
                acc_a_r <= lr + rr;  acc_a_g <= lg + rg;  acc_a_b <= lb + rb;
                beat <= 2'd1;
            end
            2'd1: begin
                acc_a_r <= acc_a_r + lr;  acc_a_g <= acc_a_g + lg;  acc_a_b <= acc_a_b + lb;  // -> out0
                acc_b_r <= rr;            acc_b_g <= rg;            acc_b_b <= rb;            // px3
                beat <= 2'd2;
            end
            default: begin
                acc_b_r <= acc_b_r + lr + rr;  acc_b_g <= acc_b_g + lg + rg;  acc_b_b <= acc_b_b + lb + rb;  // -> out1
                beat <= 2'd0;
            end
        endcase
    end
end

// beat1 拍末 acc_a 完整 → 该拍产生 out0；beat2 拍末 acc_b 完整 → 该拍产生 out1
//（在 beat 推进的同一拍使用旧值，故 out_valid 在 beat==1 / beat==2 拍上）
wire h_out0_vld = beat_active && (beat == 2'd1);
wire h_out1_vld = beat_active && (beat == 2'd2);

function [7:0] div3;
    input [9:0] s;
    reg [19:0] t;
    begin
        t = s * 10'd341 + 10'd512;     // ≈ s/3 四舍五入（341/1024）
        div3 = (t[19:10] > 10'd255) ? 8'd255 : t[17:10];
    end
endfunction

wire [7:0] h0_r = div3(acc_a_r + lr);  // beat1：acc_a 还差本拍 px2
wire [7:0] h0_g = div3(acc_a_g + lg);
wire [7:0] h0_b = div3(acc_a_b + lb);
wire [7:0] h1_r = div3(acc_b_r + lr + rr);  // beat2：acc_b 还差本拍 px4+px5
wire [7:0] h1_g = div3(acc_b_g + lg + rg);
wire [7:0] h1_b = div3(acc_b_b + lb + rb);

wire        h_vld  = h_out0_vld | h_out1_vld;
wire [23:0] h_pix  = h_out0_vld ? {h0_r, h0_g, h0_b} : {h1_r, h1_g, h1_b};

// ---------------------------------------------------------------------------
// 垂直 2:1 平均：行缓冲存偶行（H 平均后），奇行读出相加 >>1 输出
// ---------------------------------------------------------------------------
reg  [10:0]  x_cnt;                    // 0..OUT_W（需 ≥1024 位宽，640 像素 + 结束检测用 640 值）
always @(posedge clk or negedge rstn) begin
    if (!rstn)          x_cnt <= 11'd0;
    else if (line_start) x_cnt <= 11'd0;
    else if (h_vld)     x_cnt <= x_cnt + 1'b1;
end

(* syn_ramstyle = "block_ram" *) reg [23:0] line_mem [0:OUT_W-1];
reg  [23:0] line_rd;
reg         h_vld_d, phase_d;
reg  [23:0] h_pix_d;

always @(posedge clk) begin
    if (h_vld && line_keep && !pair_phase)
        line_mem[x_cnt] <= h_pix;      // 偶行：写入
    if (h_vld && line_keep && pair_phase)
        line_rd <= line_mem[x_cnt];    // 奇行：读出（打一拍）
    h_vld_d  <= h_vld && line_keep && pair_phase;
    phase_d  <= pair_phase;
    h_pix_d  <= h_pix;
end

// 奇行输出 = (偶行 + 奇行) >> 1（读口打一拍后对齐奇行数据；分通道 9bit 相加防溢出）
wire [8:0] v_sum_r = {1'b0, line_rd[23:16]} + {1'b0, h_pix_d[23:16]};
wire [8:0] v_sum_g = {1'b0, line_rd[15:8]}  + {1'b0, h_pix_d[15:8]};
wire [8:0] v_sum_b = {1'b0, line_rd[7:0]}   + {1'b0, h_pix_d[7:0]};
wire [23:0] v_pix  = {v_sum_r[8:1], v_sum_g[8:1], v_sum_b[8:1]};

// ---------------------------------------------------------------------------
// 输出生成
// ---------------------------------------------------------------------------
reg sof_pending;
reg h_vld_dd;
reg line_done;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        out_vs  <= 1'b0;
        out_hs  <= 1'b0;
        out_de  <= 1'b0;
        out_sof <= 1'b0;
        dout    <= 24'd0;
        sof_pending <= 1'b0;
        h_vld_dd    <= 1'b0;
        line_done   <= 1'b0;
    end else begin
        if (vs_pos) sof_pending <= 1'b1;             // 本帧待打 sof

        h_vld_dd <= h_vld_d;
        out_de   <= h_vld_d;
        out_sof  <= 1'b0;
        if (h_vld_d) begin
            dout <= v_pix;
            if (sof_pending) begin
                out_sof     <= 1'b1;
                sof_pending <= 1'b0;
            end
        end
        // 输出行结束：最后一个像素（x_cnt 已数到 OUT_W）之后再打一拍 hs
        line_done <= h_vld_d && (x_cnt == OUT_W);
        out_hs    <= line_done;
        // 帧同步直通（位置粗对齐即可，DDR 侧按像素计数）
        out_vs <= in_vs;
    end
end

endmodule
