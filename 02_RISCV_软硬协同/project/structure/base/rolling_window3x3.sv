// Two packed physical rows, read-before-overwrite with separate clock phases.
// Raster input: ceil(WIDTH*CHANNELS/5) words/row, low byte first; last word padded.
// A beat emits up to five scalar channel windows; mask holes are intentional.
// Tap byte order is TL,TC,TR,ML,MC,MR,BL,BC,BR, low byte first per 72-bit lane.
// Outputs remain stable under backpressure. New frames start after final drain.
// No intermediate frame DDR and no dependency on BRAM read-during-write mode.
module rolling_window3x3 #(
 parameter WIDTH=1280, HEIGHT=720, CHANNELS=8,
 parameter ROW_BYTES=WIDTH*CHANNELS, WORDS=(ROW_BYTES+4)/5,
 parameter AW=(WORDS<2)?1:$clog2(WORDS), DEPTH=(1<<AW),
 parameter XW=$clog2(WIDTH+1), YW=$clog2(HEIGHT+1),
 parameter CW=(CHANNELS<2)?1:$clog2(CHANNELS)
)(
 input wire clk,rst,
 input wire start_valid,output wire start_ready,input wire [31:0] start_frame,
 input wire in_valid,output wire in_ready,input wire [39:0] in_data,input wire in_eol,
 output reg out_valid,input wire out_ready,
 output reg [4:0] out_mask,output reg [359:0] out_windows,
 output reg [5*XW-1:0] out_x,output reg [5*CW-1:0] out_channel,
 output reg [YW-1:0] out_y,output reg [31:0] out_frame,
 output reg out_eol,out_last,output reg done,output reg protocol_error
);
 localparam IDLE=0,READ_WORD=1,PROCESS_WORD=2,FLUSH_RIGHT=3,DRAIN=4;
 reg [2:0] state;
 reg [31:0] frame_id;
 reg [YW-1:0] row_in;
 reg [AW-1:0] word_index;
 reg [XW-1:0] column_in;
 reg [CW-1:0] channel_in;
 reg [CW:0] flush_left;
 reg [39:0] current_word,read0,read1;
 (* syn_ramstyle="block_ram" *) reg [39:0] line0[0:DEPTH-1];
 (* syn_ramstyle="block_ram" *) reg [39:0] line1[0:DEPTH-1];
 reg [7:0] hist_t[0:2*CHANNELS-1],hist_m[0:2*CHANNELS-1],hist_b[0:2*CHANNELS-1];
 reg [7:0] next_t[0:2*CHANNELS-1],next_m[0:2*CHANNELS-1],next_b[0:2*CHANNELS-1];
 wire advance=!out_valid || out_ready;
 assign start_ready=!rst && state==IDLE && !out_valid;
 assign in_ready=!rst && state==READ_WORD && row_in<HEIGHT;
 wire read_take=!rst && state==READ_WORD && ((row_in==HEIGHT)||(in_valid && in_ready));
 wire write_take=!rst && state==PROCESS_WORD && advance && row_in<HEIGHT;
 always @(posedge clk)begin
  if(read_take)begin read0<=line0[word_index];read1<=line1[word_index];end
  if(write_take)begin
   if(row_in[0])line1[word_index]<=current_word;
   else line0[word_index]<=current_word;
  end
 end

 reg [39:0] top_word,middle_word,bottom_word;
 reg [4:0] mask_next;
 reg [359:0] windows_next;
 reg [5*XW-1:0] x_next;
 reg [5*CW-1:0] channel_next;
 reg [XW-1:0] column_next;
 reg [CW-1:0] ch_next;
 reg [7:0] bt,bm,bb,lt,lm,lb;
 integer lane,j,nbytes,shift_bytes;
 always @(*)begin
  if(row_in==1)begin top_word=current_word;middle_word=read0;bottom_word=current_word;end
  else if(row_in==HEIGHT)begin
   top_word=(HEIGHT%2==0)?read0:read1;
   middle_word=(HEIGHT%2==0)?read1:read0;bottom_word=top_word;
  end else begin
   top_word=row_in[0]?read1:read0;middle_word=row_in[0]?read0:read1;bottom_word=current_word;
  end
  for(j=0;j<2*CHANNELS;j=j+1)begin next_t[j]=hist_t[j];next_m[j]=hist_m[j];next_b[j]=hist_b[j];end
  mask_next=0;windows_next=0;x_next=0;channel_next=0;
  column_next=column_in;ch_next=channel_in;
  bt=0;bm=0;bb=0;lt=0;lm=0;lb=0;nbytes=0;shift_bytes=0;
  if(state==FLUSH_RIGHT)nbytes=(flush_left>5)?5:((CHANNELS%5==0)?5:CHANNELS%5);
  else if(state==PROCESS_WORD && row_in!=0)nbytes=(word_index==WORDS-1)?ROW_BYTES-5*(WORDS-1):5;
  shift_bytes=(state==FLUSH_RIGHT)?5:nbytes;
  for(lane=0;lane<5;lane=lane+1)begin
   if(lane<shift_bytes)begin
    if(state==FLUSH_RIGHT)begin
     bt=next_t[2*CHANNELS-1];bm=next_m[2*CHANNELS-1];bb=next_b[2*CHANNELS-1];
    end else begin bt=top_word[8*lane+:8];bm=middle_word[8*lane+:8];bb=bottom_word[8*lane+:8];end
    lt=(column_next==1)?bt:next_t[2*CHANNELS-1];
    lm=(column_next==1)?bm:next_m[2*CHANNELS-1];
    lb=(column_next==1)?bb:next_b[2*CHANNELS-1];
    begin
     mask_next[lane]=(column_next!=0) && (lane<nbytes);
     windows_next[72*lane+:72]={bb,next_b[CHANNELS-1],lb,bm,next_m[CHANNELS-1],lm,bt,next_t[CHANNELS-1],lt};
     x_next[XW*lane+:XW]=column_next-1'b1;
     channel_next[CW*lane+:CW]=ch_next;
    end
    for(j=2*CHANNELS-1;j>0;j=j-1)begin next_t[j]=next_t[j-1];next_m[j]=next_m[j-1];next_b[j]=next_b[j-1];end
    next_t[0]=bt;next_m[0]=bm;next_b[0]=bb;
    if(ch_next==CHANNELS-1)begin ch_next=0;column_next=column_next+1'b1;end
    else ch_next=ch_next+1'b1;
   end
  end
 end

 integer k;
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;out_valid<=0;done<=0;protocol_error<=0;
   frame_id<=0;row_in<=0;word_index<=0;column_in<=0;channel_in<=0;flush_left<=0;
   current_word<=0;out_mask<=0;out_windows<=0;out_x<=0;out_channel<=0;
   out_y<=0;out_frame<=0;out_eol<=0;out_last<=0;
   for(k=0;k<2*CHANNELS;k=k+1)begin hist_t[k]<=0;hist_m[k]<=0;hist_b[k]<=0;end
  end else begin
   done<=0;
   if(out_valid && out_ready)begin out_valid<=0;if(out_last)done<=1;end
   case(state)
    IDLE:if(start_valid && start_ready)begin
     frame_id<=start_frame;row_in<=0;word_index<=0;column_in<=0;channel_in<=0;state<=READ_WORD;
    end
    READ_WORD:if(read_take)begin
     current_word<=in_data;state<=PROCESS_WORD;
     if(row_in<HEIGHT && in_eol!=(word_index==WORDS-1))protocol_error<=1;
    end
    PROCESS_WORD:if(advance)begin
     if(row_in!=0)begin
      for(k=0;k<2*CHANNELS;k=k+1)begin hist_t[k]<=next_t[k];hist_m[k]<=next_m[k];hist_b[k]<=next_b[k];end
      column_in<=column_next;channel_in<=ch_next;
      out_valid<=|mask_next;out_mask<=mask_next;out_windows<=windows_next;out_x<=x_next;out_channel<=channel_next;
      out_y<=row_in-1'b1;out_frame<=frame_id;out_eol<=0;out_last<=0;
     end
     if(word_index==WORDS-1)begin
      if(row_in==0)begin row_in<=1;word_index<=0;state<=READ_WORD;end
      else begin flush_left<=CHANNELS;state<=FLUSH_RIGHT;end
     end else begin word_index<=word_index+1'b1;state<=READ_WORD;end
    end
    FLUSH_RIGHT:if(advance)begin
     for(k=0;k<2*CHANNELS;k=k+1)begin hist_t[k]<=next_t[k];hist_m[k]<=next_m[k];hist_b[k]<=next_b[k];end
     column_in<=column_next;channel_in<=ch_next;
     out_valid<=1;out_mask<=mask_next;out_windows<=windows_next;out_x<=x_next;out_channel<=channel_next;
     out_y<=row_in-1'b1;out_frame<=frame_id;out_eol<=flush_left<=5;out_last<=(row_in==HEIGHT && flush_left<=5);
     if(flush_left<=5)begin
      column_in<=0;channel_in<=0;word_index<=0;flush_left<=0;
      if(row_in==HEIGHT)state<=DRAIN;
      else begin row_in<=row_in+1'b1;state<=READ_WORD;end
     end else flush_left<=flush_left-5;
    end
    DRAIN:if(out_valid && out_ready)state<=IDLE;
    default:state<=IDLE;
   endcase
  end
 end
endmodule
