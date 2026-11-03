/////////////////////////////////////////////////////////////////////////////
// split_view.v
//
// 把 1920x1080 的显示画面左右分成两屏（各 960 像素宽），两屏显示**完全相同**
// 的画面。取景方式由参数 VIEW_MODE 选择：
//
//   VIEW_MODE = 0 （默认）居中裁剪：
//       取摄像头画面正中间 960 列（x = 480..1439），1:1 原样送到左右两屏。
//       **不缩放、不插值** —— 每个像素和单屏时完全一样，所以画面不变形、
//       清晰度和颜色都与单屏效果一致；代价是看不到左右各 480 列。
//
//   VIEW_MODE = 1  横向 2:1 缩小（压扁）：
//       整幅画面横向平均缩小成 960 像素，左右两屏各显示一份完整画面，
//       内容全，但画面被横向压扁 2:1。
//
// 实现（输入是 1 像素/时钟的 RGB，hdmi_tx_slow_clk 148.5MHz，每行 1920 像素）：
//   写侧：把要显示的 960 个像素按行写入行缓存；行末切换 bank（ping-pong），
//         保证读的是上一行写好的数据。
//   读侧：输出位置 xr = 0..1919，读地址 = xr mod 960
//         → 左半屏(xr<960) 与右半屏(xr>=960) 读到同一组数据，两屏完全一致。
//   读的是上一行数据 ⇒ 画面整体下移 1 行（看不出）；每帧第一行输出黑，
//   避免读到上一帧残留。
//
// SPLIT_EN = 0 时完全直通（不分屏），仅延迟 2 拍，用于对照实验。
/////////////////////////////////////////////////////////////////////////////
module split_view
#(
	parameter	SPLIT_EN	= 1'b1,
	parameter	VIEW_MODE	= 1'b0		// 0 = 居中裁剪(1:1)  1 = 横向压扁
)
(
	input				i_clk,			// hdmi_tx_slow_clk 148.5MHz
	input				i_rstn,

	input				i_de,
	input				i_hs,
	input				i_vs,
	input	[7:0]		i_r,
	input	[7:0]		i_g,
	input	[7:0]		i_b,

	output	reg			o_de,
	output	reg			o_hs,
	output	reg			o_vs,
	output	reg	[7:0]	o_r,
	output	reg	[7:0]	o_g,
	output	reg	[7:0]	o_b
);

localparam	H_TOTAL		= 11'd1920;		// 每行有效像素数
localparam	H_HALF		= 11'd960;		// 半屏宽度 = 行缓存深度
localparam	H_CROP		= 11'd480;		// 裁剪窗口起点（居中取 960 列）

//===========================================================================
// 行内像素计数（输入位置 = 输出位置：0..1919）
//===========================================================================
reg	[10:0]	r_x;
reg			r_de_d;
reg			r_vs_d;

