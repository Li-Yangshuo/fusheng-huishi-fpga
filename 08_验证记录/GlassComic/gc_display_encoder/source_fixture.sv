// Independent ready/valid producer. It emits a complete 640x360 tagged image
// per display boundary and deliberately has no DDR/NN internals.
module hdmi_source_fixture #(parameter RIGHT=0)(
 input wire clk,rstn,boundary,style,input wire ready,output wire [31:0] model,
 output wire valid,output wire[23:0] rgb,output reg[31:0] frame_id,
 output reg[10:0] x,output reg[9:0] y,output wire sof,eol,eof
);
 reg active,style_q;
 assign model=style_q?32'h54473031:32'h50503031;
 assign valid=active;
 assign sof=(x==0)&&(y==0);
 assign eol=x==639;assign eof=eol&&(y==359);
 assign rgb=RIGHT?{(x[7:0]^y[7:0]),y[7:0],x[7:0]}:
                  {(8'h40|{2'd0,x[5:0]}),y[7:0],(x[7:0]^y[7:0])};
 always @(posedge clk or negedge rstn)
  if(!rstn)begin active<=0;style_q<=0;frame_id<=0;x<=0;y<=0;end
  else begin
   if(boundary&&!active)begin active<=1;style_q<=style;frame_id<=frame_id+1'b1;x<=0;y<=0;end
   if(valid&&ready)begin
    if(eof)active<=0;
    else if(eol)begin x<=0;y<=y+1'b1;end
    else x<=x+1'b1;
   end
  end
endmodule
