// A25: preserve camera valid bubbles, but publish only complete, continuous
// 1920-pixel rows to the legacy debayer (which uses valid-fall as EOL).
// Complete-row Gray counter is a commit pointer, not a per-pixel CDC bus.
// Input has no independently verified physical EOL. Thus row length is counted
// in valid RAW4 beats; every following VS checks exact previous-frame geometry.
module ab09_raw4_pair #(
 parameter FIFO_AW=10, WORDS_PER_LINE=480, LINES_PER_FRAME=1080
)(
 input wire wclk,wrstn,in_vs,in_de,input wire[31:0] in_raw,
 input wire rclk,rrstn,output wire out_vs,out_de,output wire[15:0] out_raw,
 output wire[31:0] out_frame_id,output wire frame_start,output wire fault
);
 wire arst=!(wrstn&&rrstn);
 reg vs_d,sof_pending,write_fault,seen_vs;
 reg[31:0] frame_id;
 reg[9:0] word_x;
 reg[15:0] frame_lines,committed_rows,committed_gray;
 reg[1:0] wrun;
 // FIFO warm-up may straddle VS and its first beat. Ignore that entire frame
 // rather than arm it while its first one or two words cannot be written.
 // vs_d still tracks during warm-up: readiness never creates a false VS edge.
 wire vs_rise=wrun[1]&&in_vs&&!vs_d;
 wire input_armed=seen_vs||vs_rise;
 wire sof=sof_pending||vs_rise;
 wire[31:0] fid=vs_rise?frame_id+1'b1:frame_id;
 wire eol=(word_x==WORDS_PER_LINE-1)&&!sof;
 wire bad_boundary=vs_rise&&seen_vs&&
     ((word_x!=0)||(frame_lines!=LINES_PER_FRAME));
 wire excess_data=in_de&&input_armed&&!vs_rise&&
     (frame_lines>=LINES_PER_FRAME);
 wire ready,valid,take;
 wire[65:0] data;
 wire accepted=in_de&&input_armed&&wrun[1]&&!write_fault&&
     !bad_boundary&&!excess_data;
 wire[15:0] next_commit=committed_rows+1'b1;
 always @(posedge wclk or posedge arst)begin
  if(arst)begin
   vs_d<=0;sof_pending<=0;frame_id<=0;word_x<=0;write_fault<=0;
   wrun<=0;seen_vs<=0;frame_lines<=0;committed_rows<=0;committed_gray<=0;
  end else begin
   wrun<={wrun[0],1'b1};vs_d<=in_vs;
   if(vs_rise)begin
    seen_vs<=1;frame_id<=frame_id+1'b1;sof_pending<=1;word_x<=0;
    frame_lines<=0;
   end
   // Fail-stop rather than combine an incomplete old frame with a new one.
   if(bad_boundary||excess_data)write_fault<=1;
   if(accepted)begin
    if(!ready)write_fault<=1;
    else begin
     if(sof)begin sof_pending<=0;word_x<=1;end
     else if(eol)begin
      word_x<=0;frame_lines<=frame_lines+1'b1;
      committed_rows<=next_commit;
      committed_gray<=(next_commit>>1)^next_commit;
     end else word_x<=word_x+1'b1;
    end
   end
  end
 end
 ab05_async_stream #(.W(66),.AW(FIFO_AW)) fifo(
  .arst(arst),.wclk(wclk),.rclk(rclk),.s_valid(accepted),.s_ready(ready),
  .s_data({fid,eol,sof,in_raw}),.m_valid(valid),.m_ready(take),
  .m_data(data),.w_high_water());
 (* async_reg="true" *)reg[1:0] fault_sync;
 (* async_reg="true" *)reg[15:0] committed_g1,committed_g2;
 reg[15:0] consumed_rows;
 reg phase,sof_seen,line_running,read_fault;
 reg[3:0] pause_count;
 function[15:0] ungray(input[15:0] g);
  integer i;begin ungray[15]=g[15];for(i=14;i>=0;i=i-1)
   ungray[i]=ungray[i+1]^g[i];end
 endfunction
 wire complete_line=(ungray(committed_g2)!=consumed_rows);
 wire can_start=complete_line&&valid&&!line_running&&pause_count==0;
 wire sof_guard=can_start&&data[32]&&!sof_seen;
 assign frame_start=sof_guard&&!fault;
 // Retain six guard cycles before first camera row for capture/lease arming.
 assign out_vs=pause_count>=5;
 assign out_de=line_running&&valid&&pause_count==0&&!fault;
 assign out_raw=phase?data[31:16]:data[15:0];
 assign out_frame_id=data[65:34];
 assign take=out_de&&phase;
 assign fault=fault_sync[1]||read_fault;
 always @(posedge rclk or posedge arst)begin
  if(arst)begin
   phase<=0;sof_seen<=0;pause_count<=0;fault_sync<=0;line_running<=0;
   read_fault<=0;committed_g1<=0;committed_g2<=0;consumed_rows<=0;
  end else begin
   fault_sync<={fault_sync[0],write_fault};
   committed_g1<=committed_gray;committed_g2<=committed_g1;
   if(pause_count!=0)pause_count<=pause_count-1'b1;
   if(sof_guard)begin sof_seen<=1;pause_count<=6;end
   else if(can_start&&!fault)begin line_running<=1;phase<=0;end
   // This is an internal underflow after row commit, never a legal CSI bubble.
   if(line_running&&!valid&&!fault)read_fault<=1;
   if(out_de)begin
    phase<=!phase;
    if(phase&&data[33])begin
     sof_seen<=0;pause_count<=4;line_running<=0;
     consumed_rows<=consumed_rows+1'b1;
    end
   end
  end
 end
 // synthesis translate_off
 initial begin
  if((1<<FIFO_AW)<WORDS_PER_LINE)$fatal(1,"RAW FIFO must hold a complete row");
  if(WORDS_PER_LINE<2||WORDS_PER_LINE>1024)$fatal(1,"unsupported RAW row size");
 end
 // synthesis translate_on
endmodule
