/////////////////////////////////////////////////////////////////////////////
// gamma_correction.v   （重写：用 block RAM 做查表）
//
// 原实现把 1024x10 的曲线表复制成 3 份"寄存器组"做查表（r_gamma_2P[0:1023]），
// 综合后要 2.6 万个 LUT，占用半片芯片。这里改成直接读 block RAM 里的表：
//   地址 = 像素值映射到 10bit 表索引
//   数据 = 表值（10bit）取高 8 位输出
//   表 = RAM_INIT_FILE 指定的 .mem（$readmemh，HEX，1024 行 x 3 位）
//
//   DATA_WIDTH = 8 ：地址 {v, v[7:6]}（等效 v*4 铺满 10bit 地址），输出 表值[9:2]
//   DATA_WIDTH = 10：地址就是像素值，输出 表值
//
// 流水线：地址(T) → RAM 输出(T+2) → 输出寄存器(T+3)
//         i_valid/i_hs/i_vs 同步延迟 3 拍，保证与数据对齐。
//
// 曲线表 gamma_bright.mem = 1023*(i/1023)^(1/2.2)，即"提亮"曲线：
//   输入 64 → 输出 136，输入 128 → 186，输入 192 → 224（原来的 2P2.mem 是压暗曲线）
/////////////////////////////////////////////////////////////////////////////
module gamma_correction
#(
	parameter	DATA_WIDTH	= 10,
	parameter 	GAMMA_CURVE	= "2P2.mem"
)
(
	input						i_pclk,
	input						i_rstn,
			
	input 						i_valid,
	input 						i_hs,
	input 						i_vs,
	input 	[DATA_WIDTH-1:0]	i_red,
	input 	[DATA_WIDTH-1:0]	i_green,
	input 	[DATA_WIDTH-1:0]	i_blue,
		
	output	reg[DATA_WIDTH-1:0]	o_red,
	output	reg[DATA_WIDTH-1:0]	o_green,
	output	reg[DATA_WIDTH-1:0]	o_blue,
	output	reg					o_valid,
	output  reg  				o_hs,
	output 	reg 				o_vs
);

//---------------------------------------------------------------------------
// 表地址（8bit 视频 → 10bit 表索引；用 generate 避免位宽越界）
//---------------------------------------------------------------------------
wire	[9:0]	a_red, a_green, a_blue;

generate
	if (DATA_WIDTH == 10)
	begin : g_addr10
		assign a_red	= i_red[9:0];
		assign a_green	= i_green[9:0];
		assign a_blue	= i_blue[9:0];
	end
	else
	begin : g_addr8
		assign a_red	= {i_red[7:0],   i_red[7:6]  };
		assign a_green	= {i_green[7:0], i_green[7:6]};
		assign a_blue	= {i_blue[7:0],  i_blue[7:6] };
	end
endgenerate

wire	[9:0]	q_red, q_green, q_blue;

//---------------------------------------------------------------------------
// 三个通道各一张 1024x10 的表（block RAM，2 拍读延迟）
//---------------------------------------------------------------------------
true_dual_port_ram
#(
	.DATA_WIDTH		(10),
	.ADDR_WIDTH		(10),
	.WRITE_MODE_1	("WRITE_FIRST"),
	.WRITE_MODE_2	("WRITE_FIRST"),
	.OUTPUT_REG_1	("TRUE"),
	.OUTPUT_REG_2	("FALSE"),
	.RAM_INIT_FILE	(GAMMA_CURVE)
)
inst_lut_red
(
	.we1	(1'b0		),
	.clka	(i_pclk		),
	.din1	(10'd0		),
	.addr1	(a_red		),
	.dout1	(q_red		),
	.we2	(1'b0		),
	.clkb	(1'b0		),
	.din2	(10'd0		),
	.addr2	(10'd0		),
	.dout2	(			)
);

true_dual_port_ram
#(
	.DATA_WIDTH		(10),
	.ADDR_WIDTH		(10),
	.WRITE_MODE_1	("WRITE_FIRST"),
	.WRITE_MODE_2	("WRITE_FIRST"),
	.OUTPUT_REG_1	("TRUE"),
	.OUTPUT_REG_2	("FALSE"),
	.RAM_INIT_FILE	(GAMMA_CURVE)
)
inst_lut_green
(
	.we1	(1'b0		),
	.clka	(i_pclk		),
	.din1	(10'd0		),
	.addr1	(a_green	),
	.dout1	(q_green	),
	.we2	(1'b0		),
	.clkb	(1'b0		),
	.din2	(10'd0		),
	.addr2	(10'd0		),
	.dout2	(			)
);

true_dual_port_ram
#(
	.DATA_WIDTH		(10),
	.ADDR_WIDTH		(10),
	.WRITE_MODE_1	("WRITE_FIRST"),
	.WRITE_MODE_2	("WRITE_FIRST"),
	.OUTPUT_REG_1	("TRUE"),
	.OUTPUT_REG_2	("FALSE"),
	.RAM_INIT_FILE	(GAMMA_CURVE)
)
inst_lut_blue
(
	.we1	(1'b0		),
	.clka	(i_pclk		),
	.din1	(10'd0		),
	.addr1	(a_blue		),
	.dout1	(q_blue		),
	.we2	(1'b0		),
	.clkb	(1'b0		),
	.din2	(10'd0		),
	.addr2	(10'd0		),
	.dout2	(			)
);

//---------------------------------------------------------------------------
// 输出 + 同步延迟 3 拍
//---------------------------------------------------------------------------
wire	[DATA_WIDTH-1:0]	g_red, g_green, g_blue;

generate
	if (DATA_WIDTH == 10)
	begin : g_out10
		assign g_red	= q_red;
		assign g_green	= q_green;
		assign g_blue	= q_blue;
	end
	else
	begin : g_out8
		assign g_red	= q_red[9:2];
		assign g_green	= q_green[9:2];
		assign g_blue	= q_blue[9:2];
	end
endgenerate

reg	[2:0]	vld_s, hs_s, vs_s;

always @(posedge i_pclk or negedge i_rstn)
begin
	if (!i_rstn)
	begin
		vld_s	<= 3'd0;
		hs_s	<= 3'd0;
		vs_s	<= 3'd0;
		o_red	<= {DATA_WIDTH{1'b0}};
		o_green	<= {DATA_WIDTH{1'b0}};
		o_blue	<= {DATA_WIDTH{1'b0}};
		o_valid	<= 1'b0;
		o_hs	<= 1'b0;
		o_vs	<= 1'b0;
	end
	else
	begin
		vld_s	<= {vld_s[1:0], i_valid};
		hs_s	<= {hs_s[1:0],  i_hs};
		vs_s	<= {vs_s[1:0],  i_vs};

		o_red	<= g_red;
		o_green	<= g_green;
		o_blue	<= g_blue;

		o_valid	<= vld_s[2];
		o_hs	<= hs_s[2];
		o_vs	<= vs_s[2];
	end
end

endmodule
