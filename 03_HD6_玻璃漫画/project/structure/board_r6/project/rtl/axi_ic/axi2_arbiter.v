// ============================================================================
// axi2_arbiter.v — 2 主 1 从 AXI4 仲裁器（突发粒度轮询）
//
// 规则：每个方向（写 AW/W/B、读 AR/R）独立仲裁；
//   请求方拿到授权后保持到本突发结束（写：B 响应；读：rlast），然后轮换优先。
//   无 ID 重映射（两主用不同常数 ID 即可），prot/cache/lock 不转发（从侧绑 0）。
// 应用场景：Ti60F225 竞赛工程 frame_buffer + fb640_wr 共享 ddr3_top 单从口。
// ============================================================================
module axi2_arbiter #(
    parameter integer DATA_WIDTH = 128,
    parameter integer ADDR_WIDTH = 32,
    parameter integer ID_WIDTH   = 4
)(
    input  wire clk,
    input  wire rstn,

    // ---- 主0（frame_buffer，缺省高优先） ----
    input  wire [ID_WIDTH-1:0]   s0_awid,
    input  wire [ADDR_WIDTH-1:0] s0_awaddr,
    input  wire [7:0]            s0_awlen,
    input  wire                  s0_awvalid,
    output wire                  s0_awready,
    input  wire [DATA_WIDTH-1:0] s0_wdata,
    input  wire [DATA_WIDTH/8-1:0] s0_wstrb,
    input  wire                  s0_wlast,
    input  wire                  s0_wvalid,
    output wire                  s0_wready,
    output wire [ID_WIDTH-1:0]   s0_bid,
    output wire                  s0_bvalid,
    input  wire                  s0_bready,
    input  wire [ID_WIDTH-1:0]   s0_arid,
    input  wire [ADDR_WIDTH-1:0] s0_araddr,
    input  wire [7:0]            s0_arlen,
    input  wire                  s0_arvalid,
    output wire                  s0_arready,
    output wire [ID_WIDTH-1:0]   s0_rid,
    output wire [DATA_WIDTH-1:0] s0_rdata,
    output wire                  s0_rlast,
    output wire                  s0_rvalid,
    input  wire                  s0_rready,

    // ---- 主1（fb640_wr，只写） ----
    input  wire [ID_WIDTH-1:0]   s1_awid,
    input  wire [ADDR_WIDTH-1:0] s1_awaddr,
    input  wire [7:0]            s1_awlen,
    input  wire                  s1_awvalid,
    output wire                  s1_awready,
    input  wire [DATA_WIDTH-1:0] s1_wdata,
    input  wire [DATA_WIDTH/8-1:0] s1_wstrb,
    input  wire                  s1_wlast,
    input  wire                  s1_wvalid,
    output wire                  s1_wready,
    output wire [ID_WIDTH-1:0]   s1_bid,
    output wire                  s1_bvalid,
    input  wire                  s1_bready,
    input  wire [ID_WIDTH-1:0]   s1_arid,
    input  wire [ADDR_WIDTH-1:0] s1_araddr,
    input  wire [7:0]            s1_arlen,
    input  wire                  s1_arvalid,
    output wire                  s1_arready,
    output wire [ID_WIDTH-1:0]   s1_rid,
    output wire [DATA_WIDTH-1:0] s1_rdata,
    output wire                  s1_rlast,
    output wire                  s1_rvalid,
    input  wire                  s1_rready,

    // ---- 从口（ddr3_top） ----
    output wire [ID_WIDTH-1:0]   m_awid,
    output wire [ADDR_WIDTH-1:0] m_awaddr,
    output wire [7:0]            m_awlen,
    output wire                  m_awvalid,
    input  wire                  m_awready,
    output wire [DATA_WIDTH-1:0] m_wdata,
    output wire [DATA_WIDTH/8-1:0] m_wstrb,
    output wire                  m_wlast,
    output wire                  m_wvalid,
    input  wire                  m_wready,
    input  wire [ID_WIDTH-1:0]   m_bid,
    input  wire                  m_bvalid,
    output wire                  m_bready,
    output wire [ID_WIDTH-1:0]   m_arid,
    output wire [ADDR_WIDTH-1:0] m_araddr,
    output wire [7:0]            m_arlen,
    output wire                  m_arvalid,
    input  wire                  m_arready,
    input  wire [ID_WIDTH-1:0]   m_rid,
    input  wire [DATA_WIDTH-1:0] m_rdata,
    input  wire                  m_rlast,
    input  wire                  m_rvalid,
    output wire                  m_rready
);

// ---------------------------------------------------------------------------
// 写方向：AW 仲裁 → W 跟随同一授权 → B 结束后轮换
// ---------------------------------------------------------------------------
reg       wr_grant;        // 当前授权主：0/1
reg       wr_busy;
reg       wr_turn;         // 下次优先给谁

