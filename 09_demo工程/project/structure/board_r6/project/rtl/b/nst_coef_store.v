// Layer coefficients shared across APB/core through synchronous dual-clock RAM.
// Norm channel q: A[q]=index1+2q, C[q]=index2+2q; index0 is Rq.
// Tanh reuses the same APB layout: index0=Tz0, index1=Tz1,index2=Tz2.
// Firmware writes only in WAIT, then coef_go CDC + COPY delay fence the data.
module nst_coef_store(
 input wire wclk,wrst_n,wren,input wire [6:0] widx,input wire [63:0] wdata,
 input wire rclk,rrst_n,ren,input wire [5:0] channel,input wire tanh_mode,
 output wire signed [63:0] a,c,r
);
 reg [63:0] amem[0:31],cmem[0:31];
 reg [63:0] rq,aq,cq;
 reg tz,zero,odd;
 wire[6:0] wi=widx-7'd1;
 wire[5:0] qi=channel-6'd1;
 wire[4:0] ra=tanh_mode ? qi[5:1] : channel[4:0];
 always @(posedge wclk) begin
  if(wren && widx>=1 && widx<=64)begin
   if(widx[0])amem[wi[5:1]]<=wdata;
   else cmem[wi[5:1]]<=wdata;
  end
 end
 always @(posedge wclk or negedge wrst_n)
  if(!wrst_n)rq<=0;else if(wren && widx==0)rq<=wdata;
 always @(posedge rclk)if(ren)begin aq<=amem[ra];cq<=cmem[ra];end
 always @(posedge rclk or negedge rrst_n)
  if(!rrst_n)begin tz<=0;zero<=0;odd<=0;end
  else if(ren)begin tz<=tanh_mode;zero<=channel==0;odd<=channel[0];end
 assign a=tz ? (zero ? rq : odd ? aq : cq) : aq;
 assign c=cq;assign r=rq;
endmodule
