module ab09_fps_cdc #(parameter WIDTH=8)(input wire sclk,srstn,input wire[WIDTH-1:0] sdata,input wire dclk,drstn,output reg[WIDTH-1:0] ddata);
 wire arst=!(srstn&&drstn);
 reg req,ack;reg[WIDTH-1:0] held;
 (* async_reg="true" *)reg[1:0] reqsync,acksync;
 always @(posedge sclk or posedge arst)
  if(arst)begin req<=0;acksync<=0;held<=0;end
  else begin acksync<={acksync[0],ack};if(req==acksync[1]&&held!=sdata)begin held<=sdata;req<=!req;end end
 always @(posedge dclk or posedge arst)
  if(arst)begin reqsync<=0;ack<=0;ddata<=0;end
  else begin reqsync<={reqsync[0],req};if(reqsync[1]!=ack)begin ddata<=held;ack<=reqsync[1];end end
endmodule
