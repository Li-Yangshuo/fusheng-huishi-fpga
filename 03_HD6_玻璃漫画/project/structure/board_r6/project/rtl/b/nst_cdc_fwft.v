//==============================================================================
// nst_cdc_fwft.v — FWFT（First-Word-Fall-Through）异步 FIFO（灰指针跨时钟域）
//
//   BRAM 预取版：存储体使用【同步读】（mout <= mem[rbin]），可被综合推断为
//   双时钟块 RAM；读侧用预取指针保持对外 FWFT 语义：
//     rempty==0 时 rdata 即为队首词；rden 当拍弹出，下一拍呈现下一词
//     （与旧组合读版本的弹出节拍完全一致；仅首字可见晚 1 个 rclk）。
//   可持续每拍弹出一个词（吞吐不变）。
//   注意：rbin 预取领先真实弹出 1 个词（该词位于输出寄存器 mout 中），
//   写侧满判定基于 mem 占用，因此 FIFO 可容纳 mem(DEPTH)+mout(1) 个词，
//   不小于旧版深度，使用方按 wfull/rempty 握手即安全。
//   用途：
//     cmd 队列(49b, clk_c→aclk)、wf/cof(128b, clk_c→aclk)、
//     rS/rA/rB(128b, aclk→clk_c)
//   两时钟同频/同源时亦正常工作（仿真可给同一时钟）。
//   参考 Cummings《Simulation and Synthesis Techniques for Asynchronous
//   FIFO Design》（指针/灰度同步部分）。
//==============================================================================
`timescale 1ns/1ps
module nst_cdc_fwft #(
    parameter DW = 128,
    parameter AW = 4            // 深度 = 2^AW
)(
    input  wire          wclk, wrst_n,
    input  wire          wren,
    input  wire [DW-1:0] wdata,
    output wire          wfull,
    input  wire          rclk, rrst_n,
    input  wire          rden,
    output wire [DW-1:0] rdata,       // FWFT：队首词（mout 寄存器输出）
    output wire [AW:0] dbg_wbin,dbg_rbin,dbg_wbin_rc,
    output wire          rempty
);
    localparam DEPTH = (1 << AW);

    reg [DW-1:0] mem [0:DEPTH-1];

    // gray 编码/解码
    function [AW:0] bin2gray;
        input [AW:0] b;
        bin2gray = (b >> 1) ^ b;
    endfunction
    function [AW:0] gray2bin;
        input [AW:0] g;
        integer i;
        begin
            gray2bin[AW] = g[AW];
            for (i = AW-1; i >= 0; i = i-1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    //=============================================================== 写侧
    reg  [AW:0] wbin, wgray;
    wire        wwrite    = wren & ~wfull;
    wire [AW:0] wbin_next  = wbin + wwrite;
    wire [AW:0] wgray_next = bin2gray(wbin_next);
    reg  [AW:0] wq1_rgray, wq2_rgray;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin  <= 0;  wgray <= 0;
        end else begin
            if (wwrite) mem[wbin[AW-1:0]] <= wdata;   // FIFO 存储体写入
            wbin  <= wbin_next;
            wgray <= wgray_next;
        end
    end
    // 预测下拍满（rgray 为预取指针：mem 腾出的位置即可写，mout 另占 1 词）
    reg wfull_r;
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) wfull_r <= 1'b0;
        else         wfull_r <= (wgray_next == {~wq2_rgray[AW:AW-1], wq2_rgray[AW-2:0]});
    end
    assign wfull = wfull_r;

    //=============================================================== 读侧（预取）
    reg  [AW:0] rbin, rgray;          // 预取指针：下一个要取入 mout 的 mem 地址
    reg  [AW:0] rq1_wgray, rq2_wgray;
    reg  [DW-1:0] mout;
    reg           mvalid;             // mout 中是有效队首词

    wire [AW:0] wbin_rc = gray2bin(rq2_wgray);
    wire        avail   = (rbin != wbin_rc);          // mem 中尚有未预取的词
    wire        pop     = rden & mvalid;
    wire        fetch   = (!mvalid || pop) && avail;  // 装载/换词
    wire [AW:0] rbin_next  = rbin + 1'b1;
    wire [AW:0] rgray_next = bin2gray(rbin_next);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin <= 0;  rgray <= 0;  mvalid <= 1'b0;
        end else if (fetch) begin
            mout   <= mem[rbin[AW-1:0]];   // 同步读：块 RAM 友好
            rbin   <= rbin_next;
            rgray  <= rgray_next;
            mvalid <= 1'b1;
        end else if (pop) begin
            mvalid <= 1'b0;                 // 弹出最后一个词，FIFO 变空
        end
    end

    assign rdata  = mout;
    assign rempty = ~mvalid;
    wire   rempty_r = ~mvalid;   // 旧版层级探针别名（TB 直接引用 u_xx.rempty_r）

    //=============================================================== 跨域同步
    always @(posedge wclk or negedge wrst_n)
        if (!wrst_n) {wq2_rgray, wq1_rgray} <= 0;
        else         {wq2_rgray, wq1_rgray} <= {wq1_rgray, rgray};

    always @(posedge rclk or negedge rrst_n)
        if (!rrst_n) {rq2_wgray, rq1_wgray} <= 0;
        else         {rq2_wgray, rq1_wgray} <= {rq1_wgray, wgray};

    assign dbg_wbin=wbin;assign dbg_rbin=rbin;assign dbg_wbin_rc=wbin_rc;
endmodule
