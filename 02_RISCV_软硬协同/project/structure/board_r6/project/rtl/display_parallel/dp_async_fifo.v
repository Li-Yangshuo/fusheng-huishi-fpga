//======================================================================
// dp_async_fifo.v  ——  24bit 异步 FIFO（Cummings 格雷指针风格）
//
//   写域: axi_clk (core_clk, 100MHz)   读域: pix_clk (hdmi_tx_slow_clk, 148.5MHz)
//   组合读（first-word-fall-through），带 walmost 供上游反压。
//   全满/全空由格雷指针比较得到，指针只用 2 级同步器跨域。
//
//   复位注意: 两侧指针必须各自复位到 0 才能保持一致；本模块只提供
//   两个独立的异步复位，调用方负责让两侧都在同一帧边界复位
//   （见 dp_live_display.v：写侧 core_rstn，读侧 vs 后 7 拍的 pix_rstn_f）。
//======================================================================
`timescale 1ns/1ps

module dp_async_fifo #(
    parameter integer DW     = 24,
    parameter integer AW     = 11,       // 深度 = 2**AW
    parameter integer ALMOST = 1500      // o_almost 的阈值（字数）
)(
    input  wire          wclk,
    input  wire          wrstn,
    input  wire          winc,
    input  wire [DW-1:0] wdata,
    output wire          wfull,
    output wire          walmost,
    output wire [AW:0]   wlevel,     // 写域可见的存量（A15.1：reader 的 AR 闸门要用）

    input  wire          rclk,
    input  wire          rrstn,
    input  wire          rinc,
    output wire [DW-1:0] rdata,
    output wire          rempty
);

    reg [DW-1:0] mem [0:(1<<AW)-1];

    reg [AW:0] wbin   = 0, wgray   = 0;
    reg [AW:0] rbin   = 0, rgray   = 0;
    reg [AW:0] rgray_s1 = 0, rgray_s2 = 0;   // 读指针同步到写域
    reg [AW:0] wgray_s1 = 0, wgray_s2 = 0;   // 写指针同步到读域

    // ------------------------------------------------------------------
    // 写域
    // ------------------------------------------------------------------
    wire        winc_ok   = winc & ~wfull;
    wire [AW:0] wbin_nxt  = wbin + {{AW{1'b0}}, winc_ok};
    wire [AW:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;

    // 满: 当前写格雷码 == 同步过来的读格雷码反转最高两位。
    // ★ 必须用“当前” wgray 而不是 wgray_nxt：用 nxt 会形成
    //   wfull -> winc_ok -> wbin_nxt -> wgray_nxt -> wfull 的组合环，
    //   在“差一步就满”时该方程没有不动点，iverilog 会零延迟死循环（已踩过）。
    assign wfull = (wgray == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});

    // 写域可见的存量（用同步过来的读指针的二进制还原）
    function [AW:0] gray2bin(input [AW:0] g);
        integer i;
        begin
            gray2bin[AW] = g[AW];
            for (i = AW-1; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    wire [AW:0] rbin_sync = gray2bin(rgray_s2);
    assign wlevel  = wbin - rbin_sync;
    assign walmost = (wlevel >= ALMOST);

    always @(posedge wclk or negedge wrstn) begin
        if (!wrstn) begin
            wbin  <= 0;
            wgray <= 0;
        end else begin
            wbin  <= wbin_nxt;
            wgray <= wgray_nxt;
            if (winc_ok) mem[wbin[AW-1:0]] <= wdata;
        end
    end

    always @(posedge wclk or negedge wrstn) begin
        if (!wrstn) begin
            rgray_s1 <= 0;
            rgray_s2 <= 0;
        end else begin
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
        end
    end

    // ------------------------------------------------------------------
    // 读域
    // ------------------------------------------------------------------
    wire        rinc_ok   = rinc & ~rempty;
    wire [AW:0] rbin_nxt  = rbin + {{AW{1'b0}}, rinc_ok};
    wire [AW:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

    // 空: 当前读格雷码 == 同步过来的写格雷码（同样不能用 nxt，否则又是组合环）
    assign rempty = (rgray == wgray_s2);

    always @(posedge rclk or negedge rrstn) begin
        if (!rrstn) begin
            rbin  <= 0;
            rgray <= 0;
        end else begin
            rbin  <= rbin_nxt;
            rgray <= rgray_nxt;
        end
    end

    always @(posedge rclk or negedge rrstn) begin
        if (!rrstn) begin
            wgray_s1 <= 0;
            wgray_s2 <= 0;
        end else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
        end
    end

    // 组合读，首字直通
    assign rdata = mem[rbin[AW-1:0]];

endmodule
