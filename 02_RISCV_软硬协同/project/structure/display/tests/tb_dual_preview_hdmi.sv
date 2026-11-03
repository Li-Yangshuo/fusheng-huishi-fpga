`timescale 1ns/1ps
module tb_dual_preview_hdmi #(parameter A_HALF=3,P_HALF=7);
 localparam W=32,H=8,AH=16;
 reg axi_clk=0,pix_clk=0,axi_rstn=0,pix_rstn=0;
 always #A_HALF axi_clk=~axi_clk;
 always #P_HALF pix_clk=~pix_clk;
 wire frame_start,pix_hs,pix_vs,pix_de;wire [11:0] pix_x,pix_y;
 ab05_hdmi_timing #(.H_ACTIVE(2*W),.H_FP(8),.H_SYNC(4),.H_BP(8),
  .V_ACTIVE(AH),.V_FP(2),.V_SYNC(2),.V_BP(4)) timing(
  .pix_clk(pix_clk),.pix_rstn(pix_rstn),.frame_start(frame_start),
  .hs(pix_hs),.vs(pix_vs),.de(pix_de),.x(pix_x),.y(pix_y));
 reg left_pixel_valid=0,right_pixel_valid=0;
 wire left_pixel_ready,right_pixel_ready;
 reg [23:0] left_pixel_rgb=0,right_pixel_rgb=0;
 reg [31:0] left_pixel_frame_id=0,right_pixel_frame_id=0;
 reg [10:0] left_pixel_x=0,right_pixel_x=0;
 reg [9:0] left_pixel_y=0,right_pixel_y=0;
 reg left_pixel_sof=0,left_pixel_eol=0,left_pixel_eof=0;
 reg right_pixel_sof=0,right_pixel_eol=0,right_pixel_eof=0;
 wire left_boundary,right_boundary;
 wire [23:0] hdmi_rgb;wire hdmi_hs,hdmi_vs,hdmi_de;
 wire [31:0] left_display_frame_id,right_display_frame_id;
 wire [5:0] left_fifo_high_water,right_fifo_high_water,left_pix_available,right_pix_available;
 reg snapshot_request=0;wire snapshot_busy,snapshot_valid;wire [639:0] snapshot_data;
 ab05_dual_preview_hdmi #(.VIEW_W(W),.VIEW_H(H),.ACTIVE_W(2*W),.ACTIVE_H(AH),
  .FIFO_AW(5),.MIN_START_PIXELS(16)) dut(.*);
 function [23:0] color(input [31:0] id,input integer x,y);
  color={8'(id[31:24]^x),8'(id[23:16]+y),8'(x*7+y*13+id[7:0])};
 endfunction
 integer lseq=0,rseq=0,frames=0,checks=0,good=0,black=0,stalls=0,snaps=0;
 integer fd;
 reg lb_seen=0,rb_seen=0,l_seen=0,r_seen=0;
 reg [31:0] l_id,r_id;
 always @(posedge axi_clk)if(axi_rstn)begin
  if(left_pixel_valid&&!left_pixel_ready)stalls=stalls+1;
  if(right_pixel_valid&&!right_pixel_ready)stalls=stalls+1;
  if(left_boundary)$fdisplay(fd,"BOUNDARY,L,%0t",$time);
  if(right_boundary)$fdisplay(fd,"BOUNDARY,R,%0t",$time);
  if(snapshot_valid)begin snaps=snaps+1;$fdisplay(fd,"SNAP,%0t,%h",$time,snapshot_data);end
 end
 task send_left(input integer seq);
  integer x,y,i;reg [31:0] id;begin
   id=32'hA1000055+(seq<<16);
   for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+1)begin
    i=y*W+x;
    if(seq==2&&i==64)begin
     @(negedge axi_clk);left_pixel_valid=0;repeat(700)@(negedge pix_clk);
    end
    @(negedge axi_clk);
    left_pixel_valid=1;left_pixel_rgb=color(id,x,y);left_pixel_frame_id=id;
    left_pixel_x=x;left_pixel_y=y;left_pixel_sof=i==0;left_pixel_eol=x==W-1;left_pixel_eof=i==W*H-1;
    if(seq==4&&i==40)left_pixel_frame_id=id^32'h10000;
    begin: accept_l
     reg done;done=0;while(!done)begin @(posedge axi_clk);done=left_pixel_ready;end
    end
   end
   @(negedge axi_clk);left_pixel_valid=0;
  end endtask
 task send_right(input integer seq);
  integer x,y,i;reg [31:0] id;begin
   id=32'hB2000055+(seq<<16);
   for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+1)begin
    i=y*W+x;@(negedge axi_clk);
    if(seq==3&&i==0)repeat(800)@(negedge pix_clk);
    right_pixel_valid=1;right_pixel_rgb=color(id,x,y);right_pixel_frame_id=id;
    right_pixel_x=x;right_pixel_y=y;right_pixel_sof=i==0;right_pixel_eol=x==W-1;right_pixel_eof=i==W*H-1;
    begin: accept_r
     reg done;done=0;while(!done)begin @(posedge axi_clk);done=right_pixel_ready;end
    end
   end
   @(negedge axi_clk);right_pixel_valid=0;
  end endtask
 initial begin
  wait(axi_rstn);forever begin wait(left_boundary);send_left(lseq);lseq=lseq+1;end
 end
 initial begin
  wait(axi_rstn);forever begin wait(right_boundary);send_right(rseq);rseq=rseq+1;end
 end
 always @(posedge pix_clk)if(pix_rstn)begin : pixel_check
  reg fs,hs,vs,de,lr,rr;integer x,y;
  fs=frame_start;hs=pix_hs;vs=pix_vs;de=pix_de;x=pix_x;y=pix_y;
  lr=de&&(y>=4)&&(y<12)&&(x<W);
  rr=de&&(y>=4)&&(y<12)&&(x>=W)&&(x<2*W);
  if(fs)begin frames=frames+1;lb_seen=0;rb_seen=0;l_seen=0;r_seen=0;end
  #0.001;checks=checks+1;
  if(hdmi_hs!==hs||hdmi_vs!==vs||hdmi_de!==de)$fatal(1,"HDMI sync delay mismatch");
  if(!(lr||rr)&&hdmi_rgb!==0)$fatal(1,"outside ROI not black");
  if(lr)begin
   if(dut.lb)begin lb_seen=1;black=black+1;if(hdmi_rgb!==0)$fatal(1,"left black suffix data");end
   else begin
    if(lb_seen)$fatal(1,"left resumed midframe");
    if(!l_seen)begin l_id=left_display_frame_id;l_seen=1;end
    if(left_display_frame_id!==l_id)$fatal(1,"left switched identity within frame");
    if(hdmi_rgb!==color(l_id,x,y-4))$fatal(1,"left RGB/coordinate mismatch");
    good=good+1;
   end
  end
  if(rr)begin
   if(dut.rb)begin rb_seen=1;black=black+1;if(hdmi_rgb!==0)$fatal(1,"right black suffix data");end
   else begin
    if(rb_seen)$fatal(1,"right resumed midframe");
    if(!r_seen)begin r_id=right_display_frame_id;r_seen=1;end
    if(right_display_frame_id!==r_id)$fatal(1,"right switched identity within frame");
    if(hdmi_rgb!==color(r_id,x-W,y-4))$fatal(1,"right RGB/coordinate mismatch");
    good=good+1;
   end
  end
 end
 initial begin
  fd=$fopen("display_trace.csv","w");
  repeat(6)@(negedge axi_clk);axi_rstn=1;pix_rstn=1;
  wait(frames==9);
  @(negedge axi_clk);snapshot_request=1;@(negedge axi_clk);snapshot_request=0;
  wait(snapshot_valid);repeat(5)@(posedge axi_clk);
  if(dut.l_done<3||dut.r_done<3||dut.l_srcerr==0||dut.l_under==0||dut.r_under==0||stalls==0||snaps==0)
   $fatal(1,"coverage missing done %d/%d err %d under %d/%d stalls %d snaps %d",dut.l_done,dut.r_done,dut.l_srcerr,dut.l_under,dut.r_under,stalls,snaps);
  if(snapshot_data[31:0]!=dut.l_under||snapshot_data[63:32]!=dut.l_drop||snapshot_data[511:480]>33)
   $fatal(1,"snapshot packing/coherence");
  $display("DUAL_HDMI PASS checks=%0d good=%0d black=%0d stalls=%0d snapshots=%0d left_done=%0d right_done=%0d",checks,good,black,stalls,snaps,dut.l_done,dut.r_done);
  $fclose(fd);$finish;
 end
 initial begin #5000000;$fatal(1,"timeout");end
endmodule
