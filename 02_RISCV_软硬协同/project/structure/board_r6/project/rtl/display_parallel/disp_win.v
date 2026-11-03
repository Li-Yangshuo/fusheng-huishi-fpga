// ============================================================================
// disp_win.v — 窗口扫描 + 最近邻放大（pclk 域）
//
// 从行缓存双槽按源像素地址取数，把 act 帧（width×height）最近邻放大到
// WIN_W×WIN_H 窗口，窗口放在 (WIN_X0, WIN_Y0)。窗口外 out_rgb=0、
// out_active=0（叠加由集成方做）。
//
// 放大映射（Bresenham，方向与 scale_wr 相反：这里是 1 源像素 → 多输出像素）：
//   输出像素 (ox,oyr) 取源 (floor(ox*act_w/WIN_W), floor(oyr*act_h/WIN_H))
//   横向：每窗口像素 xacc+=act_w，xacc>=WIN_W 则 sx++、xacc-=WIN_W（ upscale
//         约束 act_w<=WIN_W，每拍最多进 1）
//   纵向：每窗口行尾 yacc+=act_h，yacc>=WIN_H 则 sy++、yacc-=WIN_H
//   一条源行会被连续 15/4≈3.75 条输出行复用，最后一复用行尾才释放槽位。
//
// 槽位握手（pclk 侧）：
//   槽有新行 = wr_tgl 同步值 != 本地 rd_tgl；行号/帧号低8位随 toggle 准静态
//   过域（写侧翻 toggle 到本侧翻 rd_tgl 之间不变）。行首窗口像素"抓取"：
//   A16.6: 元数据两级采样，发布toggle三级同步，避免先看到发布再看到数据。
//   新行 && 帧号匹配 act && 行号==sy → 本行可用；抓不到 → 整行品红
//   24'hFF00FF + underrun 计数/sticky。组尾（sy 推进）翻 rd_tgl 释放。
//   废弃清理：帧号不匹配（换帧遗留）或扫描区内过期行（欠载迟到）立即释放。
//   帧号匹配但行号≠sy 且≠sy+1 的丢弃只在扫描区（oy<WIN_Y0+WIN_H）内做——
//   场消隐期读侧会预取下一遍的行 0/1，不能误丢。
//
// 帧元数据：pub_* 准静态 + pub_tgl 过域；本模块只在帧边界（in_vs 下降沿）
// 锁存新帧 → 本扫描周期内窗口输出恒为同一帧（不撕裂），锁存同时翻
// disp_sw_tgl 通知 frm_rd 可以归还旧帧。
//
// 输出延迟：in_de 像素 → out_rgb/out_active 固定 2 拍（RAM 读 1 拍 + 输出
// 寄存 1 拍）。in_hs 未用（行尾用 in_de 下降沿），保留仅为接口契约。
// ============================================================================
module disp_win #(
    parameter integer WIN_X0 = 960,
    parameter integer WIN_Y0 = 180,
    parameter integer WIN_W  = 960,
    parameter integer WIN_H  = 720,
    parameter integer AW     = 10,
    parameter integer MIRROR_LEFT = 0
)(
    input  wire        pclk,
    input  wire        prstn,
    input  wire        in_vs,
    input  wire        in_hs,
    input  wire        in_de,

    // 行缓存读口（两槽各一）
    output wire [AW-1:0] lb_raddr0,
    output wire [AW-1:0] lb_raddr1,
    output wire        lb_re0,
    output wire        lb_re1,
    input  wire [23:0] lb_rdata0,
    input  wire [23:0] lb_rdata1,

    // 槽位握手（异步输入，本模块内打拍；rd_tgl 回 axi 域由 frm_rd 打拍）
    input  wire        wr_tgl0,
    input  wire        wr_tgl1,
    input  wire [15:0] slot_line0,
    input  wire [15:0] slot_line1,
    input  wire [31:0]  slot_fid0,
    input  wire [31:0]  slot_fid1,
    output reg         rd_tgl0,
    output reg         rd_tgl1,

    // 发布元数据（axi 域准静态 + toggle，本模块内打拍）
    input  wire        pub_valid,
    input  wire        pub_tgl,
    input  wire [31:0] pub_id,
    input  wire [15:0] pub_width,
    input  wire [15:0] pub_height,
    output reg         disp_sw_tgl,

    input  wire        frm_err_async,       // frm_rd 的 frm_err（单 bit）

    // 输出
    output reg  [23:0] out_rgb,
    output reg         out_active,
    output reg  [31:0] curr_frame_id,
    output reg         frm_err,
    output reg  [15:0] underrun_cnt,
    output reg [31:0] miss_expected_slot0,miss_slot1_flags,
    output reg         underrun_sticky,
    output wire        validation_pause
);

