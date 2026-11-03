// Eight dual-INT8 lanes. Each lane may serve a different spatial pixel.
// Thus CO2 processes 4 pixels, CO4 2 pixels, CO8 1 pixel per output vector.
module packed_pw_mac8 #(parameter TAG_W=105,MW=TAG_W+2,AW=20)(
 input wire clk,rst,in_valid,output wire in_ready,
 input wire [127:0] in_pairs,weights,input wire [255:0] biases,
 input wire in_first,in_last,input wire [TAG_W-1:0] in_tag,
 output wire out_valid,input wire out_ready,output reg [255:0] result,
 output reg [7:0] overflow,output reg [TAG_W-1:0] out_tag
);
 wire [7:0] mr,mv;wire signed [23:0] p0[0:7],p1[0:7];wire [MW-1:0] meta;
 reg valid;wire advance=!valid||out_ready;
 assign in_ready=&mr;assign out_valid=!rst&&valid;
 genvar g;
 generate for(g=0;g<8;g=g+1)begin:lane
  if(g==0)begin
   dual_int8_mul #(.TAG_W(MW)) mul(clk,rst,in_valid,mr[g],in_pairs[g*16+:8],weights[g*16+:8],in_pairs[g*16+8+:8],weights[g*16+8+:8],{in_first,in_last,in_tag},mv[g],advance,p0[g],p1[g],meta);
  end else begin
   wire unused_tag;
   dual_int8_mul #(.TAG_W(1)) mul(clk,rst,in_valid,mr[g],in_pairs[g*16+:8],weights[g*16+:8],in_pairs[g*16+8+:8],weights[g*16+8+:8],1'b0,mv[g],advance,p0[g],p1[g],unused_tag);
  end
  reg signed [AW-1:0] accumulator;
  wire signed [16:0] pair_sum=$signed({p0[g][15],p0[g][15:0]})+$signed({p1[g][15],p1[g][15:0]});
  wire signed [AW-1:0] next_sum=(meta[MW-1]?{AW{1'b0}}:accumulator)+$signed({{(AW-17){pair_sum[16]}},pair_sum});
  wire signed [32:0] total=$signed({{(33-AW){next_sum[AW-1]}},next_sum})+$signed({biases[g*32+31],biases[g*32+:32]});
  always @(posedge clk)if(!rst&&advance&&mv[0])begin
   accumulator<=next_sum;
   if(meta[TAG_W])begin result[g*32+:32]<=total[31:0];overflow[g]<=total[32]!=total[31];end
  end
 end endgenerate
 always @(posedge clk)begin
  if(rst)valid<=0;
  else if(advance)begin valid<=mv[0]&&meta[TAG_W];if(mv[0]&&meta[TAG_W])out_tag<=meta[TAG_W-1:0];end
 end
endmodule
