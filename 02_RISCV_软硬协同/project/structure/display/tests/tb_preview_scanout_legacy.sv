`timescale 1ns/1ps
module tb_preview_scanout #(parameter A_HALF=3,P_HALF=5);
 localparam W=32,H=8;
 reg axi_clk=0,pix_clk=0,axi_rstn=0,pix_rstn=0,axi_enable=1;
 always #(A_HALF)if(axi_enable)axi_clk=~axi_clk;
 always #(P_HALF)pix_clk=~pix_clk;
 reg in_valid=0;wire in_ready;reg [23:0] in_rgb=0;reg [31:0] in_frame_id=0;
 reg [10:0] in_x=0;reg [9:0] in_y=0;reg in_sof=0,in_eol=0,in_eof=0;
 reg frame_start=0,roi_active=0;reg [10:0] roi_x=0;reg [9:0] roi_y=0;
 wire [5:0] fifo_high_water,pix_available; wire [31:0] startup_short_frames; wire scan_valid,scan_black,axi_boundary;wire [23:0] scan_rgb;wire [31:0] scan_frame_id;
 wire [31:0] source_errors,source_drop_pixels,underflow_frames,dropped_frames,completed_frames;
 wire [31:0] tag_error_frames,scan_error_frames,boundary_overflows;
 ab05_preview_scanout_r9 #(.VIEW_W(W),.VIEW_H(H),.FIFO_AW(5)) dut(.*);
 function [23:0] color(input [31:0] id,input integer x,y);
  begin color={8'(id[31:24]^x),8'(id[23:16]+y),8'(x*7+y*13+id[7:0])};end
 endfunction
 integer checks=0,boundaries=0,source_stalls=0,good_pixels=0,black_pixels=0;
 integer per_good=0,per_black=0;
 reg checking=0,black_seen=0;reg [31:0] expected_id;
 reg [31:0] rng=32'h39b19b73;
 always @(posedge axi_clk)begin
  if(axi_boundary)boundaries=boundaries+1;
  if(in_valid&&!in_ready)source_stalls=source_stalls+1;
  rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
 end
 always @(posedge pix_clk)begin
  #0.001;
  if(checking&&pix_rstn&&scan_valid)begin
   checks=checks+1;
   if(scan_black)begin
    if(scan_rgb!==0)$fatal(1,"black suffix leaked RGB");
    black_seen=1;per_black=per_black+1;black_pixels=black_pixels+1;
   end else begin
    if(black_seen)$fatal(1,"resumed within poisoned display frame");
    if(scan_frame_id!==expected_id)$fatal(1,"frame identity mismatch got=%h wanted=%h",scan_frame_id,expected_id);
    if(scan_rgb!==color(expected_id,roi_x,roi_y))$fatal(1,"RGB or row mismatch xy=%0d/%0d",roi_x,roi_y);
    per_good=per_good+1;good_pixels=good_pixels+1;
   end
  end
 end
 task send_frame(input [31:0] id,input integer mode);
  integer x,y,i;begin : sending
   if(mode!=9)wait(axi_boundary);
   if(mode==8)repeat(150)@(posedge pix_clk);
   for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+1)begin
    i=y*W+x;
    if(mode==1&&i==64)begin
     @(negedge axi_clk);in_valid=0;repeat(900)@(negedge axi_clk);
    end
    @(negedge axi_clk);
    if(!axi_rstn)disable sending;
    // Random bubbles plus finite FIFO cause both input bubbles and real stalls.
    if(rng[2:0]==0)begin in_valid=0;@(negedge axi_clk);end
    in_valid=1;in_rgb=color(id,x,y);in_frame_id=id;in_x=x;in_y=y;
    in_sof=(i==0);in_eol=(x==W-1);in_eof=(i==W*H-1);
    if(i==40)begin
     if(mode==2)in_frame_id=id^32'h10000;
     if(mode==3)in_x=x+1;
     if(mode==4)in_eol=!in_eol;
     if(mode==5)in_eof=1;
     if(mode==6)in_sof=1;
    end
    begin : acceptance
     reg accepted;accepted=0;
     while(!accepted)begin
      @(posedge axi_clk);
      if(!axi_rstn)disable sending;
      if(in_ready)accepted=1;
     end
    end
   end
   @(negedge axi_clk);in_valid=0;
  end
 endtask
 // mode 0: all pixels correct; 1: correct prefix then black; 2: all black.
 task scan_frame(input [31:0] id,input integer mode,input integer bad_xy);
  integer x,y;begin : scanning
   expected_id=id;per_good=0;per_black=0;black_seen=0;checking=1;
   @(negedge pix_clk);frame_start=1;
   @(negedge pix_clk);frame_start=0;
   repeat(80)@(negedge pix_clk);
   for(y=0;y<H;y=y+1)begin
    for(x=0;x<W;x=x+1)begin
     if(!pix_rstn)disable scanning;
     roi_active=1;roi_x=x;roi_y=y;
     if(bad_xy&&y*W+x==60)roi_x=x+1;
     @(negedge pix_clk);
    end
    roi_active=0;repeat(7)@(negedge pix_clk);
   end
   roi_active=0;repeat(20)@(negedge pix_clk);
   checking=0;
   if(per_good+per_black!=W*H)$fatal(1,"fixed-rate pixel count mismatch");
   if(mode==0&&(per_good!=W*H||per_black!=0))$fatal(1,"normal frame black good=%0d black=%0d",per_good,per_black);
   if(mode==1&&(per_good==0||per_black==0))$fatal(1,"fault did not preserve prefix/black suffix good=%0d black=%0d",per_good,per_black);
   if(mode==2&&per_black!=W*H)$fatal(1,"late frame was adopted mid-frame");
  end
 endtask
 task case_frame(input [31:0] id,input integer mode);
  begin
   fork send_frame(id,mode);scan_frame(id,(mode==0)?0:1,0);join
   $display("CASE PASS source_mode=%0d id=%h",mode,id);
  end
 endtask
 integer k,j;reg [31:0] before_drop,before_error,before_underflow;
 initial begin
  repeat(8)@(negedge axi_clk);axi_rstn=1;pix_rstn=1;
  repeat(8)@(negedge pix_clk);
  case_frame(32'h00010035,0);
  case_frame(32'h00020035,0); // same low16; full ID must survive.
  if(completed_frames!=2||dropped_frames!=0||source_stalls==0)$fatal(1,"normal/backpressure receipts");
  // An early next source header must not bind in the previous frame porch.
  fork
   begin send_frame(32'h00060035,0);send_frame(32'h00070035,9);end
   begin scan_frame(32'h00060035,0,0);scan_frame(32'h00070035,0,0);end
  join
  before_underflow=underflow_frames;before_drop=dropped_frames;
  case_frame(32'h00030035,1);
  if(underflow_frames!=before_underflow+1||dropped_frames!=before_drop+1)$fatal(1,"underflow must count once per display frame underflow=%0d before=%0d drop=%0d before=%0d",underflow_frames,before_underflow,dropped_frames,before_drop);
  case_frame(32'h00040035,0);
  for(k=2;k<=6;k=k+1)begin
   before_error=source_errors;before_drop=dropped_frames;
   case_frame(32'h00100035+k*32'h10000,k);
   if(source_errors!=before_error+1||dropped_frames!=before_drop+1)$fatal(1,"source malformed frame counting mode=%0d",k);
   case_frame(32'h00200035+k*32'h10000,0);
  end
  before_drop=dropped_frames;
  fork send_frame(32'h00300035,0);scan_frame(32'h00300035,1,1);join
  if(scan_error_frames!=1||dropped_frames!=before_drop+1)$fatal(1,"external scan coordinate fault not isolated");
  // No header by first ROI: black the whole frame. Late header remains for the
  // next display interval, with producer backpressured behind it as necessary.
  fork
   send_frame(32'h00400035,8);
   begin scan_frame(32'h00400035,2,0);scan_frame(32'h00400035,0,0);end
  join
  if(boundary_overflows!=0)$fatal(1,"unexpected boundary FIFO overflow");
  // New frame_start before EOF abandons exactly one unfinished frame.
  before_drop=dropped_frames;
  fork
   send_frame(32'h00410035,0);
   begin
    expected_id=32'h00410035;per_good=0;per_black=0;black_seen=0;checking=1;
    @(negedge pix_clk);frame_start=1;
    @(negedge pix_clk);frame_start=0;repeat(80)@(negedge pix_clk);
    for(j=0;j<W;j=j+1)begin roi_active=1;roi_x=j;roi_y=0;@(negedge pix_clk);end
    roi_active=0;checking=0;frame_start=1;
    @(negedge pix_clk);frame_start=0;
   end
  join
  if(dropped_frames!=before_drop+1)$fatal(1,"interrupted frame not dropped once");
  case_frame(32'h00420035,0);
  // Pausing the destination control clock explicitly fills the event queue;
  // lost frame boundary requests are counted, never silently overwritten.
  @(negedge axi_clk);axi_enable=0;
  for(j=0;j<8;j=j+1)begin
   @(negedge pix_clk);frame_start=1;
   @(negedge pix_clk);frame_start=0;
  end
  if(boundary_overflows==0)$fatal(1,"event queue overflow was hidden");
  axi_enable=1;repeat(30)@(negedge pix_clk);
  // Coordinated reset interrupts producer, scanout, FIFO and ID context.
  fork
   send_frame(32'h00500035,0);
   scan_frame(32'h00500035,1,0);
   begin repeat(120)@(negedge pix_clk);checking=0;axi_rstn=0;pix_rstn=0;end
  join_any
  disable fork;
  in_valid=0;roi_active=0;frame_start=0;
  repeat(12)@(negedge pix_clk);axi_rstn=1;pix_rstn=1;
  repeat(8)@(negedge pix_clk);
  if(scan_valid||scan_rgb||source_errors||underflow_frames||dropped_frames||completed_frames)$fatal(1,"coordinated reset did not clear context/counters");
  case_frame(32'h00600035,0);
  if(completed_frames!=1||dropped_frames!=0)$fatal(1,"post-reset fresh frame failed");
  $display("SCANOUT PASS width=%0d height=%0d axi_half=%0d pix_half=%0d checks=%0d good=%0d black=%0d source_stalls=%0d boundaries=%0d",W,H,A_HALF,P_HALF,checks,good_pixels,black_pixels,source_stalls,boundaries);
  $finish;
 end
 initial begin #2000000;$fatal(1,"scanout test timeout");end
endmodule