// ---------------------------------------------------------------------------
// 跨域打拍（axi -> pclk）。toggle 用 3FF；准静态多位元数据用 2FF。
// 发布有效比数据采样多等待一拍；读侧翻 rd_tgl 前，源端保持元数据不变。
// ---------------------------------------------------------------------------
// Bundled metadata uses two sampling stages. Delay its validity event by an
// additional destination cycle so a one-cycle data/event capture skew cannot
// make stale cleanup acknowledge a freshly published slot using old metadata.
(* async_reg="true" *) reg [2:0] wr_tgl0_s, wr_tgl1_s;
(* async_reg="true" *) reg [2:0] pub_tgl_s, pub_valid_s;
(* async_reg="true" *) reg [1:0] frm_err_s;
reg [15:0] slot_line0_s0, slot_line0_s1, slot_line1_s0, slot_line1_s1;
reg [31:0]  slot_fid0_s0,  slot_fid0_s1,  slot_fid1_s0,  slot_fid1_s1;
reg [31:0] pub_id_s0, pub_id_s1;
reg [15:0] pub_w_s0, pub_w_s1, pub_h_s0, pub_h_s1;

always @(posedge pclk or negedge prstn) begin
    if (!prstn) begin
        wr_tgl0_s <= 3'b000; wr_tgl1_s <= 3'b000;
        pub_tgl_s <= 3'b000; pub_valid_s <= 3'b000; frm_err_s <= 2'b00;
        slot_line0_s0 <= 16'd0; slot_line0_s1 <= 16'd0;
        slot_line1_s0 <= 16'd0; slot_line1_s1 <= 16'd0;
        slot_fid0_s0 <= 8'd0; slot_fid0_s1 <= 8'd0;
        slot_fid1_s0 <= 8'd0; slot_fid1_s1 <= 8'd0;
        pub_id_s0 <= 32'd0; pub_id_s1 <= 32'd0;
        pub_w_s0 <= 16'd0; pub_w_s1 <= 16'd0;
        pub_h_s0 <= 16'd0; pub_h_s1 <= 16'd0;
    end else begin
        wr_tgl0_s <= {wr_tgl0_s[1:0], wr_tgl0};
        wr_tgl1_s <= {wr_tgl1_s[1:0], wr_tgl1};
        pub_tgl_s <= {pub_tgl_s[1:0], pub_tgl};
        pub_valid_s <= {pub_valid_s[1:0], pub_valid};
        frm_err_s <= {frm_err_s[0], frm_err_async};
        slot_line0_s0 <= slot_line0; slot_line0_s1 <= slot_line0_s0;
        slot_line1_s0 <= slot_line1; slot_line1_s1 <= slot_line1_s0;
        slot_fid0_s0 <= slot_fid0; slot_fid0_s1 <= slot_fid0_s0;
        slot_fid1_s0 <= slot_fid1; slot_fid1_s1 <= slot_fid1_s0;
        pub_id_s0 <= pub_id; pub_id_s1 <= pub_id_s0;
        pub_w_s0 <= pub_width; pub_w_s1 <= pub_w_s0;
        pub_h_s0 <= pub_height; pub_h_s1 <= pub_h_s0;
    end
