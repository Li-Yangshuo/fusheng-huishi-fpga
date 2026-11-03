// Single outstanding read and write independently; burst round robin.
// All ports share clk/rstn. Fixed-width INCR profile; no ID rewriting.
// Forward BRESP/RRESP unchanged. Reset must include every attached master.
// No burst splitting, QoS/deadline guarantee, timeout or independent reset.
module a19_shared_axi2 #(parameter integer READ_S0_QUOTA=1)(
input wire clk,rstn,
input wire [3:0] s0_awid,
input wire [31:0] s0_awaddr,
input wire [7:0] s0_awlen,
input wire [2:0] s0_awsize,
input wire [1:0] s0_awburst,
input wire s0_awvalid,
output wire s0_awready,
input wire [127:0] s0_wdata,
input wire [15:0] s0_wstrb,
input wire s0_wlast,
input wire s0_wvalid,
output wire s0_wready,
output wire [3:0] s0_bid,
output wire [1:0] s0_bresp,
output wire s0_bvalid,
input wire s0_bready,
input wire [3:0] s0_arid,
input wire [31:0] s0_araddr,
input wire [7:0] s0_arlen,
input wire [2:0] s0_arsize,
input wire [1:0] s0_arburst,
input wire s0_arvalid,
output wire s0_arready,
output wire [3:0] s0_rid,
output wire [127:0] s0_rdata,
output wire [1:0] s0_rresp,
output wire s0_rlast,
output wire s0_rvalid,
input wire s0_rready,
input wire [3:0] s1_awid,
input wire [31:0] s1_awaddr,
input wire [7:0] s1_awlen,
input wire [2:0] s1_awsize,
input wire [1:0] s1_awburst,
input wire s1_awvalid,
output wire s1_awready,
input wire [127:0] s1_wdata,
input wire [15:0] s1_wstrb,
input wire s1_wlast,
input wire s1_wvalid,
output wire s1_wready,
output wire [3:0] s1_bid,
output wire [1:0] s1_bresp,
output wire s1_bvalid,
input wire s1_bready,
input wire [3:0] s1_arid,
input wire [31:0] s1_araddr,
input wire [7:0] s1_arlen,
input wire [2:0] s1_arsize,
input wire [1:0] s1_arburst,
input wire s1_arvalid,
output wire s1_arready,
output wire [3:0] s1_rid,
output wire [127:0] s1_rdata,
output wire [1:0] s1_rresp,
output wire s1_rlast,
output wire s1_rvalid,
input wire s1_rready,
output wire [3:0] m_awid,
output wire [31:0] m_awaddr,
output wire [7:0] m_awlen,
output wire [2:0] m_awsize,
output wire [1:0] m_awburst,
output wire m_awvalid,
input wire m_awready,
output wire [127:0] m_wdata,
output wire [15:0] m_wstrb,
output wire m_wlast,
output wire m_wvalid,
input wire m_wready,
input wire [3:0] m_bid,
input wire [1:0] m_bresp,
input wire m_bvalid,
output wire m_bready,
output wire [3:0] m_arid,
output wire [31:0] m_araddr,
output wire [7:0] m_arlen,
output wire [2:0] m_arsize,
output wire [1:0] m_arburst,
output wire m_arvalid,
input wire m_arready,
input wire [3:0] m_rid,
input wire [127:0] m_rdata,
input wire [1:0] m_rresp,
input wire m_rlast,
input wire m_rvalid,
output wire m_rready);
localparam IDLE=0,ADDR=1,DATA=2,RESP=3;
reg [1:0] ws=IDLE,rs=IDLE;
reg wo=0,ro=0,wrr=0,rrr=0;
localparam QCW=(READ_S0_QUOTA<2)?1:$clog2(READ_S0_QUOTA+1);
reg [QCW-1:0] read_credit=0;
always @(posedge clk) begin
 if(!rstn) begin ws<=IDLE;rs<=IDLE;wo<=0;ro<=0;wrr<=0;rrr<=0;read_credit<=0;end
 else begin
  case(ws)
   IDLE: if(s0_awvalid||s1_awvalid) begin wo<=(s0_awvalid&&s1_awvalid)?wrr:s1_awvalid;ws<=ADDR;end
   ADDR: if(m_awvalid&&m_awready)ws<=DATA;
   DATA: if(m_wvalid&&m_wready&&m_wlast)ws<=RESP;
   RESP: if(m_bvalid&&m_bready)begin ws<=IDLE;wrr<=!wo;end
  endcase
  case(rs)
   IDLE: if(s0_arvalid||s1_arvalid)begin
    ro<=(s0_arvalid&&s1_arvalid)?(read_credit>=READ_S0_QUOTA):s1_arvalid;rs<=ADDR;
   end
   ADDR: if(m_arvalid&&m_arready)rs<=DATA;
   DATA: if(m_rvalid&&m_rready&&m_rlast)begin
    rs<=IDLE;rrr<=!ro;
    if(ro||!s1_arvalid)read_credit<=0;
    else if(read_credit<READ_S0_QUOTA)read_credit<=read_credit+1'b1;
   end
  endcase
 end
