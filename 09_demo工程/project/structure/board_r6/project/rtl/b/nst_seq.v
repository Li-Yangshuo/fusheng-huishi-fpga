//==============================================================================
// nst_seq.v — 层序列控制器（v3-tile：DDR 平面 + tile 行组 + IN 两阶段 + PWL tanh）
//
// 时钟域 clk_c。每层按 TILE_R 行分 tile，两阶段：
//   阶段1(卷积统计) 每 tile：TP1/TP1Q/TP1W(pmem 填源行组) -> PCLR->P0/P1(taps)
//                 ->OSH：acc[o]=Σ_t in*w+Bq[o]，顺序流写 DDR acc 区（ab_we
//                 受 ab_wrdy 停等），同时累加 ss[o]/ssq[o]（int64）。
//                 全层完成后 wait_o=1，等 RISC-V 经 APB 写系数并给 cv_go 脉冲。
//   系数拷贝(COPY) 65 项 Q33：coef_r=Rq(残差)，cfc[1+2o]=Aq，cfc[2+2o]=Cq；
//                 tanh 层 cfc[o]=Tzq（只用前 32 项）。
//   阶段2(仿射激活) 每 tile：TP2/TP2W(pmem 预取 acc+skip) -> A0->A1->A2(->A3)->A4，
//                 A0 受 ab_rdy/sk_rdy 停等，A4 受 dw_rdy 停等。
//     relu/add: num=acc*Aq+Cq+sext(res)*Rq; q=clamp(rhu_q(num), 0/255 或 -128/127)
//     tanh   : z=acc*Tzq, u=clip(rhu_q(z*Gq)), idx=floor(u/1024),
//              PWL 258 节点 Q12 线性插值 -> clamp(rhu12,0,255)
//
// 微码 seq_rom.mem（64bit）：
//   [11:0]woff [16]s2 [17]up [19:18]act(0relu/1add/2tanh) [20]ins(0u/1s)
//   [23:21]src [26:24]dst [29:27]skip(7=none) [37:30]ic [45:38]oc [46]res_sgn
//
// wrom：512 深层内缓存，每层 S_WLD 等 style 区热加载 ic*9 字；
//       每 tap 一个 256bit 字，lane o 权重在 [255-8o -:8]，waddr=tap。
//==============================================================================
`timescale 1ns/1ps
`ifndef NST_SIMDIR
 `define NST_SIMDIR "../simdata256/"
`endif

