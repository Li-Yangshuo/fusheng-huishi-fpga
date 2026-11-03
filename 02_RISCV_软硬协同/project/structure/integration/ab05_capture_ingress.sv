// Camera pixel ingress proposal. Camera is NEVER backpressured.
// Reserve destination before arm, then wait for cam_armed before selecting SOF.
// Input RGB24 -> native 0xRRGGBB00; every four pixels form one128bit beat.
// Any ingress fault quarantines the descriptor. Existing AXI VALID is not gated.
// Both clock domains and the external AXI fabric must reset together on abort.
module ab05_capture_ingress #(
 parameter WIDTH=1280,HEIGHT=720,BB=16,FIFO_AW=9,WDOG=100000,
 parameter [32:0] MEM_BYTES=33'h010000000
)(
 input wire axi_clk,axi_rstn,cam_clk,cam_rstn,
 input wire arm_valid,output wire arm_ready,
 input wire [31:0] arm_frame_id,arm_base,
 input wire cam_valid,input wire [23:0] cam_pixel,input wire [31:0] cam_frame_id,
 input wire cam_sof,cam_eol,cam_eof,output wire cam_armed,
 output wire error,output wire [3:0] error_code,
 output reg done,output reg [31:0] done_id,
 output wire [31:0] accepted_frames,dropped_frames,
 output reg [31:0] completed_frames,output wire [FIFO_AW:0] fifo_high,
 output wire [3:0] awid,output wire [31:0] awaddr,output wire [7:0] awlen,
 output wire [2:0] awsize,output wire [1:0] awburst,
 output wire awvalid,input wire awready,
 output wire [127:0] wdata,output wire [15:0] wstrb,
 output wire wlast,wvalid,input wire wready,
 input wire [3:0] bid,input wire [1:0] bresp,input wire bvalid,output wire bready
);
 localparam PIXELS=WIDTH*HEIGHT;
 wire arst=!(axi_rstn&&cam_rstn);
 (* async_reg="true" *) reg [1:0] arun,crun;
 always @(posedge axi_clk or posedge arst)if(arst)arun<=0;else arun<={arun[0],1'b1};
 always @(posedge cam_clk or posedge arst)if(arst)crun<=0;else crun<={crun[0],1'b1};
 wire axrun=arun[1],camrun=crun[1];
 reg active,invalid,writer_start,saw_end,saw_writer;
 reg [3:0] first_error_code;
 reg [31:0] fid,base;
 wire launch_ready,launch_valid,launch_take;wire [31:0] launch_id;
 wire end_ready,end_valid;wire [31:0] end_id;
 reg end_pending;
 reg armed,capturing,cfault;reg [3:0] cfault_code;
 (* async_reg="true" *) reg ce1,ce2,ce3;
 (* async_reg="true" *) reg [3:0] cc1,cc2;
 reg [31:0] cid,cindex,cx,cy;reg [1:0] lane;
 reg [127:0] assemble;reg [162:0] pending;reg pending_valid;
 wire packed_ready,stream_valid,stream_ready;wire [162:0] stream;
 reg [31:0] admitted,discarded,admit_gray,drop_gray;
 (* async_reg="true" *) reg [31:0] ag1,ag2,dg1,dg2;
 wire writer_busy,writer_done,writer_error,writer_ready;
 wire [31:0] unused_beats,unused_bursts,unused_wait;
 wire [32:0] arm_end={1'b0,arm_base}+PIXELS*4;
 wire arm_bad=arm_base%(BB*16)!=0 || arm_end>MEM_BYTES;
 wire arm_take=arm_valid&&arm_ready;
 wire end_fault=end_valid&&(!active||end_id!=fid||saw_end);
 assign error=invalid||writer_error||ce3;
 assign error_code=first_error_code!=0?first_error_code:(invalid?4'd1:(ce3?cc2:(writer_error?4'd8:4'd0)));
 assign arm_ready=axrun&&!active&&!error&&!writer_busy&&launch_ready;
 assign cam_armed=camrun&&armed&&!cfault;
 function [31:0] ungray(input [31:0] g);
  integer k;begin ungray[31]=g[31];for(k=30;k>=0;k=k-1)ungray[k]=ungray[k+1]^g[k];end
 endfunction
 assign accepted_frames=ungray(ag2);
 assign dropped_frames=ungray(dg2);
 always @(posedge axi_clk or negedge axrun)begin
  if(!axrun)begin
   active<=0;invalid<=0;writer_start<=0;saw_end<=0;saw_writer<=0;fid<=0;base<=0;
   done<=0;done_id<=0;completed_frames<=0;ce1<=0;ce2<=0;ce3<=0;cc1<=0;cc2<=0;first_error_code<=0;
   ag1<=0;ag2<=0;dg1<=0;dg2<=0;
  end else begin
   ce1<=cfault;ce2<=ce1;ce3<=ce2;cc1<=cfault_code;cc2<=cc1;
   ag1<=admit_gray;ag2<=ag1;dg1<=drop_gray;dg2<=dg1;
   if(first_error_code==0)begin
    if(invalid)first_error_code<=1;else if(ce3)first_error_code<=cc2;else if(writer_error)first_error_code<=8;
   end
   done<=0;writer_start<=0;
   if(arm_take)begin
    if(arm_bad)invalid<=1;
    else begin active<=1;fid<=arm_frame_id;base<=arm_base;writer_start<=1;saw_end<=0;saw_writer<=0;end
   end
   if(end_valid)begin if(end_fault)invalid<=1;else saw_end<=1;end
   if(writer_done)begin if(!active||saw_writer)invalid<=1;else saw_writer<=1;end
   if(active&&!error&&!end_fault&&(saw_end||end_valid)&&(saw_writer||writer_done))begin
    active<=0;done<=1;done_id<=fid;completed_frames<=completed_frames+1;
   end
  end
 end
 ab05_async_stream #(.W(32),.AW(2)) arm_cdc(
  .arst(arst),.wclk(axi_clk),.rclk(cam_clk),.s_valid(arm_take&&!arm_bad),.s_ready(launch_ready),
  .s_data(arm_frame_id),.m_valid(launch_valid),.m_ready(launch_take),.m_data(launch_id),.w_high_water());
 assign launch_take=camrun&&!armed&&!capturing&&!cfault&&!end_pending;
 ab05_async_stream #(.W(32),.AW(2)) end_cdc(
  .arst(arst),.wclk(cam_clk),.rclk(axi_clk),.s_valid(end_pending),.s_ready(end_ready),
  .s_data(cid),.m_valid(end_valid),.m_ready(1'b1),.m_data(end_id),.w_high_water());
 ab05_async_stream #(.W(163),.AW(FIFO_AW)) pixels_cdc(
  .arst(arst),.wclk(cam_clk),.rclk(axi_clk),.s_valid(pending_valid&&!cfault),.s_ready(packed_ready),
  .s_data(pending),.m_valid(stream_valid),.m_ready(stream_ready),.m_data(stream),.w_high_water(fifo_high));
 assign stream_ready=writer_ready&&!error;
 wire marks_ok=cam_frame_id==cid && cam_sof==(cindex==0) &&
   cam_eol==(cx==WIDTH-1) && cam_eof==(cindex==PIXELS-1);
 always @(posedge cam_clk or negedge camrun)begin
  if(!camrun)begin
   armed<=0;capturing<=0;cfault<=0;cfault_code<=0;cid<=0;cindex<=0;cx<=0;cy<=0;lane<=0;
   assemble<=0;pending<=0;pending_valid<=0;end_pending<=0;
   admitted<=0;discarded<=0;admit_gray<=0;drop_gray<=0;
  end else begin
   if(pending_valid&&packed_ready)pending_valid<=0;
   if(end_pending&&end_ready)end_pending<=0;
   if(launch_valid&&launch_take)begin
    cid<=launch_id;armed<=1;capturing<=0;cindex<=0;cx<=0;cy<=0;lane<=0;
   end
   if(cam_valid&&!cfault)begin
    if(!(armed||capturing)||!marks_ok)begin
     cfault<=1;cfault_code<=!(armed||capturing)?4'd2:(cam_frame_id!=cid?4'd3:4'd4);
     armed<=0;capturing<=0;discarded<=discarded+1;
     drop_gray<=((discarded+32'd1)>>1)^(discarded+32'd1);
    end else if(lane==3 && pending_valid&&!packed_ready)begin
     cfault<=1;cfault_code<=5;armed<=0;capturing<=0;discarded<=discarded+1;
     drop_gray<=((discarded+32'd1)>>1)^(discarded+32'd1);
    end else begin
     if(cindex==0)begin
      armed<=0;capturing<=1;admitted<=admitted+1;
      admit_gray<=((admitted+32'd1)>>1)^(admitted+32'd1);
     end
     assemble[lane*32+:32]<={cam_pixel,8'h00};
     if(lane==3)begin
      pending<={cid,(cindex==3),(cx==WIDTH-1),(cindex==PIXELS-1),{cam_pixel,8'h00},assemble[95:0]};
      pending_valid<=1;lane<=0;
     end else lane<=lane+1;
     cindex<=cindex+1;
     if(cx==WIDTH-1)begin cx<=0;cy<=cy+1;end else cx<=cx+1;
     if(cindex==PIXELS-1)begin capturing<=0;end_pending<=1;end
    end
   end
  end
 end
 ab05_native_writer #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BB(BB),.WDOG(WDOG)) writer(
  .clk(axi_clk),.rstn(axrun),.start(writer_start),.base(base),.id(fid),.busy(writer_busy),.done(writer_done),.error(writer_error),
  .valid(stream_valid&&!error),.ready(writer_ready),.payload(stream),
  .awid(awid),.awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),.awvalid(awvalid),.awready(awready),
  .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),
  .bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready),
  .accepted_beats(unused_beats),.committed_bursts(unused_bursts),.wait_cycles(unused_wait));
 // synthesis translate_off
 initial if(WIDTH<4||HEIGHT<1||WIDTH%4||(PIXELS/4)%BB||FIFO_AW<2)$fatal(1,"capture dimensions");
 // synthesis translate_on
endmodule
