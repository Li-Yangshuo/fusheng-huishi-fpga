//==============================================================================
// nst_axi_eng.v — 命令队列 AXI4 引擎（aclk 域）
//
//   从 cmd FWFT FIFO 逐条取 49b 命令 {wr,tag[2:0],addr[31:0],beats[12:0]}：
//     wr=0 读：把 128b beat 按 tag 路由到 rS/rA/rB FIFO
//              (TAG_STYLE=0 / TAG_A=1 / TAG_B=2)，wfull 背压 r 通道
//     wr=1 写：从 wf(TAG_WF=3)/cof(TAG_OF=4) FWFT FIFO 取 128b beat 写 DDR，
//              握手拍弹出源 FIFO
//   burst 自动拆分：单 burst ≤256 beats 且不跨 4KB 边界（AXI4 规范）。
//   命令严格顺序执行：先入队的写命令完成（收到 B）后才执行后续读命令，
//   保证平面数据依赖（dst 写回 → 下一层 fill 读）。
//   eng_idle = 队列空 && 无在途命令（顶层 all_done 用）。
//==============================================================================
`timescale 1ns/1ps
module nst_axi_eng #(
    parameter MAX_BURST_BEATS = 8
)(
    input  wire        aclk,
    input  wire        aresetn,

    // ---- 命令 FWFT 读侧 ----
    input  wire        cmd_rempty,
    input  wire [48:0] cmd_rdata,
    output wire        cmd_re,

    // ---- 读数据路由（engine → FIFO 写侧，aclk 域）----
    output wire        s_we,   output wire [127:0] s_wdata,  input wire s_full,
    output wire        a_we,   output wire [127:0] a_wdata,  input wire a_full,
    output wire        b_we,   output wire [127:0] b_wdata,  input wire b_full,

    // ---- 写数据源（FIFO 读侧 → engine，FWFT）----
    output wire        wf_re,  input wire [127:0] wf_rdata, input wire wf_rempty,
    output wire        of_re,  input wire [127:0] of_rdata, input wire of_rempty,

    //---------------- AXI4 Master ----------------
    output wire [3:0]  m_axi_awid,
    output reg  [31:0] m_axi_awaddr,
    output reg  [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [127:0] m_axi_wdata,
    output wire [15:0] m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [3:0]  m_axi_bid,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,
    output wire [3:0]  m_axi_arid,
    output reg  [31:0] m_axi_araddr,
    output reg  [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [3:0]  m_axi_rid,
    input  wire [127:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    output wire [31:0] diag_engine,
    output wire        eng_idle,
    output reg  [7:0]  fault         // sticky: cmd, RID, RRESP, RLAST, BID, BRESP
);
    localparam [2:0] TAG_STYLE=3'd0, TAG_A=3'd1, TAG_B=3'd2,
                     TAG_WF=3'd3,    TAG_OF=3'd4;
    localparam E_IDLE=3'd0, E_RAR=3'd1, E_RD=3'd2,
               E_WAR=3'd3, E_WD=3'd4, E_WB=3'd5,
               E_DRAIN=3'd6, E_HALT=3'd7;
    reg [2:0] st;

    reg         wr_r;
    reg [2:0]   tag_r;
    reg [31:0]  adr_r;                 // 当前地址（burst 间推进）
    reg [12:0]  rem_r;                 // 本命令剩余 beats
    reg [12:0]  bt_cnt;                // 本 burst 剩余 beats
    reg [12:0]  blen;                  // 本 burst 长度（完成时扣减 rem_r）

    // burst 拆分：≤32 且不跨 4KB（AXI4 规范）。
    // 上限 32 是 A 线仲裁器压测硬结论（2026-10-14）：256 beat 独占总线 4.3µs，
    // 显示读死线 14.8µs 下 30% 行欠载；32 beat 时 0 欠载且自身带宽仍够 ~20fps。
    function [12:0] f_burst;
        input [12:0] rem;
        input [31:0] adr;
        reg [12:0] c1, c2;
        begin
            c1 = (rem < MAX_BURST_BEATS) ? rem : MAX_BURST_BEATS;
            c2 = 13'd256 - {9'd0, adr[11:4]};   // 4KB 块内剩余 beats
            f_burst = (c1 < c2) ? c1 : c2;
        end
    endfunction

    //=============================================================== 取命令
    // FWFT：锁存拍即弹出（cmd_re 组合，cmd_rdata 当拍有效）
    wire cmd_fire = (st==E_IDLE) && !cmd_rempty;
    assign cmd_re = cmd_fire;

    //=============================================================== 读数据路由
    wire sel_full = (tag_r==TAG_STYLE) ? s_full :
                    (tag_r==TAG_A)     ? a_full : b_full;
    wire read_bad = (m_axi_rid != 0) || (m_axi_rresp != 0)
                  || (m_axi_rlast != (bt_cnt == 1));
    wire rd_fire = (st==E_RD) && m_axi_rvalid && !sel_full;
    wire rd_en = rd_fire && !read_bad;
    assign m_axi_rready = ((st==E_RD) && !sel_full) || (st==E_DRAIN);
    assign s_we = rd_en && (tag_r==TAG_STYLE);
    assign a_we = rd_en && (tag_r==TAG_A);
    assign b_we = rd_en && (tag_r==TAG_B);
    assign s_wdata = m_axi_rdata;
    assign a_wdata = m_axi_rdata;
    assign b_wdata = m_axi_rdata;

    //=============================================================== 写数据源
    wire src_is_wf = (tag_r==TAG_WF);
    wire src_vld   = src_is_wf ? !wf_rempty : !of_rempty;
    wire wv        = (st==E_WD) && src_vld && (bt_cnt != 13'd0);
    wire wfire     = wv && m_axi_wready;
    assign m_axi_wvalid = wv;
    assign m_axi_wdata  = src_is_wf ? wf_rdata : of_rdata;
    assign m_axi_wlast  = (bt_cnt == 13'd1);
    assign wf_re = wfire &&  src_is_wf;    // 握手拍弹出源 FIFO
    assign of_re = wfire && !src_is_wf;
    assign m_axi_bready = (st==E_WB);

    //=============================================================== 主 FSM
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            st <= E_IDLE; fault<=0; wr_r<=1'b0; tag_r<=3'd0; adr_r<=32'd0;
            rem_r<=13'd0; bt_cnt<=13'd0; blen<=13'd0;
            m_axi_awvalid<=1'b0; m_axi_arvalid<=1'b0;
            m_axi_awaddr<=32'd0; m_axi_awlen<=8'd0;
            m_axi_araddr<=32'd0; m_axi_arlen<=8'd0;
        end else begin
            case (st)
            //------------------------------------------------ 取命令
            E_IDLE: if (cmd_fire) begin
                {wr_r, tag_r, adr_r, rem_r} <= cmd_rdata;
                if (cmd_rdata[12:0]==0 || cmd_rdata[16:13]!=0 ||
                    (cmd_rdata[48] ? (cmd_rdata[47:45]!=TAG_WF && cmd_rdata[47:45]!=TAG_OF)
                                     : cmd_rdata[47:45]>TAG_B)) begin
                    fault[0]<=1; st<=E_HALT;
                end else st <= cmd_rdata[48] ? E_WAR : E_RAR;
            end
            //------------------------------------------------ 读地址
            E_RAR: begin
                blen          <= f_burst(rem_r, adr_r);
                m_axi_araddr  <= adr_r;
                m_axi_arlen   <= f_burst(rem_r, adr_r) - 13'd1;
                // valid 为寄存输出：进入本状态当拍才置位，故握手必须同时看
                // arvalid，否则 arready 恒高的 slave 会漏掉首拍事务
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 1'b0;
                    bt_cnt        <= f_burst(rem_r, adr_r);
                    adr_r         <= adr_r + {f_burst(rem_r, adr_r), 4'd0};
                    st            <= E_RD;
                end else begin
                    m_axi_arvalid <= 1'b1;
                end
            end
            //------------------------------------------------ 读数据
            E_RD: if (rd_fire) begin
                if (read_bad) begin
                    fault[1] <= (m_axi_rid != 0);
                    fault[2] <= (m_axi_rresp != 0);
                    fault[3] <= (m_axi_rlast != (bt_cnt == 1));
                    // Consume the remainder of an accepted read burst before halting.
                    st <= m_axi_rlast ? E_HALT : E_DRAIN;
                end else if (bt_cnt == 13'd1) begin
                    rem_r <= rem_r - blen;
                    st    <= (rem_r > blen) ? E_RAR : E_IDLE;
                end else bt_cnt <= bt_cnt - 13'd1;
            end
            E_DRAIN: if (m_axi_rvalid && m_axi_rlast) st<=E_HALT;
            E_HALT: st<=E_HALT;
            //------------------------------------------------ 写地址
            E_WAR: begin
                blen           <= f_burst(rem_r, adr_r);
                m_axi_awaddr   <= adr_r;
                m_axi_awlen    <= f_burst(rem_r, adr_r) - 13'd1;
                if (m_axi_awvalid && m_axi_awready) begin
                    m_axi_awvalid  <= 1'b0;
                    bt_cnt         <= f_burst(rem_r, adr_r);
                    adr_r          <= adr_r + {f_burst(rem_r, adr_r), 4'd0};
                    st             <= E_WD;
                end else begin
                    m_axi_awvalid  <= 1'b1;
                end
            end
            //------------------------------------------------ 写数据
            E_WD: if (wfire) begin
                bt_cnt <= bt_cnt - 13'd1;
                if (bt_cnt == 13'd1) st <= E_WB;
            end
            //------------------------------------------------ 写响应
            E_WB: if (m_axi_bvalid) begin
                if (m_axi_bid!=0 || m_axi_bresp!=0) begin
                    fault[4]<=(m_axi_bid!=0); fault[5]<=(m_axi_bresp!=0);
                    st<=E_HALT;
                end else begin
                    rem_r <= rem_r - blen;
                    st    <= (rem_r > blen) ? E_WAR : E_IDLE;
                end
            end
            default: st <= E_IDLE;
            endcase
        end
    end

    assign m_axi_awid    = 4'd0;
    assign m_axi_awsize  = 3'b100;         // 16B/beat
    assign m_axi_awburst = 2'b01;          // INCR
    assign m_axi_wstrb   = 16'hFFFF;
    assign m_axi_arid    = 4'd0;
    assign m_axi_arsize  = 3'b100;
    assign m_axi_arburst = 2'b01;
    assign eng_idle      = (st==E_IDLE) && cmd_rempty;

    assign diag_engine={st,rem_r,bt_cnt,cmd_rempty,m_axi_rvalid,m_axi_rready};
endmodule
