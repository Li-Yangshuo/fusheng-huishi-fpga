/////////////////////////////////////////////////////////////////////////////
// raw_to_rgb.v
//
// 2 pixel / clock RAW Bayer  ->  RGB888 (bilinear), causal 2-line kernel.
// Rewritten 2026-10 (the previous version mixed up the three line taps of
// line_buffer.v and produced a half mosaic picture).
//
// line_buffer.v delivers three taps that are ALIGNED in x:
//      i_p_00 : previous line  (row y-1)
//      i_p_01 : current  line  (row y)
//      i_p_11 : row y-2        (not needed by a 2-line bilinear kernel)
// Every tap is a 16 bit word holding two neighbouring pixels:
//      word = {high byte, low byte}
//      low  byte = the pixel of the pair that is displayed first  (left)
//      high byte = the pixel displayed second                     (right)
//
// i_bayer_sel : colour filter array phase.  Stated as the colour of
//      (row0,byte0) (row0,byte1) / (row1,byte0) (row1,byte1)
//      0 : R G / G B   = RGGB
//      1 : B G / G R   = BGGR    (SmartSens SC family power-on order)
//      2 : G R / B G   = GRBG
//      3 : G B / R G   = GBRG
//
// i_byte_swap : exchange the two bytes of every input word.  Use it when the
//      capture chain hands over the right hand pixel of the pair first
//      (this also repairs the pixel pairing, not only the phase).
//
// i_x_gain    : Q8.8 white balance gain, applied on the debayered channels.
/////////////////////////////////////////////////////////////////////////////
module raw_to_rgb
#(
	parameter	P_DEPTH		= 8,
	parameter	PW			= P_DEPTH*2
)
(
	input					i_arstn,
	input					i_pclk,

	input					i_vsync,
	input					i_hsync,
	input					i_de,
	input					i_valid,
	input	[PW-1:0]		i_p_11,
	input	[PW-1:0]		i_p_00,
	input	[PW-1:0]		i_p_01,

	input	[1:0]			i_bayer_sel,
	input					i_byte_swap,
	input	[15:0]			i_r_gain,
	input	[15:0]			i_g_gain,
	input	[15:0]			i_b_gain,

	output					o_vsync,
	output					o_hsync,
	output					o_de,
	output					o_valid,
	output	[10:0]			o_x_cnt,
	output	[10:0]			o_y_cnt,
	output	[PW-1:0]		o_r,
	output	[PW-1:0]		o_g,
	output	[PW-1:0]		o_b
);

localparam	C_R	= 2'd0;
localparam	C_G	= 2'd1;
localparam	C_B	= 2'd2;

//===========================================================================
// optional byte swap of the input pair
//===========================================================================
wire [PW-1:0]	w_cur_0 = i_byte_swap ? {i_p_01[P_DEPTH-1:0], i_p_01[PW-1:P_DEPTH]}
                                   : i_p_01;
wire [PW-1:0]	w_prv_0 = i_byte_swap ? {i_p_00[P_DEPTH-1:0], i_p_00[PW-1:P_DEPTH]}
                                   : i_p_00;

//===========================================================================
// pixel / line counters (referenced to the current input sample)
//===========================================================================
reg	[10:0]	r_x_cnt;
reg	[10:0]	r_y_cnt;
reg			r_vs_1p;
reg             r_vld_1;

always @(posedge i_pclk or negedge i_arstn)
begin
	if (!i_arstn)
	begin
		r_x_cnt	<= 11'd0;
		r_y_cnt	<= 11'd0;
		r_vs_1p	<= 1'b0;
	end
	else
	begin
		r_vs_1p	<= i_vsync;

		if (!i_vsync && r_vs_1p)			// falling edge of vsync = frame start
			r_y_cnt	<= 11'd0;
		else if (r_vld_1 && !i_valid)		// end of a line
			r_y_cnt	<= r_y_cnt + 1'b1;

		if (i_valid)
			r_x_cnt	<= r_x_cnt + 1'b1;
		else
			r_x_cnt	<= 11'd0;
	end
