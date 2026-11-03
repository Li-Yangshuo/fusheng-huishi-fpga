//==============================================================================
// nst_accel_top.v — 实时绘画风格化加速器 顶层（队员B v3-tile）
//
//   clk_c   : 计算核时钟（目标 100MHz，与 A 线 PLL 一致）
//   clk_axi : AXI/APB 时钟（100MHz）
//
//   v3 架构：特征平面 / accbank 全部放 DDR 工作区(work_base)，
//     片上只留 tile 行组缓存 + skid/FIFO（nst_pmem）。
//     APB 写 CTRL.go -> seq 逐层：层启动热加载本层权重(style->wrom 512 深)
//     后 tile【阶段1】行组填充+卷积+sum/sumsq，acc 流式写 DDR，
//     wait 等 RISC-V 写 Aq/Cq/Rq(Tzq) -> tile【阶段2】预取+Q33 仿射+
//     ReLU/add/PWL-tanh，dst 流式写 DDR；L11 经 OUT 行打包写回 out_base+IRQ。
//
//   all_done 三方汇合：seq.done(clk_c 脉冲) 且 pmem.out_done(clk_c 电平)
//     且 axi_eng.eng_idle(aclk)，缺一不可（避免最后 OUT burst 未完成即报完成）。
//==============================================================================
`timescale 1ns/1ps
module nst_accel_top #(
    parameter H0 = 256, W0 = 256,
    parameter STYLE_WORDS = 512,           // wrom 层内缓存深度（最大层 288 字）
    parameter WROM_AW = 9,
    parameter NE = 4,                      // 引擎数（B2 综合参数化用）
    parameter NL = 8,
    parameter AXI_MAX_BURST_BEATS = 8,
    parameter TILE_R=2
)(
    input  wire        clk_c,
    input  wire        clk_axi,
    input  wire        rst_n,

    //---------------- APB3 ----------------
    input  wire [15:0] paddr,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] pwdata,
    output wire        pready,
    output wire [31:0] prdata,
    output wire        pslverr,
    output wire        irq,

    //---------------- AXI4 Master --------
    output wire [3:0]  m_axi_awid,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awvalid,
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
    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [3:0]  m_axi_rid,
    input  wire [127:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    //---------------- 仿真调试口 ----------
    output wire        dbg_layer_pulse,
    output wire [3:0]  dbg_layer,
    output wire [2:0]  dbg_dst,
    output wire [31:0] monitor_frame_count,
    output wire monitor_busy,
    output wire        frame_done,
    output wire [7:0]  axi_fault
);
    //================================================================= 复位
    reg [1:0] rsync = 2'b00;
    always @(posedge clk_c or negedge rst_n)
        if (!rst_n) rsync <= 2'b00;
        else        rsync <= {rsync[0], 1'b1};
    wire srst_c = ~rsync[1];

    //================================================================= APB
    wire        go_pulse, sw_rst;
    wire [31:0] style_base, in_base, out_base, work_base;
    wire        in_buf_sel;
    wire [31:0] out_stride;
    wire        out_buf;
    wire        irq_en;
    wire [31:0] frame_cnt;
    wire        seq_busy;
    wire        eng_idle;

    wire [6:0] stat_idx; wire [63:0] stat_word;
    wire [4159:0] cf_flat;
    wire          seq_wait;
    wire          cv_pulse;
    reg           core_done_a;        // all_done 汇合脉冲（赋值在文件尾部）

    // ROM 初始化写口（pclk→clk_c toggle 握手）
    wire [1:0]   rom_sel;
    wire [9:0]   rom_idx;
    wire [63:0]  rom_wdata;
    wire         rom_tog;

    // busy：计算核运行 或 AXI 引擎有在途/待执行命令（含权重加载）
    reg busy_s1, busy_s2;
    always @(posedge clk_axi) begin
        busy_s1 <= seq_busy; busy_s2 <= busy_s1;
    end
    wire core_busy_a = busy_s2 | ~eng_idle;
    assign monitor_frame_count=frame_cnt;
    assign monitor_busy=core_busy_a;

    wire cf_write,coef_read,coef_tanh;
    wire [6:0] cf_widx;wire [5:0] coef_channel;
    wire [63:0] cf_wdata;
    wire signed [63:0] coef_a,coef_c,coef_r;
    nst_coef_store u_coefficients(.wclk(clk_axi),.wrst_n(rst_n),.wren(cf_write),
      .widx(cf_widx),.wdata(cf_wdata),.rclk(clk_c),.rrst_n(~srst_c),
      .ren(coef_read),.channel(coef_channel),.tanh_mode(coef_tanh),.a(coef_a),.c(coef_c),.r(coef_r));
    wire [31:0] diag_seq,diag_pmem,diag_engine,diag_flags;
    // Debug only: two sampling stages for slow UART inspection. Multi-bit
    // snapshots may tear while active; repeat reads at a halted point. These
    // values never control arithmetic, handshakes, reset or frame completion.
    reg [31:0] ds1,ds2,dp1,dp2,df1,df2;
    always @(posedge clk_axi or negedge rst_n)
     if(!rst_n)begin ds1<=0;ds2<=0;dp1<=0;dp2<=0;df1<=0;df2<=0;end
     else begin ds1<=diag_seq;ds2<=ds1;dp1<=diag_pmem;dp2<=dp1;df1<=diag_flags;df2<=df1;end
    wire [31:0] dc_counts,dc_totals,dc_cmd,dc_phase1,dc_geometry;
    wire [31:0] dc_ptrs,dc_chunk;wire [5:0] ra_wp,ra_rp,ra_wc;
    reg [31:0] dc4a,dc4b,dc5a,dc5b,dc6a,dc6b,dc7a,dc7b,dc8a,dc8b,dc9a,dc9b;
    reg dbg_epoch;reg [2:0] dbg_epoch_sync;reg [15:0] dbg_received;
    nst_apb u_apb (
        .pclk(clk_axi), .presetn(rst_n),
        .paddr(paddr), .psel(psel), .penable(penable), .pwrite(pwrite),
        .pwdata(pwdata), .pready(pready), .prdata(prdata), .pslverr(pslverr),
        .go_pulse(go_pulse), .sw_rst(sw_rst),
        .style_base(style_base), .in_base(in_base), .out_base(out_base),
        .work_base(work_base),
        .in_buf_sel(in_buf_sel), .out_stride(out_stride), .out_buf(out_buf),
        .irq_en(irq_en), .irq(irq),
        .core_busy(core_busy_a),
        .core_done(core_done_a),
        .frame_cnt(frame_cnt),
        .stat_idx(stat_idx), .stat_word(stat_word), .wait_c(seq_wait),
        .diag0(ds2),.diag1(dp2),.diag2(diag_engine),.diag3(df2),.diag4(dc4b),.diag5(dc5b),.diag6(dc6b),.diag7(dc7b),.diag8(dc8b),.diag9(dc9b),
        .cv_pulse(cv_pulse), .cf_flat(cf_flat),
        .rom_sel(rom_sel), .rom_idx(rom_idx),
        .rom_wdata(rom_wdata), .rom_tog(rom_tog),.cf_write(cf_write),.cf_widx(cf_widx),.cf_wdata(cf_wdata)
    );

    //================================================================= 跨域脉冲
    // go_pulse(aclk 1 拍) -> clk_c：toggle 同步，边沿即 fstart_c
    reg go_tog;
    always @(posedge clk_axi or negedge rst_n)
        if (!rst_n)       go_tog <= 1'b0;
        else if (go_pulse) go_tog <= ~go_tog;
    reg [2:0] go_sync;
    always @(posedge clk_c) go_sync <= {go_sync[1:0], go_tog};
    wire fstart_c = go_sync[2] ^ go_sync[1];

    // coef_go：aclk 脉冲 -> clk_c（go 时清 toggle，避免遗留边沿）
    reg cv_tog;
    always @(posedge clk_axi or negedge rst_n)
        if (!rst_n)              cv_tog <= 1'b0;
        else if (go_pulse)       cv_tog <= 1'b0;
        else if (cv_pulse)       cv_tog <= ~cv_tog;
    reg [2:0] cv_sync;
    always @(posedge clk_c) cv_sync <= {cv_sync[1:0], cv_tog};
    wire cv_go = cv_sync[2] ^ cv_sync[1];

    // ROM init 写：aclk toggle -> clk_c 边沿脉冲（boot 时 core idle，握手安全）
    reg [2:0] rom_sync;
    always @(posedge clk_c or negedge rst_n)
        if (!rst_n) rom_sync <= 3'b0;
        else        rom_sync <= {rom_sync[1:0], rom_tog};
    wire rom_we_c = rom_sync[2] ^ rom_sync[1];

    //================================================================= pmem
    wire         lay_start;
    wire [2:0]   lb_src, lb_skip, lb_dst;
    wire [5:0]   lb_ic, lb_oc;
    wire [9:0]   lb_oh;
    wire [10:0]  lb_ow;
    wire         lb_s2, lb_up;
    wire [11:0]  lb_wbase;
    wire [9:0]   lb_wcnt;
    wire         wld_done;
    wire         p1_req, p1_rdy, p2_req, p2_rdy;
    wire [9:0]   g_y;
    wire [10:0]  g_x;
    wire [5:0]   g_c;
    wire [1:0]   g_ki, g_kj;
    wire         g_vld;
    wire [7:0]   g_q;
    wire         sk_rd;
    wire [7:0]   sk_q;
    wire         sk_rdy;
    wire         dw_we;
    wire [7:0]   dw_data;
    wire         dw_rdy;
    wire         ab_we, ab_wrdy, ab_re, ab_rdy;
    wire signed [31:0] ab_wdata, ab_rdata;
    wire         of_wr;
    wire [127:0] of_d;
    wire         of_full;
    wire         cmd_we, cmd_full;
    wire [48:0]  cmd_wdata;
    wire [127:0] rS_d, rA_d, rB_d;
    wire         rS_empty, rA_empty, rB_empty;
    wire         rS_re, rA_re, rB_re;
    wire         w_we, w_full;
    wire [127:0] w_d;
    wire         out_done, fill_busy;

    nst_pmem #(.W0(W0), .H0(H0), .TILE_R(TILE_R), .LOOKAHEAD(1)) u_pmem (
        .clk(clk_c), .srst(srst_c),
        .in_base_w(in_base), .out_base_w(out_base), .out_stride_w(out_stride),
        .work_base_w(work_base), .style_base_w(style_base),
        .in_buf_sel_w(in_buf_sel), .fstart(fstart_c),
        .lay_start(lay_start),
        .lb_src(lb_src), .lb_skip(lb_skip), .lb_dst(lb_dst),
        .lb_ic(lb_ic), .lb_oc(lb_oc), .lb_oh(lb_oh), .lb_ow(lb_ow),
        .lb_s2(lb_s2), .lb_up(lb_up),
        .lb_wbase(lb_wbase), .lb_wcnt(lb_wcnt),
        .p1_req(p1_req), .p1_rdy(p1_rdy),
        .p2_req(p2_req), .p2_rdy(p2_rdy),
        .gy(g_y), .gx(g_x), .gc(g_c), .gki(g_ki), .gkj(g_kj),
        .g_vld(g_vld), .gq(g_q),
        .sk_rd(sk_rd), .skq(sk_q), .sk_rdy(sk_rdy),
        .dw_we(dw_we), .dw_data(dw_data), .dw_rdy(dw_rdy),
        .ab_we(ab_we), .ab_wdata(ab_wdata), .ab_wrdy(ab_wrdy),
        .ab_re(ab_re), .ab_rdata(ab_rdata), .ab_rdy(ab_rdy),
        .of_wr(of_wr), .of_d(of_d), .of_full(of_full),
        .cmd_we(cmd_we), .cmd_wdata(cmd_wdata), .cmd_full(cmd_full),
        .rA_d(rA_d), .rA_empty(rA_empty), .rA_re(rA_re),
        .rB_d(rB_d), .rB_empty(rB_empty), .rB_re(rB_re),
        .w_we(w_we), .w_d(w_d), .w_full(w_full),
        .out_done(out_done), .fill_busy(fill_busy),.diag_pmem(diag_pmem),.diag_counts(dc_counts),.diag_totals(dc_totals),.diag_commands(dc_cmd),.diag_phase1(dc_phase1),.diag_geometry(dc_geometry),.diag_chunk(dc_chunk),
        .eng_idle(eng_idle)
    );

    //================================================================= 跨域 FIFO（FWFT）
    // 命令队列 clk_c -> aclk
    wire        cmd_re, cmd_rempty;
    wire [48:0] cmd_rdata;
    nst_cdc_fwft #(.DW(49), .AW(4)) u_cmdq (
        .wclk(clk_c), .wrst_n(~srst_c),
        .wren(cmd_we), .wdata(cmd_wdata), .wfull(cmd_full),
        .rclk(clk_axi), .rrst_n(rst_n),
        .rden(cmd_re), .rdata(cmd_rdata), .rempty(cmd_rempty)
    );
    // plane 写数据流 clk_c -> aclk
    wire        wf_re, wf_rempty;
    wire [127:0] wf_rdata;
    nst_cdc_fwft #(.DW(128), .AW(5)) u_wf (
        .wclk(clk_c), .wrst_n(~srst_c),
        .wren(w_we), .wdata(w_d), .wfull(w_full),
        .rclk(clk_axi), .rrst_n(rst_n),
        .rden(wf_re), .rdata(wf_rdata), .rempty(wf_rempty)
    );
    // OUT 写数据流 clk_c -> aclk
    wire        cof_re, cof_rempty;
    wire [127:0] cof_rdata;
    nst_cdc_fwft #(.DW(128), .AW(4)) u_cof (
        .wclk(clk_c), .wrst_n(~srst_c),
        .wren(of_wr), .wdata(of_d), .wfull(of_full),
        .rclk(clk_axi), .rrst_n(rst_n),
        .rden(cof_re), .rdata(cof_rdata), .rempty(cof_rempty)
    );
    // This experiment REQUIRES clk_c and clk_axi to be the same net.
    // Three independent logical queues, one AXI writer, one shared RAM read port.
    wire s_we, s_full, a_we, a_full, b_we, b_full;
    wire [127:0] s_wdata, a_wdata, b_wdata;
    nst_shared_readq u_readq (
        .clk(clk_axi), .rst_n(rst_n & ~srst_c),
        .we({b_we,a_we,s_we}), .wd({b_wdata,a_wdata,s_wdata}),
        .full({b_full,a_full,s_full}),
        .pop({rB_re,rA_re,rS_re}), .rd({rB_d,rA_d,rS_d}),
        .empty({rB_empty,rA_empty,rS_empty}),
        .a_wp(ra_wp), .a_rp(ra_rp), .a_wc(ra_wc)
    );

    //================================================================= AXI 命令引擎
    nst_axi_eng #(.MAX_BURST_BEATS(AXI_MAX_BURST_BEATS)) u_eng (
        .aclk(clk_axi), .aresetn(rst_n & ~sw_rst),
        .cmd_rempty(cmd_rempty), .cmd_rdata(cmd_rdata), .cmd_re(cmd_re),
        .s_we(s_we), .s_wdata(s_wdata), .s_full(s_full),
        .a_we(a_we), .a_wdata(a_wdata), .a_full(a_full),
        .b_we(b_we), .b_wdata(b_wdata), .b_full(b_full),
        .wf_re(wf_re), .wf_rdata(wf_rdata), .wf_rempty(wf_rempty),
        .of_re(cof_re), .of_rdata(cof_rdata), .of_rempty(cof_rempty),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
        .eng_idle(eng_idle), .fault(axi_fault),.diag_engine(diag_engine)
    );

    //================================================================= style 加载桥（clk_c）
    //   wrom 为 512 深层内缓存：pmem 在每层 lay_start 后发本层 style 读命令
    //   （lb_wcnt 字 = 2*lb_wcnt beat），rS FWFT 连续 2 beat 拼 256bit（beat0
    //   缓存，beat1 降序写 wrom，byte0 在 [255:248]）。wld_done=本层数满。
    reg          s_ph;                     // 0=待 beat0，1=待 beat1
    reg [9:0]    widx;
    reg [127:0]  wpack0;
    reg          wram_we;
    reg [WROM_AW-1:0] wram_addr;
    reg [255:0]  wram_wdata;

    wire [127:0] rS_rev;
    genvar b;
    generate for (b = 0; b < 16; b = b + 1) begin : gen_rS_rev
        assign rS_rev[127-8*b -: 8] = rS_d[8*b +: 8];
    end endgenerate

    // 仅在本层 style 数据在途时弹出（层间 widx==lb_wcnt，隔离 stale 数据）
    wire ld_act  = (widx != lb_wcnt);
    wire pop0 = ld_act && (s_ph == 1'b0) && !rS_empty;
    wire pop1 = ld_act && (s_ph == 1'b1) && !rS_empty;
    assign rS_re = pop0 | pop1;
    assign wld_done = (widx == lb_wcnt);

    always @(posedge clk_c) begin
        if (srst_c) begin
            s_ph <= 1'b0; widx <= 0; wpack0 <= 0;
            wram_we <= 1'b0; wram_addr <= 0; wram_wdata <= 0;
        end else if (lay_start) begin
            s_ph <= 1'b0; widx <= 0;            // 层启动清计数（本层权重重载）
            wram_we <= 1'b0;
        end else begin
            wram_we <= 1'b0;
            if (pop0) begin
                wpack0 <= rS_rev;
                s_ph   <= 1'b1;
            end else if (pop1) begin
                wram_we    <= 1'b1;
                wram_addr  <= widx[WROM_AW-1:0];
                wram_wdata <= {wpack0, rS_rev};
                widx  <= widx + 1'b1;
                s_ph  <= 1'b0;
            end
        end
    end

    //================================================================= 计算核
    wire [7:0]  eng_a;
    wire        eng_aus;
    wire [255:0] eng_w;
    wire        eng_en, eng_clr;
    wire [1:0]  eng_ae;
    wire [2:0]  eng_ao;
    wire signed [31:0] eng_acc;
    wire        seq_done;

    nst_engine #(.NE(NE), .NL(NL)) u_mac (
        .clk(clk_c), .srst(srst_c),
        .a(eng_a), .a_us(eng_aus), .w(eng_w), .en(eng_en), .clr(eng_clr),
        .ae(eng_ae), .ao(eng_ao), .acc_q(eng_acc)
    );

    nst_seq #(.WROM_AW(WROM_AW), .WROM_DEPTH(STYLE_WORDS), .H0(H0), .W0(W0), .TILE_R(TILE_R), .LOOKAHEAD(1)) u_seq (
        .clk(clk_c), .srst(srst_c),
        .start(fstart_c), .done(seq_done),
        .layer_pulse(dbg_layer_pulse), .dbg_layer(dbg_layer), .dbg_dst(dbg_dst),
        .wait_o(seq_wait), .cv_go(cv_go),
        .stat_idx(stat_idx), .stat_word(stat_word), .cf_flat(cf_flat),
        .wram_we(wram_we), .wram_waddr(wram_addr), .wram_wdata(wram_wdata),
        .wld_done(wld_done),
        .rom_we(rom_we_c), .rom_sel(rom_sel), .rom_idx(rom_idx), .rom_wdata(rom_wdata),
        .lay_start(lay_start),
        .lb_src(lb_src), .lb_skip(lb_skip), .lb_dst(lb_dst),
        .lb_ic(lb_ic), .lb_oc(lb_oc), .lb_oh(lb_oh), .lb_ow(lb_ow),
        .lb_s2(lb_s2), .lb_up(lb_up),
        .lb_wbase(lb_wbase), .lb_wcnt(lb_wcnt),
        .p1_req(p1_req), .p1_rdy(p1_rdy),
        .p2_req(p2_req), .p2_rdy(p2_rdy),
        .g_y(g_y), .g_x(g_x), .g_c(g_c), .g_ki(g_ki), .g_kj(g_kj),
        .g_vld(g_vld), .g_q(g_q),
        .sk_rd(sk_rd), .sk_q(sk_q), .sk_rdy(sk_rdy),
        .dw_we(dw_we), .dw_data(dw_data), .dw_rdy(dw_rdy),
        .ab_we(ab_we), .ab_wdata(ab_wdata), .ab_wrdy(ab_wrdy),
        .ab_re(ab_re), .ab_rdata(ab_rdata), .ab_rdy(ab_rdy),
        .eng_a(eng_a), .eng_aus(eng_aus), .eng_w(eng_w),
        .eng_en(eng_en), .eng_clr(eng_clr),
        .eng_ae(eng_ae), .eng_ao(eng_ao), .eng_acc(eng_acc),
        .busy(seq_busy),.diag_seq(diag_seq),.coef_a(coef_a),.coef_c(coef_c),.coef_r(coef_r),
        .coef_read(coef_read),.coef_channel(coef_channel),.coef_tanh(coef_tanh)
    );

    //================================================================= all_done 三方汇合（aclk）
    // seq.done(clk_c 脉冲) -> aclk 边沿
    reg dn_tog;
    always @(posedge clk_c or negedge rst_n)
        if (!rst_n)      dn_tog <= 1'b0;
        else if (seq_done) dn_tog <= ~dn_tog;
    reg [2:0] dn_sync;
    always @(posedge clk_axi) dn_sync <= {dn_sync[1:0], dn_tog};
    wire sd_pulse = dn_sync[2] ^ dn_sync[1];

    // out_done(clk_c 电平) -> aclk 2FF
    reg od_s1, od_s2;
    always @(posedge clk_axi or negedge rst_n)
        if (!rst_n) begin od_s1 <= 1'b0; od_s2 <= 1'b0; end
        else         begin od_s1 <= out_done; od_s2 <= od_s1; end

    assign frame_done = core_done_a;
    reg dnd_pend;
    always @(posedge clk_axi or negedge rst_n) begin
        if (!rst_n) begin
            dnd_pend <= 1'b0; core_done_a <= 1'b0;
        end else begin
            core_done_a <= 1'b0;
            if (sd_pulse) begin
                if (od_s2 && eng_idle) core_done_a <= 1'b1;
                else                   dnd_pend <= 1'b1;
            end
            if (dnd_pend && od_s2 && eng_idle && !sd_pulse) begin
                core_done_a <= 1'b1;
                dnd_pend    <= 1'b0;
            end
        end
    end
    assign diag_flags={dw_rdy,ab_rdy,ab_re,w_we,of_wr,b_we,a_we,s_we,
      m_axi_bready,m_axi_bvalid,m_axi_wready,m_axi_wvalid,
      m_axi_awready,m_axi_awvalid,m_axi_rready,m_axi_rvalid,
      m_axi_arready,m_axi_arvalid,seq_wait,seq_busy,fill_busy,out_done,
      eng_idle,cof_rempty,of_full,wf_rempty,w_full,rB_empty,rA_empty,rS_empty,cmd_rempty,cmd_full};
    always @(posedge clk_c)begin
      if(srst_c)dbg_epoch<=0;else if(lay_start)dbg_epoch<=~dbg_epoch;
    end
    always @(posedge clk_axi or negedge rst_n)begin
      if(!rst_n)begin dbg_epoch_sync<=0;dbg_received<=0;end
      else begin
        dbg_epoch_sync<={dbg_epoch_sync[1:0],dbg_epoch};
        if(dbg_epoch_sync[2]!=dbg_epoch_sync[1])dbg_received<=0;
        else if(a_we)dbg_received<=dbg_received+16'd1;
      end
    end
    always @(posedge clk_axi or negedge rst_n)begin
      if(!rst_n)begin
        dc4a<=0;dc4b<=0;dc5a<=0;dc5b<=0;dc6a<=0;dc6b<=0;
        dc7a<=0;dc7b<=0;dc8a<=0;dc8b<=0;dc9a<=0;dc9b<=0;
      end else begin
        dc4a<=dc_counts;dc4b<=dc4a;dc5a<=dc_totals;dc5b<=dc5a;dc6a<=dc_ptrs;dc6b<=dc6a;
        dc7a<={dbg_received,dc_cmd[15:0]};dc7b<=dc7a;dc8a<=dc_phase1;dc8b<=dc8a;dc9a<=dc_geometry;dc9b<=dc9a;
      end
    end
    assign dc_ptrs={6'd0,dc_chunk[7:0],ra_wp,ra_rp,ra_wc};
endmodule
