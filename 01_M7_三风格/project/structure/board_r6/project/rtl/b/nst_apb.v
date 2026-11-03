//==============================================================================
// nst_apb.v — APB3 从机寄存器（v256：InstanceNorm 两阶段协作口）
//   pclk 域 = clk_axi。
//
//   0x00 CTRL  W: bit0 go(写1启动) bit1 sw_rst bit2 coef_go(写完系数写1放行)
//                R: bit16 irq_pending bit1 sw_rst
//   0x04 STYLE_BASE   权重 DDR 基址（16B 对齐）
//   0x08 IN_BASE      输入帧 DDR 基址
//   0x0C OUT_BASE     输出帧 DDR 基址
//   0x10 IRQ    W bit0 irq_en ; bit16 写1清中断
//   0x14 STATUS R bit0 busy bit1 done bit2 wait(等系数)
//   0x18 FRAME_CNT
//   0x1C IN_BUF_SEL  W/R bit0 乒乓 IN 帧选择（0/1）
//   0x50 OUT_STRIDE  W/R [31:0] OUT 行步长（字节，0=紧凑无 padding）
//   0x54 OUT_BUF     R   bit0 乒乓 OUT 缓冲号（硬件 all_done 翻转）
//   0x58 WORK_BASE   W/R [31:0] DDR 工作区基址（v3：P0/P1/P2/ACC 平面）
//   ---- RISC-V 协作窗口（wait=1 期间使用）----
//   0x20 STAT_IDX  W: 统计项索引 0..63（2*oc=sum, 2*oc+1=sumsq）
//   0x24 STAT_LO   R: 当前统计项 [31:0]（不增量）
//   0x28 STAT_HI   R: 当前统计项 [63:32]
//   0x2C STAT_EVT  R: 当前等待的层号 0..11（wait 上升沿计数）
//   0x40 COEF_IDX  W: 系数索引（norm: 0=Rq, 1+2o=Aq, 2+2o=Cq；tanh: o=Tzq）
//   0x44 COEF_LO  W: [31:0]
//   0x48 COEF_HI  W: [63:32]，写入时提交该 64bit 项并自动 idx+1
//
//   ---- ROM 初始化窗口（boot 时 RISC-V 下发 srom/brom/pwl，$readmemh 板上无效）----
//   0x60 ROM_SEL   W/R [1:0]  0=srom(12×64b) 1=brom(384×32b) 2=pwl(258×20b)
//   0x64 ROM_IDX   W/R [9:0]  写索引（ROM_HI 提交后自动 +1）
//   0x68 ROM_LO    W/R [31:0] 低 32 位
//   0x6C ROM_HI    W   [31:0] 高 32 位，写入时提交 {HI,LO} 并翻转 rom_tog、idx+1
//
// stat_flat 在 wait 期间保持稳定（clk_c 侧 seq 停在 S_WAIT），按准静态总线直读。
//==============================================================================
`timescale 1ns/1ps
module nst_apb (
    input  wire        pclk,
    input  wire        presetn,
    input  wire [15:0] paddr,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] pwdata,
    output reg         pready,
    output reg  [31:0] prdata,
    output wire        pslverr,

    output reg         go_pulse,
    output reg         sw_rst,
    output reg  [31:0] style_base,
    output reg  [31:0] in_base,
    output reg  [31:0] out_base,
    output reg  [31:0] work_base,      // v3 DDR 工作区（特征平面/acc）
    output reg         in_buf_sel,     // 乒乓 IN 帧选择（0/1）
    output reg  [31:0] out_stride,     // OUT 行步长（字节，0=紧凑）
    output reg         out_buf,        // 乒乓 OUT 缓冲号（all_done 翻转）
    output reg         irq_en,
    output wire        irq,

    input  wire        core_busy,      // clk_c 域
    input  wire        core_done,      // clk_c 域，完成脉冲/电平（DMA all_done）
    output reg  [31:0] frame_cnt,

    //---- 两阶段协作 ----
    input wire [31:0] diag0,diag1,diag2,diag3,diag4,diag5,diag6,diag7,diag8,diag9,
    input wire [63:0] stat_word,
    output reg [6:0] stat_idx,    // clk_c 准静态
    input  wire         wait_c,        // clk_c 电平
    output reg          cv_pulse,      // coef_go 脉冲（pclk 域，top 跨到 clk_c）
    output wire [4159:0] cf_flat,      // 65×64 系数

    //---- ROM 初始化写口（boot 时 RISC-V 经 APB 下发 srom/brom/pwl）----
    output reg  [1:0]  rom_sel,       // 0=srom 1=brom 2=pwl（保持值，提交时锁定）
    output reg  [9:0]  rom_idx,       // 写索引（提交时锁定，clk_c 读）
    output reg  [63:0] rom_wdata,      // {hi[31:0], lo[31:0]}
    output wire cf_write, output wire [6:0] cf_widx, output wire [63:0] cf_wdata,
    output reg         rom_tog        // 每次提交翻转（toggle 握手 pclk→clk_c）
);
    assign pslverr = 1'b0;

    //---- core 状态跨域同步（2FF）----
    reg busy_s1, busy_s2, done_s1, done_s2;
    reg wait_s1, wait_s2, wait_d;
    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            busy_s1<=0; busy_s2<=0; done_s1<=0; done_s2<=0;
            wait_s1<=0; wait_s2<=0; wait_d<=0;
        end else begin
            busy_s1 <= core_busy; busy_s2 <= busy_s1;
            done_s1 <= core_done; done_s2 <= done_s1;
            wait_s1 <= wait_c;    wait_s2 <= wait_s1;
            wait_d  <= wait_s2;
        end
    end
    wire wait_rise = wait_s2 & ~wait_d;

    //---- 等待事件计数（= 当前层号）；done 边沿帧计数；IRQ 锁存 ----
    reg [3:0] evt_cnt;
    reg irq_pend;
    reg done_d_r;
    always @(posedge pclk or negedge presetn)
        if (!presetn) done_d_r <= 1'b0;
        else          done_d_r <= done_s2;
    assign irq = irq_pend & irq_en;

    //---- 统计/系数窗口寄存器 ----
    reg [6:0] coef_idx;
    reg [31:0] coef_lo;
    reg signed [63:0] cf [0:64];

    //---- ROM 初始化窗口寄存器 ----
    reg [31:0] rom_d_lo;
    reg [9:0]  rom_idx_n;      // 下一写索引（APB 域自增计数器）
    reg [1:0]  rom_sel_n;      // 下一 ROM 选择（APB 配置，0x60 写）

    genvar gi;
    generate
        for (gi = 0; gi < 65; gi = gi + 1) begin : G_CF
            assign cf_flat[gi*64 +: 64] = cf[gi];
        end
    endgenerate

    // Common-clock synchronous statistics query; index precedes APB read setup.

    wire apb_wr = psel & penable & pwrite;
    wire apb_rd = psel & ~pwrite;

    always @(*) begin
        pready = 1'b1;
        prdata = 32'd0;
        if (apb_rd) begin
            case (paddr[7:2])
                6'd0:  prdata = {15'd0, irq_pend, 8'd0, wait_s2, 2'd0, sw_rst, 1'b0};
                6'd1:  prdata = style_base;
                6'd2:  prdata = in_base;
                6'd3:  prdata = out_base;
                6'd4:  prdata = {31'd0, irq_en};
                6'd5:  prdata = {29'd0, wait_s2, done_s2, busy_s2};
                6'd6:  prdata = frame_cnt;
                6'd7:  prdata = {31'd0, in_buf_sel};
                6'd9:  prdata = stat_word[31:0];
                6'd10: prdata = stat_word[63:32];
                6'd11: prdata = {28'd0, evt_cnt};
                6'd12: prdata=diag0;
                6'd13: prdata=diag1;
                6'd14: prdata=diag2;
                6'd15: prdata=diag3;
                6'd19: prdata=diag4; // 0x4c q usage and operand occupancy
                6'd23: prdata=diag5; // 0x5c fill/AF beat totals
                6'd28: prdata=diag6; // 0x70 RA pointers and chunk size
                6'd29: prdata=diag7; // 0x74 received/commanded A beats
                6'd30: prdata=diag8; // 0x78 totals before first phase2 tile
                6'd31: prdata=diag9; // 0x7c source row bytes and geometry
                6'd20: prdata = out_stride;
                6'd21: prdata = {31'd0, out_buf};
                6'd22: prdata = work_base;
                6'd24: prdata = {30'd0, rom_sel_n};
                6'd25: prdata = {22'd0, rom_idx_n};
                6'd26: prdata = rom_d_lo;
                6'd27: prdata = rom_wdata[63:32];
                default: prdata = 32'd0;
            endcase
        end
    end

    assign cf_write=apb_wr && paddr[7:2]==6'd18;
    assign cf_widx=coef_idx;
    assign cf_wdata={pwdata,coef_lo};
    //---- 统一时钟域寄存器块（合并 Block3+Block5，避免多重驱动）----
    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            go_pulse <= 1'b0;
            sw_rst <= 1'b0;
            cv_pulse <= 1'b0;
            style_base<=0; in_base<=0; out_base<=0; work_base<=0; irq_en<=0;
            in_buf_sel<=0; out_stride<=0; out_buf<=0;
            stat_idx<=0; coef_idx<=0; coef_lo<=0;
            evt_cnt <= 0; irq_pend <= 0; frame_cnt <= 0;
            rom_sel<=0; rom_sel_n<=0; rom_idx<=0; rom_idx_n<=0; rom_d_lo<=0; rom_wdata<=0; rom_tog<=0;
        end else begin
            go_pulse <= 1'b0;
            cv_pulse <= 1'b0;
            // 事件计数 / IRQ 锁存 / 帧计数 / out_buf 翻转
            if (go_pulse)     evt_cnt <= 4'd0;
            else if (wait_rise) evt_cnt <= evt_cnt + 4'd1;
            if (wait_rise) irq_pend <= 1'b1;
            if (done_s2 && !done_d_r) begin
                irq_pend  <= 1'b1;
                frame_cnt <= frame_cnt + 32'd1;
                out_buf   <= ~out_buf;
            end
            // APB 写
            if (apb_wr) begin
                case (paddr[7:2])
                    6'd0: begin
                        sw_rst <= pwdata[1];
                        if (pwdata[0]) go_pulse <= 1'b1;
                        if (pwdata[2]) cv_pulse <= 1'b1;
                    end
                    6'd1: style_base <= pwdata;
                    6'd2: in_base    <= pwdata;
                    6'd3: out_base   <= pwdata;
                    6'd7: in_buf_sel <= pwdata[0];
                    6'd4: begin
                        irq_en <= pwdata[0];
                        if (pwdata[16]) irq_pend <= 1'b0;   // APB 清中断优先
                    end
                    6'd8:  stat_idx <= pwdata[6:0];
                    6'd16: coef_idx <= pwdata[6:0];
                    6'd17: coef_lo  <= pwdata;
                    6'd18: begin
                        cf[coef_idx] <= $signed({pwdata, coef_lo});
                        coef_idx <= coef_idx + 7'd1;
                    end
                    6'd20: out_stride <= pwdata;
                    6'd22: work_base  <= pwdata;
                    6'd24: rom_sel_n  <= pwdata[1:0];           // 0x60 ROM_SEL（下一 ROM）
                    6'd25: rom_idx_n  <= pwdata[9:0];           // 0x64 ROM_IDX（下一写索引）
                    6'd26: rom_d_lo   <= pwdata;               // 0x68 ROM_LO
                    6'd27: begin                              // 0x6C ROM_HI — 提交
                        rom_wdata <= {pwdata, rom_d_lo};
                        rom_sel   <= rom_sel_n;               // 锁定当前 sel（clk_c 读）
                        rom_idx   <= rom_idx_n;               // 锁定当前写索引（clk_c 读）
                        rom_tog   <= ~rom_tog;
                        rom_idx_n <= rom_idx_n + 10'd1;       // 自增下一索引
                    end
                    default: ;
                endcase
            end
        end
    end

    //---- 系数块初值：依赖 !presetn 复位路径清零（L142-149）。
    //    Efinity 综合对 reg 数组 initial 不保证上电初值，已移除。
endmodule
