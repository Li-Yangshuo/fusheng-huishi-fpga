// One owned 64bit register, ordered 8bit S8 or 32bit native RGBx items.
module word64_to_items #(
 parameter WIDTH=1280,HEIGHT=720,ITEM_BITS=8,CHANNELS=2,
 parameter XW=$clog2(WIDTH+1),YW=$clog2(HEIGHT+1),LANES=64/ITEM_BITS,
 parameter LW=(LANES<2)?1:$clog2(LANES),ROW_WORDS=WIDTH*CHANNELS/LANES,
 parameter TOTAL=WIDTH*HEIGHT*CHANNELS
)(
 input wire clk,rst,start_valid,output wire start_ready,input wire [127:0] start_descriptor,input wire [63:0] start_session,
 input wire in_valid,output wire in_ready,input wire [63:0] in_data,input wire [7:0] in_mask,
 input wire [11:0] in_row,input wire [9:0] in_word,input wire in_eol,in_last,
 input wire [127:0] in_descriptor,input wire [63:0] in_session,
 output wire out_valid,input wire out_ready,output wire [ITEM_BITS-1:0] out_data,
 output wire [XW-1:0] out_x,output wire [YW-1:0] out_y,output wire out_channel,out_eol,out_last,
 output wire [127:0] out_descriptor,output wire [63:0] out_session,
 output wire busy,error,output reg [2:0] error_code,output reg done
);
 reg active,valid,input_end;reg [63:0] data;reg [127:0] descriptor;reg [63:0] session;
 reg [LW-1:0] lane;reg [31:0] words,items;reg [11:0] ir;reg [9:0] iw;
 reg [XW-1:0] x;reg [YW-1:0] y;reg ch;
 assign busy=active;assign error=|error_code;
 assign start_ready=!rst&&!active&&!valid&&!error;
 wire go=start_valid&&start_ready;
 assign out_valid=!rst&&valid;assign out_data=data[lane*ITEM_BITS+:ITEM_BITS];
 assign out_x=x;assign out_y=y;assign out_channel=ch;assign out_eol=x==WIDTH-1&&(CHANNELS==1||ch);
 assign out_last=items==TOTAL-1;assign out_descriptor=descriptor;assign out_session=session;
 wire ot=out_valid&&out_ready;
 assign in_ready=!rst&&active&&!error&&!input_end&&(!valid||(ot&&lane==LANES-1));
 wire it=in_valid&&in_ready;
 wire context_ok=in_descriptor==descriptor&&in_session==session;
 wire marks=in_mask==8'hff&&in_row==ir&&in_word==iw&&in_eol==(iw==ROW_WORDS-1)&&in_last==(words==TOTAL/LANES-1);
 wire bad=it&&(!context_ok||!marks);
 always @(posedge clk)begin
  if(rst)begin active<=0;valid<=0;input_end<=0;data<=0;descriptor<=0;session<=0;lane<=0;words<=0;items<=0;ir<=0;iw<=0;x<=0;y<=0;ch<=0;error_code<=0;done<=0;end
  else begin
   done<=0;
   if(go)begin active<=1;input_end<=0;descriptor<=start_descriptor;session<=start_session;lane<=0;words<=0;items<=0;ir<=0;iw<=0;x<=0;y<=0;ch<=0;end
   if(ot)begin
    items<=items+1'b1;
    if(CHANNELS==1||ch)begin ch<=0;if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;end else ch<=1;
    if(lane==LANES-1)begin lane<=0;valid<=0;end else lane<=lane+1'b1;
    if(out_last)begin
     if(!input_end||words!=TOTAL/LANES)error_code[2]<=1;
     if(!error&&!bad&&input_end&&words==TOTAL/LANES)begin active<=0;done<=1;end
    end
   end
   if(it)begin
    if(!context_ok)error_code[0]<=1;if(!marks)error_code[1]<=1;
    if(!bad)begin
     data<=in_data;valid<=1;lane<=0;words<=words+1'b1;
     if(iw==ROW_WORDS-1)begin iw<=0;ir<=ir+1'b1;end else iw<=iw+1'b1;
     if(in_last)input_end<=1;
    end
   end
  end
 end
 // synthesis translate_off
 initial if((ITEM_BITS!=8&&ITEM_BITS!=32)||(CHANNELS!=1&&CHANNELS!=2)||WIDTH*CHANNELS%LANES!=0)$fatal(1,"64bit item geometry");
 // synthesis translate_on
endmodule
