// Real fused DW -> two-bank tile transpose -> packed PW, one job lease.
// Full external task/frame/model/slot and session held and checked once here.
// All children share a coordinated reset and a constant internal lease tag.
// The parent cannot reuse the lease until every compute/tile stage retires.
module shared_dw_pw_stage(
 input wire clk,rst,cfg_valid,output wire cfg_ready,input wire cfg_stage,
 input wire [1:0] cfg_kind,input wire [3:0] cfg_index,input wire [255:0] cfg_data,
 input wire start_valid,output wire start_ready,input wire [127:0] start_descriptor,
 input wire [63:0] start_session,input wire [3:0] start_ci,start_co,
 input wire [31:0] start_pixels,input wire start_residual,
 input wire in_valid,output wire in_ready,input wire [287:0] in_windows,
 input wire [127:0] in_descriptor,input wire [63:0] in_session,
 input wire [31:0] in_pixel,input wire [2:0] in_channel,input wire in_frame_last,
 output wire out_valid,input wire out_ready,output wire [63:0] out_data,
 output wire [7:0] out_mask,output wire [31:0] out_pixel,output wire out_frame_last,
 output wire [127:0] out_descriptor,output wire [63:0] out_session,
 output wire busy,error,output wire [13:0] error_code,output reg done,
 output wire [1:0] tile_bank_high_water
);
 reg active,ctx_error,mode_error,retire_error;reg [1:0] retired;
 reg [127:0] descriptor;reg [63:0] session;
 wire ds,ts,ps,dc,pc;wire de,te,pe,dd,td,pd;wire [3:0] dcode,pcode;wire [2:0] tcode;
 wire mode_ok=(start_ci==2||start_ci==4||start_ci==8)&&(start_co==2||start_co==4||start_co==8)&&start_pixels!=0&&!(start_ci==2&&start_co==8)&&(!start_residual||(start_ci==8&&start_co==8));
 assign error_code={retire_error,mode_error,ctx_error,tcode,pcode,dcode};
 assign error=ctx_error||mode_error||retire_error||de||te||pe;
 assign busy=active;
 assign start_ready=!rst&&!active&&!error&&mode_ok&&ds&&ts&&ps;
 wire go=start_valid&&start_ready;
 assign cfg_ready=!rst&&!active&&!error&&!start_valid&&(cfg_stage?pc:dc);
 wire cv=cfg_valid&&cfg_ready;
 wire dr,dv;wire [31:0] ddata,didentity,dpx;wire [3:0] dmask;wire [2:0] dch;wire dlast;
 wire [127:0] unused_dctx;wire [63:0] unused_dsess;wire unused_db;
 wire context_ok=in_descriptor==descriptor&&in_session==session;
 wire dw_ready;
 assign in_ready=!rst&&active&&!error&&dw_ready;
 wire it=in_valid&&in_ready;
 shared_dw_vector dw(clk,rst,cv&&!cfg_stage,dc,cfg_kind,cfg_index,cfg_data,go,ds,128'd0,64'd0,start_ci,start_pixels,
  it&&context_ok,dw_ready,in_windows,128'd0,64'd0,in_pixel,in_channel,in_frame_last,
  dv,dr,ddata,didentity,dmask,dpx,dch,dlast,unused_dctx,unused_dsess,unused_db,de,dcode,dd);
 wire tv,tr,tf,tl,tlast;wire [63:0] tdata,tidentity;wire [31:0] tpx;
 wire [127:0] unused_tctx;wire [63:0] unused_tsess;wire unused_tb;
 dw_pw_tile tile(clk,rst,go,ts,128'd0,64'd0,start_ci,start_co,start_pixels,start_residual,
  dv,dr,ddata,didentity,dmask,dpx,dch,dlast,128'd0,64'd0,
  tv,tr,tdata,tidentity,tpx,tf,tl,tlast,unused_tctx,unused_tsess,unused_tb,te,tcode,td,tile_bank_high_water);
 wire [127:0] unused_pctx;wire [63:0] unused_psess;wire unused_pb;
 shared_pw_vector_r2 pw(clk,rst,cv&&cfg_stage,pc,cfg_kind,cfg_index,cfg_data,go,ps,128'd0,64'd0,start_ci,start_co,start_pixels,start_residual,
  tv,tr,tdata,128'd0,64'd0,tpx,tf,tl,tlast,tidentity,
  out_valid,out_ready,out_data,out_mask,out_pixel,out_frame_last,unused_pctx,unused_psess,unused_pb,pe,pcode,pd);
 assign out_descriptor=descriptor;assign out_session=session;
 wire barriers=(retired[0]||dd)&&(retired[1]||td);
 always @(posedge clk)begin
  if(rst)begin active<=0;ctx_error<=0;mode_error<=0;retire_error<=0;retired<=0;descriptor<=0;session<=0;done<=0;end
  else begin
   done<=0;
   if(start_valid&&!active&&!mode_ok)mode_error<=1;
   if(go)begin active<=1;retired<=0;descriptor<=start_descriptor;session<=start_session;end
   if(it&&!context_ok)ctx_error<=1;
   if(dd)retired[0]<=1;if(td)retired[1]<=1;
   if(active&&pd)begin
    if(!barriers)retire_error<=1;
    if(barriers&&!error)begin active<=0;done<=1;end
   end
  end
 end
endmodule
