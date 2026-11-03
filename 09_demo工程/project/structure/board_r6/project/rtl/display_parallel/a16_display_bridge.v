// Join the accepted complete-frame descriptor to the supplied DDR display RTL.
// Original left half passes through. Right half is a 960x720 letterbox.
// This preserves the old left crop; it does NOT yet establish same-FOV/same-id
// with that live path. Sync, DE and background are delayed exactly two clocks.
module a16_display_bridge #(
 parameter MAX_BURST_BEATS=16,
 parameter AW=10,
 parameter MIRROR_LEFT=0,
 parameter WIN_X0=960,WIN_Y0=180,WIN_W=960,WIN_H=720
)(
 input wire axi_clk,axi_rstn,pix_clk,pix_rstn,
 input wire frame_valid,output wire frame_ready,
 input wire [31:0] frame_id,frame_base,frame_stride_bytes,
 input wire [15:0] frame_width,frame_height,
 output wire release_valid,input wire release_ready,output wire [31:0] release_frame_id,
 output wire [3:0] arid,output wire [31:0] araddr,output wire [7:0] arlen,
 output wire arvalid,input wire arready,
 input wire [3:0] rid,input wire [127:0] rdata,input wire [1:0] rresp,
 input wire rlast,rvalid,output wire rready,
 input wire i_de,i_hs,i_vs,input wire [23:0] i_rgb,
 output wire o_de,o_hs,o_vs,output wire [23:0] o_rgb,
 output wire [31:0] timing_dbg,miss_expected_slot0,miss_slot1_flags,
 output wire [15:0] display_underrun_count,
 output wire [31:0] curr_frame_id,output wire axi_error,underflow
);
 wire [23:0] win_rgb;wire win_active;wire [15:0] uf_count;
 assign display_underrun_count=uf_count;
 disp_rd_top #(.AW(AW),.MAX_BURST_BEATS(MAX_BURST_BEATS),.MIRROR_LEFT(MIRROR_LEFT),.ARID(4'd2),.WIN_X0(WIN_X0),.WIN_Y0(WIN_Y0),.WIN_W(WIN_W),.WIN_H(WIN_H)) u_display (
  .axi_clk(axi_clk),.axi_rstn(axi_rstn),.pclk(pix_clk),.prstn(pix_rstn),
  .frame_valid(frame_valid),.frame_ready(frame_ready),.frame_id(frame_id),.frame_base(frame_base),
  .frame_width(frame_width),.frame_height(frame_height),.frame_stride_bytes(frame_stride_bytes),
  .release_valid(release_valid),.release_ready(release_ready),.release_frame_id(release_frame_id),
  .m_axi_arid(arid),.m_axi_araddr(araddr),.m_axi_arlen(arlen),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
  .m_axi_rid(rid),.m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready),
  .in_de(i_de),.in_hs(i_hs),.in_vs(i_vs),.out_rgb(win_rgb),.out_active(win_active),
  .timing_dbg(timing_dbg),.miss_expected_slot0(miss_expected_slot0),.miss_slot1_flags(miss_slot1_flags),
  .curr_frame_id(curr_frame_id),.frm_err(axi_error),.underrun_cnt(uf_count),.underrun_sticky(underflow));
 reg [11:0] x;
 reg [1:0] de_pipe,hs_pipe,vs_pipe,left_pipe;
 reg [23:0] rgb1,rgb2;
 always @(posedge pix_clk or negedge pix_rstn) begin
  if(!pix_rstn) begin
   x<=0;de_pipe<=0;hs_pipe<=0;vs_pipe<=0;left_pipe<=0;rgb1<=0;rgb2<=0;
  end else begin
   if(!i_de) x<=0;else x<=x+1'b1;
   de_pipe<={de_pipe[0],i_de};hs_pipe<={hs_pipe[0],i_hs};vs_pipe<={vs_pipe[0],i_vs};
   left_pipe<={left_pipe[0],(x<WIN_X0)};rgb1<=i_rgb;rgb2<=rgb1;
  end
 end
 assign o_de=de_pipe[1];assign o_hs=hs_pipe[1];assign o_vs=vs_pipe[1];
 assign o_rgb=win_active ? win_rgb : (!MIRROR_LEFT && left_pipe[1]) ? rgb2 : 24'd0;
endmodule
