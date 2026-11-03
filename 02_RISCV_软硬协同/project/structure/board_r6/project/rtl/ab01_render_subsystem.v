// AB01 real arithmetic + host service + result display, all AXI at core_clk.
module ab01_render_subsystem(
 input wire clk,rstn,pix_clk,rx,dual_mode,output wire tx,toggle,
 output wire flash_clk,flash_cs,flash_mosi,input wire flash_miso,
 input wire input_valid,output wire input_ready,
 input wire [31:0] input_id,input_base,input_stride,input_bytes,
 input wire [15:0] input_width,input_height,input_format,
 output wire source_release_valid,input wire source_release_ready,output wire [31:0] source_release_id,
 input wire i_de,i_hs,i_vs,input wire [23:0] i_rgb,
 output wire o_de,o_hs,o_vs,output wire [23:0] o_rgb,
 output wire [31:0] jobs_done,error_bits,result_id,result_uf,
 output wire [3:0] awid,
 output wire [31:0] awaddr,
 output wire [7:0] awlen,
 output wire [2:0] awsize,
 output wire [1:0] awburst,
 output wire awvalid,
 input wire awready,
 output wire [127:0] wdata,
 output wire [15:0] wstrb,
 output wire wlast,
 output wire wvalid,
 input wire wready,
 input wire [3:0] bid,
 input wire [1:0] bresp,
 input wire bvalid,
 output wire bready,
 output wire [3:0] arid,
 output wire [31:0] araddr,
 output wire [7:0] arlen,
 output wire [2:0] arsize,
 output wire [1:0] arburst,
 output wire arvalid,
 input wire arready,
 input wire [3:0] rid,
 input wire [127:0] rdata,
 input wire [1:0] rresp,
 input wire rlast,
 input wire rvalid,
 output wire rready
);
wire [3:0] b_awid;
wire [31:0] b_awaddr;
wire [7:0] b_awlen;
wire [2:0] b_awsize;
wire [1:0] b_awburst;
wire b_awvalid;
wire b_awready;
wire [127:0] b_wdata;
wire [15:0] b_wstrb;
wire b_wlast;
wire b_wvalid;
wire b_wready;
wire [3:0] b_bid;
wire [1:0] b_bresp;
wire b_bvalid;
wire b_bready;
wire [3:0] b_arid;
wire [31:0] b_araddr;
wire [7:0] b_arlen;
wire [2:0] b_arsize;
wire [1:0] b_arburst;
wire b_arvalid;
wire b_arready;
wire [3:0] b_rid;
wire [127:0] b_rdata;
wire [1:0] b_rresp;
wire b_rlast;
wire b_rvalid;
wire b_rready;
wire [3:0] h_awid;
wire [31:0] h_awaddr;
wire [7:0] h_awlen;
wire [2:0] h_awsize;
wire [1:0] h_awburst;
wire h_awvalid;
wire h_awready;
wire [127:0] h_wdata;
wire [15:0] h_wstrb;
wire h_wlast;
wire h_wvalid;
wire h_wready;
wire [3:0] h_bid;
wire [1:0] h_bresp;
wire h_bvalid;
wire h_bready;
wire [3:0] h_arid;
wire [31:0] h_araddr;
wire [7:0] h_arlen;
wire [2:0] h_arsize;
wire [1:0] h_arburst;
wire h_arvalid;
wire h_arready;
wire [3:0] h_rid;
wire [127:0] h_rdata;
wire [1:0] h_rresp;
wire h_rlast;
wire h_rvalid;
wire h_rready;
wire [3:0] c_awid;
wire [31:0] c_awaddr;
wire [7:0] c_awlen;
wire [2:0] c_awsize;
wire [1:0] c_awburst;
wire c_awvalid;
wire c_awready;
wire [127:0] c_wdata;
wire [15:0] c_wstrb;
wire c_wlast;
wire c_wvalid;
wire c_wready;
wire [3:0] c_bid;
wire [1:0] c_bresp;
wire c_bvalid;
wire c_bready;
wire [3:0] c_arid;
wire [31:0] c_araddr;
wire [7:0] c_arlen;
wire [2:0] c_arsize;
wire [1:0] c_arburst;
wire c_arvalid;
wire c_arready;
wire [3:0] c_rid;
wire [127:0] c_rdata;
wire [1:0] c_rresp;
wire c_rlast;
wire c_rvalid;
wire c_rready;
wire [3:0] d_awid;
wire [31:0] d_awaddr;
wire [7:0] d_awlen;
wire [2:0] d_awsize;
wire [1:0] d_awburst;
wire d_awvalid;
wire d_awready;
wire [127:0] d_wdata;
wire [15:0] d_wstrb;
wire d_wlast;
wire d_wvalid;
wire d_wready;
wire [3:0] d_bid;
wire [1:0] d_bresp;
wire d_bvalid;
wire d_bready;
wire [3:0] d_arid;
wire [31:0] d_araddr;
wire [7:0] d_arlen;
wire [2:0] d_arsize;
wire [1:0] d_arburst;
wire d_arvalid;
wire d_arready;
wire [3:0] d_rid;
wire [127:0] d_rdata;
wire [1:0] d_rresp;
wire d_rlast;
wire d_rvalid;
wire d_rready;
wire [15:0] paddr;wire psel,penable,pwrite,pready,pslverr;wire [31:0] pwdata,prdata;
wire [31:0] local_addr,local_wdata;wire local_write;wire [127:0] local_rdata;
wire [31:0] b_count,job_id,job_in_base,job_out_base;wire b_busy,job_active;
wire [7:0] b_fault;
wire frame_valid,frame_ready,release_valid,release_ready;wire [31:0] frame_id,frame_base,release_id;
wire [15:0] uf_count;wire display_error,display_underflow;
(* async_reg="true" *) reg mode1,mode2;
always @(posedge clk or negedge rstn)if(!rstn)begin mode1<=1;mode2<=1;end else begin mode1<=dual_mode;mode2<=mode1;end
ab01_jobs jobs(.clk(clk),.rstn(rstn),.input_valid(input_valid),.input_ready(input_ready),
 .input_id(input_id),.input_base(input_base),.input_stride(input_stride),.input_bytes(input_bytes),
 .input_width(input_width),.input_height(input_height),.input_format(input_format),
 .source_release_valid(source_release_valid),.source_release_ready(source_release_ready),.source_release_id(source_release_id),
 .completed_count(b_count),.b_busy(b_busy),.b_fault(b_fault),.frame_valid(frame_valid),.frame_ready(frame_ready),.frame_id(frame_id),.frame_base(frame_base),
 .release_valid(release_valid),.release_ready(release_ready),.release_id(release_id),
 .local_addr(local_addr),.local_wdata(local_wdata),.local_write(local_write),.local_rdata(local_rdata),
 .job_id(job_id),.job_in_base(job_in_base),.job_out_base(job_out_base),.jobs_done(jobs_done),.error_bits(error_bits),.active(job_active));
