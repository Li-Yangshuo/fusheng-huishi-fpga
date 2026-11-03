// Whole-frame admission in front of ab05_capture_ingress. The physical camera
// has no ready and is never stopped. Reserve/arm both modules atomically before
// the intended raw SOF. Unselected frames are skipped; selected marks and IDs
// pass through unchanged so that capture_ingress detects malformed frames.
// No local timeout/cancel: a missing matching frame retains the single intent.
module ab05_camera_selector #(
 parameter FIFO_AW=2
)(
 input wire axi_clk,axi_rstn,cam_clk,cam_rstn,
 input wire arm_valid,output wire arm_ready,input wire [31:0] arm_frame_id,
 input wire raw_valid,input wire [23:0] raw_pixel,input wire [31:0] raw_frame_id,
 input wire raw_sof,raw_eol,raw_eof,input wire ingress_armed,
 output wire selected_valid,output wire [23:0] selected_pixel,
 output wire [31:0] selected_frame_id,
 output wire selected_sof,selected_eol,selected_eof,
 output wire selection_armed,
 output wire [31:0] skipped_frames,selected_frames
);
 wire arst=!(axi_rstn&&cam_rstn);
 (* async_reg="true" *) reg [1:0] arun,crun;
 always @(posedge axi_clk or posedge arst)if(arst)arun<=0;else arun<={arun[0],1'b1};
 always @(posedge cam_clk or posedge arst)if(arst)crun<=0;else crun<={crun[0],1'b1};
 wire axrun=arun[1],camrun=crun[1];
 reg outstanding;reg [31:0] outstanding_id;
 wire token_ready,token_valid,token_take;wire [31:0] token_id;
 wire finish_ready,finish_valid;wire [31:0] finish_id;
 reg intent,forwarding,finish_pending;reg [31:0] intended_id;
 reg [31:0] skipped,selected,skip_gray,select_gray;
 (* async_reg="true" *) reg [31:0] sk1,sk2,se1,se2;
 assign arm_ready=axrun&&!outstanding&&token_ready;
 wire arm_take=arm_valid&&arm_ready;
 always @(posedge axi_clk or negedge axrun)begin
  if(!axrun)begin outstanding<=0;outstanding_id<=0;sk1<=0;sk2<=0;se1<=0;se2<=0;end
  else begin
   sk1<=skip_gray;sk2<=sk1;se1<=select_gray;se2<=se1;
   if(arm_take)begin outstanding<=1;outstanding_id<=arm_frame_id;end
   if(finish_valid&&outstanding&&finish_id==outstanding_id)outstanding<=0;
  end
 end
 ab05_async_stream #(.W(32),.AW(FIFO_AW)) arm_cdc(
  .arst(arst),.wclk(axi_clk),.rclk(cam_clk),.s_valid(arm_take),.s_ready(token_ready),
  .s_data(arm_frame_id),.m_valid(token_valid),.m_ready(token_take),.m_data(token_id),.w_high_water());
 assign token_take=camrun&&!intent&&!forwarding&&!finish_pending;
 ab05_async_stream #(.W(32),.AW(FIFO_AW)) finish_cdc(
  .arst(arst),.wclk(cam_clk),.rclk(axi_clk),.s_valid(finish_pending),.s_ready(finish_ready),
  .s_data(intended_id),.m_valid(finish_valid),.m_ready(1'b1),.m_data(finish_id),.w_high_water());
 wire select_start=camrun&&raw_valid&&raw_sof&&!forwarding&&intent&&
                   ingress_armed&&raw_frame_id==intended_id;
 assign selected_valid=camrun&&raw_valid&&(forwarding||select_start);
 assign selected_pixel=raw_pixel;
 assign selected_frame_id=raw_frame_id;
 assign selected_sof=selected_valid&&raw_sof;
 assign selected_eol=selected_valid&&raw_eol;
 assign selected_eof=selected_valid&&raw_eof;
 assign selection_armed=camrun&&intent;
 function [31:0] ungray(input [31:0] g);
  integer k;begin ungray[31]=g[31];for(k=30;k>=0;k=k-1)ungray[k]=ungray[k+1]^g[k];end
 endfunction
 assign skipped_frames=ungray(sk2);
 assign selected_frames=ungray(se2);
 always @(posedge cam_clk or negedge camrun)begin
  if(!camrun)begin
   intent<=0;forwarding<=0;finish_pending<=0;intended_id<=0;
   skipped<=0;selected<=0;skip_gray<=0;select_gray<=0;
  end else begin
   if(finish_pending&&finish_ready)finish_pending<=0;
   if(token_valid&&token_take)begin intent<=1;intended_id<=token_id;end
   if(raw_valid&&raw_sof&&!forwarding&&!select_start)begin
    skipped<=skipped+1;skip_gray<=((skipped+32'd1)>>1)^(skipped+32'd1);
   end
   if(select_start)begin
    intent<=0;forwarding<=1;selected<=selected+1;
    select_gray<=((selected+32'd1)>>1)^(selected+32'd1);
   end
   // Do not re-check/replace the selected ID or filter bad marks mid-frame.
   // A later SOF without EOF remains forwarded, allowing ingress to fault.
   if(selected_valid&&raw_eof)begin forwarding<=0;finish_pending<=1;end
  end
 end
 // synthesis translate_off
 initial if(FIFO_AW<2)$fatal(1,"camera_selector FIFO_AW>=2");
 // synthesis translate_on
endmodule
