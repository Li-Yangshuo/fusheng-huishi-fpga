// Auxiliary preview stream -> fixed-rate ROI scanout. No vendor/PLL instance.
// FRAME carries the full frame ID once; every source pixel is validated before
// enqueue. Pixels carry RGB/EOL/EOF. A missed deadline poisons the remaining
// display frame; a later header can only bind after the next frame_start.
module ab05_preview_scanout_r9 #(
 parameter integer VIEW_W=960,VIEW_H=540,FIFO_AW=11,MIN_START_PIXELS=0
)(
 input wire axi_clk,axi_rstn,pix_clk,pix_rstn,
 input wire in_valid,output wire in_ready,input wire [23:0] in_rgb,
 input wire [31:0] in_frame_id,input wire [10:0] in_x,input wire [9:0] in_y,
 input wire in_sof,in_eol,in_eof,
 // One-cycle frame_start in blanking, >=4 pixel clocks before first ROI.
 input wire frame_start,roi_active,roi_repeat,input wire [10:0] roi_x,input wire [9:0] roi_y,
 output reg scan_valid,output wire [23:0] scan_rgb,
 output reg scan_black,output reg [31:0] scan_frame_id,
 output wire axi_boundary,
 output wire [FIFO_AW:0] fifo_high_water,pix_available,
 output reg [31:0] startup_short_frames,
 output reg [31:0] source_errors,source_drop_pixels,
 output reg [31:0] underflow_frames,dropped_frames,completed_frames,
 output reg [31:0] tag_error_frames,scan_error_frames,boundary_overflows
);
 localparam [1:0] PIXEL=0,FRAME=1,ABORT=2;
 localparam [1:0] SEEK=0,FIRST=1,STREAM=2,DROP=3;
 wire arst=!(axi_rstn&&pix_rstn);
 (* async_reg="true" *) reg [1:0] arun,prun;
 always @(posedge axi_clk or posedge arst)
  if(arst)arun<=0;else arun<={arun[0],1'b1};
 always @(posedge pix_clk or posedge arst)
  if(arst)prun<=0;else prun<={prun[0],1'b1};
 function [31:0] inc(input [31:0] x);
  begin inc=(&x)?x:x+32'd1;end
 endfunction

 reg [1:0] istate;
 reg [31:0] source_id;
 reg [10:0] sx;reg [9:0] sy;
 reg [23:0] first_rgb;
 wire first_ok=in_sof&&(in_x==0)&&(in_y==0)&&
  (in_eol==(VIEW_W==1))&&(in_eof==((VIEW_W==1)&&(VIEW_H==1)));
 wire stream_ok=(in_frame_id==source_id)&&(in_x==sx)&&(in_y==sy)&&!in_sof&&
  (in_eol==(sx==VIEW_W-1))&&(in_eof==((sx==VIEW_W-1)&&(sy==VIEW_H-1)));
 wire fw_ready,fr_valid,fr_ready;wire [33:0] fr_data;
 reg fw_valid;reg [33:0] fw_data;
 // DROP consumes corrupt-frame tail even with a full FIFO. A prospective SOF
 // is backpressured until its FRAME token can be recorded atomically.
 assign in_ready=arun[1]&&((istate==FIRST)?1'b0:
  ((istate==STREAM)?fw_ready:(first_ok?fw_ready:1'b1)));
 always @* begin
  fw_valid=0;fw_data=0;
  if(arun[1])begin
   if(istate==FIRST)begin
    fw_valid=1;fw_data={PIXEL,6'b0,(VIEW_H==1&&VIEW_W==1),(VIEW_W==1),first_rgb};
   end else if(istate==STREAM)begin
    fw_valid=in_valid;
    fw_data=stream_ok?{PIXEL,6'b0,in_eof,in_eol,in_rgb}:{ABORT,32'd1};
   end else if(in_valid&&first_ok)begin
    fw_valid=1;fw_data={FRAME,in_frame_id};
   end
  end
 end
 always @(posedge axi_clk or posedge arst)begin
  if(arst)begin
   istate<=SEEK;source_id<=0;sx<=0;sy<=0;first_rgb<=0;
   source_errors<=0;source_drop_pixels<=0;
  end else if(arun[1])begin
   if(istate==FIRST)begin
    if(fw_ready)begin
     if(VIEW_W==1&&VIEW_H==1)istate<=SEEK;
     else begin istate<=STREAM;sx<=(VIEW_W==1)?0:1;sy<=(VIEW_W==1)?1:0;end
    end
   end else if(in_valid&&in_ready)begin
    if(istate==STREAM)begin
     if(!stream_ok)begin
      istate<=DROP;source_errors<=inc(source_errors);source_drop_pixels<=inc(source_drop_pixels);
     end else if(in_eof)begin istate<=SEEK;sx<=0;sy<=0;end
     else if(in_eol)begin sx<=0;sy<=sy+1'b1;end
     else sx<=sx+1'b1;
    end else if(first_ok)begin
     source_id<=in_frame_id;first_rgb<=in_rgb;istate<=FIRST;sx<=0;sy<=0;
    end else begin
     source_drop_pixels<=inc(source_drop_pixels);
     if(istate==SEEK)begin source_errors<=inc(source_errors);istate<=DROP;end
    end
   end
  end
 end
 ab05_display_async_stream #(.W(34),.AW(FIFO_AW)) pixels(
  .arst(arst),.wclk(axi_clk),.rclk(pix_clk),.s_valid(fw_valid),.s_ready(fw_ready),.s_data(fw_data),
  .m_valid(fr_valid),.m_ready(fr_ready),.m_data(fr_data),.w_high_water(fifo_high_water),.r_available(pix_available));

 wire request_ready,request_valid;
 ab05_display_async_stream #(.W(1),.AW(2)) requests(
  .arst(arst),.wclk(pix_clk),.rclk(axi_clk),.s_valid(prun[1]&&frame_start),.s_ready(request_ready),.s_data(1'b1),
  .m_valid(request_valid),.m_ready(arun[1]),.m_data(),.w_high_water(),.r_available());
 assign axi_boundary=arun[1]&&request_valid;

 reg armed,selected,poisoned,roi_seen,complete;
 reg [10:0] px;reg [9:0] py;reg [31:0] chosen_id;
 (* syn_ramstyle="block_ram" *) reg [23:0] line_cache[0:VIEW_W-1];
 wire [1:0] kind=fr_data[33:32];
 wire coordinate_ok=(roi_x==px)&&(roi_y==py)&&(roi_x<VIEW_W)&&(roi_y<VIEW_H);
 wire markers_ok=(fr_data[24]==(px==VIEW_W-1))&&
  (fr_data[25]==((px==VIEW_W-1)&&(py==VIEW_H-1)))&&(fr_data[31:26]==0);
 wire start_level_ok=roi_seen||(pix_available>=MIN_START_PIXELS);
 wire usable=!roi_repeat&&start_level_ok&&armed&&selected&&!poisoned&&!complete&&fr_valid&&(kind==PIXEL)&&coordinate_ok&&markers_ok;
 // A separate, unreset synchronous RAM port infers block RAM. Both paths have
 // one pixel-clock latency; the registered selector aligns RAM/direct data.
 reg [23:0] direct_rgb,cache_rgb;
 reg repeat_q;
 always @(posedge pix_clk)begin
  cache_rgb<=line_cache[roi_x];
  if(prun[1]&&!frame_start&&roi_active&&usable)line_cache[px]<=fr_data[23:0];
 end
 assign scan_rgb=repeat_q?cache_rgb:direct_rgb;
 wire select_header=armed&&!selected&&!poisoned&&!roi_seen&&!roi_active&&fr_valid&&(kind==FRAME);
 // Never consume another FRAME while emitting/poisoning the current frame.
 // Corrupt/late pixels drain in blanking as well as during the black suffix.
 assign fr_ready=prun[1]&&!frame_start&&fr_valid&&
  ((roi_active)?(!roi_repeat&&(usable||((kind!=FRAME)&&(!selected||poisoned||!usable)))):
   (select_header||((!selected||poisoned)&&(kind!=FRAME))));
 always @(posedge pix_clk or posedge arst)begin
  if(arst)begin
   armed<=0;selected<=0;poisoned<=0;roi_seen<=0;complete<=0;px<=0;py<=0;chosen_id<=0;
   scan_valid<=0;direct_rgb<=0;repeat_q<=0;scan_black<=1;scan_frame_id<=0;
   underflow_frames<=0;dropped_frames<=0;completed_frames<=0;
   tag_error_frames<=0;scan_error_frames<=0;boundary_overflows<=0;startup_short_frames<=0;
  end else if(prun[1])begin
   scan_valid<=roi_active;direct_rgb<=0;repeat_q<=0;scan_black<=1;scan_frame_id<=chosen_id;
   if(frame_start)begin
    if(!request_ready)boundary_overflows<=inc(boundary_overflows);
    if(armed&&selected&&!complete&&!poisoned)dropped_frames<=inc(dropped_frames);
    armed<=1;selected<=0;poisoned<=0;roi_seen<=0;complete<=0;px<=0;py<=0;chosen_id<=0;
    scan_frame_id<=0;
    if(roi_active)begin
     poisoned<=1;roi_seen<=1;dropped_frames<=inc(dropped_frames);scan_error_frames<=inc(scan_error_frames);
    end
   end else begin
    if(select_header&&fr_ready)begin selected<=1;chosen_id<=fr_data[31:0];end
    if(roi_active&&roi_repeat)begin
     if(armed&&(selected||complete)&&roi_seen&&!poisoned&&roi_x<VIEW_W)begin repeat_q<=1;scan_black<=0;scan_frame_id<=chosen_id;end
    end else if(roi_active)begin
     roi_seen<=1;
     if(usable)begin
      direct_rgb<=fr_data[23:0];scan_black<=0;scan_frame_id<=chosen_id;
      if(px==VIEW_W-1)begin
       px<=0;
       if(py==VIEW_H-1)begin complete<=1;selected<=0;completed_frames<=inc(completed_frames);end
       else py<=py+1'b1;
      end else px<=px+1'b1;
     end else if(!poisoned)begin
      poisoned<=1;selected<=0;dropped_frames<=inc(dropped_frames);
      if(!start_level_ok)startup_short_frames<=inc(startup_short_frames);
      if(!armed||!selected||!fr_valid||!start_level_ok)underflow_frames<=inc(underflow_frames);
      else if(kind!=PIXEL||!markers_ok)tag_error_frames<=inc(tag_error_frames);
      if(!coordinate_ok||complete)scan_error_frames<=inc(scan_error_frames);
     end
    end
   end
  end
 end
 // synthesis translate_off
 initial if(VIEW_W<1||VIEW_W>2048||VIEW_H<1||VIEW_H>1024||FIFO_AW<2)
  $fatal(1,"preview scanout parameters out of range");
 // synthesis translate_on
endmodule
