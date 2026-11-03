// B single-clock/single-job source raster -> real windows -> DW/tile/PW.
// Full external identity held once; constant internal tags require coordinated
// reset and prohibit child reuse until BOTH true retirement receipts arrive.
module stream_dw_pw_stage #(
 parameter MAX_ROW_BYTES=2560,parameter WORDS=(MAX_ROW_BYTES+7)/8,
 parameter AW=(WORDS<2)?1:$clog2(WORDS)
)(
 input wire clk,rst,cfg_valid,output wire cfg_ready,input wire cfg_stage,
 input wire [1:0] cfg_kind,input wire [3:0] cfg_index,input wire [255:0] cfg_data,
 input wire start_valid,output wire start_ready,input wire [127:0] start_descriptor,
 input wire [63:0] start_session,input wire [11:0] start_width,start_height,
 input wire [3:0] start_ci,start_co,input wire start_stride2,start_up2,start_residual,
 input wire in_valid,output wire in_ready,input wire [63:0] in_data,input wire [7:0] in_mask,
 input wire [11:0] in_row,input wire [AW-1:0] in_word,input wire in_eol,in_frame_last,
 input wire [127:0] in_descriptor,input wire [63:0] in_session,
 output wire out_valid,input wire out_ready,output wire [63:0] out_data,
 output wire [7:0] out_mask,output wire [31:0] out_pixel,output wire out_frame_last,
 output wire [127:0] out_descriptor,output wire [63:0] out_session,
 output wire busy,error,output wire [20:0] error_code,output reg done
);
 reg active,ctx_error,mode_error,retire_error,window_retired;
 reg [127:0] descriptor;reg [63:0] session;
 wire ws,ks,werr,kerr,wd,kd,wready,kv;wire [3:0] wcode;wire [13:0] kcode;
 wire [11:0] ow=start_up2?(start_width<<1):start_stride2?((start_width>>1)+start_width[0]):start_width;
 wire [11:0] oh=start_up2?(start_height<<1):start_stride2?((start_height>>1)+start_height[0]):start_height;
 wire [31:0] npixels=ow*oh;
 wire [14:0] source_bytes=({3'd0,start_width}<<((start_ci==2)?1:(start_ci==4)?2:3));
 wire mode_ok=(start_ci==2||start_ci==4||start_ci==8)&&(start_co==2||start_co==4||start_co==8)&&
              start_width!=0&&start_height!=0&&source_bytes<=MAX_ROW_BYTES&&
              (!start_up2||(start_width<=2047&&start_height<=2047))&&!(start_stride2&&start_up2)&&
              !(start_ci==2&&start_co==8)&&(!start_residual||(start_ci==8&&start_co==8));
 assign error=ctx_error||mode_error||retire_error||werr||kerr;
 // Published child output is never withdrawn on a fault. No successful
 // done/feature commit may be inferred from a prefix or final data alone.
 assign error_code={retire_error,mode_error,ctx_error,wcode,kcode};
 assign busy=active;
 assign start_ready=!rst&&!active&&!error&&mode_ok&&ws&&ks;
 wire go=start_valid&&start_ready;
 wire fc;
 assign cfg_ready=!rst&&!active&&!error&&!start_valid&&fc;
 wire cv=cfg_valid&&cfg_ready;
 wire context_ok=in_descriptor==descriptor&&in_session==session;
 assign in_ready=!rst&&active&&!error&&wready;
 wire take=in_valid&&in_ready;
 wire [287:0] windows;wire [31:0] wpixel;wire [2:0] wchannel;wire wlast;
 wire [127:0] unused_wctx,unused_kctx;wire [63:0] unused_wsession,unused_ksession;
 wire unused_wbusy,unused_kbusy,wready_out;wire [1:0] unused_high;
 shared_window_stream #(.MAX_ROW_BYTES(MAX_ROW_BYTES)) window(clk,rst,go,ws,128'd0,64'd0,start_width,start_height,start_ci,start_stride2,start_up2,
  take&&context_ok,wready,in_data,in_mask,in_row,in_word,in_eol,in_frame_last,128'd0,64'd0,
  kv,wready_out,windows,wpixel,wchannel,wlast,unused_wctx,unused_wsession,unused_wbusy,werr,wcode,wd);
 shared_dw_pw_stage kernel(clk,rst,cv,fc,cfg_stage,cfg_kind,cfg_index,cfg_data,
  go,ks,128'd0,64'd0,start_ci,start_co,npixels,start_residual,
  kv,wready_out,windows,128'd0,64'd0,wpixel,wchannel,wlast,
  out_valid,out_ready,out_data,out_mask,out_pixel,out_frame_last,unused_kctx,unused_ksession,unused_kbusy,kerr,kcode,kd,unused_high);
 assign out_descriptor=descriptor;assign out_session=session;
 wire barriers=window_retired||wd;
 always @(posedge clk)begin
  if(rst)begin active<=0;ctx_error<=0;mode_error<=0;retire_error<=0;window_retired<=0;descriptor<=0;session<=0;done<=0;end
  else begin
   done<=0;
   if(start_valid&&!active&&!mode_ok)mode_error<=1;
   if(go)begin active<=1;window_retired<=0;descriptor<=start_descriptor;session<=start_session;end
   if(take&&!context_ok)ctx_error<=1;
   if(wd)window_retired<=1;
   if(active&&kd)begin
    if(!barriers||kcode[13])retire_error<=1;
    if(barriers&&!error&&!(take&&!context_ok))begin active<=0;done<=1;end
   end
  end
 end
endmodule
