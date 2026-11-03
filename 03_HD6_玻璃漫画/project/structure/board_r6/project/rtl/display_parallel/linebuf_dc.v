// ============================================================================
// linebuf_dc.v — 双时钟双行乒乓缓存（纯存储 + 双口，所有权握手在 frm_rd /
// disp_win 两侧用 toggle 完成，本模块不参与）
//
// 2 槽 × 每槽 2**AW 像素 × 24bit RGB。
// 写侧 axi_clk（frm_rd 解包后的 24bit 像素流），读侧 pclk（disp_win 按源像素
// 地址读）。用 simple_dual_port_ram 同款写法推 RAM10：
//   每槽 1024×24bit = 24576 bit ≈ 3 块 RAM10（每块 1024×8），两槽共 ≈6 块。
// 读延迟 = 1（re/raddr 当拍发出，下一拍 rdata 有效），读侧需自行打拍对齐。
// ============================================================================
module linebuf_dc #(
    parameter integer MAX_W = 1024,
    parameter integer AW    = 10            // log2(MAX_W)
)(
    // 写侧（axi_clk）
    input  wire        wclk,
    input  wire        we,
    input  wire        wslot,
    input  wire [AW-1:0] waddr,
    input  wire [23:0] wdata,
    // 读侧（pclk），两槽各一个读口
    input  wire        rclk,
    input  wire        re0,
    input  wire        re1,
    input  wire [AW-1:0] raddr0,
    input  wire [AW-1:0] raddr1,
    output wire [23:0] rdata0,
    output wire [23:0] rdata1
);

simple_dual_port_ram #(
    .DATA_WIDTH (24),
    .ADDR_WIDTH (AW),
    .OUTPUT_REG ("FALSE"),
    .RAM_INIT_FILE("")
) u_slot0 (
    .wclk  (wclk),
    .we    (we && !wslot),
    .waddr (waddr),
    .wdata (wdata),
    .rclk  (rclk),
    .re    (re0),
    .raddr (raddr0),
    .rdata (rdata0)
);

simple_dual_port_ram #(
    .DATA_WIDTH (24),
    .ADDR_WIDTH (AW),
    .OUTPUT_REG ("FALSE"),
    .RAM_INIT_FILE("")
) u_slot1 (
    .wclk  (wclk),
    .we    (we && wslot),
    .waddr (waddr),
    .wdata (wdata),
    .rclk  (rclk),
    .re    (re1),
    .raddr (raddr1),
    .rdata (rdata1)
);

endmodule
