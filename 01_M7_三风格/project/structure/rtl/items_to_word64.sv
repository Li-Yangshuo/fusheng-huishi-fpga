module items_to_word64 #(
 parameter WIDTH=1280,HEIGHT=720,ITEM_BITS=8,CHANNELS=2,
 parameter XW=$clog2(WIDTH+1),YW=$clog2(HEIGHT+1),LANES=64/ITEM_BITS,
 parameter LW=(LANES<2)?1:$clog2(LANES),TOTAL=WIDTH*HEIGHT*CHANNELS
)(
 input wire clk,rst,start_valid,output wire start_ready,input wire [127:0] start_descriptor,input wire [63:0] start_session,
 input wire in_valid,output wire in_ready,input wire [ITEM_BITS-1:0] in_data,
 input wire [XW-1:0] in_x,input wire [YW-1:0] in_y,input wire in_channel,in_eol,in_last,
 input wire [127:0] in_descriptor,input wire [63:0] in_session,
 output wire out_valid,input wire out_ready,output wire [63:0] out_data,output wire [7:0] out_mask,
 output wire [31:0] out_pixel,output wire out_last,output wire [127:0] out_descriptor,output wire [63:0] out_session,
 output wire busy,error,output reg [2:0] error_code,output reg done
);
 reg active,valid,input_end,last;reg [63:0] data;reg [127:0] descriptor;reg [63:0] session;
 reg [LW-1:0] lane;reg [31:0] items,word_pixel;
 reg [XW-1:0] x;reg [YW-1:0] y;reg ch;
 assign busy=active;assign error=|error_code;
 assign start_ready=!rst&&!active&&!valid&&!error;
 wire go=start_valid&&start_ready;
 assign in_ready=!rst&&active&&!input_end&&!error&&(!valid||out_ready);
 wire it=in_valid&&in_ready;
 wire context_ok=in_descriptor==descriptor&&in_session==session;
 wire marks=in_x==x&&in_y==y&&in_channel==ch&&in_eol==(x==WIDTH-1&&(CHANNELS==1||ch))&&in_last==(items==TOTAL-1);
 wire bad=it&&(!context_ok||!marks);
 assign out_valid=!rst&&valid;assign out_data=data;assign out_mask=8'hff;assign out_pixel=word_pixel;assign out_last=last;
 assign out_descriptor=descriptor;assign out_session=session;
 always @(posedge clk)begin
  if(rst)begin active<=0;valid<=0;input_end<=0;last<=0;data<=0;descriptor<=0;session<=0;lane<=0;items<=0;word_pixel<=0;x<=0;y<=0;ch<=0;error_code<=0;done<=0;end
  else begin
   done<=0;
   if(go)begin active<=1;input_end<=0;descriptor<=start_descriptor;session<=start_session;lane<=0;items<=0;x<=0;y<=0;ch<=0;end
   if(out_valid&&out_ready)begin
    valid<=0;
    if(out_last)begin
     if(!input_end||items!=TOTAL)error_code[2]<=1;
     if(!error&&!bad&&input_end&&items==TOTAL)begin active<=0;done<=1;end
    end
   end
   if(it)begin
    if(!context_ok)error_code[0]<=1;if(!marks)error_code[1]<=1;
    if(!bad)begin
     data[lane*ITEM_BITS+:ITEM_BITS]<=in_data;items<=items+1'b1;
     if(CHANNELS==1||ch)begin ch<=0;if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;end else ch<=1;
     if(lane==LANES-1)begin
      lane<=0;valid<=1;last<=in_last;
      word_pixel<=(CHANNELS==2)?((items+1-LANES)>>1):(items+1-LANES);
     end else lane<=lane+1'b1;
     if(in_last)input_end<=1;
    end
   end
  end
 end
 // synthesis translate_off
 initial if((ITEM_BITS!=8&&ITEM_BITS!=32)||(CHANNELS!=1&&CHANNELS!=2)||WIDTH*CHANNELS%LANES!=0)$fatal(1,"64bit pack geometry");
 // synthesis translate_on
endmodule
