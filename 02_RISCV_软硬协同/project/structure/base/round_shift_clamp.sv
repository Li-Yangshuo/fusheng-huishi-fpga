// Signed right shift with jam, and saturation to the only width that can
// affect a later INT8 RNE. Each level reserves all remaining shift distance.
module shift_clamp_step #(parameter IW=52,OW=41,K=32)(
 input wire signed [IW-1:0] value,input wire choose,
 output wire signed [OW-1:0] shifted
);
 wire overflow=|(value[IW-1:OW-1]^{(IW-OW+1){value[IW-1]}});
 wire [OW-1:0] limit=value[IW-1] ? {1'b1,{(OW-1){1'b0}}} : {1'b0,{(OW-1){1'b1}}};
 wire signed [OW-1:0] saturated=overflow ? limit : value[OW-1:0];
 wire signed [IW-1:0] right_value=value >>> K;
 wire signed [OW-1:0] extended=right_value;
 wire [OW-1:0] jammed={extended[OW-1:1],extended[0]|(|value[K-1:0])};
 assign shifted=choose ? jammed : saturated;
endmodule
module round_shift_clamp #(parameter KEEP_W=8)(
 input wire signed [49:0] product,input wire [5:0] shift,
 output wire signed [KEEP_W-1:0] floor_bits,output wire guard_bit,sticky_bit
);
 wire signed [51:0] start_value={product,2'b00};
 wire signed [KEEP_W+32:0] s32;
 wire signed [KEEP_W+16:0] s16;
 wire signed [KEEP_W+8:0] s8;
 wire signed [KEEP_W+4:0] s4;
 wire signed [KEEP_W+2:0] s2;
 wire signed [KEEP_W+1:0] s1;
 shift_clamp_step #(.IW(52),.OW(KEEP_W+33),.K(32)) a(start_value,shift[5],s32);
 shift_clamp_step #(.IW(KEEP_W+33),.OW(KEEP_W+17),.K(16)) b(s32,shift[4],s16);
 shift_clamp_step #(.IW(KEEP_W+17),.OW(KEEP_W+9),.K(8)) c(s16,shift[3],s8);
 shift_clamp_step #(.IW(KEEP_W+9),.OW(KEEP_W+5),.K(4)) d(s8,shift[2],s4);
 shift_clamp_step #(.IW(KEEP_W+5),.OW(KEEP_W+3),.K(2)) e(s4,shift[1],s2);
 shift_clamp_step #(.IW(KEEP_W+3),.OW(KEEP_W+2),.K(1)) f(s2,shift[0],s1);
 assign floor_bits=s1[KEEP_W+1:2];assign guard_bit=s1[1];assign sticky_bit=s1[0];
endmodule
