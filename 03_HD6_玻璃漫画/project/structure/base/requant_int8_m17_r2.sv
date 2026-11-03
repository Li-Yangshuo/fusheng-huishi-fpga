// Exact H1b M17 replacement candidate: same ports, latency, II and global stall.
// r2: full INT32 product, six-stage jam/clamp combinational shift network.
module requant_int8_m17 #(parameter TAG_W=16)(
 input wire clk,rst,input wire in_valid,output wire in_ready,
 input wire signed [31:0] acc,input wire [16:0] multiplier,
 input wire [5:0] shift,input wire relu,input wire [TAG_W-1:0] in_tag,
 output wire out_valid,input wire out_ready,output reg signed [7:0] result,
 output wire [TAG_W-1:0] out_tag
);
 reg [2:0] valid;
 wire advance=!valid[2] || out_ready;
 assign in_ready=advance && !rst;assign out_valid=valid[2] && !rst;
 reg [TAG_W-1:0] tag0,tag1,tag2;assign out_tag=tag2;
 reg [5:0] shift0,shift1;reg relu0,relu1;
 wire signed [17:0] low_acc=$signed({1'b0,acc[16:0]});
 wire signed [14:0] high_acc=$signed(acc[31:17]);
 wire signed [17:0] positive_m=$signed({1'b0,multiplier});
 (* syn_use_dsp="true" *) reg signed [35:0] low_product;
 (* syn_use_dsp="true" *) reg signed [32:0] high_product;
 reg signed [49:0] full_product;
 wire signed [49:0] lo_ext={{14{low_product[35]}},low_product};
 wire signed [49:0] hi_ext={{17{high_product[32]}},high_product};
 wire signed [7:0] floor8;wire guard_bit,sticky_bit;
 round_shift_clamp #(.KEEP_W(8)) slice(full_product,shift1,floor8,guard_bit,sticky_bit);
 wire increment=guard_bit && (sticky_bit || floor8[0]);
 wire signed [8:0] rounded=$signed({floor8[7],floor8})+$signed({8'd0,increment});
 always @(posedge clk)begin
  if(rst)valid<=0;
  else if(advance)begin
   valid<={valid[1:0],in_valid};
   low_product<=low_acc*positive_m;high_product<=high_acc*positive_m;
   full_product<=lo_ext+(hi_ext <<< 17);
   shift0<=shift;shift1<=shift0;relu0<=relu;relu1<=relu0;
   tag0<=in_tag;tag1<=tag0;tag2<=tag1;
   if(relu1 && rounded<0)result<=8'sd0;
   else if(rounded>127)result<=8'sd127;
   else if(rounded< -128)result<=-8'sd128;
   else result<=rounded[7:0];
  end
 end
endmodule
