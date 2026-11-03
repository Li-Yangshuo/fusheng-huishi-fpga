// Tagged ready/valid CDC. Registered read, Gray pointers, no binary CDC.
// Either domain reset resets BOTH ends. Fabric reset is also required if
// reset aborts an AXI transfer outside this FIFO. AW>=2, capacity=2**AW+1
// including the output register. Physical CDC/constraints still require PNR.
module ab05_async_stream #(parameter W=163, AW=5)(
 input wire arst, wclk, rclk,
 input wire s_valid, output wire s_ready, input wire [W-1:0] s_data,
 output wire m_valid, input wire m_ready, output reg [W-1:0] m_data,
 output reg [AW:0] w_high_water
);
 localparam DEPTH=1<<AW;
 reg [W-1:0] mem[0:DEPTH-1];
 reg [AW:0] wb,wg,rb,rg;
 (* async_reg="true" *) reg [AW:0] rg1,rg2,wg1,wg2;
 (* async_reg="true" *) reg [1:0] wrun,rrun;
 reg have;
 wire full=wg=={~rg2[AW:AW-1],rg2[AW-2:0]};
 wire empty=rg==wg2;
 function [AW:0] ungray(input [AW:0] g);
  integer i;begin ungray[AW]=g[AW];for(i=AW-1;i>=0;i=i-1)ungray[i]=ungray[i+1]^g[i];end
 endfunction
 wire [AW:0] used=wb-ungray(rg2);
 wire [AW:0] wn=wb+1'b1,rn=rb+1'b1;
 assign s_ready=wrun[1]&&!full;
 assign m_valid=rrun[1]&&have;
 always @(posedge wclk or posedge arst) begin
  if(arst)begin wb<=0;wg<=0;rg1<=0;rg2<=0;wrun<=0;w_high_water<=0;end
  else begin
   wrun<={wrun[0],1'b1};rg1<=rg;rg2<=rg1;
   if(used>w_high_water)w_high_water<=used;
   if(s_valid&&s_ready)begin mem[wb[AW-1:0]]<=s_data;wb<=wn;wg<=(wn>>1)^wn;end
  end
 end
 always @(posedge rclk or posedge arst) begin
  if(arst)begin rb<=0;rg<=0;wg1<=0;wg2<=0;rrun<=0;have<=0;m_data<=0;end
  else begin
   rrun<={rrun[0],1'b1};wg1<=wg;wg2<=wg1;
   if(rrun[1]&&(!have||m_ready))begin
    if(!empty)begin m_data<=mem[rb[AW-1:0]];rb<=rn;rg<=(rn>>1)^rn;have<=1;end
    else have<=0;
   end
  end
 end
 // synthesis translate_off
 initial if(AW<2)$fatal(1,"ab05_async_stream AW>=2");
 // synthesis translate_on
endmodule
