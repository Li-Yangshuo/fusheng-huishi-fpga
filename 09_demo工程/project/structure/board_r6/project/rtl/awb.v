/////////////////////////////////////////////////////////////////////////////
// awb.v
//
// Gray world automatic white balance.
//
// The debayer output (r/g/b, 2 pixels per clock) is accumulated over one
// frame, and the R and B channel gains (Q8.8) are nudged once per frame so
// that  mean(R) = mean(R target)  and  mean(B) = mean(B target).
//
// Green is the reference and is never changed.
//
// The three VIO trims are a LIVE manual colour-temperature control applied at
// the output (not part of the closed loop):
//    o_x_gain = awb_x * trim / 256      (trim clamped to 128..384)
//    trim = 256 -> x1.00 (neutral, default); larger red trim = warmer picture
// The automatic loop itself always aims at plain gray world.
//
// Update schedule ("fast convergence + slow self correction"):
//    phase 1  the first AWB_WARM frames after reset: every frame  (快速收敛)
//    phase 2  after that: one step every AWB_DIV frames (~1.5%/s)
//    Both phases require  scene_ok  (no single colour dominating the frame)
//    and a frame that is bright enough (see MIN_SUM / 暗场冻结).
//    A frame that is too dark freezes the loop AND arms a re-convergence, so
//    after the camera comes back out of the dark the white balance is rebuilt
//    within about 3 seconds instead of drifting green.
/////////////////////////////////////////////////////////////////////////////
module awb
#(
	parameter	MIN_SUM		= 32'd48000000,		// 平均亮度 < ~12/255 视为暗场
	parameter	G_MIN		= 16'd160,			// 0.625x
	parameter	G_MAX		= 16'd640			// 2.50x
)
(
	input					i_clk,
	input					i_rstn,

	input					i_de,
	input					i_vs,

	input	[15:0]			i_r,
	input	[15:0]			i_g,
	input	[15:0]			i_b,

	input	[15:0]			i_r_trim,
	input	[15:0]			i_g_trim,
	input	[15:0]			i_b_trim,

	output reg [15:0]		o_r_gain,
	output reg [15:0]		o_g_gain,
	output reg [15:0]		o_b_gain
);

//===========================================================================
// frame accumulation
//===========================================================================
reg	[31:0]	acc_r, acc_g, acc_b;
reg	[31:0]	sum_r, sum_g, sum_b;
reg			r_vs_1p;

always @(posedge i_clk or negedge i_rstn)
begin
	if (!i_rstn)
	begin
		acc_r	<= 32'd0;	acc_g	<= 32'd0;	acc_b	<= 32'd0;
		sum_r	<= 32'd0;	sum_g	<= 32'd0;	sum_b	<= 32'd0;
		r_vs_1p	<= 1'b0;
	end
	else
	begin
		r_vs_1p	<= i_vs;
		if (i_vs && !r_vs_1p)						// start of a new frame
		begin
			sum_r	<= acc_r;
			sum_g	<= acc_g;
			sum_b	<= acc_b;
			acc_r	<= 32'd0;
			acc_g	<= 32'd0;
			acc_b	<= 32'd0;
		end
		else if (i_de)
		begin
			acc_r	<= acc_r + {24'd0, i_r[7:0]} + {24'd0, i_r[15:8]};
			acc_g	<= acc_g + {24'd0, i_g[7:0]} + {24'd0, i_g[15:8]};
			acc_b	<= acc_b + {24'd0, i_b[7:0]} + {24'd0, i_b[15:8]};
		end
	end
end

// one pulse after the sums have been latched
reg	r_upd;

always @(posedge i_clk or negedge i_rstn)
begin
	if (!i_rstn)
		r_upd	<= 1'b0;
	else
		r_upd	<= (i_vs && !r_vs_1p);
end

