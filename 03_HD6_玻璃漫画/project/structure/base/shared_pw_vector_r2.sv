// Runtime CI/CO=2/4/8. CO2 packs 4 pixels, CO4 2, CO8 1 per 64-bit vector.
// Eight physical dual MACs, eight exact residual requants; no scalar serializer.
// Full descriptor/session are retained once and compared on every input beat.
// Coefficients remain locked through the actual final vector handshake.
// DDR owner/last-R/B and downstream frame publication remain caller obligations.
module shared_pw_vector_r2(
 input wire clk,rst,cfg_valid,output wire cfg_ready,input wire [1:0] cfg_kind,
 input wire [3:0] cfg_index,input wire [255:0] cfg_data,
 input wire start_valid,output wire start_ready,input wire [127:0] start_descriptor,
 input wire [63:0] start_session,input wire [3:0] start_ci,start_co,
 input wire [31:0] start_pixels,input wire start_residual,
 input wire in_valid,output wire in_ready,input wire [63:0] in_data,
 input wire [127:0] in_descriptor,input wire [63:0] in_session,input wire [31:0] in_pixel,
 input wire in_first,in_last,in_frame_last,input wire [63:0] in_identity,
 output wire out_valid,input wire out_ready,output wire [63:0] out_data,
 output wire [7:0] out_mask,output wire [31:0] out_pixel,output wire out_frame_last,
 output wire [127:0] out_descriptor,output wire [63:0] out_session,
 output wire busy,error,output reg [3:0] error_code,output reg done
);
 reg active,input_done;reg [127:0] descriptor;reg [63:0] session;
 reg [3:0] ci,co;reg [31:0] pixels,input_pixel,output_pixel;reg residual;
 reg [1:0] pair_index;reg [63:0] pixel_identity;
 reg [127:0] weights[0:3];reg [255:0] biases;reg [191:0] quant;
 reg [3:0] loaded_w;reg [7:0] loaded_q;
 function [7:0] cmask(input [3:0] n);begin case(n)2:cmask=8'h03;4:cmask=8'h0f;8:cmask=8'hff;default:cmask=0;endcase end endfunction
 function [3:0] wmask(input [3:0] n);begin case(n)2:wmask=4'h1;4:wmask=4'h3;8:wmask=4'hf;default:wmask=0;endcase end endfunction
 function [7:0] word_mask(input [3:0] channels,input [2:0] count);begin
  if(channels==2)case(count)1:word_mask=8'h03;2:word_mask=8'h0f;3:word_mask=8'h3f;default:word_mask=8'hff;endcase
  else if(channels==4)word_mask=count==1?8'h0f:8'hff;
  else word_mask=8'hff;
 end endfunction
 wire mode_ok=cmask(start_ci)!=0&&cmask(start_co)!=0&&start_pixels!=0&&(!start_residual||(start_ci==8&&start_co==8));
 wire loaded=(loaded_w&wmask(start_ci))==wmask(start_ci)&&(loaded_q&cmask(start_co))==cmask(start_co);
 assign error=|error_code;assign busy=active;
 assign start_ready=!rst&&!active&&!error&&mode_ok&&loaded;wire go=start_valid&&start_ready;
 assign cfg_ready=!rst&&!active&&!error&&!start_valid;wire cfg_take=cfg_valid&&cfg_ready;
 assign out_descriptor=descriptor;assign out_session=session;
 wire [2:0] ppv=co==2?3'd4:co==4?3'd2:3'd1;
 wire [31:0] in_remain=pixels-input_pixel,out_remain=pixels-output_pixel;
 wire [2:0] in_count=in_remain>=ppv?ppv:in_remain[2:0];
 wire [2:0] out_count=out_remain>=ppv?ppv:out_remain[2:0];
 wire [7:0] input_mask=word_mask(co,in_count);
 wire expected_last_pair=pair_index==(ci/2-1);
 wire expected_frame_last=expected_last_pair&&in_remain<=ppv;
 wire context_ok=in_descriptor==descriptor&&in_session==session;
 wire protocol_ok=in_pixel==input_pixel&&in_first==(pair_index==0)&&in_last==expected_last_pair&&in_frame_last==expected_frame_last;
 wire identity_ok=(residual||in_identity==0)&&(pair_index==0||in_identity==pixel_identity);
 wire good=context_ok&&protocol_ok&&identity_ok;
 wire mr,mv;wire [255:0] sums;wire [7:0] overflow;wire [104:0] mt;
 wire [7:0] qr,qv;wire [7:0] qdata[0:7];wire [40:0] qt;
 wire qout_ready=out_ready&&(&qv);
 wire [127:0] lane_pairs,lane_weights;wire [255:0] lane_biases;wire [191:0] lane_quant;
 genvar g;
 generate for(g=0;g<8;g=g+1)begin:map_lane
  assign lane_pairs[g*16+:16]=co==2?in_data[(g/2)*16+:16]:co==4?in_data[(g/4)*16+:16]:in_data[15:0];
  assign lane_weights[g*16+:16]=co==2?weights[pair_index][(g%2)*16+:16]:co==4?weights[pair_index][(g%4)*16+:16]:weights[pair_index][g*16+:16];
  assign lane_biases[g*32+:32]=co==2?biases[(g%2)*32+:32]:co==4?biases[(g%4)*32+:32]:biases[g*32+:32];
  assign lane_quant[g*24+:24]=co==2?quant[(g%2)*24+:24]:co==4?quant[(g%4)*24+:24]:quant[g*24+:24];
 end endgenerate
 assign in_ready=!rst&&active&&!input_done&&!error&&mr;wire take_in=in_valid&&in_ready;
 wire math_ok=(overflow&mt[39:32])==0;
 packed_pw_mac8 dot(clk,rst,take_in&&good,mr,lane_pairs,lane_weights,lane_biases,in_first,in_last,{in_frame_last,in_identity,input_mask,in_pixel},mv,&qr,sums,overflow,mt);
 generate for(g=0;g<8;g=g+1)begin:requant_lane
  if(g==0)begin
   requant_residual_m17 #(.TAG_W(41)) rq(clk,rst,mv&&math_ok,qr[g],sums[g*32+:32],lane_quant[g*24+:17],lane_quant[g*24+17+:6],lane_quant[g*24+23],residual?mt[40+g*8+:8]:8'd0,{mt[104],mt[39:0]},qv[g],qout_ready,qdata[g],qt);
  end else begin
   wire unused_tag;
   requant_residual_m17 #(.TAG_W(1)) rq(clk,rst,mv&&math_ok,qr[g],sums[g*32+:32],lane_quant[g*24+:17],lane_quant[g*24+17+:6],lane_quant[g*24+23],residual?mt[40+g*8+:8]:8'd0,1'b0,qv[g],qout_ready,qdata[g],unused_tag);
  end
  assign out_data[g*8+:8]=out_mask[g]?qdata[g]:8'd0;
 end endgenerate
 assign out_valid=!rst&&(&qv);assign out_pixel=qt[31:0];assign out_mask=qt[39:32];assign out_frame_last=qt[40];
 always @(posedge clk)begin
  if(rst)begin
   active<=0;input_done<=0;descriptor<=0;session<=0;ci<=0;co<=0;pixels<=0;residual<=0;
   input_pixel<=0;output_pixel<=0;pair_index<=0;pixel_identity<=0;loaded_w<=0;loaded_q<=0;error_code<=0;done<=0;
  end else begin
   done<=0;
   if(cfg_take)case(cfg_kind)
    0:if(cfg_index<4)begin weights[cfg_index]<=cfg_data[127:0];loaded_w[cfg_index]<=1;end else error_code[0]<=1;
    1:if(cfg_index<8)begin biases[cfg_index*32+:32]<=cfg_data[31:0];quant[cfg_index*24+:24]<=cfg_data[55:32];loaded_q[cfg_index]<=1;end else error_code[0]<=1;
    3:if(cfg_index==0)begin loaded_w<=0;loaded_q<=0;end else error_code[0]<=1;
    default:error_code[0]<=1;
   endcase
   if(start_valid&&!active&&!mode_ok)error_code[1]<=1;
   if(go)begin active<=1;input_done<=0;descriptor<=start_descriptor;session<=start_session;ci<=start_ci;co<=start_co;pixels<=start_pixels;residual<=start_residual;input_pixel<=0;output_pixel<=0;pair_index<=0;end
   if(take_in)begin
    if(!context_ok)error_code[2]<=1;
    if(!protocol_ok||!identity_ok)error_code[1]<=1;
    if(good)begin
     if(pair_index==0)pixel_identity<=in_identity;
     if(expected_last_pair)begin pair_index<=0;input_pixel<=input_pixel+in_count;if(expected_frame_last)input_done<=1;end
     else pair_index<=pair_index+1'b1;
    end
   end
   if(mv&&(&qr)&&!math_ok)error_code[3]<=1;
   if(out_valid&&out_ready)begin
    if(out_pixel!=output_pixel||out_mask!=word_mask(co,out_count)||out_frame_last!=(out_remain<=ppv))error_code[1]<=1;
    output_pixel<=output_pixel+out_count;
    if(out_frame_last)begin
     if(!input_done||input_pixel!=pixels)error_code[1]<=1;
     if(!error&&input_done&&input_pixel==pixels&&out_pixel==output_pixel&&out_mask==word_mask(co,out_count)&&out_remain<=ppv)begin active<=0;done<=1;end
    end
   end
  end
 end
endmodule
