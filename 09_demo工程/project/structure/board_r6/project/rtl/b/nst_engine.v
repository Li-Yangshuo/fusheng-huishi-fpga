//==============================================================================
// nst_engine.v  — 队员B v2(256) 卷积 MAC 阵列（4 引擎 × 8 lane = 32 个乘加器）
//
//   每拍处理一个输出像素、一个输入通道(c)、一个 tap(0..8)：
//     acc[idx] <= acc[idx] + a_mag * signed(w[idx])， idx = {引擎,lane}
//   - lane idx 即输出通道号 oc（wrom 已按 lane 转置打包，每拍 32B 一字）；
//   - 输入字节 a 对 32 lane 广播；a_us=1 时按无符号 0..255 扩展（图像/上游 relu），
//     a_us=0 时按 int8 补码符号扩展（上游 add 层）；
//   - 32 个 9×8→32 累加，Efinity dsp-mac-packing=0 时落 DSP。
//
// 时序：外部先 clr 一拍清空累加器，随后 en 逐拍喂 (a,w)。
//       acc 组合读：给 (ae,ao)，acc_q 当拍返回该 lane 累加结果。
//==============================================================================
`timescale 1ns/1ps
module nst_engine #(
    parameter NE = 4,          // 引擎数
    parameter NL = 8           // 每引擎 lane 数（每 lane = 一个输出通道）
)(
    input  wire               clk,
    input  wire               srst,        // 同步清零（高有效）
    input  wire [7:0]         a,           // 当拍输入像素字节（原始字节）
    input  wire               a_us,        // 1=unsigned 0=signed(int8)
    input  wire [NE*NL*8-1:0] w,           // 当拍权重：lane o 在 byte o，共 32B
    input  wire               en,          // 累加使能
    input  wire               clr,         // 下一拍清零所有 acc
    input  wire [1:0]         ae,          // acc 读口：引擎号
    input  wire [2:0]         ao,          // acc 读口：lane 号
    output wire signed [31:0] acc_q        // 读出的累加值（Σin·w，不含 Bq）
);
    localparam NW = NE * NL;               // 32

    // 统一符号扩展到 9bit signed：unsigned 0..255 与 signed -128..127 都精确表示
    wire signed [8:0] am = a_us ? $signed({1'b0, a}) : $signed({a[7], a});

    (* syn_use_dsp = "true" *) reg signed [31:0] mac_r [0:NW-1];

    genvar i;
    generate
        for (i = 0; i < NW; i = i + 1) begin : G_MAC
            wire signed [7:0] wv;
            assign wv = w[i*8 +: 8];
            always @(posedge clk) begin
                if (srst || clr)
                    mac_r[i] <= 32'sd0;
                else if (en)
                    mac_r[i] <= mac_r[i] + (am * wv);
            end
        end
    endgenerate

    assign acc_q = mac_r[{ae, ao}];
endmodule
