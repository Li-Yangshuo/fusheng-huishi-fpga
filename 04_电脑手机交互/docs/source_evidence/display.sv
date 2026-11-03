// Connect directly to a_b_video_renderer_loaded left/right preview ports.
// Four frame-latched modes; complete pair is stretched vertically to full height.
// Both complete 640x360 DDR previews upscale by 2 in both axes.
module ab05_dual_preview_hdmi #(
 parameter VIEW_W=960,VIEW_H=540,ACTIVE_W=1920,ACTIVE_H=1080,
 parameter X0=(ACTIVE_W/2-VIEW_W)/2,Y0=(ACTIVE_H-VIEW_H)/2,FIFO_AW=13,MIN_START_PIXELS=960
)(
 input wire axi_clk,axi_rstn,pix_clk,pix_rstn,
 input wire [1:0] demo_mode,
 input wire frame_start,pix_hs,pix_vs,pix_de,
 input wire [11:0] pix_x,pix_y,
 input wire left_pixel_valid,output wire left_pixel_ready,
 input wire [23:0] left_pixel_rgb,input wire [31:0] left_pixel_frame_id,
 input wire [10:0] left_pixel_x,input wire [9:0] left_pixel_y,
 input wire left_pixel_sof,left_pixel_eol,left_pixel_eof,
 input wire right_pixel_valid,output wire right_pixel_ready,
 input wire [23:0] right_pixel_rgb,input wire [31:0] right_pixel_frame_id,
 input wire [10:0] right_pixel_x,input wire [9:0] right_pixel_y,
 input wire right_pixel_sof,right_pixel_eol,right_pixel_eof,
 output wire left_boundary,right_boundary,
 output wire [23:0] hdmi_rgb,output reg hdmi_hs,hdmi_vs,hdmi_de,
 output wire [31:0] left_display_frame_id,right_display_frame_id,
 output wire [FIFO_AW:0] left_fifo_high_water,right_fifo_high_water,
 output wire [FIFO_AW:0] left_pix_available,right_pix_available,
 input wire snapshot_request,output wire snapshot_busy,output reg snapshot_valid,
 output reg [639:0] snapshot_data,
 output wire net_lv,net_rv,output wire [23:0] net_lr,net_rr,
 output reg [9:0] net_lx,net_rx,output reg [8:0] net_y,
 output wire [31:0] net_lid,net_rid
);
 localparam SMALL_Y=0;
 wire small_pair=demo_mode==2'd3;
 wire small_row=(pix_y>=SMALL_Y)&&(pix_y<SMALL_Y+2*VIEW_H);
 wire left_roi=pix_de&&(!small_pair||(small_row&&pix_x<VIEW_W));
 wire right_roi=pix_de&&(!small_pair||(small_row&&pix_x>=ACTIVE_W/2&&pix_x<ACTIVE_W/2+VIEW_W));
 wire [10:0] left_x=small_pair?pix_x:(pix_x>>1);
 wire [10:0] right_x=small_pair?(pix_x-ACTIVE_W/2):(pix_x>>1);
 wire [9:0] local_y=small_pair?((pix_y-SMALL_Y)>>1):((pix_y-Y0)>>1);
 wire repeat_row=small_pair?pix_y[0]:(pix_y[0]||pix_x[0]);
 wire lv,rv,lb,rb;wire [23:0] lr,rr;
 wire [31:0] l_srcerr,l_srcdrop,l_under,l_drop,l_done,l_tag,l_scan,l_bover,l_short;
 wire [31:0] r_srcerr,r_srcdrop,r_under,r_drop,r_done,r_tag,r_scan,r_bover,r_short;
 ab05_preview_scanout_r9 #(.VIEW_W(VIEW_W),.VIEW_H(VIEW_H),.FIFO_AW(FIFO_AW),
  .MIN_START_PIXELS(MIN_START_PIXELS)) left_scanout(
  .axi_clk(axi_clk),.axi_rstn(axi_rstn),.pix_clk(pix_clk),.pix_rstn(pix_rstn),
  .in_valid(left_pixel_valid),.in_ready(left_pixel_ready),.in_rgb(left_pixel_rgb),
  .in_frame_id(left_pixel_frame_id),.in_x(left_pixel_x),.in_y(left_pixel_y),
  .in_sof(left_pixel_sof),.in_eol(left_pixel_eol),.in_eof(left_pixel_eof),
  .frame_start(frame_start),.roi_active(left_roi),.roi_repeat(repeat_row),.roi_x(left_x),.roi_y(local_y),
  .scan_valid(lv),.scan_rgb(lr),.scan_black(lb),.scan_frame_id(left_display_frame_id),
  .axi_boundary(left_boundary),.source_errors(l_srcerr),.source_drop_pixels(l_srcdrop),
  .underflow_frames(l_under),.dropped_frames(l_drop),.completed_frames(l_done),
  .tag_error_frames(l_tag),.scan_error_frames(l_scan),.boundary_overflows(l_bover),
  .startup_short_frames(l_short),.fifo_high_water(left_fifo_high_water),.pix_available(left_pix_available));
 ab05_preview_scanout_r9 #(.VIEW_W(VIEW_W),.VIEW_H(VIEW_H),.FIFO_AW(FIFO_AW),
  .MIN_START_PIXELS(MIN_START_PIXELS)) right_scanout(
  .axi_clk(axi_clk),.axi_rstn(axi_rstn),.pix_clk(pix_clk),.pix_rstn(pix_rstn),
  .in_valid(right_pixel_valid),.in_ready(right_pixel_ready),.in_rgb(right_pixel_rgb),
  .in_frame_id(right_pixel_frame_id),.in_x(right_pixel_x),.in_y(right_pixel_y),
  .in_sof(right_pixel_sof),.in_eol(right_pixel_eol),.in_eof(right_pixel_eof),
  .frame_start(frame_start),.roi_active(right_roi),.roi_repeat(repeat_row),.roi_x(right_x),.roi_y(local_y),
  .scan_valid(rv),.scan_rgb(rr),.scan_black(rb),.scan_frame_id(right_display_frame_id),
  .axi_boundary(right_boundary),.source_errors(r_srcerr),.source_drop_pixels(r_srcdrop),
  .underflow_frames(r_under),.dropped_frames(r_drop),.completed_frames(r_done),
  .tag_error_frames(r_tag),.scan_error_frames(r_scan),.boundary_overflows(r_bover),
  .startup_short_frames(r_short),.fifo_high_water(right_fifo_high_water),.pix_available(right_pix_available));
 // Passive network tap: one sample per native preview pixel, 1/4 HDMI scans.
 reg [1:0] net_phase;reg net_capture,net_lsample,net_rsample;
 always @(posedge pix_clk or negedge pix_rstn)
 if(!pix_rstn)begin net_phase<=0;net_capture<=0;net_lsample<=0;net_rsample<=0;net_lx<=0;net_rx<=0;net_y<=0;end
 else begin
 if(frame_start)begin net_phase<=net_phase+1;net_capture<=net_phase==0;end
 net_lsample<=left_roi&&!repeat_row;net_rsample<=right_roi&&!repeat_row;
 net_lx<=left_x;net_rx<=right_x;net_y<=local_y;
 end
 wire net_pair_ok=left_display_frame_id[30:0]==right_display_frame_id[30:0]&&right_display_frame_id[31];
 assign net_lv=net_capture&&net_pair_ok&&net_lsample&&lv&&!lb;
 assign net_rv=net_capture&&net_pair_ok&&net_rsample&&rv&&!rb;
 assign net_lid={1'b0,left_display_frame_id[30:0]};
 assign net_rid={1'b0,right_display_frame_id[30:0]};
 assign net_lr=present_rgb(lr);assign net_rr=present_rgb(rr);
 reg [11:0] xq;reg deq,hsq,vsq;reg [1:0] modeq;
 // Mild display-only shadow/midtone lift, without gain in the CNN path.
 // y=x+floor(min(x,255-x)/4): 0->0,64->80,128->159,192->207,255->255.
 // Shift/add only; no extra frame/line buffer, RAM or DSP multiplier.
 function automatic [7:0] display_lift(input [7:0] c);
  reg [7:0] distance;
  begin distance=c[7]?(8'd255-c):c;display_lift=c+(distance>>2);end
 endfunction
 function automatic [23:0] present_rgb(input [23:0] rgb);
  begin present_rgb={display_lift(rgb[23:16]),display_lift(rgb[15:8]),display_lift(rgb[7:0])};end
 endfunction
 reg [23:0] output_rgb;
 always @(posedge pix_clk or negedge pix_rstn)
 if(!pix_rstn)begin hdmi_hs<=0;hdmi_vs<=0;hdmi_de<=0;deq<=0;hsq<=0;vsq<=0;xq<=0;modeq<=0;output_rgb<=0;end
 else begin
 xq<=pix_x;deq<=pix_de;hsq<=pix_hs;vsq<=pix_vs;modeq<=demo_mode;
 hdmi_hs<=hsq;hdmi_vs<=vsq;hdmi_de<=deq;
 output_rgb<=0;
 if(deq)begin
 if(left_display_frame_id[30:0]==right_display_frame_id[30:0])begin
  if((modeq==0||((modeq==1||modeq==3)&&xq<ACTIVE_W/2))&&lv)output_rgb<=present_rgb(lr);
  else if((modeq==2||((modeq==1||modeq==3)&&xq>=ACTIVE_W/2))&&rv&&right_display_frame_id[31])output_rgb<=present_rgb(rr);
 end
 end
 end
 assign hdmi_rgb=output_rgb;
 // Pixel-domain words 0..7 left, 8..15 right. Source counters are sampled
 // locally in AXI on request; this is a coherent per-domain snapshot.
 wire [511:0] pixel_stats={
  32'(right_pix_available),r_short,r_bover,r_scan,r_tag,r_done,r_drop,r_under,
  32'(left_pix_available),l_short,l_bover,l_scan,l_tag,l_done,l_drop,l_under};
 wire pixel_snapshot_valid;wire [511:0] pixel_snapshot;
 reg [127:0] source_snapshot;
 ab05_display_snapshot #(.W(512)) counters(
  .axi_clk(axi_clk),.axi_rstn(axi_rstn),.pix_clk(pix_clk),.pix_rstn(pix_rstn),
  .request(snapshot_request),.pix_data(pixel_stats),.busy(snapshot_busy),
  .valid(pixel_snapshot_valid),.data(pixel_snapshot));
 always @(posedge axi_clk or negedge axi_rstn)
  if(!axi_rstn)begin source_snapshot<=0;snapshot_data<=0;snapshot_valid<=0;end
  else begin
   snapshot_valid<=pixel_snapshot_valid;
   if(snapshot_request&&!snapshot_busy)source_snapshot<={r_srcdrop,r_srcerr,l_srcdrop,l_srcerr};
   if(pixel_snapshot_valid)snapshot_data<={source_snapshot,pixel_snapshot};
  end
 // synthesis translate_off
 initial if(2*VIEW_W>ACTIVE_W||Y0<0||Y0+VIEW_H>ACTIVE_H||MIN_START_PIXELS>(1<<FIFO_AW))
  $fatal(1,"dual preview geometry/prefetch parameters");
 // synthesis translate_on
endmodule
