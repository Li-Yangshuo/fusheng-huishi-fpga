// A18.6: KEY1 active-low, synchronizer + stable-level debounce + release rearm.
// Switch only on aligned video VS falling edge while both paths are blank.
// RAW_LATENCY=5 matches split_view (3 clocks) + a16_display_bridge (2).
module a18_view_mode #(
 parameter integer DEBOUNCE_CYCLES=2970000,
 parameter integer RAW_LATENCY=5
)(
 input wire clk,rstn,key_n,
 input wire serial_toggle,
 input wire raw_de,raw_hs,raw_vs,input wire [23:0] raw_rgb,
 input wire dual_de,dual_hs,dual_vs,input wire [23:0] dual_rgb,
 output wire o_de,o_hs,o_vs,output wire [23:0] o_rgb,
 output reg dual_mode,requested_dual,press_pulse
);
 localparam integer CW=(DEBOUNCE_CYCLES>1)?$clog2(DEBOUNCE_CYCLES):1;
 (* async_reg="true" *) reg key_meta,key_sync;
 reg candidate,armed;
 reg [CW-1:0] stable_count;
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin key_meta<=1;key_sync<=1;end
  else begin key_meta<=key_n;key_sync<=key_meta;end
 end
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin candidate<=1;armed<=0;stable_count<=0;press_pulse<=0;end
  else begin
   press_pulse<=0;
   if(key_sync!=candidate)begin candidate<=key_sync;stable_count<=0;end
   else if(stable_count<DEBOUNCE_CYCLES-1)stable_count<=stable_count+1'b1;
   else if(candidate)armed<=1;
   else if(armed)begin armed<=0;press_pulse<=1;end
  end
 end
 // Each independent input event toggles once; simultaneous key+UART cancel.
 wire key_event;
 assign key_event=(key_sync==candidate)&&(stable_count>=DEBOUNCE_CYCLES-1)&&!candidate&&armed;
 always @(posedge clk or negedge rstn)begin
  if(!rstn)requested_dual<=1;
  else if(serial_toggle ^ key_event)requested_dual<=~requested_dual;
 end
 reg [RAW_LATENCY-1:0] raw_de_pipe,raw_hs_pipe,raw_vs_pipe;
 reg [23:0] raw_pixels[0:RAW_LATENCY-1];
 integer i;
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin
   raw_de_pipe<=0;raw_hs_pipe<=0;raw_vs_pipe<=0;
   for(i=0;i<RAW_LATENCY;i=i+1)raw_pixels[i]<=0;
  end else begin
   raw_de_pipe[0]<=raw_de;raw_hs_pipe[0]<=raw_hs;raw_vs_pipe[0]<=raw_vs;raw_pixels[0]<=raw_rgb;
   for(i=1;i<RAW_LATENCY;i=i+1)begin
    raw_de_pipe[i]<=raw_de_pipe[i-1];raw_hs_pipe[i]<=raw_hs_pipe[i-1];
    raw_vs_pipe[i]<=raw_vs_pipe[i-1];raw_pixels[i]<=raw_pixels[i-1];
   end
  end
 end
 reg vs_d;
 wire frame_boundary=vs_d&&!raw_vs_pipe[RAW_LATENCY-1];
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin vs_d<=0;dual_mode<=1;end
  else begin
   vs_d<=raw_vs_pipe[RAW_LATENCY-1];
   if(frame_boundary&&!raw_de_pipe[RAW_LATENCY-1]&&!dual_de)dual_mode<=requested_dual;
  end
 end
 assign o_de=dual_mode?dual_de:raw_de_pipe[RAW_LATENCY-1];
 assign o_hs=dual_mode?dual_hs:raw_hs_pipe[RAW_LATENCY-1];
 assign o_vs=dual_mode?dual_vs:raw_vs_pipe[RAW_LATENCY-1];
 assign o_rgb=dual_mode?dual_rgb:raw_pixels[RAW_LATENCY-1];
endmodule
