//==============================================================================
// nst_pmem.v — v3-tile 平面存储管理器（clk_c 域）
//
// 特征平面 / accbank 全部放 DDR（工作区 work_base，板上 0x0400_0000）。
// 片上只保留：
//   1) 源行组缓存 sc：NS=2*TILE_R+1 槽 × RB_MAX 字节（口A 3x3 取窗）
//      实现：4×32b bank 块 RAM，fill 每 beat 整写一次（地址顺序 → 可推断
//      RAM10）；首 beat 的 f_head 字节歪斜不剔除，按槽存 skew，读侧补偿。
//   2) acc 乒乓写 skid（2×64×128b）：阶段1 逐字打包，256 word 自动成
//      64-beat burst 写 DDR acc 区（层尾自动补排）
//   3) acc 读 FIFO（8 beat = 32 word）：阶段2 A0 逐字弹出
//   4) skip 读 FIFO（4 beat = 64B）：add 层 A0 逐字节弹出
//   5) dst 写 skid（2×64×128b）：A4 逐字节打包，1KB 自动写 DDR 平面区
//   6) OUT 行缓存 ×2 + 3B→4B 打包器：L11 输出直接成显示帧写 out_base
//
// 平面 DDR 布局（字节）：P0=work_base, P1=+PLANE_BYTES, P2=+2*PLANE_BYTES,
//   ACC=+3*PLANE_BYTES；元素布局与 golden 一致 addr=((y*W)+x)*C+c（acc 4B/word）。
//   要求：W0%16==0（各行/流 16B 对齐）；nrows*ow*oc%4==0（acc tile beats 整）。
//
// tile 流程：p1_req(填源行组)→p1_rdy→conv→…→wait(系数)→p2_req(预取 acc+skip)
//   →p2_rdy→affine→…→layer_pulse。acc/skip/dst 全为顺序流，仅口A走行组缓存。
//==============================================================================
`timescale 1ns/1ps

module nst_pmem #(
    parameter LOOKAHEAD     = 0,          // paired seq supplies next query on invalid P1
    parameter TILE_R        = 4,
    parameter W0            = 256,
    parameter H0            = 256,
    parameter RB_MAX        = 8*W0,          // 行组缓存行步距（字节）
    parameter NS            = 2*TILE_R+1,    // 槽数（s2 最坏）
    parameter IN_BYTES      = 3*W0*H0,
    parameter PLANE_BYTES   = 8*W0*H0,
    parameter OUT_ROW_BYTES = 3*W0
)(
    input  wire        clk,
    input  wire        srst,

    // ---- APB 准静态配置（帧间改写）----
    input  wire [31:0] in_base_w,
    input  wire [31:0] out_base_w,
    input  wire [31:0] out_stride_w,
    input  wire [31:0] work_base_w,
    input  wire [31:0] style_base_w,
    input  wire        in_buf_sel_w,
    input  wire        fstart,            // 帧启动脉冲（清 out_done）

    // ---- 层配置（lay_start 1 拍采样）----
    input  wire        lay_start,
    input  wire [2:0]  lb_src, lb_skip, lb_dst,
    input  wire [5:0]  lb_ic, lb_oc,
    input  wire [9:0]  lb_oh,
    input  wire [10:0] lb_ow,
    input  wire        lb_s2, lb_up,
    input  wire [11:0] lb_wbase,          // 本层权重字偏移（style 区，字=32B）
    input  wire [9:0]  lb_wcnt,           // 本层权重字数 ic*9

    // ---- tile 握手 ----
    input  wire        p1_req,
    output wire        p1_rdy,
    input  wire        p2_req,
    output wire        p2_rdy,

    // ---- 口A 取窗（发坐标后第 2 拍得 gq，原始字节）----
    input  wire [9:0]  gy,
    input  wire [10:0] gx,
    input  wire [5:0]  gc,
    input  wire [1:0]  gki, gkj,
    input  wire        g_vld,
    output wire [7:0]  gq,

    // ---- skip 流 ----
    input  wire        sk_rd,
    output reg  [7:0]  skq,
    output wire        sk_rdy,

    // ---- dst 写 ----
    input  wire        dw_we,
    input  wire [7:0]  dw_data,
    output wire        dw_rdy,

    // ---- acc 流 ----
    input  wire        ab_we,
    input  wire signed [31:0] ab_wdata,
    output wire        ab_wrdy,
    input  wire        ab_re,
    output reg  signed [31:0] ab_rdata,
    output wire        ab_rdy,

    // ---- OUT 行打包 → ofifo ----
    output wire        of_wr,
    output wire [127:0] of_d,
    input  wire        of_full,

    // ---- 引擎命令口（单驱动仲裁）----
    output wire [31:0] diag_pmem,diag_counts,diag_totals,diag_commands,diag_phase1,diag_geometry,diag_chunk,
    output wire        cmd_we,
    output wire [48:0] cmd_wdata,         // {wr,tag[2:0],addr[31:0],beats[12:0]}
    input  wire        cmd_full,

    // ---- 引擎读数据流 A/B（aclk→clk_c，同步读）----
    input  wire [127:0] rA_d,  input wire rA_empty,  output wire rA_re,
    input  wire [127:0] rB_d,  input wire rB_empty,  output wire rB_re,

    // ---- 引擎写数据流 plane（clk_c→aclk）----
    output wire        w_we,
    output wire [127:0] w_d,
    input  wire        w_full,

    // ---- 状态 ----
    output wire        out_done,
    output wire        fill_busy,
    input  wire        eng_idle
);
    localparam [2:0] TAG_STYLE=3'd0, TAG_A=3'd1, TAG_B=3'd2,
                     TAG_WF=3'd3,    TAG_OF=3'd4;

    //---- 源行组缓存 sc：4×32b bank，每槽 SC_SLOT_W 个 128b 字 ----
    //  写：fill 每 beat 整写一次，地址 = 槽基址 + beat 序号（严格顺序）。
    //  读：行内逻辑字节 j=su*ic+gc 对应流字节 j+skew[slot]（首 beat 非对齐
    //  吸收在 skew），字=(j+skew)>>4，bank=((j+skew)>>2)&3，字节=j&3。
    localparam integer SC_SLOT_W = RB_MAX/16 + 1;   // 含首 beat 歪斜 + 尾 beat 余量
    localparam integer SC_WORDS  = NS*SC_SLOT_W;
    localparam integer SC_AW     = $clog2(SC_WORDS);

    //================================================================= 配置同步
    reg [31:0] in_base_r, out_base_r, out_stride_r, work_base_r, style_base_r;
    reg        inbs_r;
    always @(posedge clk) begin
        if (srst) begin
            in_base_r<=0; out_base_r<=0; out_stride_r<=0;
            work_base_r<=0; style_base_r<=0; inbs_r<=0;
        end else begin
            in_base_r   <= in_base_w;    out_base_r  <= out_base_w;
            out_stride_r<= out_stride_w; work_base_r <= work_base_w;
            style_base_r<= style_base_w; inbs_r     <= in_buf_sel_w;
        end
    end
    wire [31:0] WB0  = work_base_r;
    wire [31:0] WB1  = work_base_r + PLANE_BYTES;
    wire [31:0] WB2  = work_base_r + 2*PLANE_BYTES;
    wire [31:0] ACCB = work_base_r + 3*PLANE_BYTES;
    wire [31:0] INB  = in_base_r + (inbs_r ? IN_BYTES : 32'd0);

    // bank 基址选择：直接用三目连续赋值。
    // 注意：iverilog 对 f_selbase 这类函数调用驱动连续赋值会传播 X
    //（同文件 f_slotrow 却正常，原因不明），故禁用函数封装。
    // 三个选择线在层几何 reg 声明之后、命令拼接之前定义（见 fill 段）。

    //================================================================= 层几何
    reg [2:0]  g_src, g_sk, g_dst;
    reg [5:0]  g_ic, g_oc;
    reg [9:0]  g_oh;
    reg [10:0] g_ow;
    reg        g_s2, g_up, g_dst_out;
    reg [11:0] g_sw;                       // 源宽
    reg [12:0] g_rb;                       // 行字节 = sw*ic
    reg [9:0]  g_sh;                       // 源行数
    reg [26:0] g_tot;                      // oh*ow*oc
    reg [3:0]  g_nslot;
    always @(posedge clk) begin
        if (srst) begin
            g_src<=0; g_sk<=7; g_dst<=0; g_ic<=0; g_oc<=0;
            g_oh<=0; g_ow<=0; g_s2<=0; g_up<=0; g_dst_out<=0;
            g_sw<=0; g_rb<=0; g_sh<=0; g_tot<=0; g_nslot<=0;
        end else if (lay_start) begin : GEO_CALC
            reg [11:0] swv;
            reg [16:0] pxv;
            g_src<=lb_src; g_sk<=lb_skip; g_dst<=lb_dst;
            g_ic<=lb_ic;   g_oc<=lb_oc;   g_oh<=lb_oh; g_ow<=lb_ow;
            g_s2<=lb_s2;   g_up<=lb_up;   g_dst_out<=(lb_dst==3'd4);
            if (lb_s2) begin
                swv = {lb_ow,1'b0};
                g_sh <= {lb_oh,1'b0};
                // 槽数=2*TILE_R+1（行 2y0-1..2y0+2TILE_R-1），fslot 0..g_nslot
                g_nslot <= 2*TILE_R;
            end else if (lb_up) begin
                swv = {1'b0,lb_ow[10:1]};
                g_sh <= {1'b0,lb_oh[9:1]};
                // up：4 输出行映射 4 个源行槽（含反射后），fslot 0..g_nslot
                g_nslot <= TILE_R/2+1;
            end else begin
                swv = {1'b0,lb_ow};
                g_sh <= lb_oh;
                // normal：3×3 卷积 4 输出行需要源行 y0-1..y0+TILE_R，共 TILE_R+2 槽
                g_nslot <= TILE_R+1;
            end
            g_sw  <= swv;
            g_rb  <= {1'b0,swv} * {2'b0,lb_ic};
            pxv   = lb_oh * lb_ow;
            g_tot <= pxv * {2'b0,lb_oc};
        end
    end

    //================================================================= 反射
    function signed [12:0] f_refl;
        input signed [12:0] v;
        input signed [12:0] n;
        begin
            if (v < 0)        f_refl = -v;
            else if (v >= n)  f_refl = 2*n - 13'sd2 - v;
            else              f_refl = v;
        end
    endfunction

    //================================================================= tile 计数
    // 位宽必须容纳整网最大 tile 数：H=192/TILE_R=4 -> 48（4bit 会在 tile16
    // 即输出行 64 处回绕，p1_y0/p2_y0 归零导致后 128 行重复处理前 64 行窗口）
    reg [7:0]  p1_til, p2_til;
    reg [9:0]  p1_y0, p1_base0, p2_y0;
    reg        f_req_d, q_req_d;
    wire       p1_rise = p1_req & ~f_req_d;
    wire       p2_rise = p2_req & ~q_req_d;

    function [9:0] f_slotrow;              // 槽 s 的源物理行
        input [3:0] s;
        input [9:0] y0;
        input [9:0] b0;
        input mode_s2, mode_up;
        input [9:0] height_out, height_src;
        begin : SR
            reg signed [12:0] v, n, p;
            if (mode_s2) begin
                v = 13'sd2*$signed({3'b0,y0}) - 13'sd1 + $signed({5'b0,s});
                n = $signed({height_out,1'b0});
                p = f_refl(v, n);
            end else if (mode_up) begin
                p = $signed({3'b0,b0}) + $signed({6'b0,s});
                if (p > $signed({3'b0,height_src}) - 13'sd1)
                    p = $signed({3'b0,height_src}) - 13'sd1;
            end else begin
                v = $signed({3'b0,y0}) - 13'sd1 + $signed({5'b0,s});
                n = $signed({3'b0,height_out});
                p = f_refl(v, n);
            end
            f_slotrow = p[9:0];
        end
    endfunction
    function [9:0] f_nrows;                // tile 行数（末 tile 可不满）
        input [9:0] y0;
        begin
            f_nrows = (y0 + TILE_R > g_oh) ? (g_oh - y0) : TILE_R;
        end
    endfunction

    always @(posedge clk) begin
        if (srst) begin
            p1_til<=0; p2_til<=0; p1_y0<=0; p1_base0<=0; p2_y0<=0;
            f_req_d<=0; q_req_d<=0;
        end else begin
            f_req_d <= p1_req;
            q_req_d <= p2_req;
            if (lay_start) begin
                p1_til<=0; p2_til<=0; p1_y0<=0; p1_base0<=0; p2_y0<=0;
            end else begin
                if (p1_rise) begin : P1_LOCK
                    reg signed [12:0] rv;
                    p1_y0 <= p1_til * TILE_R;
                    rv = f_refl($signed({3'b0,p1_til} * TILE_R - 13'sd1),
                                $signed({3'b0,g_oh}));
                    p1_base0 <= rv[12:1];          // up 模式：refl(y0-1,oh)>>1
                    p1_til   <= p1_til + 8'd1;
                end
                if (p2_rise) begin
                    p2_y0  <= p2_til * TILE_R;
                    p2_til <= p2_til + 8'd1;
                end
            end
        end
    end

    //================================================================= fill FSM
    localparam F_IDLE=2'd0, F_CMD=2'd1, F_DAT=2'd2, F_NXT=2'd3;
    reg [1:0]  fst;
    reg [3:0]  fslot;
    reg        fill_done;
    reg        f_pend;                     // p1_req 已锁存（等 dst 排空）
    // dst 排空状态前向声明（fill 门控 / 层首复位 / acc wf_ga·wf_gd 互锁需要）
    reg [26:0] dst_cnt, dst_flsh;
    reg [1:0]  dd_st;
    reg        dd_pend;
    reg        dwsel;
    reg [6:0]  dwptr;
    reg [3:0]  dpc;
    // fill 读源平面：必须等上一层 dst 全部写回 DDR（命令队列保序 → 排空后
    // 读命令才不会越过写命令读到旧数据）。acc 排空与 fill 读区不相交，不等待。
    wire dst_flush_idle = (dd_st==2'd0) && !dd_pend && (dst_flsh==dst_cnt);
    // fill FSM 确认 dst 排空后、进入 F_CMD 前的单拍复位脉冲（dst 指针由 OUT 块管理，
    // 不能在 fill FSM 内跨块赋值，否则多驱动）
    wire dst_clr = (fst==F_IDLE) && f_pend && dst_flush_idle;
    wire [31:0] f_base   = (g_src==3'd0) ? INB
                         : (g_src==3'd1) ? WB0
                         : (g_src==3'd2) ? WB1 : WB2;
    wire [31:0] sk_base  = (g_sk ==3'd0) ? INB
                         : (g_sk ==3'd1) ? WB0
                         : (g_sk ==3'd2) ? WB1 : WB2;
    wire [31:0] dst_base = (g_dst==3'd0) ? INB
                         : (g_dst==3'd1) ? WB0
                         : (g_dst==3'd2) ? WB1 : WB2;
    wire [31:0] f_rowba  = f_slotrow(fslot, p1_y0, p1_base0, g_s2, g_up, g_oh, g_sh) * g_rb;
    wire [31:0] f_ba     = f_base + f_rowba;   // 行字节首址（可非 16B 对齐）
    // AXI/BFM 按 16B beat 对齐出数：从对齐首址起读，首 beat 跳过 f_ba[3:0]
    wire [31:0] f_ba_a   = {f_ba[31:4], 4'b0};
    wire [12:0] rb_beats = (g_rb + {9'd0,f_ba[3:0]} + 13'd15) >> 4;
    wire [48:0] f_cmdd;   // 定义在 f_ba_r 预取段（命令地址走寄存器）
    wire        fill_pop = (fst==F_DAT) && !rA_empty;
    // 命令仲裁为固定优先级单写口：本授权必须排除所有更高优先级授权，
    // 否则 FSM 按本信号推进但入队的是别人的命令 → 丢命令（同拍 g_d 撞 g_qa
    // 会整块丢失 256 元素读命令）。未抢到仲裁时留在原状态等一拍即可。
    wire        g_s;   // 前向声明（style 授权，定义在 lay_start 段）
    wire        g_f;   // fill 授权（定义在 f_take 之后的 f_ba_r 预取段）
    // fill 命令地址含 fslot*g_rb 多级乘法链（33 级逻辑，clk_c 最差路径）。
    // 在"进入 F_CMD 的前一拍"把本槽 f_ba 预取到 f_ba_r：F_CMD 拍命令从寄存器
    // 出，切断 fslot→cmdq WDATA 长组合路径，且不增加任何等待周期。
    reg  [31:0] f_ba_r;

    // ---- 非对齐行收集：f_head=本 beat 前弃字节（仅首 beat 非0），f_left=行剩余
    reg [3:0]  f_head;
    reg [12:0] f_left;
    wire [12:0] f_room = 13'd16 - {9'd0,f_head};
    wire [12:0] f_take = (f_left < f_room) ? f_left : f_room;
    wire        fill_cmd_enter =
                  ((fst==F_IDLE) && f_pend && dst_flush_idle)
               || ((fst==F_DAT)  && fill_pop && (f_left==f_take)
                                && (fslot != g_nslot + 4'd1));
    // IDLE 启动拍 fslot 的 NBA 清零尚未生效，首槽地址必须显式按槽 0 计算；
    // F_DAT→F_CMD 时 fslot 早已预递增到下一槽，直接采 f_ba 即可。
    wire [31:0] f_ba_slot0 = f_base
                  + f_slotrow(4'd0, p1_y0, p1_base0, g_s2, g_up, g_oh, g_sh) * g_rb;
    always @(posedge clk)
        if (srst)              f_ba_r <= 32'd0;
        else if (fill_cmd_enter)
            f_ba_r <= (fst==F_IDLE) ? f_ba_slot0 : f_ba;
    wire [31:0] f_ba_a_r = {f_ba_r[31:4], 4'b0};
    wire [12:0] rb_beats_r = (g_rb + {9'd0,f_ba_r[3:0]} + 13'd15) >> 4;
    assign      f_cmdd = {1'b0, TAG_A, f_ba_a_r, rb_beats_r};
    assign      g_f = (fst==F_CMD) && !cmd_full && !g_s;

    // fill 收到的 beat → 整写 4×32b bank（地址顺序递增 → 可推断块 RAM）
    // 首 beat 的 f_head 歪斜字节不剔除，按槽存 skew，读侧补偿（见口A 取窗）。
    reg [SC_AW-1:0] f_wa16;                // 槽内 beat 字地址
    always @(posedge clk) begin
        if (srst)                   f_wa16 <= 0;
        else if (fst==F_CMD && g_f) f_wa16 <= fslot * SC_SLOT_W;
        else if (fill_pop)          f_wa16 <= f_wa16 + 1'b1;
    end
    reg [3:0]  skew [0:NS-1];              // 每槽首 beat 字节歪斜（读侧补偿）
    reg [31:0] sc_bk0 [0:SC_WORDS-1];
    reg [31:0] sc_bk1 [0:SC_WORDS-1];
    reg [31:0] sc_bk2 [0:SC_WORDS-1];
    reg [31:0] sc_bk3 [0:SC_WORDS-1];
    always @(posedge clk) begin
        if (fst==F_CMD && g_f) skew[fslot] <= f_ba_r[3:0];
        if (fill_pop) begin
            sc_bk0[f_wa16] <= rA_d[31:0];
            sc_bk1[f_wa16] <= rA_d[63:32];
            sc_bk2[f_wa16] <= rA_d[95:64];
            sc_bk3[f_wa16] <= rA_d[127:96];
        end
    end

    always @(posedge clk) begin
        if (srst) begin
            fst<=F_IDLE; fslot<=0; f_left<=0; f_head<=0; fill_done<=1; f_pend<=0;
        end else begin
            if (lay_start) fill_done <= 1'b0;
            case (fst)
            F_IDLE: begin
                if (p1_rise) begin             // 锁存请求并立即清 done（防陈旧 rdy）
                    f_pend    <= 1'b1;
                    fill_done <= 1'b0;
                end
                if (f_pend && dst_flush_idle) begin
                    f_pend <= 1'b0;
                    fslot  <= 4'd0;
                    fst    <= F_CMD;
                    // dst 指针复位改由 OUT 块在 dst_clr 拍统一处理（消除多驱动）
                end
            end
            F_CMD: if (g_f) begin
                f_left <= g_rb;
                f_head <= f_ba_r[3:0];
                fslot  <= fslot + 4'd1;        // 提前推进，F_DAT 用 f_wa16 写
                fst    <= F_DAT;
            end
            F_DAT: begin
                if (fill_pop) begin
                    f_left <= f_left - f_take;
                    f_head <= 4'd0;
                end
                if (fill_pop && f_left == f_take) begin
                    // fslot 在 F_CMD 拍已 NBA 预递增（当前槽号+1），
                    // 需填槽号 0..g_nslot 共 g_nslot+1 槽 → 收到 g_nslot+1 时完成
                    if (fslot == g_nslot + 4'd1) begin
                        fill_done <= 1'b1;
                        fst <= F_IDLE;
                    end else fst <= F_CMD;
                end
            end
            default: fst <= F_IDLE;
            endcase
        end
    end
    assign p1_rdy = fill_done;
    assign fill_busy = (fst != F_IDLE);

    //================================================================= 口A 取窗
    // 读侧补偿首 beat 歪斜：流字节号 = 逻辑字节 j + skew[slot]。
    //   j = su*ic + gc；bank字=(j+skew)>>4，bank=((j+skew)>>2)&3，字节=(j+skew)&3
    reg [12:0]      a_off;
    reg [SC_AW-1:0] a_wrd;
    reg signed [12:0] a_su;
    reg [3:0] a_slot;
    // Reflected source columns are in [0,W0). Limit the registered column
    // width to the supported image; avoid multiplying five constant high zeros.
    localparam integer SU_AW = (W0 < 2) ? 1 : $clog2(W0);
    reg [SU_AW-1:0] su_pre;
    reg [3:0] slot_pre;
    reg [5:0] channel_pre;
    always @(posedge clk) begin
        if(srst) begin su_pre<=0;slot_pre<=0;channel_pre<=0;end
        else begin su_pre<=a_su;slot_pre<=a_slot;channel_pre<=gc;end
    end
    always @(*) begin : PORTA_COORD
        reg signed [12:0] vr, sr, su;
        reg [3:0] slot;
        // 行 → 槽（反射映射在 fill 端做，读端只做槽索引）
        if (g_s2) begin
            vr = 13'sd2*$signed({3'b0,gy}) + $signed({1'b0,gki}) - 13'sd1;
            slot = vr[3:0] - (2*p1_y0 - 1);
        end else if (g_up) begin
            vr = f_refl($signed({3'b0,gy}) + $signed({1'b0,gki}) - 13'sd1,
                        $signed({3'b0,g_oh}));
            slot = vr[12:1] - p1_base0[3:0];
        end else begin
            vr = $signed({3'b0,gy}) + $signed({1'b0,gki}) - 13'sd1;
            slot = vr[3:0] - (p1_y0[3:0] - 4'd1);
        end
        // 列（与旧 linebuf 公式一致）
        if (g_up) begin
            sr = f_refl($signed({3'b0,gx}) + $signed({1'b0,gkj}) - 13'sd1,
                        $signed({3'b0,g_ow}));
            su = sr >>> 1;
        end else if (g_s2) begin
            su = f_refl(($signed({2'b0,gx}) << 1) + $signed({1'b0,gkj}) - 13'sd1,
                        $signed({4'b0,g_ow}) << 1);
        end else begin
            su = f_refl($signed({2'b0,gx}) + $signed({1'b0,gkj}) - 13'sd1,
                        $signed({3'b0,g_ow}));
        end
        a_su = su; a_slot = slot;
    end
    wire signed [12:0] use_su = LOOKAHEAD ? su_pre : a_su;
    wire [3:0] use_slot = LOOKAHEAD ? slot_pre : a_slot;
    wire [5:0] use_channel = LOOKAHEAD ? channel_pre : gc;
    always @(*) begin : PORTA_ADDR
        a_off = use_su * {2'b0,g_ic} + {7'b0,use_channel} + {9'b0,skew[use_slot]};
        a_wrd = use_slot * SC_SLOT_W + a_off[12:4];
    end
    wire [1:0] a_bks = a_off[3:2];
    wire [1:0] a_sln = a_off[1:0];
    reg [31:0] qa0, qa1, qa2, qa3;
    reg [1:0]  qa_bk, qa_sl;
    always @(posedge clk)
        if (g_vld) begin
            qa0 <= sc_bk0[a_wrd]; qa1 <= sc_bk1[a_wrd];
            qa2 <= sc_bk2[a_wrd]; qa3 <= sc_bk3[a_wrd];
            qa_bk <= a_bks; qa_sl <= a_sln;
        end
    wire [31:0] qa_w = (qa_bk==2'd0) ? qa0 : (qa_bk==2'd1) ? qa1 :
                       (qa_bk==2'd2) ? qa2 : qa3;
    wire [7:0] qa = qa_w[8*qa_sl +: 8];
    assign gq = qa;                        // 与旧 linebuf 相同：第 2 拍出数

    //================================================================= acc 写 skid
    reg [127:0] askm0 [0:63];
    reg [127:0] askm1 [0:63];
    reg         awsel;
    reg [6:0]   awptr;
    reg [31:0]  apk0, apk1, apk2;
    reg [1:0]   pkc;
    reg [26:0]  acc_cnt, acc_flsh;
    reg [1:0]   dr_st;
    reg         dr_bank, dr_pend, dr_pend_bank;
    reg [6:0]   dr_idx;
    reg [12:0]  dr_beat;
    wire [48:0] a_cmdd = {1'b1, TAG_WF, ACCB + {acc_flsh[24:0],2'b00}, dr_beat};
    // wfifo 推送授权（唯一驱动点见底部统一块；dd_st==0 防护为冗余保险）
    wire        wf_ga = (dr_st==2'd2) && !w_full && (dd_st==2'd0);
    wire        wf_gd = (dd_st==2'd2) && !w_full && (dr_st==2'd0);
    wire        g_a = (dr_st==2'd1) && !cmd_full && !(g_s||g_f);

    always @(posedge clk) begin
        if (srst) begin
            awsel<=0; awptr<=0; pkc<=0; apk0<=0; apk1<=0; apk2<=0;
            acc_cnt<=0; acc_flsh<=0;
            dr_st<=0; dr_bank<=0; dr_idx<=0; dr_beat<=0; dr_pend<=0; dr_pend_bank<=0;
        end else begin
            if (lay_start) begin
                acc_cnt<=0; acc_flsh<=0; awptr<=0; awsel<=0; pkc<=0;
                dr_st<=0; dr_pend<=0;
            end
            //---------------- OSH word 打包（4 word/beat）
            if (ab_we && ab_wrdy) begin
                acc_cnt <= acc_cnt + 27'd1;
                case (pkc)
                2'd0: apk0 <= ab_wdata;
                2'd1: apk1 <= ab_wdata;
                2'd2: apk2 <= ab_wdata;
                default: begin
                    if (awsel==1'b0) askm0[awptr[5:0]] <= {ab_wdata,apk2,apk1,apk0};
                    else             askm1[awptr[5:0]] <= {ab_wdata,apk2,apk1,apk0};
                end
                endcase
                if (pkc==2'd3) begin
                    pkc <= 2'd0;
                    if (awptr == 7'd63) begin
                        awptr <= 7'd0;
                        awsel <= ~awsel;
                        if (dr_st != 2'd0) begin
                            dr_pend <= 1'b1; dr_pend_bank <= awsel;
                        end else begin
                            dr_st<=2'd1; dr_bank<=awsel; dr_idx<=7'd0; dr_beat<=13'd64;
                        end
                    end else awptr <= awptr + 7'd1;
                end else pkc <= pkc + 2'd1;
            end
            //---------------- 层尾补排（word 总数 %4==0 → 仅 awptr 残组）
            if (acc_cnt == g_tot && awptr != 7'd0 && dr_st == 2'd0
                && acc_flsh != acc_cnt) begin
                dr_st <= 2'd1; dr_bank <= awsel; dr_idx <= 7'd0;
                dr_beat <= {6'd0,awptr};
                awptr <= 7'd0; awsel <= ~awsel;
            end
            //---------------- 排空 → wfifo（推送由统一块完成，这里只推进指针）
            if (g_a) begin
                dr_st <= 2'd2;
            end else case (dr_st)
            2'd2: if (wf_ga) begin
                dr_idx<= dr_idx + 7'd1;
                acc_flsh <= acc_flsh + 27'd4;
                if (dr_beat == 13'd1) begin dr_beat<=13'd0; dr_st<=2'd3; end
                else dr_beat <= dr_beat - 13'd1;
            end
            2'd3: begin
                if (dr_pend) begin
                    dr_pend <= 1'b0;
                    dr_st<=2'd1; dr_bank<=dr_pend_bank; dr_idx<=7'd0; dr_beat<=13'd64;
                end else dr_st <= 2'd0;
            end
            default: ;
            endcase
        end
    end
    // OSH 停等：写 bank 正被排空且已满 / 挂起中 / pend 未排空时禁止写满当前 bank
    //（最后一项防 pend 被下一次 bank 满覆盖而丢数据）
    assign ab_wrdy = ~((dr_st != 2'd0) && (dr_bank == awsel) && (awptr == 7'd63))
                     && !(dr_pend && (dr_pend_bank == awsel))
                     && !(dr_pend && (awptr == 7'd63) && (pkc == 2'd3));

    //================================================================= acc 读 FIFO（8 beat = 32 word）
    reg [127:0] afm [0:7];
    reg [5:0]  af_w, af_r;
    wire [5:0] af_occ = af_w - af_r;
    assign ab_rdy = (af_occ != 6'd0);
    wire af_push = (fst==F_IDLE) && !rA_empty && (af_occ <= 6'd28);
    assign rA_re = fill_pop | af_push;
    always @(posedge clk) begin
        if (srst) begin af_w<=0; af_r<=0; end
        else if (lay_start) begin af_w<=0; af_r<=0; end
        else begin
            if (af_push) begin
                afm[af_w[4:2]] <= rA_d;
                af_w <= af_w + 6'd4;
            end
            if (ab_re) begin
                ab_rdata <= $signed(afm[af_r[4:2]][af_r[1:0]*32 +: 32]);
                af_r <= af_r + 6'd1;
            end
        end
    end

    //================================================================= skip FIFO（4 beat = 64B）
    reg [127:0] sfm [0:3];
    reg [6:0]  sf_w, sf_r;
    wire [6:0] sf_occ = sf_w - sf_r;
    assign sk_rdy = (sf_occ != 7'd0);
    wire sf_push = (g_sk != 3'd7) && !rB_empty && (sf_occ <= 7'd48);
    assign rB_re = sf_push;
    always @(posedge clk) begin
        if (srst) begin sf_w<=0; sf_r<=0; end
        else if (lay_start) begin sf_w<=0; sf_r<=0; end
        else begin
            if (sf_push) begin
                sfm[sf_w[5:4]] <= rB_d;
                sf_w <= sf_w + 7'd16;
            end
            if (sk_rd) begin
                skq  <= sfm[sf_r[5:4]][sf_r[3:0]*8 +: 8];
                sf_r <= sf_r + 7'd1;
            end
        end
    end

    //================================================================= p2 预取命令
    // f_nrows 内联（iverilog 对函数调用驱动连续赋值有返 0/X 怪癖）
    wire [9:0]  p2_nrows = (p2_y0 + TILE_R > g_oh) ? (g_oh - p2_y0) : TILE_R;
    // (* syn_use_dsp=no *)：三因子乘法链分解出的 DSP24 半块会触发 2026.1
    // pnr 布线后时序 "serializing traces failed"；常量因子下用逻辑实现代价很小
    (* syn_use_dsp = "no" *)
    wire [26:0] q_wo  = {17'd0,p2_y0} * {16'd0,g_ow} * {21'd0,g_oc};  // 元素偏移
    (* syn_use_dsp = "no" *)
    wire [26:0] q_nwo = {17'd0,p2_nrows} * {16'd0,g_ow}
                      * {21'd0,g_oc};                        // 先取 27b 宽积再截
    wire [12:0] q_abt = q_nwo[26:2];                          // acc beats = 元素/4（探针用）
    wire [12:0] q_sbt = q_nwo[26:4];                          // skip beats = 元素/16（探针用）
    //------------------------------------------------------------ 分块交错预取
    // 整 tile 一条大读命令在 256 宽几何下死锁：引擎严格保序，读返回 FIFO
    // 容量有限（rA 33beat+afm 8beat / rB 17beat+sfm 4beat），而 seq 又会被
    // dst/OUT 排空反压（wf/cof 只在后续写命令时才被引擎抽走）→ 读写循环等待。
    // 改为每 256 元素一小块：add 层先发 skip(16beat) 再发 acc(64beat)，
    // 块末等全部排空（引擎空闲 + 读 FIFO 空 + dst/OUT 排空完）再发下一块。
    // Bound the ENTIRE read command, not just its AXI bursts. 64 acc beats
    // exceed the rA FIFO (32) + local afm (8) capacity and can block an OUT
    // write queued behind this read when the producer's row banks fill.
    localparam [13:0] CHUNK_ELEMENTS = 14'd128;
    localparam [2:0]  Q_IDLE=3'd0, Q_SKC=3'd1, Q_ACC=3'd2,
                     Q_WAIT=3'd3, Q_DONE=3'd4;
    reg [2:0]  qst;
    reg [13:0] q_off;                 // 本 tile 已发元素数（256 的倍数，最大 8192）
    reg        p2_pend;               // p2 请求锁存（FSM 忙时不丢 tile 请求）
    reg        q_armed;               // 首块已入队 → 放行 seq 进 S_A0
    // tile 预取总量/基址偏移在"接受 p2_pend"拍锁存（Q_IDLE/Q_DONE 两个入口），
    // 命令生成从寄存器出：切断 g_oh→p2_nrows→三因子乘→q_left→cmdq 的 30 级
    // 组合路径（148.5M 差 0.101ns），零等待周期；顺带消除 p2_y0 在 p2_rise
    // 即翻转、而本 tile 尾块尚在排空时 q_nwo 被下一 tile 值污染的竞态。
    reg [26:0] q_nwo_r, q_wo_r;
    wire [13:0] q_left = q_nwo_r[13:0] - q_off;
    wire [13:0] q_take = (q_left < CHUNK_ELEMENTS) ? q_left : CHUNK_ELEMENTS;
    wire [12:0] q_acc_beats = {1'b0,q_take[13:2]};
    wire [12:0] q_skip_beats = {3'b0,q_take[13:4]};
    wire [26:0] qa_off = q_wo_r + {13'd0, q_off};
    wire [48:0] qa_cmdd = {1'b0, TAG_A, ACCB + {qa_off[24:0],2'b00}, q_acc_beats};
    wire [48:0] qs_cmdd = {1'b0, TAG_B, sk_base + qa_off[25:0], q_skip_beats};
    wire       g_d;   // 前向声明（dst 排空授权，定义在 dst skid 段）
    wire       g_qa = (qst==Q_ACC) && !cmd_full && !(g_s||g_f||g_a||g_d);
    wire       g_qs = (qst==Q_SKC) && !cmd_full && !(g_s||g_f||g_a||g_d);
    // 块排空判据（赋值在 pst/orb 声明之后，见命令仲裁前）
    wire       drain_ok;
    reg [13:0] q_acc_used,q_skip_used;
    always @(posedge clk)begin
        if(srst || lay_start)begin q_acc_used<=0;q_skip_used<=0;end
        else begin
            if(g_qa)q_acc_used<=0;else if(ab_re)q_acc_used<=q_acc_used+14'd1;
            if(g_qs)q_skip_used<=0;else if(sk_rd)q_skip_used<=q_skip_used+14'd1;
        end
    end
    wire chunk_consumed=q_acc_used>=q_take && (g_sk==7 || q_skip_used>=q_take);

    always @(posedge clk) begin
        if (srst) begin qst <= Q_IDLE; q_off <= 14'd0; p2_pend<=1'b0; q_armed<=1'b0;
                        q_nwo_r <= 27'd0; q_wo_r <= 27'd0; end
        else if (lay_start) begin qst <= Q_IDLE; q_off <= 14'd0; p2_pend<=1'b0; q_armed<=1'b0;
                        q_nwo_r <= 27'd0; q_wo_r <= 27'd0; end
        else begin
            if (p2_rise) p2_pend <= 1'b1;
            if (g_qa && (q_off==14'd0)) q_armed <= 1'b1;   // 首块 A 入队即放行
            case (qst)
        Q_IDLE: if (p2_pend) begin
                    p2_pend <= 1'b0; q_armed <= 1'b0;
                    q_off <= 14'd0;
                    q_nwo_r <= q_nwo; q_wo_r <= q_wo;   // 锁存本 tile 预取量/偏移
                    qst   <= (g_sk != 3'd7) ? Q_SKC : Q_ACC;
                end
        Q_SKC:  if (g_qs) qst <= Q_ACC;
        Q_ACC:  if (g_qa) qst <= Q_WAIT;
        Q_WAIT: if (drain_ok && chunk_consumed) begin
                    if (q_off + CHUNK_ELEMENTS >= q_nwo_r[13:0]) begin
                        qst <= Q_DONE; q_armed <= 1'b0;
                    end
                    else begin
                        q_off <= q_off + CHUNK_ELEMENTS;
                        qst   <= (g_sk != 3'd7) ? Q_SKC : Q_ACC;
                    end
                end
        Q_DONE: if (p2_pend) begin
                    p2_pend <= 1'b0; q_armed <= 1'b0;
                    q_off <= 14'd0;
                    q_nwo_r <= q_nwo; q_wo_r <= q_wo;   // 下一 tile 重锁存
                    qst   <= (g_sk != 3'd7) ? Q_SKC : Q_ACC;
                end else qst <= Q_IDLE;
        default: qst <= Q_IDLE;
            endcase
        end
    end
    // p2_rdy = 本 tile 首个 acc 块已入队（seq 即可进入 S_A0 边算边喂）
    //   且 acc 写侧已全部排空（阶段1 尾补排完成，保证阶段2 wfifo 不被 acc 占用）
    assign p2_rdy = q_armed && (dr_st==2'd0) && !dr_pend
                    && (acc_flsh == acc_cnt);

    //================================================================= dst 写 skid（dst=1..3）
    reg [127:0] dstm0 [0:63];
    reg [127:0] dstm1 [0:63];
    reg [127:0] dpk;
    // dwsel/dwptr/dpc 前向声明于 fill 段（层首复位在该段 F_IDLE）
    // dst_cnt/dst_flsh/dd_st/dd_pend 前向声明于 fill 段
    reg         dd_bank, dd_pend_bank;
    reg [6:0]   dd_idx;
    reg [12:0]  dd_beat;
    wire [48:0] d_cmdd = {1'b1, TAG_WF, dst_base + dst_flsh[25:0], dd_beat};
    assign      g_d = (dd_st==2'd1) && !cmd_full && !(g_s||g_f||g_a);

    //================================================================= OUT 行缓存 + 打包
    reg [7:0] orb0 [0:OUT_ROW_BYTES-1];
    reg [7:0] orb1 [0:OUT_ROW_BYTES-1];
    reg        osel;
    reg [20:0] owidx;
    reg [9:0]  orb_y;
    reg        orb_full0, orb_full1;
    wire [20:0] rowbytes = {11'd0,g_ow,1'b0} + {12'd0,g_ow};   // ow*3
    localparam P_IDLE=3'd0, P_RD=3'd1, P_PUSH=3'd2, P_NXT=3'd3,
               P_CMD=3'd4, P_END=3'd5;
    reg [2:0]  pst;
    reg        pbank;
    reg [20:0] prd;
    reg [3:0]  pc12;                       // 行内 mod-12 计数（12B=4px 凑一 beat）
    reg [9:0]  prow_y;
    reg [127:0] pk;
    reg        out_done_r;
    // pk 12B 组：新字节从 [7:0] 移入 → pk[23:16]=R(第1字节) pk[15:8]=G pk[7:0]=B
    // 与旧 OUT 桥格式一致：每 32bit 字 = {R,G,B,00}（MSB→LSB）
    wire [127:0] pk_of = {pk[23:16], pk[15:8],  pk[7:0],   8'h00,    // px3
                          pk[47:40], pk[39:32], pk[31:24], 8'h00,    // px2
                          pk[71:64], pk[63:56], pk[55:48], 8'h00,    // px1
                          pk[95:88], pk[87:80], pk[79:72], 8'h00};   // px0
    // cof FIFO 同拍组合写（of_full 与 wren 必须在同一拍握手，否则满边界丢 beat）
    assign of_wr = (pst==P_PUSH) && !of_full;
    assign of_d  = pk_of;
    wire [31:0] rowba = (out_stride_r == 32'd0)
                      ? out_base_r + prow_y * {g_ow,2'b00}
                      : out_base_r + prow_y * out_stride_r;
    wire [48:0] p_cmdd = {1'b1, TAG_OF, rowba, {4'd0, g_ow[10:2]}};
    wire        g_p = (pst==P_CMD) && !cmd_full
                      && !(g_s||g_f||g_a||g_d||g_qs||g_qa);
    wire        orb_rdy = ~(g_dst_out && ((osel==1'b0) ? orb_full0 : orb_full1));

    // dst 就绪：skid 路径看排空状态（含 pend 覆写防护）；OUT 路径看行缓存
    assign dw_rdy = g_dst_out ? orb_rdy
                    : (~((dd_st!=2'd0) && (dd_bank==dwsel) && (dwptr==7'd63))
                       && !(dd_pend && (dd_pend_bank==dwsel))
                       && !(dd_pend && (dwptr==7'd63) && (dpc==4'd15)));

    always @(posedge clk) begin
        if (srst) begin
            dwsel<=0; dwptr<=0; dpc<=0; dpk<=0;
            dst_cnt<=0; dst_flsh<=0;
            dd_st<=0; dd_bank<=0; dd_idx<=0; dd_beat<=0; dd_pend<=0; dd_pend_bank<=0;
            osel<=0; owidx<=0; orb_y<=0; orb_full0<=0; orb_full1<=0;
            pst<=P_IDLE; pbank<=0; prd<=0; pc12<=0; prow_y<=0; pk<=0;
            out_done_r<=0;
        end else begin
            if (fstart) out_done_r <= 1'b0;
            if (lay_start) begin
                // dst 计数/指针不在这里复位：阶段2 层尾 drain 可能仍在进行，
                // 复位改到 F_IDLE 确认 dst_flush_idle 后（dst_clr 脉冲）。
                // 此处只复位 OUT 行打包器（g_dst_out 层开始前必然空闲）。
                owidx<=0; orb_y<=0; orb_full0<=0; orb_full1<=0; pst<=P_IDLE;
                osel<=0; pbank<=0; prow_y<=0; prd<=0; pc12<=0;
            end
            if (dst_clr) begin
                // fill FSM 确认上一层 dst 排空完成，复位新层 dst 指针/计数
                dst_cnt<=0; dst_flsh<=0; dwptr<=0; dwsel<=0; dpc<=0;
                dd_st<=0; dd_pend<=0;
            end
            //---------------- A4 字节流（dst=1..3 skid / dst=4 行缓存）
            if (dw_we && dw_rdy) begin
                if (!g_dst_out) begin
                    dst_cnt <= dst_cnt + 27'd1;
                    dpk <= {dw_data, dpk[127:8]};
                    if (dpc == 4'd15) begin
                        dpc <= 4'd0;
                        if (dwsel==1'b0) dstm0[dwptr[5:0]] <= {dw_data,dpk[127:8]};
                        else             dstm1[dwptr[5:0]] <= {dw_data,dpk[127:8]};
                        if (dwptr == 7'd63) begin
                            dwptr <= 7'd0;
                            dwsel <= ~dwsel;
                            if (dd_st != 2'd0) begin
                                dd_pend <= 1'b1; dd_pend_bank <= dwsel;
                            end else begin
                                dd_st<=2'd1; dd_bank<=dwsel; dd_idx<=7'd0; dd_beat<=13'd64;
                            end
                        end else dwptr <= dwptr + 7'd1;
                    end else dpc <= dpc + 4'd1;
                end else begin
                    // L11 → OUT 行缓存
                    if (osel==1'b0) orb0[owidx] <= dw_data;
                    else            orb1[owidx] <= dw_data;
                    if (owidx == rowbytes - 21'd1) begin
                        owidx <= 21'd0;
                        if (osel==1'b0) orb_full0 <= 1'b1; else orb_full1 <= 1'b1;
                        // P_IDLE schedules full banks in row order. A row can
                        // become full while the preceding row is still draining.
                        osel  <= ~osel;
                        orb_y <= orb_y + 10'd1;
                    end else owidx <= owidx + 21'd1;
                end
            end
            //---------------- dst 层尾补排（字节总数 %16==0 → 仅 dwptr 残组）
            if (!g_dst_out && dst_cnt == g_tot && dwptr != 7'd0
                && dd_st == 2'd0 && dr_st == 2'd0 && !dr_pend
                && dst_flsh != dst_cnt) begin
                dd_st <= 2'd1; dd_bank <= dwsel; dd_idx <= 7'd0;
                dd_beat <= {6'd0,dwptr};
                dwptr <= 7'd0; dwsel <= ~dwsel;
            end
            //---------------- dst 排空 → wfifo（推送由统一块完成）
            if (g_d) begin
                dd_st <= 2'd2;
            end else case (dd_st)
            2'd2: if (wf_gd) begin
                dd_idx<= dd_idx + 7'd1;
                dst_flsh <= dst_flsh + 27'd16;
                if (dd_beat == 13'd1) begin dd_beat<=13'd0; dd_st<=2'd3; end
                else dd_beat <= dd_beat - 13'd1;
            end
            2'd3: begin
                if (dd_pend) begin
                    dd_pend <= 1'b0;
                    dd_st<=2'd1; dd_bank<=dd_pend_bank; dd_idx<=7'd0; dd_beat<=13'd64;
                end else dd_st <= 2'd0;
            end
            default: ;
            endcase
            //---------------- OUT 行打包器
            case (pst)
            P_IDLE: if ((pbank==1'b0) ? orb_full0 : orb_full1) begin
                prd<=0; pc12<=0;
                // Queue the write BEFORE pushing the row into the 16-beat
                // OUT FIFO. A 256-pixel row is 64 beats and cannot fit there.
                pst<=P_CMD;
            end
            P_RD: begin
                // 新字节从最低字节 [7:0] 移入，旧字节向高位走：读满 12B 后
                // b0..b11 紧凑落在 pk[95:0]（b0 在最高 [95:88]），pk_of 才能
                // 按 {R,G,B,00}×4 取出。切勿写成 {byte,pk[127:8]}（顶入会错位丢字节）
                pk  <= {pk[119:0], (pbank==1'b0) ? orb0[prd] : orb1[prd]};
                prd <= prd + 21'd1;
                pc12 <= (pc12 == 4'd11) ? 4'd0 : pc12 + 4'd1;
                if (pc12 == 4'd11) pst <= P_PUSH;        // 每 12B（4px）成一 beat
            end
            // cof 写使能/数据为同拍组合（见 of_wr assign），避免寄存 wren
            // 在 FIFO 满边界丢 beat
            P_PUSH: if (!of_full) pst <= P_NXT;
            P_NXT: begin
                if (prd >= rowbytes) pst <= P_END;
                else pst <= P_RD;
            end
            P_CMD: if (g_p) begin
                pst <= P_RD;
            end
            P_END: begin
                if (pbank==1'b0) orb_full0 <= 1'b0; else orb_full1 <= 1'b0;
                if (prow_y == g_oh - 10'd1) out_done_r <= 1'b1;
                else prow_y <= prow_y + 10'd1;
                pbank <= ~pbank;
                pst <= P_IDLE;
            end
            default: pst <= P_IDLE;
            endcase
        end
    end
    assign out_done = out_done_r;

    //================================================================= wfifo 统一推送（组合直写）
    // 必须同拍组合驱动 wren/wdata：FIFO 的 wfull 是寄存预测值，若 wren 再寄存
    // 一拍，生产者按当拍 !wfull 计数、FIFO 却可能在下一拍按新 wfull 丢字
    //（突发排空撞上 FIFO 满边界时恰好丢 1 beat → 引擎写 burst 尾拍死等）。
    // acc 排空（阶段1）与 dst 排空（阶段2）分相，wf_ga/wf_gd 互斥。
    assign w_we = wf_ga | wf_gd;
    assign w_d  = wf_ga ? ((dr_bank==1'b0) ? askm0[dr_idx] : askm1[dr_idx])
                        : ((dd_bank==1'b0) ? dstm0[dd_idx] : dstm1[dd_idx]);

    //================================================================= lay_start：层启动发本层 style 读命令
    // wrom 改为 512 深层内缓存：每层 lay_start 后读本层 ic*9 个权重字
    //（每字 32B=2 beat），TAG_STYLE 数据由 top 桥 2 beat 拼 256b 写 wrom。
    reg ld_pend;
    always @(posedge clk) begin
        if (srst)                      ld_pend <= 1'b0;
        else if (lay_start)            ld_pend <= 1'b1;
        else if (ld_pend && !cmd_full) ld_pend <= 1'b0;
    end
    assign      g_s       = ld_pend && !cmd_full;
    wire [31:0] sty_addr  = style_base_r + {lb_wbase, 5'd0};   // 每字 32B
    wire [12:0] sty_beats = {lb_wcnt, 1'b0};                   // 每字 2 beat
    wire [48:0] sty_cmdd  = {1'b0, TAG_STYLE, sty_addr, sty_beats};

    // 块排空判据：读 FIFO/本地行缓存全空 + acc/dst/OUT 排空机全闲 + 引擎空闲。
    // 注意不能要求 dst_flsh==dst_cnt：dstm 满 bank(1024B) 才排空，末组残块只在
    // 层尾补排；块间 dd_st==0 && !dd_pend 即表示所有满 bank 的写命令已发完，
    // eng_idle 进一步保证这些写已落 DDR。
    assign drain_ok =
                 eng_idle && rA_empty && rB_empty && (af_occ==6'd0) && (sf_occ==7'd0)
                 && (dr_st==2'd0) && !dr_pend
                 && (dd_st==2'd0) && !dd_pend
                 && (!g_dst_out || ((pst==P_IDLE) && !orb_full0 && !orb_full1));

    //================================================================= 命令仲裁（单驱动）
    // 优先级：style(层启动) > fill > acc排空 > dst排空 > p2预取 > OUT行命令
    assign cmd_we = g_s | g_f | g_a | g_d | g_qa | g_qs | g_p;
    assign cmd_wdata = g_s ? sty_cmdd :
                       g_f ? f_cmdd :
                       g_a ? a_cmdd :
                       g_d ? d_cmdd :
                       g_qs ? qs_cmdd :
                       g_qa ? qa_cmdd : p_cmdd;

    assign diag_pmem={fst,qst,dd_st,dr_st,p2_pend,p2_rdy,ab_rdy,ab_wrdy,dw_rdy,sk_rdy,q_off[12:0],dpc[3:0]};
    // AB07 observation only. Counts wrap modulo 65536; no control reads these.
    reg [15:0] dbg_fill,dbg_af,dbg_cmd,dbg_phase1_fill,dbg_phase1_af;
    always @(posedge clk) begin
      if(srst || lay_start) begin
        dbg_fill<=0;dbg_af<=0;dbg_cmd<=0;dbg_phase1_fill<=0;dbg_phase1_af<=0;
      end else begin
        if(fill_pop)dbg_fill<=dbg_fill+16'd1;
        if(af_push)dbg_af<=dbg_af+16'd1;
        if(g_f)dbg_cmd<=dbg_cmd+{3'd0,rb_beats_r};
        else if(g_qa)dbg_cmd<=dbg_cmd+{3'd0,q_acc_beats};
        if(p2_rise && p2_til==0)begin dbg_phase1_fill<=dbg_fill;dbg_phase1_af<=dbg_af;end
      end
    end
    assign diag_chunk={24'd0,q_take[7:0]};
    assign diag_counts={g_sk,q_acc_used[7:0],q_skip_used[7:0],af_occ,sf_occ};
    assign diag_totals={dbg_fill,dbg_af};
    assign diag_commands={16'd0,dbg_cmd};
    assign diag_phase1={dbg_phase1_fill,dbg_phase1_af};
    assign diag_geometry={g_rb,g_nslot,g_ic,g_oc,g_sk};
endmodule