end
assign m_awid=(wo?s1_awid:s0_awid);
assign m_awaddr=(wo?s1_awaddr:s0_awaddr);
assign m_awlen=(wo?s1_awlen:s0_awlen);
assign m_awsize=(wo?s1_awsize:s0_awsize);
assign m_awburst=(wo?s1_awburst:s0_awburst);
assign m_awvalid=(rstn&&(ws==ADDR))&&(wo?s1_awvalid:s0_awvalid);
assign s0_awready=(rstn&&(ws==ADDR))&&(wo==1'd0)&&m_awready;
assign s1_awready=(rstn&&(ws==ADDR))&&(wo==1'd1)&&m_awready;
assign m_wdata=(wo?s1_wdata:s0_wdata);
assign m_wstrb=(wo?s1_wstrb:s0_wstrb);
assign m_wlast=(wo?s1_wlast:s0_wlast);
assign m_wvalid=(rstn&&(ws==DATA))&&(wo?s1_wvalid:s0_wvalid);
assign s0_wready=(rstn&&(ws==DATA))&&(wo==1'd0)&&m_wready;
assign s1_wready=(rstn&&(ws==DATA))&&(wo==1'd1)&&m_wready;
assign s0_bid=m_bid;
assign s1_bid=m_bid;
assign s0_bresp=m_bresp;
assign s1_bresp=m_bresp;
assign s0_bvalid=(rstn&&(ws==RESP))&&(wo==1'd0)&&m_bvalid;
assign s1_bvalid=(rstn&&(ws==RESP))&&(wo==1'd1)&&m_bvalid;
assign m_bready=(rstn&&(ws==RESP))&&(wo?s1_bready:s0_bready);
assign m_arid=(ro?s1_arid:s0_arid);
assign m_araddr=(ro?s1_araddr:s0_araddr);
assign m_arlen=(ro?s1_arlen:s0_arlen);
assign m_arsize=(ro?s1_arsize:s0_arsize);
assign m_arburst=(ro?s1_arburst:s0_arburst);
assign m_arvalid=(rstn&&(rs==ADDR))&&(ro?s1_arvalid:s0_arvalid);
assign s0_arready=(rstn&&(rs==ADDR))&&(ro==1'd0)&&m_arready;
assign s1_arready=(rstn&&(rs==ADDR))&&(ro==1'd1)&&m_arready;
assign s0_rid=m_rid;
assign s1_rid=m_rid;
assign s0_rdata=m_rdata;
assign s1_rdata=m_rdata;
assign s0_rresp=m_rresp;
assign s1_rresp=m_rresp;
assign s0_rlast=m_rlast;
assign s1_rlast=m_rlast;
assign s0_rvalid=(rstn&&(rs==DATA))&&(ro==1'd0)&&m_rvalid;
assign s1_rvalid=(rstn&&(rs==DATA))&&(ro==1'd1)&&m_rvalid;
assign m_rready=(rstn&&(rs==DATA))&&(ro?s1_rready:s0_rready);
endmodule