//===========================================================================
// target ratios from the VIO trims
//===========================================================================
function [9:0] clamp_trim;
	input [15:0] t;
	begin
		if (t > 16'd384)
			clamp_trim = 10'd384;
		else if (t < 16'd128)
			clamp_trim = 10'd128;
		else
			clamp_trim = t[9:0];
	end
endfunction

wire	[9:0]	trim_r	= clamp_trim(i_r_trim);
wire	[9:0]	trim_b	= clamp_trim(i_b_trim);

// 自动白平衡的目标：中性（灰度世界），即 R/G/B 三个均值拉平。
// 手动色温微调不参与这里的闭环，而是放在输出端做乘法（见下面 o_x_gain），
// 这样即使 AWB 已经锁定，VIO 的 r_trim/b_trim 依然**实时**生效。
wire	[31:0]	tgt_r	= sum_g;
wire	[31:0]	tgt_b	= sum_g;

wire	[31:0]	deadband	= sum_g >> 6;
wire			upd_ok		= (sum_g > MIN_SUM);

//===========================================================================
// gain update
//===========================================================================
reg	[15:0]	awb_r, awb_b;

function [15:0] awb_step;
	input [15:0]	gain;
	input			too_low;
	input			too_high;
	reg	 [15:0]	nxt;
	begin
		if (too_low)
			nxt = gain + (gain >> 6) + 1'b1;
		else if (too_high)
			nxt = gain - (gain >> 6);
		else
			nxt = gain;

		if (nxt > G_MAX)		awb_step = G_MAX;
		else if (nxt < G_MIN)	awb_step = G_MIN;
		else					awb_step = nxt;
	end
endfunction

wire	too_low_r	= (sum_r + deadband) < tgt_r;
wire	too_high_r	= (sum_r > (tgt_r + deadband));
wire	too_low_b	= (sum_b + deadband) < tgt_b;
wire	too_high_b	= (sum_b > (tgt_b + deadband));

//---------------------------------------------------------------------------
// 工作方式：**快收敛 + 缓慢自修正**（不再"一锤定音"锁死）
//   阶段1  开机后前 AWB_WARM 次统计（≈2.7s）：每帧都调整，快速收敛
//   阶段2  之后：每 AWB_DIV 帧（64帧≈1.07s）才修正一步 → 约 1.5%/秒
//   两级都要求 scene_ok：画面被单一颜色占满（某通道均值超过另一通道
//   3 倍）时本帧不统计，避免"物体靠近 → 整幅偏蓝绿"
//   这样即使下载/上电那几秒镜头对着奇怪的东西，之后也能自己慢慢纠正回来；
//   而飞快晃过的物体既过不了 scene_ok、又只能影响很慢的修正，颜色不会跳。
//---------------------------------------------------------------------------
localparam [8:0] AWB_WARM = 9'd160;			// ≈2.7 秒 @60Hz 更新
localparam [5:0] AWB_DIV  = 6'd63;			// 之后每 64 帧修正一步

wire [23:0] n_r = sum_r[31:8];
wire [23:0] n_g = sum_g[31:8];
wire [23:0] n_b = sum_b[31:8];

wire	scene_ok	= (n_r < (n_g * 3)) && (n_g < (n_r * 3)) &&
				  (n_b < (n_g * 3)) && (n_g < (n_b * 3));

// 分频：快收敛期每帧都动，之后每 64 帧动一次
reg	[5:0]	r_div;

wire	fast_phase	= (r_lock_cnt < AWB_WARM);
wire	slow_tick	= (r_div == 6'd0);

wire	awb_en		= scene_ok && (fast_phase ? 1'b1 : slow_tick);

reg	[8:0]	r_lock_cnt;
reg			r_was_dark;						// 曾出现暗场 → 回到亮场时重新快速收敛

always @(posedge i_clk or negedge i_rstn)
begin
	if (!i_rstn)
	begin
		awb_r		<= 16'd256;
		awb_b		<= 16'd256;
		r_lock_cnt	<= 9'd0;
		r_div		<= 6'd0;
		r_was_dark	<= 1'b0;
	end
	else
	begin
		if (r_upd)
		begin
			r_div	<= r_div + 1'b1;

			if (!upd_ok)						// 本帧太暗：冻结并记住
				r_was_dark	<= 1'b1;
			else if (r_was_dark)				// 从暗场回到亮场：重新进入快收敛
			begin
				r_was_dark	<= 1'b0;
				r_lock_cnt	<= 9'd0;
			end
		end

		if (r_upd && upd_ok && awb_en)
		begin
			awb_r		<= awb_step(awb_r, too_low_r, too_high_r);
			awb_b		<= awb_step(awb_b, too_low_b, too_high_b);

			if (fast_phase)						// 快收敛期计数，满 AWB_WARM 后不再增加
				r_lock_cnt	<= r_lock_cnt + 1'b1;
		end
	end
end

//---------------------------------------------------------------------------
// 输出增益 = AWB 增益 × 手动色温微调(trim/256)
//   trim = 256(0x100) → ×1.00（中性，默认）
//   r_trim 调大 → 画面偏暖；b_trim 调大 → 画面偏冷
//   范围 128~384 = ×0.5~×1.5，锁定后依然实时生效
//---------------------------------------------------------------------------
wire	[31:0]	out_r_gain	= (awb_r * trim_r) >> 8;
wire	[31:0]	out_b_gain	= (awb_b * trim_b) >> 8;

wire	[15:0]	o_r_gain_n	= (out_r_gain > 32'd1023) ? 16'd1023 : out_r_gain[15:0];
wire	[15:0]	o_b_gain_n	= (out_b_gain > 32'd1023) ? 16'd1023 : out_b_gain[15:0];

always @(posedge i_clk or negedge i_rstn)
begin
	if (!i_rstn)
	begin
		o_r_gain	<= 16'd256;
		o_g_gain	<= 16'd256;
		o_b_gain	<= 16'd256;
	end
	else
	begin
		o_r_gain	<= o_r_gain_n;
		o_g_gain	<= 16'd256;
		o_b_gain	<= o_b_gain_n;
	end
end

endmodule
