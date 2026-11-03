// One M17 lane: serialize two accumulators, then join the two signed bytes.
module requant_pair_serial #(parameter TAG_W=56)(
 input wire clk,rst,input wire in_valid,output wire in_ready,
 input wire signed [31:0] acc0,acc1,input wire [47:0] quant,input wire [TAG_W-1:0] in_tag,
 output wire out_valid,input wire out_ready,output reg [15:0] result,output reg [TAG_W-1:0] out_tag
);
 reg held_valid,lane;reg [63:0] held_acc;reg [47:0] held_quant;reg [TAG_W-1:0] held_tag;
 wire qr,qv;wire signed [7:0] qdata;wire [TAG_W:0] qtag;
 wire issue=held_valid && qr;
 assign in_ready=!rst && (!held_valid || (issue && lane));
 reg valid;reg [7:0] low_byte;
 assign out_valid=!rst && valid;
 wire join_ready=!qv || !qtag[0] || !valid || out_ready;
 wire [31:0] chosen_acc=held_acc[lane*32+:32];wire [23:0] chosen_quant=held_quant[lane*24+:24];
 requant_int8_m17 #(.TAG_W(TAG_W+1)) q(clk,rst,held_valid,qr,chosen_acc,
 chosen_quant[16:0],chosen_quant[22:17],chosen_quant[23],{held_tag,lane},qv,join_ready,qdata,qtag);
 always @(posedge clk)begin
  if(rst)begin held_valid<=0;lane<=0;valid<=0;end
  else begin
   if(issue)begin if(lane)begin held_valid<=0;lane<=0;end else lane<=1;end
   if(in_valid && in_ready)begin held_valid<=1;lane<=0;held_acc<={acc1,acc0};held_quant<=quant;held_tag<=in_tag;end
   if(out_valid && out_ready)valid<=0;
   if(qv && join_ready)begin
    if(!qtag[0])low_byte<=qdata;
    else begin valid<=1;result<={qdata,low_byte};out_tag<=qtag[TAG_W:1];end
   end
  end
 end
endmodule