// AB05: AB10 one-tap convolution plus backpressured streaming affine/activation.
module nst_seq #(
    parameter WROM_AW    = 9,          // 地址位宽（512 深层内缓存，最大层 288 字）
    parameter WROM_DEPTH = 512,        // 物理深度（style 逐层热加载，非整网 2475）
    parameter H0         = 256,
    parameter W0         = 256,
    parameter LOOKAHEAD  = 0,          // internal paired-pmem address prefetch
    parameter TILE_R     = 4           // 每 tile 输出行数
)(
    input  wire         clk,
    input  wire        srst,
    input  wire        start,
    output reg         done,
    output reg         layer_pulse,
    output reg  [3:0]  dbg_layer,
    output reg  [2:0]  dbg_dst,

    //---- 两阶段握手（clk_c）----
    output reg         wait_o,         // 正等待 RISC-V 系数（电平）
    input  wire        cv_go,          // 系数已写好脉冲（top 自 APB 跨域）
    input wire [6:0] stat_idx,
    output wire [63:0] stat_word,    // {32×(sum64,sumsq64)} 顺序展平，等待期稳定
    input  wire [4159:0] cf_flat,      // 65×64 系数（APB 域，握手后稳定，COPY 拍拷贝）

    // ---- wrom 热加载写口（style FIFO 跨域后；降序 [255:0]：lane k 在 [255-8k -:8]）----
    input  wire        wram_we,
    input  wire [WROM_AW-1:0] wram_waddr,
    input  wire [255:0] wram_wdata,
    input  wire        wld_done,      // 本层权重字已全部写入 wrom（top 桥）

    // ---- APB ROM 初始化写口（boot 时 RISC-V 下发 srom/brom/pwl）----
    input  wire        rom_we,         // clk_c 域 1 拍脉冲（toggle 握手）
    input  wire [1:0]  rom_sel,        // 0=srom 1=brom 2=pwl
    input  wire [9:0]  rom_idx,        // 写索引
    input  wire [63:0] rom_wdata,      // {hi[31:0], lo[31:0]}

    // ---- 到 nst_pmem 的层配置（lay_start 拍采样）----
    output wire        lay_start,
    output reg  [2:0]  lb_src,
    output reg  [2:0]  lb_skip,
    output reg  [2:0]  lb_dst,
    output reg  [5:0]  lb_ic,
    output reg  [5:0]  lb_oc,
    output reg  [9:0]  lb_oh,
    output reg  [10:0] lb_ow,
    output reg         lb_s2,
    output reg         lb_up,
    output reg  [11:0] lb_wbase,       // 本层权重字偏移（style 区，字=32B）
    output reg  [9:0]  lb_wcnt,        // 本层权重字数 ic*9

    // ---- tile 握手 ----
    output wire        p1_req,         // 阶段1 填源行组请求（1 拍脉冲）
    input  wire        p1_rdy,         // 行组填充完成
    output wire        p2_req,         // 阶段2 acc/skip 预取请求（1 拍脉冲）
    input  wire        p2_rdy,         // 预取命令入队 + acc 排空完成

    // ---- 口A 取窗 ----
    output wire [9:0]  g_y,
    output wire [10:0] g_x,
    output wire [5:0]  g_c,
    output wire [1:0]  g_ki, g_kj,
    output wire        g_vld,
    input  wire [7:0]  g_q,

    // ---- skip 流（pmem，注册输出：A0 发读，A1 得 sk_q）----
    output wire        sk_rd,
    input  wire [7:0]  sk_q,
    input  wire        sk_rdy,

    // ---- dst 写流（pmem 纯字节流，无坐标）----
    output wire        dw_we,
    output wire [7:0]  dw_data,
    input  wire        dw_rdy,

    // ---- acc 流（pmem DDR acc 区，注册输出：A0 发读，A1 得 ab_rdata）----
    output wire         ab_we,
    output wire signed [31:0] ab_wdata,
    input  wire         ab_wrdy,
    output wire         ab_re,
    input  wire signed [31:0] ab_rdata,
    input  wire         ab_rdy,

    // ---- MAC 阵列 ----
    output wire [7:0]  eng_a,
    output wire        eng_aus,
    output wire [255:0] eng_w,
    output wire        eng_en,
    output wire        eng_clr,
    output wire [1:0]  eng_ae,
    output wire [2:0]  eng_ao,
    input  wire signed [31:0] eng_acc,

    input wire signed [63:0] coef_a,coef_c,coef_r,
    output wire coef_read,output wire [5:0] coef_channel,output wire coef_tanh,
    output wire [31:0] diag_seq,
    output wire        busy
);
    //================================================================= ROM
    reg [255:0] wrom [0:WROM_DEPTH-1];   // 512 深层内缓存，style 区逐层热加载
    reg [63:0]  srom [0:11];
    reg signed [31:0] brom [0:383];     // Bq: brom[L*32+o]
    reg [19:0]        pwl  [0:257];     // 258 节点 Q12（无符号，可达 255*4096）
