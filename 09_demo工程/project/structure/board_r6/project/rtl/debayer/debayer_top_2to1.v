module debayer_top_2to1
(
	input			in_pclk,
	input			in_rstn,
	
	input			raw_vs_i,
	input			raw_hs_i,
	input			raw_de_i,
	input			raw_valid_i,
	input	[15:0]	raw_datax4_i,
	input [15:0] r_gain,
	input [15:0] g_gain,
	input [15:0] b_gain,

	input [1:0]  i_bayer_sel,	// 0=RGGB 1=BGGR 2=GRBG 3=GBRG
	input        i_byte_swap,	// swap the two pixels of every input pair
	
	output				rgb_vs_o,
	output				rgb_hs_o,
	output				rgb_de_o,
	output				rgb_valid_o,
	output [15:0] 	rgb_bout,
	output [15:0] 	rgb_gout,
	output [15:0] 	rgb_rout,
	output	[24*2-1:0]	rgb_datax2_o //b,g,r,b,g,r
);

//===========================================================================
// one pipeline stage, in the place where rgb_gain.v used to sit.  This keeps
// the total latency of the debayer unchanged.
// The white balance gain is applied AFTER debayering now (inside raw_to_rgb.v),
// so no per photosite gain is needed here any more.
//===========================================================================
reg					r_de_1P;
reg					r_vs_1P;
reg					r_hs_1P;
reg					r_valid_1P;
reg	[15:0]			r_data_1P;

always @(posedge in_pclk or negedge in_rstn)
begin
	if (!in_rstn)
	begin
		r_de_1P		<= 1'b0;
		r_vs_1P		<= 1'b0;
		r_hs_1P		<= 1'b0;
		r_valid_1P	<= 1'b0;
		r_data_1P	<= 16'd0;
	end
	else
	begin
		r_de_1P		<= raw_de_i;
		r_vs_1P		<= raw_vs_i;
		r_hs_1P		<= raw_hs_i;
		r_valid_1P	<= raw_valid_i;
		r_data_1P	<= raw_datax4_i;
	end
end
	
		wire	    	w_debayer_lb_hs;
		wire	    	w_debayer_lb_vs;
		wire	    	w_debayer_lb_ah;
		wire	    	w_debayer_lb_de;
		wire	[15:0]	w_debayer_lb_p_11;
		wire	[15:0]	w_debayer_lb_p_00;
		wire	[15:0]	w_debayer_lb_p_01;

		line_buffer
		#(
			.P_DEPTH	(8),
			.X_CNT_WIDTH(10)
		)
		inst_line_buffer_debayer
		(
			.i_arstn	(in_rstn	),
			.i_pclk		(in_pclk	),
			
			.i_vsync	(r_vs_1P	),					
			.i_hsync	(r_hs_1P	),
			.i_de		(r_valid_1P	),
			.i_valid	(r_valid_1P	),
			.i_p		(r_data_1P	),
			
			.o_vsync	(w_debayer_lb_vs  ),
			.o_hsync	(w_debayer_lb_hs  ),
			.o_de		(w_debayer_lb_de  ),
			.o_valid	(w_debayer_lb_ah  ),
			.o_p_11		(w_debayer_lb_p_11),
			.o_p_00		(w_debayer_lb_p_00),
			.o_p_01		(w_debayer_lb_p_01),
			.o_x			()
		);
		wire	w_debayer_hs;
		wire	w_debayer_vs;
		wire	w_debayer_ah;
		wire	w_debayer_de;
		wire	[10:0]	w_debayer_x;
		wire	[10:0]	w_debayer_y;
		wire	[15:0]	w_debayer_r;
		wire	[15:0]	w_debayer_g;
		wire	[15:0]	w_debayer_b;
		raw_to_rgb
		#(
			.P_DEPTH	(8)
		)
		inst_raw_to_rgb
		(
			.i_arstn	(in_rstn	),
			.i_pclk		(in_pclk	),
			
			.i_vsync	(w_debayer_lb_vs),
			.i_hsync	(w_debayer_lb_hs),
			.i_de		(w_debayer_lb_de),
			.i_valid	(w_debayer_lb_ah),
			.i_p_11		(w_debayer_lb_p_11),
			.i_p_00		(w_debayer_lb_p_00),
			.i_p_01		(w_debayer_lb_p_01),

			.i_bayer_sel(i_bayer_sel),
			.i_byte_swap(i_byte_swap),
			.i_r_gain	(r_gain		),
			.i_g_gain	(g_gain		),
			.i_b_gain	(b_gain		),
			
			.o_vsync	(w_debayer_vs),
			.o_hsync	(w_debayer_hs),
			.o_de		(w_debayer_ah),
			.o_valid	(w_debayer_de),
			.o_x_cnt	(w_debayer_x),
			.o_y_cnt	(w_debayer_y),
			.o_r		(w_debayer_r),
			.o_g		(w_debayer_g),
			.o_b		(w_debayer_b)
		);	
		
	assign		rgb_vs_o 		= w_debayer_vs;	
	assign		rgb_hs_o 		= w_debayer_hs;	
	assign		rgb_de_o 		= w_debayer_ah;	
	assign		rgb_valid_o 	= w_debayer_de;	
	assign 		rgb_bout  		= w_debayer_b;
	assign 		rgb_gout  		= w_debayer_g;
	assign 		rgb_rout  		= w_debayer_r;

	assign		rgb_datax2_o 	= {	w_debayer_b[15:8],w_debayer_g[15:8],w_debayer_r[15:8],
									w_debayer_b[ 7:0],w_debayer_g[ 7:0],w_debayer_r[ 7:0]};	
endmodule
