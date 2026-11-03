// Two write masters. The selected AW/W/B transaction is indivisible; response
// routing uses the locked owner even if both masters use the same AXI ID.
module ab05_axi_write_rr2(
 input wire clk,rstn,
 input wire [1:0] s_awvalid,output reg [1:0] s_awready,
 input wire [63:0] s_awaddr,input wire [15:0] s_awlen,
 input wire [7:0] s_awid,input wire [5:0] s_awsize,input wire [3:0] s_awburst,
 input wire [1:0] s_wvalid,output reg [1:0] s_wready,
 input wire [255:0] s_wdata,input wire [31:0] s_wstrb,input wire [1:0] s_wlast,
 output reg [1:0] s_bvalid,input wire [1:0] s_bready,
 output wire [3:0] s_bid,output wire [1:0] s_bresp,
 output wire m_awvalid,input wire m_awready,
 output wire [31:0] m_awaddr,output wire [7:0] m_awlen,
 output wire [3:0] m_awid,output wire [2:0] m_awsize,output wire [1:0] m_awburst,
 output wire m_wvalid,input wire m_wready,
 output wire [127:0] m_wdata,output wire [15:0] m_wstrb,output wire m_wlast,
 input wire m_bvalid,output wire m_bready,input wire [3:0] m_bid,input wire [1:0] m_bresp,
 output wire debug_grant
);
reg [1:0] state;reg grant,next_master;
assign debug_grant=grant;
always @* begin
 s_awready=0;s_wready=0;s_bvalid=0;
 if(state==1)s_awready[grant]=m_awready;
 if(state==2)s_wready[grant]=m_wready;
 if(state==3)s_bvalid[grant]=m_bvalid;
end
assign m_awvalid=(state==1)&&s_awvalid[grant];
assign m_awaddr=s_awaddr[grant*32+:32];assign m_awlen=s_awlen[grant*8+:8];
assign m_awid=s_awid[grant*4+:4];assign m_awsize=s_awsize[grant*3+:3];assign m_awburst=s_awburst[grant*2+:2];
assign m_wvalid=(state==2)&&s_wvalid[grant];assign m_wdata=s_wdata[grant*128+:128];
assign m_wstrb=s_wstrb[grant*16+:16];assign m_wlast=s_wlast[grant];
assign m_bready=(state==3)&&s_bready[grant];assign s_bid=m_bid;assign s_bresp=m_bresp;
always @(posedge clk or negedge rstn)
 if(!rstn)begin state<=0;grant<=0;next_master<=0;end
 else case(state)
 0:if(s_awvalid[next_master]||s_awvalid[!next_master])begin
    grant<=s_awvalid[next_master]?next_master:!next_master;state<=1;end
 1:if(m_awvalid&&m_awready)state<=2;
 2:if(m_wvalid&&m_wready&&m_wlast)state<=3;
 3:if(m_bvalid&&m_bready)begin next_master<=!grant;state<=0;end
 default:state<=0;
 endcase
endmodule
