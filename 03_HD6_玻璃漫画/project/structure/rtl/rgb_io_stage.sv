// Shared ABI2 64bit raster boundary for the dense RGB stem and LUT RGB head.
module rgb_io_stage #(
 parameter WIDTH=1280,HEIGHT=720,HEAD=0,XW=$clog2(WIDTH+1),YW=$clog2(HEIGHT+1),
 parameter IB=HEAD?8:32,IC=HEAD?2:1,OB=HEAD?32:8,OC=HEAD?1:2
)(
 input wire clk,rst,cfg_valid,output wire cfg_ready,input wire [1:0] cfg_kind,
 input wire [9:0] cfg_index,input wire [255:0] cfg_data,input wire [31:0] cfg_model,
 input wire start_valid,output wire start_ready,input wire [127:0] start_descriptor,input wire [63:0] start_session,
 input wire in_valid,output wire in_ready,input wire [63:0] in_data,input wire [7:0] in_mask,
 input wire [11:0] in_row,input wire [9:0] in_word,input wire in_eol,in_last,
 input wire [127:0] in_descriptor,input wire [63:0] in_session,
 output wire out_valid,input wire out_ready,output wire [63:0] out_data,output wire [7:0] out_mask,
 output wire [31:0] out_pixel,output wire out_last,output wire [127:0] out_descriptor,output wire [63:0] out_session,
 output wire busy,error,output wire [13:0] error_code,output reg done
);
 reg active,padding_error,completion_error;reg [2:0] retired;
 reg [127:0] descriptor;reg [63:0] session;
 wire ss,cs,ps,cc,sd,cd,pd,cok,se,pe;wire [2:0] scode,pcode;wire [5:0] ccode;
 assign error_code={padding_error,completion_error,scode,pcode,ccode};assign error=|error_code;assign busy=active;
 assign start_ready=!rst&&!active&&!error&&ss&&cs&&ps;
 wire go=start_valid&&start_ready;
 assign cfg_ready=!rst&&!active&&!error&&!start_valid&&cc;
 wire cv=cfg_valid&&cfg_ready;
 wire iv,ir,ie,il,ich;wire [IB-1:0] idata;wire [XW-1:0] ix;wire [YW-1:0] iy;
 wire [127:0] idesc;wire [63:0] isession;wire unused_ib;
 word64_to_items #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.ITEM_BITS(IB),.CHANNELS(IC)) unpack(
  clk,rst,go,ss,start_descriptor,start_session,in_valid,in_ready,in_data,in_mask,in_row,in_word,in_eol,in_last,in_descriptor,in_session,
  iv,ir,idata,ix,iy,ich,ie,il,idesc,isession,unused_ib,se,scode,sd);
 wire ov,orr,oe,ol,och;wire [OB-1:0] odata;wire [XW-1:0] ox;wire [YW-1:0] oy;
 wire [127:0] odesc;
 generate if(HEAD)begin:head_path
  wire [31:0] ht,hf,hm;wire unused_cb;
  rgb_head #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) head(clk,rst,cv,cc,cfg_kind,cfg_index,cfg_data[63:0],cfg_model,
   go,cs,start_descriptor[127:96],start_descriptor[95:64],start_descriptor[63:32],
   iv,ir,idata,ix,iy,ich,idesc[127:96],idesc[95:64],idesc[63:32],ie,il,
   ov,orr,odata,ox,oy,ht,hf,hm,oe,ol,unused_cb,error_head,ccode,cd,cok);
  wire error_head;
  assign och=0;assign odesc={ht,hf,hm,descriptor[31:0]};
 end else begin:stem_path
  wire isr,gv,gr,ge,gd,gerr;wire [3:0] gcode;wire [39:0] gdword;wire unused_gb;
  tagged_rgb40_ingress #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) ingress(clk,rst,1'b0,go,isr,start_descriptor[127:32],
   iv,ir,{8'd0,idata[31:8]},ix,iy,idesc[127:96],idesc[95:64],idesc[63:32],ie,il,
   gv,gr,gdword,ge,unused_gb,gerr,gcode,gd);
  wire sr,sdense,sok;wire [2:0] dense_code;wire [31:0] oframe;
  reg dense_seen,ingress_seen;
  rgb_stem_stage #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) stem(clk,rst,cv,cc,cfg_kind,cfg_index[3:0],cfg_data,
   go,sr,start_descriptor[95:64],gv,gr,gdword,ge,ov,orr,odata,ox,oy,och,oframe,oe,ol,sdense,sok,dense_code);
  assign cs=sr&&isr;
  assign ccode={1'b0,(|gcode),1'b0,dense_code};
  assign cd=(dense_seen||sdense)&&(ingress_seen||gd)&&active;
  assign cok=ccode==0;
  assign odesc={descriptor[127:96],oframe,descriptor[63:0]};
  always @(posedge clk)begin
   if(rst||go)begin dense_seen<=0;ingress_seen<=0;end
   else begin if(sdense)dense_seen<=1;if(gd)ingress_seen<=1;end
  end
 end endgenerate
 wire unused_pb;
 items_to_word64 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.ITEM_BITS(OB),.CHANNELS(OC)) pack(
  clk,rst,go,ps,start_descriptor,start_session,ov,orr,odata,ox,oy,och,oe,ol,odesc,session,
  out_valid,out_ready,out_data,out_mask,out_pixel,out_last,out_descriptor,out_session,unused_pb,pe,pcode,pd);
 always @(posedge clk)begin
  if(rst)begin active<=0;retired<=0;descriptor<=0;session<=0;padding_error<=0;completion_error<=0;done<=0;end
  else begin
   done<=0;
   if(go)begin active<=1;retired<=0;descriptor<=start_descriptor;session<=start_session;end
   if(!HEAD&&iv&&ir&&idata[7:0]!=0)padding_error<=1;
   if(sd)retired[0]<=1;
   if(cd)begin retired[1]<=1;if(!cok)completion_error<=1;end
   if(pd)retired[2]<=1;
   if(active&&(&(retired|{pd,cd,sd}))&&!error&&!(cd&&!cok))begin active<=0;done<=1;end
  end
 end
endmodule
