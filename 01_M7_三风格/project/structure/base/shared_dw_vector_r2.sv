// Four DW scalar outputs per issue. CI2: two pixels; CI4: one pixel;
// CI8: channel halves 0..3 then 4..7. Runtime job-locked configuration.
// Windows are supplied by a separate reflected/strided/upsampling producer.
// Full descriptor/session and true final-vector retirement are retained.
module shared_dw_vector(
 input wire clk,rst,cfg_valid,output wire cfg_ready,input wire [1:0] cfg_kind,
 input wire [3:0] cfg_index,input wire [255:0] cfg_data,
 input wire start_valid,output wire start_ready,input wire [127:0] start_descriptor,
 input wire [63:0] start_session,input wire [3:0] start_channels,input wire [31:0] start_pixels,
 input wire in_valid,output wire in_ready,input wire [287:0] in_windows,
 input wire [127:0] in_descriptor,input wire [63:0] in_session,
 input wire [31:0] in_pixel,input wire [2:0] in_channel,input wire in_frame_last,
 output wire out_valid,input wire out_ready,output wire [31:0] out_data,out_identity,
 output wire [3:0] out_mask,output wire [31:0] out_pixel,output wire [2:0] out_channel,
 output wire out_frame_last,output wire [127:0] out_descriptor,output wire [63:0] out_session,
 output wire busy,error,output reg [3:0] error_code,output reg done
);
 reg active,input_done;reg [127:0] descriptor;reg [63:0] session;
 reg [3:0] channels;reg [31:0] pixels,input_pixel,output_pixel;reg [2:0] input_channel,output_channel;
 reg [143:0] weights[0:3];reg [255:0] biases;reg [191:0] quant;reg [3:0] loaded;
 function [3:0] need(input [3:0] c);begin case(c)2:need=1;4:need=3;8:need=15;default:need=0;endcase end endfunction
 wire mode_ok=need(start_channels)!=0&&start_pixels!=0;
 assign error=|error_code;assign busy=active;
 assign start_ready=!rst&&!active&&!error&&mode_ok&&(loaded&need(start_channels))==need(start_channels);
 wire go=start_valid&&start_ready;
 assign cfg_ready=!rst&&!active&&!error&&!start_valid;wire ct=cfg_valid&&cfg_ready;
 assign out_descriptor=descriptor;assign out_session=session;
 wire [1:0] ppv=channels==2?2:1;
 wire [31:0] in_remaining=pixels-input_pixel,out_remaining=pixels-output_pixel;
 wire [1:0] in_count=in_remaining>=ppv?ppv:in_remaining[1:0];
 wire [1:0] out_count=out_remaining>=ppv?ppv:out_remaining[1:0];
 wire [3:0] in_mask=(channels==2&&in_remaining==1)?4'h3:4'hf;
 wire in_final_half=channels!=8||input_channel==4;
 wire expected_last=in_final_half&&in_remaining<=ppv;
 wire context_ok=in_descriptor==descriptor&&in_session==session;
 wire protocol_ok=in_pixel==input_pixel&&in_channel==input_channel&&in_frame_last==expected_last;
 wire good=context_ok&&protocol_ok;
 wire [1:0] r,v;wire [3:0] qr,qv;wire [71:0] mt;
 wire signed [19:0] sum[0:3];wire [7:0] qdata[0:3];wire [71:0] qt;
 wire [31:0] centers;
 wire [1:0] wi0=channels==8?{input_channel[2],1'b0}:0;
 wire [1:0] wi1=channels==2?0:wi0+1'b1;
 assign in_ready=!rst&&active&&!input_done&&!error&&(&r);wire take=in_valid&&in_ready;
 dw9_pair_sum #(.TAG_W(72)) dot0(clk,rst,take&&good,r[0],in_windows[143:0],weights[wi0],{centers,in_frame_last,in_mask,in_channel,in_pixel},v[0],&qr,sum[0],sum[1],mt);
 wire unused_tag;
 dw9_pair_sum #(.TAG_W(1)) dot1(clk,rst,take&&good,r[1],in_windows[287:144],weights[wi1],1'b0,v[1],&qr,sum[2],sum[3],unused_tag);
 wire [3:0] overflow;wire math_ok=(overflow&mt[38:35])==0;
 wire qout_ready=out_ready&&(&qv);
 genvar g;
 generate for(g=0;g<4;g=g+1)begin:lane
  assign centers[g*8+:8]=in_windows[g*72+32+:8];
  wire [2:0] ch=channels==2?(g%2):channels==4?g:({mt[34],2'b0}+g);
  wire signed [31:0] bias=biases[ch*32+:32];wire [23:0] qp=quant[ch*24+:24];
  wire signed [32:0] total=$signed({{13{sum[g][19]}},sum[g]})+$signed({bias[31],bias});
  assign overflow[g]=total[32]!=total[31];
  if(g==0)begin
   requant_int8_m17 #(.TAG_W(72)) rq(clk,rst,(&v)&&math_ok,qr[g],total[31:0],qp[16:0],qp[22:17],qp[23],mt,qv[g],qout_ready,qdata[g],qt);
  end else begin
   wire unused_qtag;
   requant_int8_m17 #(.TAG_W(1)) rq(clk,rst,(&v)&&math_ok,qr[g],total[31:0],qp[16:0],qp[22:17],qp[23],1'b0,qv[g],qout_ready,qdata[g],unused_qtag);
  end
  assign out_data[g*8+:8]=out_mask[g]?qdata[g]:8'd0;
  assign out_identity[g*8+:8]=out_mask[g]?qt[40+g*8+:8]:8'd0;
 end endgenerate
 assign out_valid=!rst&&(&qv);assign out_pixel=qt[31:0];assign out_channel=qt[34:32];assign out_mask=qt[38:35];assign out_frame_last=qt[39];
 always @(posedge clk)begin
  if(rst)begin
   active<=0;input_done<=0;descriptor<=0;session<=0;channels<=0;pixels<=0;input_pixel<=0;output_pixel<=0;input_channel<=0;output_channel<=0;loaded<=0;error_code<=0;done<=0;
  end else begin
   done<=0;
   if(ct)begin
    if(cfg_kind==3&&cfg_index==0)loaded<=0;
    else if(cfg_kind==0&&cfg_index<4)loaded[cfg_index]<=1;
    else error_code[0]<=1;
   end
   if(start_valid&&!active&&!mode_ok)error_code[1]<=1;
   if(go)begin
    active<=1;input_done<=0;descriptor<=start_descriptor;session<=start_session;channels<=start_channels;pixels<=start_pixels;
    input_pixel<=0;output_pixel<=0;input_channel<=0;output_channel<=0;
   end
   if(take)begin
    if(!context_ok)error_code[2]<=1;if(!protocol_ok)error_code[1]<=1;
    if(good)begin
     if(in_final_half)begin input_channel<=0;input_pixel<=input_pixel+in_count;end else input_channel<=4;
     if(expected_last)input_done<=1;
    end
   end
   if(v[0]!=v[1])error_code[1]<=1;
   if((&v)&&(&qr)&&!math_ok)error_code[3]<=1;
   if(out_valid&&out_ready)begin
    if(out_pixel!=output_pixel||out_channel!=output_channel||out_mask!=((channels==2&&out_remaining==1)?4'h3:4'hf)||out_frame_last!=((channels!=8||output_channel==4)&&out_remaining<=ppv))error_code[1]<=1;
    if(channels!=8||output_channel==4)begin output_channel<=0;output_pixel<=output_pixel+out_count;end else output_channel<=4;
    if(out_frame_last)begin
     if(!input_done||input_pixel!=pixels)error_code[1]<=1;
     if(!error&&input_done&&input_pixel==pixels&&out_pixel==output_pixel&&out_channel==output_channel&&out_mask==((channels==2&&out_remaining==1)?4'h3:4'hf)&&(channels!=8||output_channel==4)&&out_remaining<=ppv)begin active<=0;done<=1;end
    end
   end
  end
 end
 genvar k;
 generate for(k=0;k<4;k=k+1)begin:cfg_bank
  always @(posedge clk)if(!rst&&ct&&cfg_kind==0&&cfg_index==k)begin
   weights[k]<=cfg_data[143:0];biases[k*64+:64]<=cfg_data[207:144];quant[k*48+:48]<=cfg_data[255:208];
  end
 end endgenerate
endmodule