end

//===========================================================================
// two pipeline stages  (total output latency = 2 clocks, same as the old
// module, so every downstream timing relation is preserved)
//===========================================================================
reg	[PW-1:0]	r_cur_1;
reg	[PW-1:0]	r_cur_2;
reg	[PW-1:0]	r_prv_1;
reg	[PW-1:0]	r_prv_2;
reg	[10:0]		r_x_1;
reg	[10:0]		r_x_2;
reg	[10:0]		r_y_1;
reg				r_vld_2;

reg				r_vsync_1p;
reg				r_vsync_2p;
reg				r_hsync_1p;
reg				r_hsync_2p;
reg				r_de_1p;
reg				r_de_2p;
reg				r_valid_1p;
reg				r_valid_2p;

always @(posedge i_pclk or negedge i_arstn)
begin
	if (!i_arstn)
	begin
		r_cur_1		<= {PW{1'b0}};
		r_cur_2		<= {PW{1'b0}};
		r_prv_1		<= {PW{1'b0}};
		r_prv_2		<= {PW{1'b0}};
		r_x_1		<= 11'd0;
		r_x_2		<= 11'd0;
		r_y_1		<= 11'd0;
		r_vld_1		<= 1'b0;
		r_vld_2		<= 1'b0;
		r_vsync_1p	<= 1'b0;
		r_vsync_2p	<= 1'b0;
		r_hsync_1p	<= 1'b0;
		r_hsync_2p	<= 1'b0;
		r_de_1p		<= 1'b0;
		r_de_2p		<= 1'b0;
		r_valid_1p	<= 1'b0;
		r_valid_2p	<= 1'b0;
	end
	else
	begin
		r_cur_2		<= r_cur_1;
		r_cur_1		<= w_cur_0;
		r_prv_2		<= r_prv_1;
		r_prv_1		<= w_prv_0;
		r_x_2		<= r_x_1;
		r_x_1		<= r_x_cnt;
		r_y_1		<= r_y_cnt;
		r_vld_2		<= r_vld_1;
		r_vld_1		<= i_valid;

		r_vsync_1p	<= i_vsync;
		r_vsync_2p	<= r_vsync_1p;
		r_hsync_1p	<= i_hsync;
		r_hsync_2p	<= r_hsync_1p;
		r_de_1p		<= i_de;
		r_de_2p		<= r_de_1p;
		r_valid_1p	<= i_valid;
		r_valid_2p	<= r_valid_1p;
	end
end

assign	o_vsync	= r_vsync_2p;
assign	o_hsync	= r_hsync_2p;
assign	o_de	= r_de_2p;
assign	o_valid	= r_valid_2p;
assign	o_x_cnt	= r_x_1;
assign	o_y_cnt	= r_y_1;

//===========================================================================
// neighbour availability
//   stage 1 = the pair that is being converted (pair index r_x_1)
//   stage 2 = the pair 1 clock earlier  -> left hand neighbour
//   stage 0 = current input              -> right hand neighbour
//===========================================================================
wire	w_left_ok	= r_vld_2 && (r_x_2 == (r_x_1 - 11'd1));
wire	w_right_ok	= i_valid && (r_x_cnt == (r_x_1 + 11'd1));
wire	w_up_ok		= (r_y_1 != 11'd0);

//===========================================================================
// bytes of the three stages
//===========================================================================
wire [P_DEPTH-1:0]	c1_lo	= r_cur_1[P_DEPTH-1:0];
wire [P_DEPTH-1:0]	c1_hi	= r_cur_1[PW-1:P_DEPTH];
wire [P_DEPTH-1:0]	c2_lo	= r_cur_2[P_DEPTH-1:0];
wire [P_DEPTH-1:0]	c2_hi	= r_cur_2[PW-1:P_DEPTH];
wire [P_DEPTH-1:0]	c0_lo	= w_cur_0[P_DEPTH-1:0];
wire [P_DEPTH-1:0]	p1_lo	= r_prv_1[P_DEPTH-1:0];
wire [P_DEPTH-1:0]	p1_hi	= r_prv_1[PW-1:P_DEPTH];
wire [P_DEPTH-1:0]	p2_lo	= r_prv_2[P_DEPTH-1:0];
wire [P_DEPTH-1:0]	p2_hi	= r_prv_2[PW-1:P_DEPTH];
wire [P_DEPTH-1:0]	p0_lo	= w_prv_0[P_DEPTH-1:0];

//===========================================================================
// interpolation taps
//   xx0 = output pixel built from the LOW  byte of the pair
//   xx1 = output pixel built from the HIGH byte of the pair
//===========================================================================
wire [P_DEPTH:0]	hh0_sum	= {1'b0, c1_hi} + {1'b0, (w_left_ok  ? c2_hi : c1_hi)};
wire [P_DEPTH:0]	hh1_sum	= {1'b0, c1_lo} + {1'b0, (w_right_ok ? c0_lo : c1_lo)};
wire [P_DEPTH-1:0]	hh0		= hh0_sum[P_DEPTH:1];
wire [P_DEPTH-1:0]	hh1		= hh1_sum[P_DEPTH:1];

wire [P_DEPTH:0]	dg0_sum	= {1'b0, p1_hi} + {1'b0, (w_left_ok  ? p2_hi : p1_hi)};
wire [P_DEPTH:0]	dg1_sum	= {1'b0, p1_lo} + {1'b0, (w_right_ok ? p0_lo : p1_lo)};
wire [P_DEPTH-1:0]	dg0_i	= dg0_sum[P_DEPTH:1];
wire [P_DEPTH-1:0]	dg1_i	= dg1_sum[P_DEPTH:1];

// 第一行没有上一行，垂直邻居和斜对角都退回像素自身值
wire [P_DEPTH-1:0]	dg0		= w_up_ok ? dg0_i : c1_lo;
wire [P_DEPTH-1:0]	dg1		= w_up_ok ? dg1_i : c1_hi;

wire [P_DEPTH-1:0]	up0		= w_up_ok ? p1_lo : c1_lo;
wire [P_DEPTH-1:0]	up1		= w_up_ok ? p1_hi : c1_hi;

//===========================================================================
// CFA phase table
//===========================================================================
reg	[1:0]	t00, t01, t10, t11;		// t[row][byte]

always @(*)
begin
	case (i_bayer_sel)
		2'd0	: begin t00 = C_R; t01 = C_G; t10 = C_G; t11 = C_B; end	// RGGB
		2'd1	: begin t00 = C_B; t01 = C_G; t10 = C_G; t11 = C_R; end	// BGGR
		2'd2	: begin t00 = C_G; t01 = C_R; t10 = C_B; t11 = C_G; end	// GRBG
		default	: begin t00 = C_G; t01 = C_B; t10 = C_R; t11 = C_G; end	// GBRG
	endcase
end

wire			w_rp	= r_y_1[0];
wire	[1:0]	cc0		= w_rp ? t10 : t00;	// current line, low  byte
wire	[1:0]	cc1		= w_rp ? t11 : t01;	// current line, high byte
wire	[1:0]	pc0		= w_rp ? t00 : t10;	// previous line, low  byte
wire	[1:0]	pc1		= w_rp ? t01 : t11;	// previous line, high byte

//===========================================================================
// one output pixel
//   dir : value of the pixel itself
//   hh  : horizontal neighbour average
//   up  : vertical (previous line) neighbour
//   dg  : diagonal neighbour average
//   cc  : colour of the pixel itself, cn : colour of its horizontal neighbours
//===========================================================================
function [3*P_DEPTH-1:0] debayer_pix;
	input [P_DEPTH-1:0]	dir;
	input [P_DEPTH-1:0]	hh;
	input [P_DEPTH-1:0]	up;
	input [P_DEPTH-1:0]	dg;
	input [1:0]			cc;
	input [1:0]			cn;
	reg	  [P_DEPTH-1:0]	r, g, b;
	reg       [P_DEPTH:0] green_sum;
	begin
		if (cc == C_G)
		begin
			g = dir;						// green site: direct
			if (cn == C_R)
			begin
				r = hh;						// red neighbours are horizontal
				b = up;						// blue neighbour is vertical
			end
			else
			begin
				r = up;
				b = hh;
			end
		end
		else
		begin
			green_sum = {1'b0, hh} + {1'b0, up};
			g = green_sum[P_DEPTH:1];
			if (cc == C_R)
			begin
				r = dir;
				b = dg;						// blue is on the diagonals
			end
			else
			begin
				r = dg;
				b = dir;
			end
		end
		debayer_pix = {b, g, r};
	end
endfunction

wire [3*P_DEPTH-1:0]	w_rgb0	= debayer_pix(c1_lo, hh0, up0, dg0, cc0, cc1);
wire [3*P_DEPTH-1:0]	w_rgb1	= debayer_pix(c1_hi, hh1, up1, dg1, cc1, cc0);

//===========================================================================
// white balance gain (Q8.8)
//===========================================================================
wire [15:0]	w_gr	= (i_r_gain == 16'd0) ? 16'd256 : i_r_gain;
wire [15:0]	w_gg	= (i_g_gain == 16'd0) ? 16'd256 : i_g_gain;
wire [15:0]	w_gb	= (i_b_gain == 16'd0) ? 16'd256 : i_b_gain;

function [P_DEPTH-1:0] gain8;
	input [P_DEPTH-1:0]	pix;
	input [15:0]		gain;
	reg	  [24:0]		prod;
	begin
		prod = pix * gain;
		gain8 = (|prod[24:P_DEPTH+8]) ? {P_DEPTH{1'b1}} : prod[P_DEPTH+8-1:8];
	end
endfunction

wire [P_DEPTH-1:0]	r0 = gain8(w_rgb0[P_DEPTH-1:0],          w_gr);
wire [P_DEPTH-1:0]	g0 = gain8(w_rgb0[2*P_DEPTH-1:P_DEPTH],  w_gg);
wire [P_DEPTH-1:0]	b0 = gain8(w_rgb0[3*P_DEPTH-1:2*P_DEPTH],w_gb);
wire [P_DEPTH-1:0]	r1 = gain8(w_rgb1[P_DEPTH-1:0],          w_gr);
wire [P_DEPTH-1:0]	g1 = gain8(w_rgb1[2*P_DEPTH-1:P_DEPTH],  w_gg);
wire [P_DEPTH-1:0]	b1 = gain8(w_rgb1[3*P_DEPTH-1:2*P_DEPTH],w_gb);

//===========================================================================
// output register
//===========================================================================
reg	[PW-1:0]	o_r_r;
reg	[PW-1:0]	o_g_r;
reg	[PW-1:0]	o_b_r;

always @(posedge i_pclk or negedge i_arstn)
begin
	if (!i_arstn)
	begin
		o_r_r	<= {PW{1'b0}};
		o_g_r	<= {PW{1'b0}};
		o_b_r	<= {PW{1'b0}};
	end
	else if (r_vld_1)
	begin
		o_r_r	<= {r1, r0};
		o_g_r	<= {g1, g0};
		o_b_r	<= {b1, b0};
	end
	else
	begin
		o_r_r	<= {PW{1'b0}};
		o_g_r	<= {PW{1'b0}};
		o_b_r	<= {PW{1'b0}};
	end
end

assign	o_r	= o_r_r;
assign	o_g	= o_g_r;
assign	o_b	= o_b_r;

endmodule
