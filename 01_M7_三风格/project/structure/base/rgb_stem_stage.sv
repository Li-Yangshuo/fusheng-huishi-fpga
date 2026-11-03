// Raw UINT8 RGB -> centered signed windows -> exact dense3x3 -> M17 INT8.
// Exporter supplies folded_bias = unsigned_RGB_bias + 128*sum(weights).
// This is a candidate integer boundary; trained C calibration is not frozen.
module rgb_stem_stage #(
 parameter WIDTH=1280,HEIGHT=720,XW=$clog2(WIDTH+1),YW=$clog2(HEIGHT+1),PT=XW+YW+34,QT=PT+1
)(
 input wire clk,rst,input wire cfg_valid,output wire cfg_ready,input wire [1:0] cfg_kind,
 input wire [3:0] cfg_index,input wire [255:0] cfg_data,
 input wire start_valid,output wire start_ready,input wire [31:0] start_frame,
 input wire in_valid,output wire in_ready,input wire [39:0] in_data,input wire in_eol,
 output wire out_valid,input wire out_ready,output wire signed [7:0] out_data,
 output wire [XW-1:0] out_x,output wire [YW-1:0] out_y,output wire [0:0] out_channel,
 output wire [31:0] out_frame,output wire out_eol,out_last,
 output reg done,frame_ok,output wire [2:0] error_code
);
 reg [31:0] frame_lease;reg frame_lease_error;
 reg active,cfg_error,math_error,window_seen,gather_seen,retired_last;
 reg [431:0] weights;reg [63:0] biases;reg [47:0] quant;reg [1:0] loaded_w,loaded_q;
 wire wsr,gsr;
 assign start_ready=!rst && !active && (&loaded_w) && (&loaded_q) && wsr && gsr && error_code==0;
 wire go=start_valid && start_ready;
 assign cfg_ready=!rst && !active && !go;
 wire cfg_take=cfg_valid && cfg_ready;
 genvar c;
 generate for(c=0;c<2;c=c+1)begin:configuration
  always @(posedge clk)if(!rst && cfg_take && cfg_index==c)begin
   if(cfg_kind==0)weights[c*216+:216]<=cfg_data[215:0];
   if(cfg_kind==1)begin biases[c*32+:32]<=cfg_data[31:0];quant[c*24+:24]<=cfg_data[55:32];end
  end
 end endgenerate
 wire wv,wr,we,wl,wd,werr;wire [4:0] mask;wire [359:0] windows;wire [5*XW-1:0] wx;wire [9:0] wc;
 wire [YW-1:0] wy;wire [31:0] wf;
 rolling_window3x3 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.CHANNELS(3)) window(
 clk,rst,go,wsr,start_frame,in_valid,in_ready,in_data^40'h8080808080,in_eol,wv,wr,mask,windows,wx,wc,wy,wf,we,wl,wd,werr);
 wire gv,gr,ge,gl,gd,gerr;wire [215:0] rgb;wire [XW-1:0] gx;wire [YW-1:0] gy;wire [31:0] gf;
 rgb_window_gather #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) gather(
 clk,rst,go,gsr,start_frame,wv,wr,mask,windows,wx,wc,wy,wf,we,wl,gv,gr,rgb,gx,gy,gf,ge,gl,gd,gerr);
 wire mv,mr,merr;wire signed [31:0] a0,a1;wire [1:0] ov;wire [QT-1:0] mtag;
 rgb_stem_mac_c2 #(.TAG_W(PT)) mac(clk,rst,weights,biases,gv,gr,rgb,{gl,ge,32'd0,gy,gx},mv,mr,a0,a1,ov,mtag,merr);
 wire qv,qr;wire [15:0] qdata;wire [QT-1:0] qtag;
 wire [47:0] selected_q=quant;
 requant_pair_serial #(.TAG_W(QT)) rq(clk,rst,mv,mr,a0,a1,selected_q,mtag,qv,qr,qdata,qtag);
 reg lane;assign qr=out_ready && lane && !rst;
 assign out_valid=qv;assign out_data=qdata[lane*8+:8];assign out_channel=lane;
 assign out_x=qtag[1+:XW];assign out_y=qtag[1+XW+:YW];assign out_frame=frame_lease;
 assign out_eol=qtag[QT-2] && lane;assign out_last=qtag[QT-1] && lane;
 assign error_code={1'b0,math_error,(cfg_error||werr||gerr||merr||frame_lease_error)};
 always @(posedge clk)begin
  if(rst)begin active<=0;cfg_error<=0;math_error<=0;loaded_w<=0;loaded_q<=0;
   window_seen<=0;gather_seen<=0;retired_last<=0;done<=0;frame_ok<=0;lane<=0;end
  else begin
   done<=0;frame_ok<=0;
   if(cfg_take)begin
    if(cfg_kind==3)begin loaded_w<=0;loaded_q<=0;end
    else if(cfg_index<2 && cfg_kind==0)loaded_w[cfg_index]<=1;
    else if(cfg_index<2 && cfg_kind==1)loaded_q[cfg_index]<=1;
    else cfg_error<=1;
   end
   if(go)begin active<=1;window_seen<=0;gather_seen<=0;retired_last<=0;end
   if(wd)window_seen<=1;if(gd)gather_seen<=1;
   if(mv && mr && (|ov))math_error<=1;
   if(out_valid && out_ready)begin lane<=~lane;if(out_last)retired_last<=1;end
   if(active && retired_last && window_seen && gather_seen)begin active<=0;done<=1;frame_ok<=error_code==0;end
  end
 end
 // Single-frame lease: retain the full ID once; internal arithmetic carries
 // constant-zero frame bits. The original tag widths and port API stay fixed.
 always @(posedge clk)begin
  if(rst)begin frame_lease<=0;frame_lease_error<=0;end
  else begin
   if(go)frame_lease<=start_frame;
   if(gv && gr && gf!=frame_lease)frame_lease_error<=1;
  end
 end
endmodule