`ifndef SYNTHESIS
    // synthesis translate_off
    initial begin
        $readmemh({`NST_SIMDIR, "wrom.mem"},   wrom);
        $readmemh({`NST_SIMDIR, "seq_rom.mem"}, srom);
        $readmemh({`NST_SIMDIR, "bias.mem"},    brom);
        $readmemh({`NST_SIMDIR, "pwl.mem"},     pwl);
    end
    // synthesis translate_on
`endif
    always @(posedge clk) if (wram_we) wrom[wram_waddr] <= wram_wdata;

    //---- APB ROM 初始化写口（srom/brom/pwl；板上 $readmemh 无效，靠 APB 下发）----
    always @(posedge clk) begin
        if (rom_we) begin
            case (rom_sel)
                2'd0: srom[rom_idx[3:0]]  <= rom_wdata;           // 12 项 64bit
                2'd1: brom[rom_idx[8:0]]  <= rom_wdata[31:0];      // 384 项 32bit
                2'd2: pwl[rom_idx[8:0]]   <= rom_wdata[19:0];       // 258 项 20bit（索引须 9bit，8bit 会在 256/257 回绕）
                default: ;
            endcase
        end
    end

    //================================================================= 微码
    reg [3:0] L;
    wire [63:0] mc = srom[L];
    wire [11:0] u_wbase = mc[11:0];
    wire        u_s2    = mc[16];
    wire        u_up    = mc[17];
    wire [1:0]  u_act   = mc[19:18];
    wire        u_ins   = mc[20];    // 0 unsigned / 1 signed
    wire [2:0]  u_src   = mc[23:21];
    wire [2:0]  u_dst   = mc[26:24];
    wire [2:0]  u_sksel = mc[29:27];
    wire [5:0]  u_ic    = mc[37:30];
    wire [5:0]  u_oc    = mc[45:38];
    wire        u_rsg   = mc[46];    // 残差字节 signed

    //================================================================= 几何/计数器
    reg [9:0]  oh;
    reg [10:0] ow;
    reg [9:0]  y;
    reg [10:0] x;
    reg [12:0] step;
    reg [5:0]  qo;          // oc 计数（OSH 写 acc / A 段仿射共用）
    reg [6:0]  ci;          // coef copy 计数
    reg [7:0]  trow;        // 阶段1 tile 计数
    reg [7:0]  t2row;       // 阶段2 tile 计数
    reg [9:0]  yend;        // 阶段1 当前 tile 末行（不含）
    reg [9:0]  t2end;       // 阶段2 当前 tile 末行（不含）

    localparam S_IDLE=5'd0, S_INIT=5'd1, S_PCLR=5'd2, S_P0=5'd3,
               S_P1=5'd4, S_OSH=5'd5, S_WAIT=5'd6, S_COPY=5'd7,
               S_A0=5'd8, S_A1=5'd9, S_A2=5'd10, S_A3=5'd11, S_A4=5'd12,
           S_TP1=5'd13, S_TP1Q=5'd14, S_TP1W=5'd15,
           S_TP2=5'd16, S_TP2W=5'd17, S_WLD=5'd18, S_A3B=5'd19, S_A1R=5'd20, S_STAT_DRAIN=5'd21;
    reg [4:0] st;
    assign diag_seq={L[3:0],st[4:0],qo[5:0],y[7:0],x[8:0]};
    localparam S_A3L=5'd22, S_A1M=5'd23;

    wire [12:0] acc_steps = {7'd0, u_ic} * 13'd18;
    wire [12:0] tap_idx = step >> 1;
    // A19.1: mixed-radix tap counters keep the exact existing two-cycle
    // P0/P1 schedule, without step -> /9 -> %9 -> /3 -> pmem addressing.
    reg [5:0] tap_channel;
    reg [1:0] tap_row, tap_column;
    wire [5:0] cc = tap_channel;
    // P1 lookahead uses the terminal flag captured in the preceding P0.
    // step does not change in P0: same tap address and same MAC schedule.
    // Cuts srom -> ic*18 -> compare -> next tap -> pmem address/DSP.
    (* syn_preserve=1 *) reg final_tap;
    always @(posedge clk) begin
        if(srst || st==S_PCLR) final_tap<=1'b0;
        else if(st==S_P0) final_tap<=(step==acc_steps-13'd2);
    end
    wire [1:0] next_column = final_tap ? 2'd0 : tap_column==2 ? 2'd0 : tap_column+2'd1;
    wire [1:0] next_row = final_tap ? 2'd0 : tap_column!=2 ? tap_row : tap_row==2 ? 2'd0 : tap_row+2'd1;
    wire [5:0] next_channel = final_tap ? 6'd0 : tap_column==2 && tap_row==2 ? tap_channel+6'd1 : tap_channel;
    // Coordinates during invalid P1 prepare the next P0; valid P0 is unchanged.
    wire prefetch_next = LOOKAHEAD && (st==S_P0 || st==S_P1);

    always @(posedge clk) begin
        if (srst || st == S_PCLR) begin
            tap_channel <= 0; tap_row <= 0; tap_column <= 0;
        end else if (st == S_P0 || st == S_P1) begin
            if (step == acc_steps - 13'd2) begin
                tap_channel <= 0; tap_row <= 0; tap_column <= 0;
            end else if (tap_column == 2) begin
                tap_column <= 0;
                if (tap_row == 2) begin tap_row <= 0; tap_channel <= tap_channel + 1'b1; end
                else tap_row <= tap_row + 1'b1;
            end else tap_column <= tap_column + 1'b1;
        end
    end
    // P0 primes tap0. During P1 consume the old registered pair while
    // fetching weight n+1; pmem uses the one-cycle-ahead coordinates already
    // registered in su_pre. The final P1 drains without issuing another read.
    wire [WROM_AW-1:0] waddr = (st==S_P1 && step!=acc_steps-13'd2)
        ? tap_idx[WROM_AW-1:0]+1'b1 : tap_idx[WROM_AW-1:0];   // 层内缓存偏移

    //================================================================= wrom
    reg [255:0] wd;
    always @(posedge clk) wd <= wrom[waddr];

    reg [255:0] w32;
    integer oi;
    always @(*)
        for (oi = 0; oi < 32; oi = oi + 1)
            w32[oi*8 +: 8] = wd[255-8*oi -: 8];

    //================================================================= 统计
    wire signed [31:0] bq_v  = $signed(brom[{L, qo[4:0]}]);
    wire signed [31:0] acc_v = eng_acc + bq_v;
    // A19.1: cut bias-add/square/64-bit-statistics feedback into two stages.
    // Each accepted OSH value is captured exactly once, including under skid stalls.
    reg stat_valid;
    reg [4:0] stat_channel;
    reg signed [31:0] stat_value;
    reg signed [63:0] stat_square;
    always @(posedge clk) begin
        if (srst) begin
            stat_valid <= 0; stat_channel <= 0; stat_value <= 0; stat_square <= 0;
        end else begin
            stat_valid <= ab_we;
            if (ab_we) begin
                stat_channel <= qo[4:0];
                stat_value <= acc_v;
                stat_square <= acc_v * acc_v;
            end
        end
    end
    // At most W0*H0 signed-int32 values are accumulated per channel.
    // 32+ceil(log2(N)) signed bits cover [-N*2^31, N*(2^31-1)].
    // Frozen network never produces a layer larger than its full input frame.
    localparam SUM_W=32+$clog2(W0*H0);
    wire statistics_busy;
    nst_stats_ram #(.SUM_W(SUM_W)) u_stats (
        .clk(clk), .srst(srst), .clear(st==S_INIT),
        .update(stat_valid), .channel(stat_channel),
        .value(stat_value), .square(stat_square),
        .query_idx(stat_idx), .query_word(stat_word), .busy(statistics_busy)
    );

    //================================================================= 系数（clk_c 拷贝）
    //================================================================= rhu（算术 round-half-up）
    // Q33 系数定点：四舍五入（负数向远离 0 方向进位）
    function signed [63:0] rhu_q;
        input signed [63:0] v;
        begin
            if (v >= 64'sd0) rhu_q = (v + 64'sd4294967296) >>> 33;
            else             rhu_q = -(((-v) + 64'sd4294967296) >>> 33);
        end
    endfunction
    function signed [63:0] rhu12;
        input signed [63:0] v;
        begin
            if (v >= 64'sd0) rhu12 = (v + 64'sd2048) >>> 12;
            else             rhu12 = -(((-v) + 64'sd2048) >>> 12);
        end
    endfunction

    //================================================================= 阶段1连线
    // ab_we 受 pmem skid 背压：停等拍统计/坐标同样停住（eng_acc 保持）
    assign ab_we    = (st == S_OSH) && ab_wrdy;
    assign ab_wdata = acc_v;

    assign busy     = (st != S_IDLE);
    assign eng_a    = g_q;
    assign eng_aus  = ~u_ins;
    assign eng_w    = w32;
    assign eng_en   = (st == S_P1);
    assign eng_clr  = (st == S_PCLR);
    assign eng_ae   = qo[4:3];
    assign eng_ao   = qo[2:0];

    assign g_y  = y;  assign g_x = x;  assign g_c = prefetch_next ? next_channel : cc;
    assign g_ki = prefetch_next ? next_row : tap_row;
    assign g_kj = prefetch_next ? next_column : tap_column;
    assign g_vld= (st == S_P0) || (st == S_P1 && step!=acc_steps-13'd2);

    //---- tile 握手 ----
    // S_TP1：lb_* 已在 S_INIT 更新，此拍让 pmem 采样新层几何（lay_start）
    assign lay_start = (st == S_TP1);
    // S_TP1Q：发填行组脉冲；S_TP1W 等 p1_rdy
    assign p1_req    = (st == S_TP1Q);
    assign p2_req    = (st == S_TP2);

    // AB05: in-order affine/activation pipeline, one byte per enabled clock.
    // pmem and coefficient RAM both register the operands on a0_fire.
    // A global clock enable freezes all stages AND their input reads on backpressure.
    // Layer/tile retirement is driven by accepted output, never by issued input.
    reg [7:0] av;
    reg [5:0] issue_q;
    reg [10:0] issue_x;
    reg [9:0] issue_y;
    reg issued_all;
    reg [7:0] sat7;
    wire affine_enable = !av[7] || dw_rdy;
    wire a0_fire = st==S_A0 && affine_enable && !issued_all && ab_rdy &&
                   (u_act!=2'd1 || sk_rdy);
    assign coef_read=a0_fire;
    assign ab_re=a0_fire;
    assign sk_rd=a0_fire && u_act==2'd1;
    assign coef_channel=issue_q;
    assign coef_tanh=u_act==2'd2;
    assign dw_we=st==S_A0 && av[7] && dw_rdy;
    assign dw_data=sat7;

    reg signed [31:0] acc1;
    (* syn_preserve=1 *) reg signed [63:0] mul1,add1,rcoef1;
    reg signed [8:0] skip1;
    reg signed [63:0] product2,residual2,add2,norm3,z3;
    reg signed [8:0] idx4;
    reg [9:0] frac4,frac5,frac6;
    reg [19:0] pw0_5,pw1_5,p0_6;
    reg signed [22:0] slope6;
    reg [7:0] sat4,sat5,sat6;
    wire [8:0] pwl_base=idx4+9'd129;
    localparam signed [63:0] G_Q=64'sd72704;

    always @(posedge clk) begin
        if (srst) begin
            issue_q<=0;issue_x<=0;issue_y<=0;issued_all<=1;
        end else if(st==S_TP2W && p2_rdy)begin
            issue_q<=0;issue_x<=0;
            issue_y<={2'd0,t2row}*TILE_R;issued_all<=0;
        end else if(a0_fire)begin
            if(issue_q==u_oc-6'd1)begin
                issue_q<=0;
                if(issue_x==ow-11'd1)begin
                    issue_x<=0;
                    if(issue_y==t2end-10'd1)issued_all<=1;
                    else issue_y<=issue_y+10'd1;
                end else issue_x<=issue_x+11'd1;
            end else issue_q<=issue_q+6'd1;
        end
    end

    always @(posedge clk) begin : AFFINE_PIPE
        reg signed [63:0] u,v;
        reg signed [33:0] prod,vf;
        if(srst || st!=S_A0) av<=0;
        else if(affine_enable)begin
            av<={av[6:0],a0_fire};
            if(av[0])begin
                acc1<=ab_rdata;mul1<=coef_a;add1<=coef_c;rcoef1<=coef_r;
                skip1<=u_act==2'd1 ? (u_rsg ? $signed({sk_q[7],sk_q}) : $signed({1'b0,sk_q})) : 9'sd0;
            end
            if(av[1])begin
                // Low 64 bits intentionally match the baseline modular arithmetic.
                product2<=acc1*mul1;residual2<=skip1*rcoef1;add2<=add1;
            end
            if(av[2])begin
                norm3<=product2+residual2+add2;
                z3<=product2*G_Q;
            end
            if(av[3])begin
                if(u_act==2'd2)begin
                    u=rhu_q(z3);
                    if(u>64'sd130048)u=64'sd130048;
                    if(u< -64'sd131072)u= -64'sd131072;
                    idx4<=u>>>10;frac4<=u[9:0];
                end else begin
                    v=rhu_q(norm3);
                    if(u_act==2'd0)begin
                        if(v>64'sd255)sat4<=8'd255;
                        else if(v<0)sat4<=0;else sat4<=v[7:0];
                    end else begin
                        if(v>64'sd127)sat4<=8'd127;
                        else if(v< -64'sd128)sat4<=8'd128;else sat4<=v[7:0];
                    end
                end
            end
            if(av[4])begin
                if(u_act==2'd2)begin
                    pw0_5<=pwl[pwl_base];pw1_5<=pwl[pwl_base+9'd1];
                end
                frac5<=frac4;sat5<=sat4;
            end
            if(av[5])begin
                p0_6<=pw0_5;slope6<=$signed({3'b0,pw1_5})-$signed({3'b0,pw0_5});
                frac6<=frac5;sat6<=sat5;
            end
            if(av[6])begin
                if(u_act==2'd2)begin
                    prod=slope6*$signed({1'b0,frac6});
                    vf=$signed({13'b0,p0_6})+(prod>>>10);
                    v=rhu12(vf);
                    if(v>64'sd255)sat7<=8'd255;
                    else if(v<0)sat7<=0;else sat7<=v[7:0];
                end else sat7<=sat6;
            end
        end
    end

    integer ks;
    always @(posedge clk) begin
        if (srst) begin
            st <= S_IDLE; done <= 1'b0; layer_pulse <= 1'b0;
            L <= 0; y <= 0; x <= 0; step <= 0; qo <= 0; ci <= 0;
            trow <= 0; t2row <= 0; yend <= 0; t2end <= 0;
            oh <= H0[9:0]; ow <= W0[10:0]; wait_o <= 1'b0;
            lb_src<=0;lb_skip<=0;lb_dst<=0;lb_ic<=0;lb_oc<=0;
            lb_s2<=0;lb_up<=0; lb_wbase<=0; lb_wcnt<=0; lb_oh<=H0; lb_ow<=W0;
        end else begin
            layer_pulse <= 1'b0;


            case (st)
            S_IDLE: begin
                done <= 1'b0;
                if (start) begin
                    L <= 4'd0;
                    oh <= H0[9:0]; ow <= W0[10:0];
                    st <= S_INIT;
                end
            end
            //-------------------------------- 层初始化
            S_INIT: begin
                lb_src  <= u_src;  lb_skip <= u_sksel; lb_dst <= u_dst;
                lb_ic   <= u_ic;   lb_oc   <= u_oc;
                if (u_s2) begin
                    oh <= oh >> 1;  ow <= ow >> 1;
                    lb_oh <= oh >> 1; lb_ow <= ow >> 1;
                end else if (u_up) begin
                    oh <= oh << 1;  ow <= ow << 1;
                    lb_oh <= oh << 1; lb_ow <= ow << 1;
                end else begin
                    lb_oh <= oh;     lb_ow <= ow;
                end
                lb_s2 <= u_s2;   lb_up <= u_up;
                lb_wbase <= u_wbase;                       // 本层权重字偏移
                lb_wcnt  <= {u_ic,3'b0} + {4'b0,u_ic};     // ic*9 个 256b 字
                dbg_layer <= L;   dbg_dst <= u_dst;
                y <= 0; x <= 0; qo <= 0;
                trow <= 0; t2row <= 0;
                st <= S_TP1;
            end
            //-------------------------------- 层配置采样拍（pmem lay_start）
            S_TP1: st <= S_WLD;
            //-------------------------------- 等本层权重热加载完成（top 桥）
            // 层内后续 tile 从 S_OSH 直接回 S_TP1Q，不经 S_WLD：权重不重载
            S_WLD: if (wld_done) st <= S_TP1Q;
            //-------------------------------- 发 p1 请求脉冲
            S_TP1Q: st <= S_TP1W;
            //-------------------------------- 等行组填充完成，锁 tile 几何
            S_TP1W: begin : TP1W_BLK
                reg [9:0] ny;
                if (p1_rdy) begin
                    ny = {2'd0, trow} * TILE_R;
                    y    <= ny;
                    x    <= 11'd0;
                    yend <= (ny + TILE_R > oh) ? oh : (ny + TILE_R);
                    trow <= trow + 8'd1;
                    st   <= S_PCLR;
                end
            end
            //-------------------------------- 清累加器
            S_PCLR: begin
                step <= 13'd0; qo <= 6'd0;
                st <= S_P0;
            end
            //-------------------------------- tap P0：发读
            S_P0: st <= S_P1;
            //-------------------------------- tap P1：MAC + 推进
            S_P1: begin
                if (step == acc_steps - 13'd2) begin
                    step <= 13'd0; qo <= 6'd0;
                    st <= S_OSH;
                end else begin
                    step <= step + 13'd2;
                    st <= S_P1;
                end
            end
            //-------------------------------- acc 写 DDR 流 + 统计（背压停等）
            S_OSH: begin
                if (ab_wrdy) begin
                    if (qo == u_oc - 6'd1) begin
                        qo <= 6'd0;
                        if (x < ow - 11'd1) begin
                            x <= x + 11'd1;
                            st <= S_PCLR;
                        end else begin
                            x <= 11'd0;
                            if (y < yend - 10'd1) begin
                                y <= y + 10'd1;
                                st <= S_PCLR;
                            end else if (yend < oh) begin
                                // 层内后续 tile 直接发 p1 请求：不能回 S_TP1，
                                // 否则 lay_start 每 tile 复位 p1_til/p1_y0
                                //（第二 tile 又变 y0=0）及 acc_cnt/dr 层状态。
                                st <= S_TP1Q;             // 本 tile 完，下一 tile
                            end else begin
                                y <= 10'd0;
                                // The final statistics item is still in flight.
                                st <= S_STAT_DRAIN;
                            end
                        end
                    end else begin
                        qo <= qo + 6'd1;
                    end
                end
            end
            //-------------------------------- Drain final captured statistics before WAIT.
            S_STAT_DRAIN: if (!statistics_busy) begin
                wait_o <= 1'b1;
                st <= S_WAIT;
            end
            //-------------------------------- 等 RISC-V 系数
            S_WAIT: begin
                if (cv_go) begin
                    wait_o <= 1'b0;
                    ci <= 7'd0;
                    st <= S_COPY;
                end
            end
            //-------------------------------- 拷贝 65 项系数
            S_COPY: begin
                if (ci == 7'd64) begin
                    ci <= 7'd0; qo <= 6'd0;
                    st <= S_TP2;
                end else ci <= ci + 7'd1;
            end
            //-------------------------------- 发 p2 请求脉冲
            S_TP2: st <= S_TP2W;
            //-------------------------------- 等预取完成，锁 tile 几何
            S_TP2W: begin : TP2W_BLK
                reg [9:0] ny;
                if (p2_rdy) begin
                    ny = {2'd0, t2row} * TILE_R;
                    y     <= ny;
                    x     <= 11'd0;
                    t2end <= (ny + TILE_R > oh) ? oh : (ny + TILE_R);
                    t2row <= t2row + 8'd1;
                    st    <= S_A0;
                end
            end
            //-------------------------------- A4：写 dst + 推进（背压停等）
            S_A0: begin
                if (dw_we) begin
                    if (qo == u_oc - 6'd1) begin
                        qo <= 6'd0;
                        if (x < ow - 11'd1) begin
                            x <= x + 11'd1;
                            st <= S_A0;
                        end else begin
                            x <= 11'd0;
                            if (y < t2end - 10'd1) begin
                                y <= y + 10'd1;
                                st <= S_A0;
                            end else if (t2end < oh) begin
                                st <= S_TP2;             // 本 tile 完，预取下一 tile
                            end else begin
                                layer_pulse <= 1'b1;
                                if (L == 4'd11) begin
                                    done <= 1'b1;
                                    st <= S_IDLE;
                                end else begin
                                    L <= L + 4'd1;
                                    st <= S_INIT;
                                end
                            end
                        end
                    end else begin
                        qo <= qo + 6'd1;
                        st <= S_A0;
                    end
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
