// Runtime CI2/4/8 reflected 3x3 window producer, four rotating source rows.
// Source raster is 64bit HWC, each row independently zero-padded to 8 bytes.
// Never materializes nearest2x expanded rows. RAM is not reset or copied.
module shared_window_stream #(
 parameter MAX_ROW_BYTES=2560, parameter WORDS=(MAX_ROW_BYTES+7)/8,
 parameter AW=(WORDS<2)?1:$clog2(WORDS), parameter DEPTH=(1<<AW)
)(
 input wire clk,rst,
 input wire start_valid,output wire start_ready,input wire [127:0] start_descriptor,
 input wire [63:0] start_session,input wire [11:0] start_width,start_height,
 input wire [3:0] start_ci,input wire start_stride2,start_up2,
 input wire in_valid,output wire in_ready,input wire [63:0] in_data,
 input wire [7:0] in_mask,input wire [11:0] in_row,input wire [AW-1:0] in_word,
 input wire in_eol,in_frame_last,input wire [127:0] in_descriptor,input wire [63:0] in_session,
 output reg out_valid,input wire out_ready,output reg [287:0] out_windows,
 output reg [31:0] out_pixel,output reg [2:0] out_channel,output reg out_frame_last,
 output wire [127:0] out_descriptor,output wire [63:0] out_session,
 output wire busy,error,output reg [3:0] error_code,output reg done
);
 reg active,input_done,generated_last;
 reg [127:0] descriptor;reg [63:0] session;
 reg [11:0] width,height,ow,oh,ox,oy,write_row;
 reg [3:0] ci;reg stride2,up2,half;
 reg [AW-1:0] write_word;reg [AW:0] row_words;
 reg [14:0] row_bytes;reg [31:0] pixel,pixels;
 reg [3:0] row_valid;reg [11:0] row_number[0:3];
 reg [AW:0] cache_base;reg [1:0] cache_count;reg pending;
 reg [63:0] cache0[0:3],cache1[0:3],cache2[0:3];
 reg [143:0] pair_first;reg pair_pending;
 wire ci_ok=start_ci==2||start_ci==4||start_ci==8;
 wire [14:0] start_bytes=({3'd0,start_width}<<((start_ci==2)?1:(start_ci==4)?2:3));
 wire mode_ok=ci_ok&&start_width!=0&&start_height!=0&&start_bytes<=MAX_ROW_BYTES&&
              (!start_up2||(start_width<=2047&&start_height<=2047))&&!(start_stride2&&start_up2);
 wire [11:0] start_ow=start_up2?(start_width<<1):start_stride2?((start_width>>1)+start_width[0]):start_width;
 wire [11:0] start_oh=start_up2?(start_height<<1):start_stride2?((start_height>>1)+start_height[0]):start_height;
 assign busy=active;assign error=|error_code;
 assign start_ready=!rst&&!active&&!out_valid&&!error&&mode_ok;
 wire go=start_valid&&start_ready;
 assign out_descriptor=descriptor;assign out_session=session;
 // Only +/-1 reflect101 is needed. A singleton dimension maps to itself.
 function [12:0] reflected(input [12:0] center,input [1:0] tap,input [12:0] extent);
 begin
  if(extent==1)reflected=0;
  else if(tap==0)reflected=(center==0)?1:center-1'b1;
  else if(tap==2)reflected=(center==extent-1'b1)?extent-2'd2:center+1'b1;
  else reflected=center;
 end endfunction
 wire [12:0] ew=up2?({1'b0,width}<<1):{1'b0,width};
 wire [12:0] eh=up2?({1'b0,height}<<1):{1'b0,height};
 wire [12:0] cx=stride2?({1'b0,ox}<<1):{1'b0,ox};
 wire [12:0] cy=stride2?({1'b0,oy}<<1):{1'b0,oy};
 wire [12:0] sx[0:2],sy[0:2];
 genvar a;
 generate for(a=0;a<3;a=a+1)begin:coords
  assign sx[a]=reflected(cx,a,ew)>>(up2?1:0);
  assign sy[a]=reflected(cy,a,eh)>>(up2?1:0);
 end endgenerate
 wire [12:0] min_x=(sx[0]<sx[1])?((sx[0]<sx[2])?sx[0]:sx[2]):((sx[1]<sx[2])?sx[1]:sx[2]);
 wire [12:0] max_x=(sx[0]>sx[1])?((sx[0]>sx[2])?sx[0]:sx[2]):((sx[1]>sx[2])?sx[1]:sx[2]);
 wire [12:0] min_y=(sy[0]<sy[1])?((sy[0]<sy[2])?sy[0]:sy[2]):((sy[1]<sy[2])?sy[1]:sy[2]);
 wire [14:0] lo_byte={2'd0,min_x}<<((ci==2)?1:(ci==4)?2:3);
 wire [14:0] hi_byte=({2'd0,max_x}<<((ci==2)?1:(ci==4)?2:3))+ci-1'b1;
 wire [AW:0] lo_word=lo_byte>>3,hi_word=hi_byte>>3;
 wire rows_ready=row_valid[sy[0][1:0]]&&row_number[sy[0][1:0]]==sy[0]&&
                 row_valid[sy[1][1:0]]&&row_number[sy[1][1:0]]==sy[1]&&
                 row_valid[sy[2][1:0]]&&row_number[sy[2][1:0]]==sy[2];
 wire cache_ready=cache_count!=0&&lo_word>=cache_base&&hi_word<cache_base+cache_count;
 wire can_emit=!out_valid||out_ready;
 wire produce=!rst&&active&&!generated_last&&!error&&rows_ready&&cache_ready&&can_emit;
 wire final_half=ci!=8||half;
 wire last_position=pixel==pixels-1'b1;
 wire row_advance=produce&&final_half&&ox==ow-1'b1;
 wire [AW:0] fetch_address=cache_base+cache_count;
 // Prefetch the next word before the last half consumes the oldest one.
 // The RAM read receipt may wait through arbitrary output backpressure.
 wire [12:0] next_left=(cx+(stride2?13'd2:13'd1)-1'b1)>>(up2?1:0);
 wire [14:0] next_lo_byte={2'd0,next_left}<<((ci==2)?1:(ci==4)?2:3);
 wire [AW:0] next_lo_word=next_lo_byte>>3;
 wire capture=pending&&(cache_count<3||lo_word>cache_base||
                       (produce&&final_half&&ox!=ow-1'b1&&next_lo_word>cache_base));
 wire fetch_issue=!rst&&active&&!generated_last&&!error&&rows_ready&&!pending&&!row_advance&&
                  (cache_count<3||lo_word>cache_base||next_lo_word>cache_base)&&fetch_address<row_words;
 // Physical banks are not cleared. Unused read ports are disabled; a write
 // only reuses a bank older than the earliest live output row.
 wire [1:0] wb=write_row[1:0];
 assign in_ready=!rst&&active&&!input_done&&!error&&(!row_valid[wb]||row_number[wb]<min_y);
 wire take=in_valid&&in_ready;
 wire [14:0] left_bytes=row_bytes-({{(15-AW){1'b0}},write_word}<<3);
 wire [7:0] expected_mask=left_bytes>=8?8'hff:(8'hff>>(8-left_bytes));
 wire expected_eol=write_word==row_words-1'b1;
 wire expected_last=expected_eol&&write_row==height-1'b1;
 wire context_ok=in_descriptor==descriptor&&in_session==session;
 wire sequence_ok=in_row==write_row&&in_word==write_word&&in_mask==expected_mask&&
                  in_eol==expected_eol&&in_frame_last==expected_last;
 wire padding_ok=(in_data&~{{8{in_mask[7]}},{8{in_mask[6]}},{8{in_mask[5]}},{8{in_mask[4]}},
                                {8{in_mask[3]}},{8{in_mask[2]}},{8{in_mask[1]}},{8{in_mask[0]}}})==0;
 wire input_bad=take&&(!context_ok||!sequence_ok||!padding_ok);
 wire write_take=take&&!input_bad;
 wire [63:0] readq[0:3];
 genvar b;
 generate for(b=0;b<4;b=b+1)begin:row_bank
  (* syn_ramstyle="block_ram" *)reg [63:0] mem[0:DEPTH-1];reg [63:0] q;
  wire needed=sy[0][1:0]==b||sy[1][1:0]==b||sy[2][1:0]==b;
  always @(posedge clk)begin
   if(fetch_issue&&needed)q<=mem[fetch_address[AW-1:0]];
   if(write_take&&wb==b)mem[write_word]<=in_data;
  end
  assign readq[b]=q;
 end endgenerate
 reg [287:0] pixel_windows;reg [63:0] selected_word;
 integer lane,ty,tx,ch,by,wi;
 always @(*)begin
  pixel_windows=0;selected_word=0;ch=0;by=0;wi=0;
  for(lane=0;lane<4;lane=lane+1)begin
   ch=(ci==8&&half)?lane+4:lane;
   for(ty=0;ty<3;ty=ty+1)for(tx=0;tx<3;tx=tx+1)begin
    by=(sx[tx]<<((ci==2)?1:(ci==4)?2:3))+ch;wi=(by>>3)-cache_base;
    case(wi)
     0:selected_word=cache0[sy[ty][1:0]];
     1:selected_word=cache1[sy[ty][1:0]];
     2:selected_word=cache2[sy[ty][1:0]];
     default:selected_word=0;
    endcase
    if(ci!=2||lane<2)pixel_windows[lane*72+(ty*3+tx)*8+:8]=selected_word[(by%8)*8+:8];
   end
  end
 end
 integer k;
 always @(posedge clk)begin
  if(rst)begin
   active<=0;input_done<=0;generated_last<=0;descriptor<=0;session<=0;width<=0;height<=0;ow<=0;oh<=0;ox<=0;oy<=0;
   write_row<=0;write_word<=0;ci<=0;stride2<=0;up2<=0;half<=0;row_words<=0;row_bytes<=0;pixel<=0;pixels<=0;
   row_valid<=0;cache_base<=0;cache_count<=0;pending<=0;pair_first<=0;pair_pending<=0;
   out_valid<=0;out_windows<=0;out_pixel<=0;out_channel<=0;out_frame_last<=0;error_code<=0;done<=0;
   for(k=0;k<4;k=k+1)row_number[k]<=0;
  end else begin
   done<=0;
   if(start_valid&&!active&&!mode_ok)error_code[0]<=1;
   if(go)begin
    active<=1;input_done<=0;generated_last<=0;descriptor<=start_descriptor;session<=start_session;
    width<=start_width;height<=start_height;ow<=start_ow;oh<=start_oh;ci<=start_ci;stride2<=start_stride2;up2<=start_up2;
    row_bytes<=start_bytes;row_words<=(start_bytes+7)>>3;write_row<=0;write_word<=0;row_valid<=0;
    ox<=0;oy<=0;pixel<=0;pixels<=start_ow*start_oh;half<=0;pair_pending<=0;cache_base<=0;cache_count<=0;pending<=0;
   end
   if(out_valid&&out_ready)begin
    out_valid<=0;
    if(out_frame_last)begin
     if(!input_done||!generated_last)error_code[3]<=1;
     if(input_done&&generated_last&&!error&&!input_bad)begin active<=0;done<=1;end
    end
   end
   if(take)begin
    if(!context_ok)error_code[1]<=1;
    if(!sequence_ok||!padding_ok)error_code[2]<=1;
   end
   if(write_take)begin
    if(write_word==0)begin row_valid[wb]<=0;row_number[wb]<=write_row;end
    if(expected_eol)begin row_valid[wb]<=1;write_word<=0;write_row<=write_row+1'b1;end
    else write_word<=write_word+1'b1;
    if(expected_last)input_done<=1;
   end
   if(fetch_issue)pending<=1;
   if(capture)pending<=0;
   if(capture)for(k=0;k<4;k=k+1)begin
    if(cache_count==0)cache0[k]<=readq[k];
    else if(cache_count==1)cache1[k]<=readq[k];
    else if(cache_count==2)cache2[k]<=readq[k];
    else begin cache0[k]<=cache1[k];cache1[k]<=cache2[k];cache2[k]<=readq[k];end
   end
   if(capture)begin
    if(cache_count<3)cache_count<=cache_count+1'b1;else cache_base<=cache_base+1'b1;
   end
   if(produce&&!input_bad)begin
    if(ci==2)begin
     if(pair_pending)begin
      out_valid<=1;out_windows<={pixel_windows[143:0],pair_first};out_pixel<=pixel-1'b1;out_channel<=0;out_frame_last<=last_position;pair_pending<=0;
     end else if(last_position)begin
      out_valid<=1;out_windows<={144'd0,pixel_windows[143:0]};out_pixel<=pixel;out_channel<=0;out_frame_last<=1;pair_pending<=0;
     end else begin pair_pending<=1;pair_first<=pixel_windows[143:0];end
    end else begin
     out_valid<=1;out_windows<=pixel_windows;out_pixel<=pixel;out_channel<=half?3'd4:3'd0;out_frame_last<=last_position&&final_half;
    end
    if(final_half)begin
     half<=0;pixel<=pixel+1'b1;
     if(last_position)generated_last<=1;
     if(ox==ow-1'b1)begin ox<=0;oy<=oy+1'b1;cache_base<=0;cache_count<=0;pending<=0;end
     else ox<=ox+1'b1;
    end else half<=1;
   end
  end
 end
endmodule
