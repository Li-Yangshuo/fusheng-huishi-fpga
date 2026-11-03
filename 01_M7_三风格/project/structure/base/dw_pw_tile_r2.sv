// Two 32-byte banks transpose DW channel-major 4-scalar words into packed
// spatial PW input pairs. No image-sized feature store. CO2/4/8 -> 4/2/1 pixels.
// Runtime CI2->CO8 is rejected: a two-pixel DW word would straddle two tiles.
module dw_pw_tile(
 input wire clk,rst,start_valid,output wire start_ready,
 input wire [127:0] start_descriptor,input wire [63:0] start_session,
 input wire [3:0] start_ci,start_co,input wire [31:0] start_pixels,input wire start_residual,
 input wire in_valid,output wire in_ready,input wire [31:0] in_data,in_identity,
 input wire [3:0] in_mask,input wire [31:0] in_pixel,input wire [2:0] in_channel,
 input wire in_frame_last,input wire [127:0] in_descriptor,input wire [63:0] in_session,
 output wire out_valid,input wire out_ready,output wire [63:0] out_data,out_identity,
 output wire [31:0] out_pixel,output wire out_first,out_last,out_frame_last,
 output wire [127:0] out_descriptor,output wire [63:0] out_session,
 output wire busy,error,output reg [2:0] error_code,output reg done,output reg [1:0] bank_high_water
);
 reg active,input_done;reg [3:0] ci,co;reg residual;reg [31:0] pixels,input_pixel,write_base;
 reg [2:0] input_channel,fill_pixel;reg [127:0] descriptor;reg [63:0] session;
 reg [1:0] full;reg wb,rb;reg [1:0] read_pair;
 reg [31:0] bank_base[0:1];reg [2:0] bank_count[0:1];reg bank_final[0:1];reg [63:0] bank_identity[0:1];
 wire mode_ok=(start_ci==2||start_ci==4||start_ci==8)&&(start_co==2||start_co==4||start_co==8)&&start_pixels!=0&&!(start_ci==2&&start_co==8)&&(!start_residual||(start_ci==8&&start_co==8));
 assign error=|error_code;assign busy=active;
 assign start_ready=!rst&&!active&&!error&&full==0&&mode_ok;
 wire go=start_valid&&start_ready;
 assign out_descriptor=descriptor;assign out_session=session;
 wire [2:0] ppv=co==2?4:co==4?2:1;
 wire [31:0] remain_group=pixels-write_base,remain_input=pixels-input_pixel;
 wire [2:0] group_count=remain_group>=ppv?ppv:remain_group[2:0];
 wire [1:0] consume_count=ci==2?(remain_input==1?1:2):1;
 wire input_pixel_end=ci!=8||input_channel==4;
 wire expected_last=input_pixel_end&&remain_input<=consume_count;
 wire [3:0] expected_mask=(ci==2&&remain_input==1)?4'h3:4'hf;
 wire context_ok=in_descriptor==descriptor&&in_session==session;
 wire position_ok=in_pixel==input_pixel&&in_channel==input_channel&&in_mask==expected_mask&&in_frame_last==expected_last;
 wire good=context_ok&&position_ok;
 assign out_valid=!rst&&active&&full[rb];
 assign out_pixel=bank_base[rb];assign out_first=read_pair==0;assign out_last=read_pair==ci/2-1;
 assign out_frame_last=bank_final[rb]&&out_last;assign out_identity=residual?bank_identity[rb]:64'd0;
 wire ot=out_valid&&out_ready;
 wire free_now=ot&&out_last&&rb==wb;
 assign in_ready=!rst&&active&&!input_done&&!error&&(!full[wb]||free_now);
 wire it=in_valid&&in_ready;
 wire group_complete=input_pixel_end&&(fill_pixel+consume_count==group_count);
 wire [63:0] row_read[0:3];wire [63:0] selected=row_read[read_pair];
 genvar p;
 generate for(p=0;p<4;p=p+1)begin:row
  reg [63:0] bank0,bank1;
  assign row_read[p]=rb?bank1:bank0;
  always @(posedge clk)if(!rst&&it&&good)begin
   if(ci==2&&p==0)begin
    if(wb)bank1[fill_pixel*16+:32]<=in_data;else bank0[fill_pixel*16+:32]<=in_data;
   end else if(ci==4&&p<2)begin
    if(wb)bank1[fill_pixel*16+:16]<=in_data[(p%2)*16+:16];else bank0[fill_pixel*16+:16]<=in_data[(p%2)*16+:16];
   end else if(ci==8&&((in_channel==0&&p<2)||(in_channel==4&&p>=2)))begin
    if(wb)bank1[fill_pixel*16+:16]<=in_data[(p%2)*16+:16];else bank0[fill_pixel*16+:16]<=in_data[(p%2)*16+:16];
   end
  end
  assign out_data[p*16+:16]=p<bank_count[rb]?selected[p*16+:16]:16'd0;
 end endgenerate
 wire [1:0] occupied={1'b0,full[0]}+{1'b0,full[1]};
 always @(posedge clk)begin
  if(rst)begin
   active<=0;input_done<=0;ci<=0;co<=0;residual<=0;pixels<=0;input_pixel<=0;write_base<=0;input_channel<=0;fill_pixel<=0;
   descriptor<=0;session<=0;full<=0;wb<=0;rb<=0;read_pair<=0;error_code<=0;done<=0;bank_high_water<=0;
   bank_base[0]<=0;bank_base[1]<=0;bank_count[0]<=0;bank_count[1]<=0;bank_final[0]<=0;bank_final[1]<=0;
  end else begin
   done<=0;
   if(occupied>bank_high_water)bank_high_water<=occupied;
   if(start_valid&&!active&&!mode_ok)error_code[0]<=1;
   if(go)begin active<=1;input_done<=0;ci<=start_ci;co<=start_co;residual<=start_residual;pixels<=start_pixels;input_pixel<=0;write_base<=0;input_channel<=0;fill_pixel<=0;descriptor<=start_descriptor;session<=start_session;wb<=0;rb<=0;read_pair<=0;full<=0;bank_high_water<=0;end
   if(ot)begin
    if(out_last)begin
     full[rb]<=0;rb<=~rb;read_pair<=0;
     if(bank_final[rb])begin
      if(!input_done||input_pixel!=pixels||full[!rb])error_code[2]<=1;
      if(!error&&input_done&&input_pixel==pixels&&!full[!rb])begin active<=0;done<=1;end
     end
    end else read_pair<=read_pair+1'b1;
   end
   if(it)begin
    if(!context_ok)error_code[1]<=1;
    if(!position_ok)error_code[2]<=1;
    if(good)begin
     if(residual)begin
      if(in_channel==0)bank_identity[wb][31:0]<=in_identity;
      else bank_identity[wb][63:32]<=in_identity;
     end
     if(input_pixel_end)begin
      input_channel<=0;input_pixel<=input_pixel+consume_count;
      if(group_complete)begin
       full[wb]<=1;bank_base[wb]<=write_base;bank_count[wb]<=group_count;bank_final[wb]<=write_base+group_count==pixels;
       wb<=~wb;write_base<=write_base+group_count;fill_pixel<=0;
      end else fill_pixel<=fill_pixel+consume_count;
     end else input_channel<=4;
     if(expected_last)input_done<=1;
    end
   end
  end
 end
endmodule
