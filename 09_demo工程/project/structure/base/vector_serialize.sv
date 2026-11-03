// One vector bank, allowing final scalar retirement and next vector replacement.
module vector_serialize #(parameter CHANNELS=4,TAG_W=48,CW=$clog2(CHANNELS))(
 input wire clk,rst,input wire in_valid,output wire in_ready,
 input wire [CHANNELS*32-1:0] in_data,input wire [CHANNELS-1:0] in_overflow,
 input wire [TAG_W-1:0] in_tag,
 output wire out_valid,input wire out_ready,output wire signed [31:0] out_data,
 output wire out_overflow,output wire [CW-1:0] out_channel,output wire [TAG_W-1:0] out_tag
);
 reg valid;reg [CHANNELS*32-1:0] data;reg [CHANNELS-1:0] errors;
 reg [TAG_W-1:0] tag;reg [CW-1:0] index;
 assign out_valid=!rst && valid;assign out_data=data[index*32+:32];
 assign out_overflow=errors[index];assign out_channel=index;assign out_tag=tag;
 assign in_ready=!rst && (!valid || (out_ready && index==CHANNELS-1));
 always @(posedge clk)begin
  if(rst)begin valid<=0;index<=0;end
  else begin
   if(out_valid && out_ready)begin
    if(index==CHANNELS-1)begin valid<=0;index<=0;end else index<=index+1'b1;
   end
   if(in_valid && in_ready)begin valid<=1;index<=0;data<=in_data;errors<=in_overflow;tag<=in_tag;end
  end
 end
endmodule