ab10_cpu host(
 .flash_clk(flash_clk),.flash_cs(flash_cs),.flash_mosi(flash_mosi),.flash_miso(flash_miso),
 .bid(h_bid),.rid(h_rid),
 .clk(clk),
 .rstn(rstn),
 .rx(rx),
 .tx(tx),
 .dual_mode(mode2),
 .toggle(toggle),
 .paddr(paddr),
 .psel(psel),
 .penable(penable),
 .pwrite(pwrite),
 .pwdata(pwdata),
 .pready(pready),
 .pslverr(pslverr),
 .prdata(prdata),
 .local_addr(local_addr),
 .local_wdata(local_wdata),
 .local_write(local_write),
 .local_rdata(local_rdata),
 .awid(h_awid),
 .arid(h_arid),
 .awaddr(h_awaddr),
 .araddr(h_araddr),
 .awlen(h_awlen),
 .arlen(h_arlen),
 .awvalid(h_awvalid),
 .wvalid(h_wvalid),
 .arvalid(h_arvalid),
 .awready(h_awready),
 .wready(h_wready),
 .arready(h_arready),
 .wdata(h_wdata),
 .wstrb(h_wstrb),
 .wlast(h_wlast),
 .bready(h_bready),
 .rready(h_rready),
 .bvalid(h_bvalid),
 .rvalid(h_rvalid),
 .rlast(h_rlast),
 .bresp(h_bresp),
 .rresp(h_rresp),
 .rdata(h_rdata)
);
assign h_awsize=4;assign h_arsize=4;assign h_awburst=1;assign h_arburst=1;
nst_accel_top #(.W0(256),.H0(192),.TILE_R(2)) b_core(
 // AB09 closure candidate: B computation, APB, DMA and control share core_clk.
 // This also removes the unsynchronized eng_idle control crossing inside B.
 // Display remains on pix_clk; all Q33 arithmetic and scheduling are unchanged.
 .clk_c(clk),
 .clk_axi(clk),
 .rst_n(rstn),
 .monitor_frame_count(b_count),
 .monitor_busy(b_busy),
 .axi_fault(b_fault),
 .irq(),
 .dbg_layer_pulse(),
 .dbg_layer(),
 .dbg_dst(),
 .paddr(paddr),
 .psel(psel),
 .penable(penable),
 .pwrite(pwrite),
 .pwdata(pwdata),
 .pready(pready),
 .pslverr(pslverr),
 .prdata(prdata),
 .m_axi_awid(b_awid),
 .m_axi_awaddr(b_awaddr),
 .m_axi_awlen(b_awlen),
 .m_axi_awsize(b_awsize),
 .m_axi_awburst(b_awburst),
 .m_axi_awvalid(b_awvalid),
 .m_axi_awready(b_awready),
 .m_axi_wdata(b_wdata),
 .m_axi_wstrb(b_wstrb),
 .m_axi_wlast(b_wlast),
 .m_axi_wvalid(b_wvalid),
 .m_axi_wready(b_wready),
 .m_axi_bid(b_bid),
 .m_axi_bresp(b_bresp),
 .m_axi_bvalid(b_bvalid),
 .m_axi_bready(b_bready),
 .m_axi_arid(b_arid),
 .m_axi_araddr(b_araddr),
 .m_axi_arlen(b_arlen),
 .m_axi_arsize(b_arsize),
 .m_axi_arburst(b_arburst),
 .m_axi_arvalid(b_arvalid),
 .m_axi_arready(b_arready),
 .m_axi_rid(b_rid),
 .m_axi_rdata(b_rdata),
 .m_axi_rresp(b_rresp),
 .m_axi_rlast(b_rlast),
 .m_axi_rvalid(b_rvalid),
 .m_axi_rready(b_rready)
);
a16_display_bridge #(.MAX_BURST_BEATS(8),.AW(8)) display(
 .axi_clk(clk),
 .axi_rstn(rstn),
 .pix_clk(pix_clk),
 .pix_rstn(rstn),
 .frame_valid(frame_valid),
 .frame_ready(frame_ready),
 .frame_id(frame_id),
 .frame_base(frame_base),
 .frame_width(16'd256),
 .frame_height(16'd192),
 .frame_stride_bytes(32'd1024),
 .release_valid(release_valid),
 .release_ready(release_ready),
 .release_frame_id(release_id),
 .timing_dbg(),
 .miss_expected_slot0(),
 .miss_slot1_flags(),
 .display_underrun_count(uf_count),
 .curr_frame_id(result_id),
 .axi_error(display_error),
 .underflow(display_underflow),
 .i_de(i_de),
 .i_hs(i_hs),
 .i_vs(i_vs),
 .i_rgb(i_rgb),
 .o_de(o_de),
 .o_hs(o_hs),
 .o_vs(o_vs),
 .o_rgb(o_rgb),
 .arid(d_arid),
 .araddr(d_araddr),
 .arlen(d_arlen),
 .arvalid(d_arvalid),
 .arready(d_arready),
 .rid(d_rid),
 .rdata(d_rdata),
 .rresp(d_rresp),
 .rlast(d_rlast),
 .rvalid(d_rvalid),
 .rready(d_rready)
);
assign d_awid=0;assign d_awaddr=0;assign d_awlen=0;assign d_awsize=4;assign d_awburst=1;assign d_awvalid=0;assign d_wdata=0;assign d_wstrb=0;assign d_wlast=0;assign d_wvalid=0;assign d_bready=1;assign d_arsize=4;assign d_arburst=1;
assign result_uf={14'd0,display_error,display_underflow,uf_count};
a19_shared_axi2 #(.READ_S0_QUOTA(1)) b_host(
 .clk(clk),
 .rstn(rstn),
 .s0_awid(b_awid),
 .s0_awaddr(b_awaddr),
 .s0_awlen(b_awlen),
 .s0_awsize(b_awsize),
 .s0_awburst(b_awburst),
 .s0_awvalid(b_awvalid),
 .s0_awready(b_awready),
 .s0_wdata(b_wdata),
 .s0_wstrb(b_wstrb),
 .s0_wlast(b_wlast),
 .s0_wvalid(b_wvalid),
 .s0_wready(b_wready),
 .s0_bid(b_bid),
 .s0_bresp(b_bresp),
 .s0_bvalid(b_bvalid),
 .s0_bready(b_bready),
 .s0_arid(b_arid),
 .s0_araddr(b_araddr),
 .s0_arlen(b_arlen),
 .s0_arsize(b_arsize),
 .s0_arburst(b_arburst),
 .s0_arvalid(b_arvalid),
 .s0_arready(b_arready),
 .s0_rid(b_rid),
 .s0_rdata(b_rdata),
 .s0_rresp(b_rresp),
 .s0_rlast(b_rlast),
 .s0_rvalid(b_rvalid),
 .s0_rready(b_rready),
 .s1_awid(h_awid),
 .s1_awaddr(h_awaddr),
 .s1_awlen(h_awlen),
 .s1_awsize(h_awsize),
 .s1_awburst(h_awburst),
 .s1_awvalid(h_awvalid),
 .s1_awready(h_awready),
 .s1_wdata(h_wdata),
 .s1_wstrb(h_wstrb),
 .s1_wlast(h_wlast),
 .s1_wvalid(h_wvalid),
 .s1_wready(h_wready),
 .s1_bid(h_bid),
 .s1_bresp(h_bresp),
 .s1_bvalid(h_bvalid),
 .s1_bready(h_bready),
 .s1_arid(h_arid),
 .s1_araddr(h_araddr),
 .s1_arlen(h_arlen),
 .s1_arsize(h_arsize),
 .s1_arburst(h_arburst),
 .s1_arvalid(h_arvalid),
 .s1_arready(h_arready),
 .s1_rid(h_rid),
 .s1_rdata(h_rdata),
 .s1_rresp(h_rresp),
 .s1_rlast(h_rlast),
 .s1_rvalid(h_rvalid),
 .s1_rready(h_rready),
 .m_awid(c_awid),
 .m_awaddr(c_awaddr),
 .m_awlen(c_awlen),
 .m_awsize(c_awsize),
 .m_awburst(c_awburst),
 .m_awvalid(c_awvalid),
 .m_awready(c_awready),
 .m_wdata(c_wdata),
 .m_wstrb(c_wstrb),
 .m_wlast(c_wlast),
 .m_wvalid(c_wvalid),
 .m_wready(c_wready),
 .m_bid(c_bid),
 .m_bresp(c_bresp),
 .m_bvalid(c_bvalid),
 .m_bready(c_bready),
 .m_arid(c_arid),
 .m_araddr(c_araddr),
 .m_arlen(c_arlen),
 .m_arsize(c_arsize),
 .m_arburst(c_arburst),
 .m_arvalid(c_arvalid),
 .m_arready(c_arready),
 .m_rid(c_rid),
 .m_rdata(c_rdata),
 .m_rresp(c_rresp),
 .m_rlast(c_rlast),
 .m_rvalid(c_rvalid),
 .m_rready(c_rready)
);
a19_shared_axi2 #(.READ_S0_QUOTA(4)) display_b(
 .clk(clk),
 .rstn(rstn),
 .s0_awid(d_awid),
 .s0_awaddr(d_awaddr),
 .s0_awlen(d_awlen),
 .s0_awsize(d_awsize),
 .s0_awburst(d_awburst),
 .s0_awvalid(d_awvalid),
 .s0_awready(d_awready),
 .s0_wdata(d_wdata),
 .s0_wstrb(d_wstrb),
 .s0_wlast(d_wlast),
 .s0_wvalid(d_wvalid),
 .s0_wready(d_wready),
 .s0_bid(d_bid),
 .s0_bresp(d_bresp),
 .s0_bvalid(d_bvalid),
 .s0_bready(d_bready),
 .s0_arid(d_arid),
 .s0_araddr(d_araddr),
 .s0_arlen(d_arlen),
 .s0_arsize(d_arsize),
 .s0_arburst(d_arburst),
 .s0_arvalid(d_arvalid),
 .s0_arready(d_arready),
 .s0_rid(d_rid),
 .s0_rdata(d_rdata),
 .s0_rresp(d_rresp),
 .s0_rlast(d_rlast),
 .s0_rvalid(d_rvalid),
 .s0_rready(d_rready),
 .s1_awid(c_awid),
 .s1_awaddr(c_awaddr),
 .s1_awlen(c_awlen),
 .s1_awsize(c_awsize),
 .s1_awburst(c_awburst),
 .s1_awvalid(c_awvalid),
 .s1_awready(c_awready),
 .s1_wdata(c_wdata),
 .s1_wstrb(c_wstrb),
 .s1_wlast(c_wlast),
 .s1_wvalid(c_wvalid),
 .s1_wready(c_wready),
 .s1_bid(c_bid),
 .s1_bresp(c_bresp),
 .s1_bvalid(c_bvalid),
 .s1_bready(c_bready),
 .s1_arid(c_arid),
 .s1_araddr(c_araddr),
 .s1_arlen(c_arlen),
 .s1_arsize(c_arsize),
 .s1_arburst(c_arburst),
 .s1_arvalid(c_arvalid),
 .s1_arready(c_arready),
 .s1_rid(c_rid),
 .s1_rdata(c_rdata),
 .s1_rresp(c_rresp),
 .s1_rlast(c_rlast),
 .s1_rvalid(c_rvalid),
 .s1_rready(c_rready),
 .m_awid(awid),
 .m_awaddr(awaddr),
 .m_awlen(awlen),
 .m_awsize(awsize),
 .m_awburst(awburst),
 .m_awvalid(awvalid),
 .m_awready(awready),
 .m_wdata(wdata),
 .m_wstrb(wstrb),
 .m_wlast(wlast),
 .m_wvalid(wvalid),
 .m_wready(wready),
 .m_bid(bid),
 .m_bresp(bresp),
 .m_bvalid(bvalid),
 .m_bready(bready),
 .m_arid(arid),
 .m_araddr(araddr),
 .m_arlen(arlen),
 .m_arsize(arsize),
 .m_arburst(arburst),
 .m_arvalid(arvalid),
 .m_arready(arready),
 .m_rid(rid),
 .m_rdata(rdata),
 .m_rresp(rresp),
 .m_rlast(rlast),
 .m_rvalid(rvalid),
 .m_rready(rready)
);
endmodule