end

// ---------------------------------------------------------------------------
// 当前帧元数据（帧边界锁存，帧内恒定）
// ---------------------------------------------------------------------------
reg [31:0] act_id;
reg [15:0] act_w, act_h;
reg        has_frame;
reg        pub_seen;

// ---------------------------------------------------------------------------
// 扫描坐标
// ---------------------------------------------------------------------------
reg [11:0] vx;              // 行内像素计数（de 有效期）
reg [11:0] oy;              // 场内行计数
reg        de_d, vs_d;
// Reserve the complete visible window for deadline-sensitive display refills.
// Begin one output row early so an already accepted validation burst can drain.
assign validation_pause=has_frame &&
                       oy >= ((WIN_Y0>0) ? WIN_Y0-1 : 0) && oy < WIN_Y0+WIN_H;
wire frame_start =  vs_d && !in_vs;         // vs 下降沿 = 帧开始
wire line_end    =  de_d && !in_de;         // de 下降沿 = 行尾

wire right_window = (vx >= WIN_X0[11:0]) && (vx < WIN_X0[11:0]+WIN_W[11:0]);
wire left_window = MIRROR_LEFT && (vx < WIN_W[11:0]);
wire in_window = in_de && (right_window || left_window)
              && (oy >= WIN_Y0[11:0]) && (oy < WIN_Y0[11:0]+WIN_H[11:0]);
