// Three read masters, one non-preemptive outstanding burst. Grant is registered
// before exposing AR and held until accepted RLAST; VALID never changes owner.
module ab05_axi_read_rr3(
 input wire clk,rstn,
 input wire [2:0] s_arvalid,output reg [2:0] s_arready,
 input wire [95:0] s_araddr,input wire [23:0] s_arlen,
 input wire [11:0] s_arid,input wire [8:0] s_arsize,input wire [5:0] s_arburst,
 output reg [2:0] s_rvalid,input wire [2:0] s_rready,
 output wire [127:0] s_rdata,output wire [3:0] s_rid,
 output wire [1:0] s_rresp,output wire s_rlast,
 output wire m_arvalid,input wire m_arready,
 output wire [31:0] m_araddr,output wire [7:0] m_arlen,
 output wire [3:0] m_arid,output wire [2:0] m_arsize,output wire [1:0] m_arburst,
 input wire m_rvalid,output wire m_rready,input wire [127:0] m_rdata,
 input wire [3:0] m_rid,input wire [1:0] m_rresp,input wire m_rlast,
 output wire [1:0] debug_grant
);
reg [1:0] state,grant,next_master;integer i,k;reg found;reg [1:0] choice;
always @* begin
 found=0;choice=0;
 for(i=0;i<3;i=i+1)begin
  k=next_master+i;if(k>=3)k=k-3;
  if(!found&&s_arvalid[k])begin found=1;choice=k;end
 end
 s_arready=0;s_rvalid=0;
 if(state==1)s_arready[grant]=m_arready;
 if(state==2)s_rvalid[grant]=m_rvalid;
end
assign debug_grant=grant;
assign m_arvalid=(state==1)&&s_arvalid[grant];
assign m_araddr=s_araddr[grant*32+:32];
assign m_arlen=s_arlen[grant*8+:8];
assign m_arid=s_arid[grant*4+:4];
assign m_arsize=s_arsize[grant*3+:3];
assign m_arburst=s_arburst[grant*2+:2];
assign s_rdata=m_rdata;assign s_rid=m_rid;assign s_rresp=m_rresp;assign s_rlast=m_rlast;
assign m_rready=(state==2)&&s_rready[grant];
always @(posedge clk or negedge rstn)
 if(!rstn)begin state<=0;grant<=0;next_master<=0;end
 else case(state)
  0:if(found)begin grant<=choice;state<=1;end
  1:if(m_arvalid&&m_arready)state<=2;
  2:if(m_rvalid&&m_rready&&m_rlast)begin next_master<=(grant==2)?0:grant+1'b1;state<=0;end
  default:state<=0;
 endcase
endmodule