always @(posedge i_clk or negedge i_rstn)
begin
	if (!i_rstn)
	begin
		r_x		<= 11'd0;
		r_de_d	<= 1'b0;
		r_vs_d	<= 1'b0;
	end
	else
	begin
		r_de_d	<= i_de;
		r_vs_d	<= i_vs;

		if (!i_de)
			r_x	<= 11'd0;
		else if (r_x != H_TOTAL - 1'b1)
			r_x	<= r_x + 1'b1;
	end
end

wire	w_line_end	= r_de_d & ~i_de;			// 行结束
wire	w_vs_fall	= r_vs_d & ~i_vs;			// 帧开始

//===========================================================================
// 写侧：bank 每行切换
//===========================================================================
reg	[23:0]	wr_data;
reg	[9:0]	wr_addr10;
reg			wr_en;
reg			r_wr_bank;
reg			r_first;						// 本帧第一行（读的 bank 还没写过）

reg	[7:0]	acc_r, acc_g, acc_b;			// 压扁模式：本对的第 1 个像素
reg			r_even;

wire	w_in_win	= (r_x >= H_CROP) && (r_x < (H_CROP + H_HALF));

always @(posedge i_clk or negedge i_rstn)
begin
	if (!i_rstn)
	begin
		wr_data		<= 24'd0;
		wr_addr10	<= 10'd0;
		wr_en		<= 1'b0;
		r_wr_bank	<= 1'b0;
		r_first		<= 1'b1;
		acc_r		<= 8'd0;
		acc_g		<= 8'd0;
		acc_b		<= 8'd0;
		r_even		<= 1'b0;
	end
	else if (w_vs_fall)
	begin
		r_wr_bank	<= 1'b0;
		r_even		<= 1'b0;
		wr_en		<= 1'b0;
		r_first		<= 1'b1;
	end
	else if (w_line_end)
	begin
		r_wr_bank	<= ~r_wr_bank;
		r_even		<= 1'b0;
		wr_en		<= 1'b0;
		r_first		<= 1'b0;
	end
	else if (i_de)
	begin
		if (VIEW_MODE)
		begin
			// ---- 横向 2:1 平均（压扁模式）----
			if (!r_even)
			begin
				acc_r	<= i_r;
				acc_g	<= i_g;
				acc_b	<= i_b;
				r_even	<= 1'b1;
				wr_en	<= 1'b0;
			end
			else
			begin
				wr_data		<= { (acc_r + i_r) >> 1,
								(acc_g + i_g) >> 1,
								(acc_b + i_b) >> 1 };
				wr_addr10	<= r_x[10:1];
				wr_en		<= 1'b1;
				r_even		<= 1'b0;
			end
		end
		else
		begin
			// ---- 居中裁剪：窗口内像素按 1:1 存入 ----
			if (w_in_win)
			begin
				wr_data		<= {i_r, i_g, i_b};
				wr_addr10	<= r_x - H_CROP;
				wr_en		<= 1'b1;
			end
			else
				wr_en	<= 1'b0;
		end
	end
	else
	begin
		wr_en	<= 1'b0;
		r_even	<= 1'b0;
	end
end

//===========================================================================
// 读侧：地址 = xr mod 960，读另一 bank（上一行写入的）
//===========================================================================
wire	[9:0]	rd_addr10	= (r_x < H_HALF) ? r_x[9:0] : (r_x - H_HALF);
wire	[10:0]	rd_addr		= { ~r_wr_bank, rd_addr10 };
wire	[10:0]	wr_addr		= {   r_wr_bank, wr_addr10 };

wire	[23:0]	ram_pix;

true_dual_port_ram
#(
	.DATA_WIDTH		(24),
	.ADDR_WIDTH		(11),
	.WRITE_MODE_1	("READ_FIRST"),
	.WRITE_MODE_2	("READ_FIRST"),
	.OUTPUT_REG_1	("TRUE"),
	.OUTPUT_REG_2	("TRUE"),
	.RAM_INIT_FILE	("")
)
inst_split_ram
(
	.we1	(wr_en		),
	.clka	(i_clk		),
	.din1	(wr_data	),
	.addr1	(wr_addr	),
	.dout1	(			),

	.we2	(1'b0		),
	.clkb	(i_clk		),
	.din2	(24'd0		),
	.addr2	(rd_addr	),
	.dout2	(ram_pix	)
);

//===========================================================================
// 直通旁路（2 拍延迟，与 RAM 通路对齐）
//===========================================================================
reg	[23:0]	byp_0, byp_1;

always @(posedge i_clk or negedge i_rstn)
begin
	if (!i_rstn)
	begin
		byp_0	<= 24'd0;
		byp_1	<= 24'd0;
	end
	else
	begin
		byp_0	<= {i_r, i_g, i_b};
		byp_1	<= byp_0;
	end
end

//===========================================================================
// 同步信号延迟 2 拍 + 输出
//===========================================================================
reg	[1:0]	dly_de, dly_hs, dly_vs;

always @(posedge i_clk or negedge i_rstn)
begin
	if (!i_rstn)
	begin
		dly_de	<= 2'd0;
		dly_hs	<= 2'd0;
		dly_vs	<= 2'd0;
	end
	else
	begin
		dly_de	<= {dly_de[0], i_de};
		dly_hs	<= {dly_hs[0], i_hs};
		dly_vs	<= {dly_vs[0], i_vs};
	end
end

wire	[23:0]	out_pix	= SPLIT_EN ? ram_pix : byp_1;
wire			out_vld	= dly_de[1] & ~(SPLIT_EN & r_first);

always @(posedge i_clk or negedge i_rstn)
begin
	if (!i_rstn)
	begin
		o_de	<= 1'b0;
		o_hs	<= 1'b0;
		o_vs	<= 1'b0;
		o_r		<= 8'd0;
		o_g		<= 8'd0;
		o_b		<= 8'd0;
	end
	else
	begin
		o_de	<= out_vld;
		o_hs	<= dly_hs[1];
		o_vs	<= dly_vs[1];
		o_r		<= out_vld ? out_pix[23:16] : 8'd0;
		o_g		<= out_vld ? out_pix[15:8]  : 8'd0;
		o_b		<= out_vld ? out_pix[7:0]   : 8'd0;
	end
end

endmodule