// Both halves consume the same held row. Only the left half acquires it;
// the right half cannot retry a missed row and silently show another image.
wire first_win_px = in_window && (vx == (MIRROR_LEFT ? 12'd0 : WIN_X0[11:0]));
wire mirror_restart = MIRROR_LEFT && in_window && vx == WIN_X0[11:0];

// ---------------------------------------------------------------------------
// Bresenham 放大坐标
// ---------------------------------------------------------------------------
reg [11:0] sx;              // 源列
reg [15:0] xacc;
reg [15:0] sy;              // 源行（当前输出行组）
reg [15:0] yacc;

wire [16:0] xsum = {1'b0, xacc} + {1'b0, act_w};
wire [16:0] ysum = {1'b0, yacc} + {1'b0, act_h};
wire        last_grp = (ysum >= {1'b0, WIN_H[15:0]});   // 本行是本源行最后复用行

// ---------------------------------------------------------------------------
// 槽位抓取/释放
// ---------------------------------------------------------------------------
reg cur_slot;               // 本行组持有槽
reg line_good;              // 本行组槽有效
reg released_early;

wire new0 = (wr_tgl0_s[2] != rd_tgl0);
wire new1 = (wr_tgl1_s[2] != rd_tgl1);
wire match0 = new0 && (slot_fid0_s1 == act_id) && (slot_line0_s1 == sy);
wire match1 = new1 && (slot_fid1_s1 == act_id) && (slot_line1_s1 == sy);
wire grab_ok   = has_frame && (match0 || match1);
wire grab_slot = match0 ? 1'b0 : 1'b1;
wire sel_comb  = first_win_px ? grab_slot : cur_slot;

// 废弃判定：旧帧号一律丢；扫描区内行号落后（欠载迟到）也丢
wire [15:0] next_sy = (sy == act_h - 16'd1) ? 16'd0 : sy + 16'd1;
wire        in_scan = (oy < WIN_Y0[11:0] + WIN_H[11:0]);
wire held0  = (line_good && !cur_slot) || (first_win_px && grab_ok && !grab_slot);
wire held1  = (line_good &&  cur_slot) || (first_win_px && grab_ok &&  grab_slot);
wire stale0 = new0 && !held0 && has_frame &&
              ((slot_fid0_s1 != act_id) ||
               (in_scan && slot_line0_s1 != sy && slot_line0_s1 != next_sy));
wire stale1 = new1 && !held1 && has_frame &&
              ((slot_fid1_s1 != act_id) ||
               (in_scan && slot_line1_s1 != sy && slot_line1_s1 != next_sy));

assign lb_raddr0 = mirror_restart ? {AW{1'b0}} : sx[AW-1:0];
assign lb_raddr1 = mirror_restart ? {AW{1'b0}} : sx[AW-1:0];
assign lb_re0 = in_window && !sel_comb;
assign lb_re1 = in_window &&  sel_comb;

// ---------------------------------------------------------------------------
// 输出流水线：T 拍窗口像素发 RAM 读 → T+1 rdata 有效 → 寄存后 T+2 出
// ---------------------------------------------------------------------------
reg        winA;
reg        selA;
reg        goodA;
reg        leftA, rightA;
reg [11:0] colA;
wire [23:0] mirror_rgb;
generate if (MIRROR_LEFT) begin : g_mirror_line
    localparam integer MAW = (WIN_W>1) ? $clog2(WIN_W) : 1;
    wire [11:0] right_col = vx-WIN_X0[11:0];
    // Snapshot the scaled left row before returning the AXI cache slot.
    // The right half reads this pixel-clock RAM, so refilling the released
    // source slot cannot change pixels already displayed on the left.
    simple_dual_port_ram #(.DATA_WIDTH(24),.ADDR_WIDTH(MAW),.OUTPUT_REG("FALSE")) row_copy (
        .wclk(pclk),.we(leftA && goodA),.waddr(colA[MAW-1:0]),
        .wdata(selA ? lb_rdata1 : lb_rdata0),
        .rclk(pclk),.re(in_window && right_window),
        .raddr(right_col[MAW-1:0]),.rdata(mirror_rgb));
end else begin : g_no_mirror_line
    assign mirror_rgb=24'd0;
end endgenerate

always @(posedge pclk or negedge prstn) begin
    if (!prstn) begin
        vx <= 12'd0; oy <= 12'd0; de_d <= 1'b0; vs_d <= 1'b0;
        sx <= 12'd0; xacc <= 16'd0; sy <= 16'd0; yacc <= 16'd0;
        act_id <= 32'd0; act_w <= 16'd0; act_h <= 16'd0;
        has_frame <= 1'b0; pub_seen <= 1'b0; disp_sw_tgl <= 1'b0;
        cur_slot <= 1'b0; line_good <= 1'b0;
        released_early <= 1'b0;
        leftA <= 1'b0; rightA <= 1'b0; colA <= 0;
        rd_tgl0 <= 1'b0; rd_tgl1 <= 1'b0;
        winA <= 1'b0; selA <= 1'b0; goodA <= 1'b0;
        out_rgb <= 24'd0; out_active <= 1'b0;
        curr_frame_id <= 32'd0; frm_err <= 1'b0;
        underrun_cnt <= 16'd0; underrun_sticky <= 1'b0;
        miss_expected_slot0<=0;miss_slot1_flags<=0;
    end else begin
        de_d <= in_de;
        vs_d <= in_vs;
        frm_err <= frm_err_s[1];

        // ---- 坐标推进 ----
        if (frame_start) begin
            vx <= 12'd0;
            oy <= 12'd0;
        end else begin
            if (!in_de) vx <= 12'd0;
            else if (vx != 12'hFFF) vx <= vx + 12'd1;
            if (line_end) oy <= oy + 12'd1;
        end

        // ---- 帧边界：锁存新发布帧（帧内不撕裂）+ 回执 toggle ----
        if (frame_start) begin
            sy   <= 16'd0;
            yacc <= 16'd0;
            if (line_good && !released_early) begin // only acknowledge once
                if (cur_slot) rd_tgl1 <= ~rd_tgl1;
                else          rd_tgl0 <= ~rd_tgl0;
                line_good <= 1'b0;
            end
            line_good <= 1'b0;
            released_early <= 1'b0;
            if (pub_valid_s[2] && (pub_tgl_s[2] != pub_seen)) begin
                pub_seen      <= pub_tgl_s[2];
                act_id        <= pub_id_s1;
                act_w         <= pub_w_s1;
                act_h         <= pub_h_s1;
                has_frame     <= 1'b1;
                curr_frame_id <= pub_id_s1;
                disp_sw_tgl   <= ~disp_sw_tgl;
            end
        end else if (line_end && oy >= WIN_Y0[11:0] && oy < WIN_Y0[11:0]+WIN_H[11:0]
                     && has_frame) begin
            // ---- 窗口行尾：纵向 Bresenham 推进；组尾/窗口末行释放槽位 ----
            if (last_grp) begin
                sy   <= sy + 16'd1;
                yacc <= ysum[15:0] - WIN_H[15:0];
            end else begin
                yacc <= ysum[15:0];
            end
            if (last_grp || oy == WIN_Y0[11:0] + WIN_H[11:0] - 12'd1) begin
                if (line_good && !released_early) begin
                    if (cur_slot) rd_tgl1 <= ~rd_tgl1;
                    else          rd_tgl0 <= ~rd_tgl0;
                end
                line_good <= 1'b0;
            end
            released_early <= 1'b0;
        end

        // Last left pixel has been sampled into row_copy on this edge.
        // Release at the midpoint, restoring the refill slack of A16.6.
        if (mirror_restart && last_grp && line_good) begin
            if (cur_slot) rd_tgl1 <= ~rd_tgl1;
            else          rd_tgl0 <= ~rd_tgl0;
            released_early <= 1'b1;
        end

        // ---- 窗口行首抓取槽位 ----
        if (first_win_px) begin
            line_good <= grab_ok;
            cur_slot  <= grab_slot;
            if (has_frame && !grab_ok) begin
                if(!underrun_sticky)begin
                    miss_expected_slot0<={sy,slot_line0_s1};
                    miss_slot1_flags<={slot_line1_s1,12'd0,(slot_fid1_s1==act_id),(slot_fid0_s1==act_id),new1,new0};
                end
                underrun_cnt    <= underrun_cnt + 16'd1;
                underrun_sticky <= 1'b1;
            end
        end

        // ---- 废弃槽清理（欠载迟到行/换帧遗留行立即还给写侧）----
        if (stale0) rd_tgl0 <= ~rd_tgl0;
        if (stale1) rd_tgl1 <= ~rd_tgl1;

        // ---- 横向 Bresenham ----
        if (!in_window) begin
            sx   <= 12'd0;
            xacc <= 16'd0;
        end else if (mirror_restart) begin
            // Request source x=0 now; advance the accumulator for the next pixel.
            if(act_w >= WIN_W) begin
                sx <= 12'd1;
                xacc <= act_w-WIN_W;
            end else begin
                sx <= 12'd0;
                xacc <= act_w;
            end
        end else if (xsum >= {1'b0, WIN_W[15:0]}) begin
            sx   <= sx + 12'd1;
            xacc <= xsum[15:0] - WIN_W[15:0];
        end else begin
            xacc <= xsum[15:0];
        end

        // ---- 输出流水线（恒定 2 拍延迟）----
        winA <= in_window;
        leftA <= in_window && left_window;
        rightA <= in_window && MIRROR_LEFT && right_window;
        colA <= vx;
        selA <= sel_comb;
        goodA <= first_win_px ? grab_ok : line_good;
        out_active <= winA;
        if (!winA)
            out_rgb <= 24'h000000;          // 窗口外输出 0
        else if (!has_frame)
            out_rgb <= 24'h000000;          // 无帧：黑
        else if (goodA)
            out_rgb <= rightA ? mirror_rgb : (selA ? lb_rdata1 : lb_rdata0);
        else
            out_rgb <= 24'hFF00FF;          // 欠载：品红
    end
end

endmodule
