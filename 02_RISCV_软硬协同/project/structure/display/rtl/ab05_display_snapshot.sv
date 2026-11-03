// AXI request -> pixel capture -> AXI acknowledgement. Held-data bus is stable
// from pixel capture until the next acknowledged request; constrain this path.
module ab05_display_snapshot #(parameter W=512)(
 input wire axi_clk,axi_rstn,pix_clk,pix_rstn,
 input wire request,input wire [W-1:0] pix_data,
 output wire busy,output reg valid,output reg [W-1:0] data
);
 wire arst=!(axi_rstn&&pix_rstn);
 reg req,ack; reg [W-1:0] held;
 (* async_reg="true" *) reg [1:0] req_sync,ack_sync;
 reg [2:0] settle;
 assign busy=req!=ack_sync[1]||(|settle);
 always @(posedge pix_clk or posedge arst)
  if(arst)begin req_sync<=0;ack<=0;held<=0;end
  else begin
   req_sync<={req_sync[0],req};
   if(req_sync[1]!=ack)begin held<=pix_data;ack<=req_sync[1];end
  end
 always @(posedge axi_clk or posedge arst)
  if(arst)begin req<=0;ack_sync<=0;settle<=0;valid<=0;data<=0;end
  else begin
   ack_sync<={ack_sync[0],ack};valid<=0;
   if(request&&!busy)begin req<=!req;settle<=3'b001;end
   else if(settle==1&&req==ack_sync[1])settle<=3'b010;
   else if(settle==2)settle<=3'b100;
   else if(settle==4)begin data<=held;valid<=1;settle<=0;end
  end
endmodule