wire s0_aw_req = s0_awvalid;
wire s1_aw_req = s1_awvalid;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        wr_grant <= 1'b0;
        wr_busy  <= 1'b0;
        wr_turn  <= 1'b0;
    end else begin
        if (!wr_busy) begin
            if (s0_aw_req || s1_aw_req) begin
                // 轮询优先：turn 优先，turn 方无请求则让另一方
                if (s0_aw_req && (wr_turn == 1'b0 || !s1_aw_req)) begin
                    wr_grant <= 1'b0; wr_busy <= 1'b1; wr_turn <= 1'b1;
                end else if (s1_aw_req) begin
                    wr_grant <= 1'b1; wr_busy <= 1'b1; wr_turn <= 1'b0;
                end
            end
        end else if (m_bvalid && m_bready) begin
            wr_busy <= 1'b0;         // B 响应 = 突发事务结束
        end
    end
end

// AW 转发
assign m_awid    = wr_grant ? s1_awid    : s0_awid;
assign m_awaddr  = wr_grant ? s1_awaddr  : s0_awaddr;
assign m_awlen   = wr_grant ? s1_awlen   : s0_awlen;
assign m_awvalid = wr_busy ? (wr_grant ? s1_awvalid : s0_awvalid) : 1'b0;
assign s0_awready = wr_busy && !wr_grant && m_awready;
assign s1_awready = wr_busy &&  wr_grant && m_awready;
// 注意：授权当拍 awvalid 还没转发（wr_busy 下一拍才置位）。
// 解决：授权采用"注册后转发"——wr_busy 置位后该主的 awvalid 仍在（主会保持到 awready），
// 转发发生在 wr_busy=1 的下一拍，协议上 awvalid 可多拍保持，合法。

// W 转发（跟随写授权）
assign m_wdata   = wr_grant ? s1_wdata : s0_wdata;
assign m_wstrb   = wr_grant ? s1_wstrb : s0_wstrb;
assign m_wlast   = wr_grant ? s1_wlast : s0_wlast;
assign m_wvalid  = wr_busy ? (wr_grant ? s1_wvalid : s0_wvalid) : 1'b0;
assign s0_wready = wr_busy && !wr_grant && m_wready;
assign s1_wready = wr_busy &&  wr_grant && m_wready;

// B 回传（按当前授权主路由）
assign s0_bid    = m_bid;
assign s1_bid    = m_bid;
assign s0_bvalid = m_bvalid && wr_busy && !wr_grant;
assign s1_bvalid = m_bvalid && wr_busy &&  wr_grant;
assign m_bready  = wr_grant ? s1_bready : s0_bready;

// ---------------------------------------------------------------------------
// 读方向：AR 仲裁 → R 跟随 → rlast 后轮换
// ---------------------------------------------------------------------------
reg       rd_grant;
reg       rd_busy;
reg       rd_turn;

wire s0_ar_req = s0_arvalid;
wire s1_ar_req = s1_arvalid;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        rd_grant <= 1'b0;
        rd_busy  <= 1'b0;
        rd_turn  <= 1'b0;
    end else begin
        if (!rd_busy) begin
            if (s0_ar_req || s1_ar_req) begin
                if (s0_ar_req && (rd_turn == 1'b0 || !s1_ar_req)) begin
                    rd_grant <= 1'b0; rd_busy <= 1'b1; rd_turn <= 1'b1;
                end else if (s1_ar_req) begin
                    rd_grant <= 1'b1; rd_busy <= 1'b1; rd_turn <= 1'b0;
                end
            end
        end else if (m_rvalid && m_rready && m_rlast) begin
            rd_busy <= 1'b0;
        end
    end
end

assign m_arid    = rd_grant ? s1_arid    : s0_arid;
assign m_araddr  = rd_grant ? s1_araddr  : s0_araddr;
assign m_arlen   = rd_grant ? s1_arlen   : s0_arlen;
assign m_arvalid = rd_busy ? (rd_grant ? s1_arvalid : s0_arvalid) : 1'b0;
assign s0_arready = rd_busy && !rd_grant && m_arready;
assign s1_arready = rd_busy &&  rd_grant && m_arready;

assign s0_rid    = m_rid;
assign s1_rid    = m_rid;
assign s0_rdata  = m_rdata;
assign s1_rdata  = m_rdata;
assign s0_rlast  = m_rlast && rd_busy && !rd_grant;
assign s1_rlast  = m_rlast && rd_busy &&  rd_grant;
assign s0_rvalid = m_rvalid && rd_busy && !rd_grant;
assign s1_rvalid = m_rvalid && rd_busy &&  rd_grant;
assign m_rready  = rd_grant ? s1_rready : s0_rready;

endmodule
