// STD FIFO: current-pointer flags; only Gray pointers cross clock domains.
// The actual simple_dual_port_ram provides one-cycle synchronous read.
module fb640_async_fifo #(parameter DW=130, AW=9)(
 input wire arst,wclk,rclk,we,re,input wire [DW-1:0] wdata,
 output wire full,empty,output wire [DW-1:0] rdata
);
 reg [AW:0] wb,wg,rb,rg;
 (* async_reg="true" *) reg [AW:0] rg_w1,rg_w2,wg_r1,wg_r2;
 wire [AW:0] wn=wb+1'b1,rn=rb+1'b1;
 assign full=(wg=={~rg_w2[AW:AW-1],rg_w2[AW-2:0]});
 assign empty=(rg==wg_r2);
 always @(posedge wclk or posedge arst)
  if(arst) begin wb<=0;wg<=0;rg_w1<=0;rg_w2<=0;end
  else begin rg_w1<=rg;rg_w2<=rg_w1;
   if(we && !full) begin wb<=wn;wg<=(wn>>1)^wn;end
  end
 always @(posedge rclk or posedge arst)
  if(arst) begin rb<=0;rg<=0;wg_r1<=0;wg_r2<=0;end
  else begin wg_r1<=wg;wg_r2<=wg_r1;
   if(re && !empty) begin rb<=rn;rg<=(rn>>1)^rn;end
  end
 simple_dual_port_ram #(.DATA_WIDTH(DW),.ADDR_WIDTH(AW),.OUTPUT_REG("FALSE")) ram (
  .wclk(wclk),.we(we && !full),.waddr(wb[AW-1:0]),.wdata(wdata),
  .rclk(rclk),.re(re && !empty),.raddr(rb[AW-1:0]),.rdata(rdata));
endmodule
