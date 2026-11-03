// ============================================================================
// frm_rd.v — AXI4 读帧主 + 帧描述接口 + 行缓存写侧（axi_clk 域）
//
// 职责：
//   1) 帧描述 ready/valid 接收（pend 深度 1）。新帧先做"验证空读"：全帧逐行
//      读一遍只校验不收数，RRESP/RLAST/beat 数全对才发布（pub_* + pub_tgl 给
//      pclk 域）；任一行出错 → 锁 frm_err、该帧作废不发布、经 release 口归还，
//      显示侧继续用上一好帧。
//   2) 显示取数：按 disp_line 0..H-1 循环逐行读"当前帧"（act），写入行缓存
//      空闲槽。槽信用 = 每槽一对 wr_tgl/rd_tgl：槽空闲条件 rd_tgl 同步值 ==
//      wr_tgl 本地值；行写完翻 wr_tgl 发布（行号/帧号低8位随 toggle 准静态
//      过域），显示侧消费完翻 rd_tgl 归还。只持有/只读 act 一帧。
//   3) 帧切换：只在显示扫描帧边界之后发生——显示侧切帧后翻 disp_sw_tgl 回执。
//      本模块在 S_IDLE（单 outstanding、行间间隙 = 旧帧读事务天然 draining 完）
//      才响应切换：先经 release 口归还旧帧（带旧 frame_id，握手成功才算完），
//      再把 act 换成已发布帧、disp_line 归 0。
//
// DDR 像素格式（RGB888x，32bit/px）字节序推导：
//   内存字节升序 = 00,B,G,R（低地址在前）
//   → 一个 32bit 像素字 bit[7:0]=8'h00、bit[15:8]=B、bit[23:16]=G、bit[31:24]=R
//   → 128bit beat 内像素 n 占 bit[32n+31:32n]，其 24bit {R,G,B} = beat[32n+8 +: 24]
//     （即丢掉每个 32bit 通道的低 8 位 00 填充字节）
//
// AXI 约定：INCR、arsize=4（16B/beat）、每突发 ≤MAX_BURST_BEATS beat、行内顺序地址 +
// 4KB 边界截断保证不跨 4KB；ID 固定 ARID。frame_base 要求 16B 对齐。
// R 通道防护：rresp!=00 / rlast 提前或缺席 / 多余 beat / rvalid 看门狗超时
// 均判本行作废。
// ============================================================================
module frm_rd #(
    parameter integer AW     = 10,          // 行缓存地址宽（每槽 2**AW 像素）
    parameter [3:0]   ARID   = 4'd3,
    parameter integer R_WDOG = 100000,
    parameter integer MAX_BURST_BEATS = 16,
    parameter integer DISP_W = 960, DISP_H = 720
)(
    input  wire        axi_clk,
    input  wire        axi_rstn,

    // 帧描述接口（ready/valid，axi_clk 域）
    input  wire        frame_valid,
    output wire        frame_ready,
    input  wire [31:0] frame_id,
    input  wire [31:0] frame_base,
    input  wire [15:0] frame_width,
    input  wire [15:0] frame_height,
    input  wire [31:0] frame_stride_bytes,

    // 归还接口（release_valid 保持到 release_ready 握手成功）
    output reg         release_valid,
    input  wire        release_ready,
    output reg  [31:0] release_frame_id,

    // AXI4 读主口
    output wire [3:0]  m_axi_arid,
    output reg  [31:0] m_axi_araddr,
    output reg  [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [3:0]  m_axi_rid,           // 未用（单 outstanding，ID 固定）
    input  wire [127:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    // 行缓存写口（接 linebuf_dc 写侧，axi_clk 域）
    output reg         lb_we,
    output reg         lb_wslot,
    output reg  [AW-1:0] lb_waddr,
    output reg  [23:0] lb_wdata,

    // 槽位握手：wr_tgl/slot_line/slot_fid 去 pclk 域（对侧打拍），
    // rd_tgl 从 pclk 域回来（本模块内打拍）
    output reg         wr_tgl0,
    output reg         wr_tgl1,
    output reg  [15:0] slot_line0,
    output reg  [15:0] slot_line1,
    output reg  [31:0]  slot_fid0,
    output reg  [31:0]  slot_fid1,
    input  wire        rd_tgl0,
    input  wire        rd_tgl1,

    // 显示侧切帧回执（pclk 域 toggle，本模块内打拍）
    input  wire        disp_sw_tgl,

    // 发布元数据（准静态 + toggle，disp_win 内打拍）；disp 侧只需 id/w/h
    output reg         pub_valid,
    output reg         pub_tgl,
    output reg  [31:0] pub_id,
    output reg  [15:0] pub_width,
    output reg  [15:0] pub_height,

    // 状态
    output wire [31:0] timing_dbg,
    input wire validation_pause_async,
    output reg         frm_err,             // sticky，下一好帧发布时清
    output reg  [31:0] act_id_dbg           // 当前取数帧 id（调试用）
);

assign m_axi_arid    = ARID;
assign m_axi_arsize  = 3'd4;                // 16B/beat
assign m_axi_arburst = 2'b01;               // INCR

// ---------------------------------------------------------------------------
// 跨域打拍（pclk -> axi）：行释放 toggle、切帧回执 toggle
// ---------------------------------------------------------------------------
(* async_reg="true" *) reg [1:0] rd_tgl0_sync, rd_tgl1_sync, disp_sw_sync;
always @(posedge axi_clk or negedge axi_rstn) begin
    if (!axi_rstn) begin
        rd_tgl0_sync <= 2'b00;
        rd_tgl1_sync <= 2'b00;
        disp_sw_sync <= 2'b00;
    end else begin
        rd_tgl0_sync <= {rd_tgl0_sync[0], rd_tgl0};
        rd_tgl1_sync <= {rd_tgl1_sync[0], rd_tgl1};
        disp_sw_sync <= {disp_sw_sync[0], disp_sw_tgl};
    end
end

// ---------------------------------------------------------------------------
// 描述寄存器组：pend（深度1）→ cand（验证中）→ pub（已发布）→ act（显示中）
// ---------------------------------------------------------------------------
reg        pend_valid;
reg [31:0] pend_id, pend_base, pend_stride;
reg [15:0] pend_w, pend_h;

reg        cand_valid;
reg [31:0] cand_id, cand_base, cand_stride;
reg [15:0] cand_w, cand_h;
reg [15:0] val_beats; // A16.4: candidate progress survives display preemption.
(* async_reg="true" *) reg [1:0] validation_pause_sync;
always @(posedge axi_clk or negedge axi_rstn)
    if(!axi_rstn) validation_pause_sync<=0;
    else validation_pause_sync<={validation_pause_sync[0],validation_pause_async};
reg [15:0] val_line;                        // 验证进行到第几行

reg        act_valid;
reg [31:0] act_id, act_base, act_stride;
reg [15:0] act_w, act_h;
reg [15:0] disp_line;                       // 显示取数循环行号
reg        wr_sel;                          // 下一个写入槽
reg        disp_sw_seen;                    // 已处理的切帧回执

assign frame_ready = !pend_valid;

// 槽空闲 = 对侧消费 toggle 同步值已追上本地发布 toggle
wire slot_free_sel = wr_sel ? (rd_tgl1_sync[1] == wr_tgl1)
                            : (rd_tgl0_sync[1] == wr_tgl0);

// ---------------------------------------------------------------------------
// 读引擎状态机：单 outstanding 突发，逐行推进
// ---------------------------------------------------------------------------
localparam S_IDLE = 3'd0;
localparam S_AR   = 3'd1;
localparam S_R    = 3'd2;
localparam S_UNPK = 3'd3;
localparam S_REL  = 3'd4;

reg [2:0]  st;
reg        t_store;                         // 1=显示取数写行缓存 0=验证空读
reg        t_slot;                          // 显示取数目标槽
reg [15:0] t_line;                          // 本任务行号
reg [15:0] t_h;                             // 本任务总行数
reg [15:0] beats_total;                     // 本行总 beat = ceil(w/4)
reg [15:0] beats_done;                      // 本行已收 beat
reg [31:0] burst_addr;                      // 当前突发起始地址
reg [7:0]  burst_cnt;                       // 当前突发已收 beat
reg        burst_last;                      // 本拍 beat 是突发尾（正常/异常）
reg        skip_write;                      // 本 beat 不写缓存（协议崩/看门狗）
reg [127:0] beat_hold;
reg [AW-1:0] unpk_base;                     // 本 beat 首像素在行内的像素地址
reg [1:0]  unpk_cnt;
reg        line_bad;
reg [31:0] wdog;
reg        rel_then_switch;                 // release 完成后是否执行切帧

// A16: never return ownership while an accepted AR still lacks RLAST.
localparam S_DRAIN = 3'd5;
localparam S_FAULT_END = 3'd6;
// A16.5: the fourth pixel write and next beat reception share a clock edge.
// beat_hold is replaced only after its final lane has been sampled.
assign m_axi_rready = (st == S_R) || (st == S_DRAIN) ||
                     (st == S_UNPK && t_store && unpk_cnt == 2'd3 && !burst_last);
// Diagnostic only: maximum reader job duration, in axi_clk cycles.
// High half = a display row; low half = a validation burst/job. Saturates.
reg [15:0] job_cycles,max_display_cycles,max_validate_cycles;
reg job_store;
assign timing_dbg={max_display_cycles,max_validate_cycles};
wire job_active=(st==S_AR)||(st==S_R)||(st==S_UNPK)||(st==S_DRAIN);
always @(posedge axi_clk or negedge axi_rstn)begin
 if(!axi_rstn)begin job_cycles<=0;max_display_cycles<=0;max_validate_cycles<=0;job_store<=0;end
 else if(job_active)begin
  job_store<=t_store;
  if(job_cycles!=16'hffff)job_cycles<=job_cycles+1'b1;
 end else begin
  if(job_store && job_cycles>max_display_cycles)max_display_cycles<=job_cycles;
  if(!job_store && job_cycles>max_validate_cycles)max_validate_cycles<=job_cycles;
  job_cycles<=0;
 end
end


// 突发长度计算：min(16, 行内剩余 beat, 到 4KB 边界的 beat 数)
wire [12:0] bytes_to_4k = 13'h1000 - {1'b0, burst_addr[11:0]};
wire [15:0] beats_4k    = {3'd0, bytes_to_4k[12:4]};        // 16B 对齐时 1..256
wire [15:0] beats_rem   = beats_total - beats_done;
// A16.4: background validation yields after a short completed burst.
// Display bursts retain 128 beats to amortize RAW arbitration overhead.
wire [15:0] burst_cap = t_store ? MAX_BURST_BEATS : ((MAX_BURST_BEATS < 32) ? MAX_BURST_BEATS : 32);
wire [15:0] blen_a = (beats_rem < burst_cap) ? beats_rem : burst_cap;
wire [15:0] burst_len_c = (blen_a < beats_4k) ? blen_a : beats_4k;

wire [47:0] disp_line_off = disp_line * act_stride;
wire [47:0] val_line_off  = val_line  * cand_stride;
wire [63:0] pend_end = {32'd0,pend_base} + (pend_h-16'd1)*{32'd0,pend_stride}
                        + ((({48'd0,pend_w}+3)>>2)<<4);
wire pend_ok = pend_w!=0 && pend_h!=0 && pend_w<=(1<<AW) &&
               pend_w<=DISP_W && pend_h<=DISP_H && pend_base[3:0]==0 &&
               pend_stride[3:0]==0 && pend_stride>=(((pend_w+32'd3)>>2)<<4) &&
               pend_end<=64'h100000000;

always @(posedge axi_clk or negedge axi_rstn) begin
    if (!axi_rstn) begin
        pend_valid <= 1'b0;
        pend_id <= 32'd0; pend_base <= 32'd0; pend_stride <= 32'd0;
        pend_w  <= 16'd0; pend_h    <= 16'd0;
        cand_valid <= 1'b0;
        cand_id <= 32'd0; cand_base <= 32'd0; cand_stride <= 32'd0;
        cand_w  <= 16'd0; cand_h    <= 16'd0; val_line <= 16'd0; val_beats <= 16'd0;
        act_valid <= 1'b0;
        act_id <= 32'd0; act_base <= 32'd0; act_stride <= 32'd0;
        act_w  <= 16'd0; act_h    <= 16'd0;
        disp_line <= 16'd0; wr_sel <= 1'b0; disp_sw_seen <= 1'b0;
        pub_valid <= 1'b0; pub_tgl <= 1'b0;
        pub_id <= 32'd0; pub_width <= 16'd0; pub_height <= 16'd0;
        st <= S_IDLE;
        t_store <= 1'b0; t_slot <= 1'b0; t_line <= 16'd0; t_h <= 16'd0;
        beats_total <= 16'd0; beats_done <= 16'd0;
        burst_addr <= 32'd0; burst_cnt <= 8'd0;
        burst_last <= 1'b0; skip_write <= 1'b0;
        beat_hold <= 128'd0; unpk_base <= {AW{1'b0}}; unpk_cnt <= 2'd0;
        line_bad <= 1'b0; wdog <= 32'd0; rel_then_switch <= 1'b0;
        m_axi_araddr <= 32'd0; m_axi_arlen <= 8'd0; m_axi_arvalid <= 1'b0;
        lb_we <= 1'b0; lb_wslot <= 1'b0; lb_waddr <= {AW{1'b0}}; lb_wdata <= 24'd0;
        wr_tgl0 <= 1'b0; wr_tgl1 <= 1'b0;
        slot_line0 <= 16'd0; slot_line1 <= 16'd0;
        slot_fid0  <= 32'd0;  slot_fid1  <= 32'd0;
        release_valid <= 1'b0; release_frame_id <= 32'd0;
        frm_err <= 1'b0; act_id_dbg <= 32'd0;
    end else begin
        lb_we <= 1'b0;                          // 缺省不写行缓存

        // 帧描述接收（pend 深度 1，frame_ready=!pend_valid）
        if (frame_valid && frame_ready) begin
            pend_valid  <= 1'b1;
            pend_id     <= frame_id;
            pend_base   <= frame_base;
            pend_stride <= frame_stride_bytes;
            pend_w      <= frame_width;
            pend_h      <= frame_height;
        end

        case (st)
        // ------------------------------------------------------------------
        S_IDLE: begin
            if (disp_sw_sync[1] != disp_sw_seen && pub_valid) begin
                // 显示侧已切到发布帧。本模块单 outstanding 且处于行间隙，
                // 旧帧读事务已全部完成（draining 完）→ 归还旧帧再换 act
                if (act_valid) begin
                    release_valid    <= 1'b1;
                    release_frame_id <= act_id;
                    rel_then_switch  <= 1'b1;
                    st               <= S_REL;
                end else begin
                    act_id       <= pub_id;
                    act_base     <= cand_base;   // pub 帧的 base/stride 留在 cand
                    act_stride   <= cand_stride;
                    act_w        <= pub_width;
                    act_h        <= pub_height;
                    act_valid    <= 1'b1;
                    act_id_dbg   <= pub_id;
                    pub_valid    <= 1'b0;
                    disp_line    <= 16'd0;
                    disp_sw_seen <= disp_sw_sync[1];
                end
            end else if (act_valid && slot_free_sel) begin
                // 显示取数（优先）：目标槽空闲才发 AR（信用节流）
                t_store     <= 1'b1;
                t_slot      <= wr_sel;
                t_line      <= disp_line;
                t_h         <= act_h;
                beats_total <= (act_w + 16'd3) >> 2;
                beats_done  <= 16'd0;
                burst_addr  <= act_base + disp_line_off[31:0];
                line_bad    <= 1'b0;
                st          <= S_AR;
            end else if (cand_valid && !validation_pause_sync[1]) begin
                // 验证空读（不收数，只校验 R 通道协议）
                t_store     <= 1'b0;
                t_slot      <= 1'b0;
                t_line      <= val_line;
                t_h         <= cand_h;
                beats_total <= (cand_w + 16'd3) >> 2;
                beats_done  <= val_beats;
                burst_addr  <= cand_base + val_line_off[31:0] + {12'd0,val_beats,4'd0};
                line_bad    <= 1'b0;
                st          <= S_AR;
            end else if (pend_valid && !pub_valid && !cand_valid) begin
                // 提升 pend → cand（已有未消费发布帧时排队，保证 cand 内容
                // 在切帧前不被覆盖）
                cand_valid  <= pend_ok;
                cand_id     <= pend_id;
                cand_base   <= pend_base;
                cand_stride <= pend_stride;
                cand_w      <= pend_w;
                cand_h      <= pend_h;
                val_line    <= 16'd0;
                val_beats   <= 16'd0;
                pend_valid  <= 1'b0;
                if (!pend_ok) begin
                    frm_err <= 1'b1;
                    release_valid <= 1'b1;
                    release_frame_id <= pend_id;
                    rel_then_switch <= 1'b0;
                    st <= S_REL;
                end
            end
        end
        // ------------------------------------------------------------------
        S_AR: begin
            if (!m_axi_arvalid) begin
                m_axi_araddr  <= burst_addr;
                m_axi_arlen   <= burst_len_c[7:0] - 8'd1;
                m_axi_arvalid <= 1'b1;
            end else if (m_axi_arready) begin
                m_axi_arvalid <= 1'b0;
                burst_cnt     <= 8'd0;
                wdog          <= 32'd0;
                st            <= S_R;
            end
        end
        // ------------------------------------------------------------------
        S_R: begin
            if (m_axi_rvalid) begin
                wdog <= 32'd0;
                if (burst_cnt > m_axi_arlen) begin
                    // RLAST 缺席后的多余 beat：只排空，等真实 RLAST 再释放。
                    line_bad   <= 1'b1;
                    burst_last <= 1'b1;
                    skip_write <= 1'b1;
                    unpk_cnt   <= 2'd3;
                    frm_err    <= 1'b1;
                    st         <= m_axi_rlast ? S_FAULT_END : S_DRAIN;
                end else begin
                    if (m_axi_rresp != 2'b00 || m_axi_rid != ARID) line_bad <= 1'b1;
                    if (m_axi_rlast != (burst_cnt == m_axi_arlen)) line_bad <= 1'b1;
                    beat_hold  <= m_axi_rdata;
                    unpk_base <= {beats_done[AW-3:0], 2'b00};    // beat 序号×4
                    skip_write <= 1'b0;
                    burst_last <= m_axi_rlast;                   // 提前 rlast 也算突发尾
                    burst_cnt  <= burst_cnt + 8'd1;
                    beats_done <= beats_done + 16'd1;
                    unpk_cnt   <= t_store ? 2'd0 : 2'd3;         // 验证模式不展开
                    st         <= S_UNPK;
                end
            end else if (wdog >= R_WDOG[31:0]) begin
                // Timeout does not cancel AXI: retain frame and drain late data.
                line_bad   <= 1'b1;
                burst_last <= 1'b1;
                skip_write <= 1'b1;
                unpk_cnt   <= 2'd3;
                frm_err    <= 1'b1;
                st         <= S_DRAIN;
            end else begin
                wdog <= wdog + 32'd1;
            end
        end
        // ------------------------------------------------------------------
        S_UNPK: begin
            // 32bit 像素字 {R,G,B,8'h00}（bit[7:0]=00 填充）→ 24bit {R,G,B}
            // = beat[32n+31:32n+8]；unpk_base+n < 2**AW 恒成立（见模块头约束）
            if (t_store && !skip_write) begin
                lb_we    <= 1'b1;
                lb_wslot <= t_slot;
                lb_waddr <= unpk_base + {{(AW-2){1'b0}}, unpk_cnt};
                lb_wdata <= beat_hold[32*unpk_cnt + 8 +: 24];
            end
            if (unpk_cnt == 2'd3) begin
                if (burst_last) begin
                    if (line_bad || beats_done >= beats_total) begin
                        // 行结束（好行到尾 / 坏行提前中止）
                        if (line_bad) begin
                            frm_err <= 1'b1;
                            if (t_store) begin
                                // 显示取数行作废：槽不发布（wr_tgl 不动 →
                                // 槽仍算空闲），跳到下一行，显示侧该行欠载品红
                                disp_line <= (disp_line == act_h - 16'd1) ?
                                             16'd0 : disp_line + 16'd1;
                                st <= S_IDLE;
                            end else begin
                                // 验证失败：帧作废不发布，归还该帧
                                cand_valid       <= 1'b0;
                                release_valid    <= 1'b1;
                                release_frame_id <= cand_id;
                                rel_then_switch  <= 1'b0;
                                st               <= S_REL;
                            end
                        end else if (t_store) begin
                            // 好行：发布槽位（toggle + 准静态行号/帧号低8位）
                            if (t_slot == 1'b0) begin
                                slot_line0 <= disp_line;
                                slot_fid0  <= act_id;
                                wr_tgl0    <= ~wr_tgl0;
                            end else begin
                                slot_line1 <= disp_line;
                                slot_fid1  <= act_id;
                                wr_tgl1    <= ~wr_tgl1;
                            end
                            wr_sel    <= ~wr_sel;
                            disp_line <= (disp_line == act_h - 16'd1) ?
                                         16'd0 : disp_line + 16'd1;
                            st <= S_IDLE;
                        end else if (t_line == t_h - 16'd1) begin
                            // 全帧验证通过 → 发布（新好帧接管，清 sticky 错误）
                            pub_id     <= cand_id;
                            pub_width  <= cand_w;
                            pub_height <= cand_h;
                            pub_tgl    <= ~pub_tgl;
                            pub_valid  <= 1'b1;
                            cand_valid <= 1'b0;
                            frm_err    <= 1'b0;
                            st         <= S_IDLE;
                        end else begin
                            val_line <= t_line + 16'd1;
                            val_beats <= 16'd0;
                            st       <= S_IDLE;
                        end
                    end else begin
                        if (!t_store) begin
                            // Only yield after accepted RLAST: no AXI cancellation.
                            // Resume at the next unverified beat, not at line start.
                            val_beats <= beats_done;
                            st <= S_IDLE;
                        end else begin
                            burst_addr <= burst_addr + {20'd0, m_axi_arlen, 4'b0000}
                                          + 32'd16;
                            st <= S_AR;
                        end
                    end
                end else begin
                    if(t_store && m_axi_rvalid) begin
                        wdog <= 32'd0;
                        if(burst_cnt > m_axi_arlen) begin
                            line_bad <= 1'b1;
                            burst_last <= 1'b1;
                            skip_write <= 1'b1;
                            frm_err <= 1'b1;
                            st <= m_axi_rlast ? S_FAULT_END : S_DRAIN;
                        end else begin
                            if(m_axi_rresp != 2'b00 || m_axi_rid != ARID)
                                line_bad <= 1'b1;
                            if(m_axi_rlast != (burst_cnt == m_axi_arlen))
                                line_bad <= 1'b1;
                            beat_hold <= m_axi_rdata;
                            unpk_base <= {beats_done[AW-3:0],2'b00};
                            skip_write <= 1'b0;
                            burst_last <= m_axi_rlast;
                            burst_cnt <= burst_cnt + 8'd1;
                            beats_done <= beats_done + 16'd1;
                            // unpk_cnt wraps to zero below; remain in S_UNPK.
                        end
                    end else st <= S_R;
                end
            end
            unpk_cnt <= unpk_cnt + 2'd1;
        end
        // ------------------------------------------------------------------
        S_DRAIN: begin
            if (m_axi_rvalid && m_axi_rlast) st <= S_FAULT_END;
        end
        S_FAULT_END: begin
            if (t_store) begin
                disp_line <= (disp_line == act_h - 16'd1) ? 16'd0 : disp_line + 16'd1;
                st <= S_IDLE;
            end else begin
                cand_valid <= 1'b0;
                release_valid <= 1'b1;
                release_frame_id <= cand_id;
                rel_then_switch <= 1'b0;
                st <= S_REL;
            end
        end
        S_REL: begin
            // release_valid 保持到握手成功
            if (release_ready) begin
                release_valid <= 1'b0;
                if (rel_then_switch) begin
                    act_id       <= pub_id;
                    act_base     <= cand_base;
                    act_stride   <= cand_stride;
                    act_w        <= pub_width;
                    act_h        <= pub_height;
                    act_valid    <= 1'b1;
                    act_id_dbg   <= pub_id;
                    pub_valid    <= 1'b0;
                    disp_line    <= 16'd0;
                    disp_sw_seen <= disp_sw_sync[1];
                end
                st <= S_IDLE;
            end
        end
        default: st <= S_IDLE;
        endcase
    end
end

endmodule
