`timescale 1ns/1ps
module tb_hd_capture;
 reg clk=0,rstn=0,v=0,sof=0,eol=0;always #5 clk=~clk;
 reg [23:0] rgb=0;reg [31:0] fid=1;
 wire ov,os,ol,oe,fault;wire [23:0] orgb;wire [31:0] ofid;wire [3:0] code;
 ab720_capture_guard dut(clk,rstn,v,sof,eol,rgb,fid,ov,os,ol,oe,orgb,ofid,fault,code);
 integer count=0,ends=0,checks=0,i,test;
 reg checking=0;
 always @(negedge clk)if(rstn&&checking&&ov)begin
  if(orgb!==count[23:0]||ofid!==32'd23||os!==(count==0)||ol!==(count%1280==1279)||oe!==(count==921599))$fatal(1,"native capture mismatch %0d",count);
  count=count+1;checks=checks+1;if(oe)ends=ends+1;
 end
 task reset_dut;
 begin checking=0;v=0;rstn=0;repeat(3)@(posedge clk);@(negedge clk);rstn=1;count=0;ends=0;end endtask
 task send(input bit s,l,input [31:0] f,input [23:0] p);
 begin @(negedge clk);v=1;sof=s;eol=l;fid=f;rgb=p;end endtask
 initial begin
  reset_dut();checking=1;
  for(i=0;i<921600;i=i+1)begin
   send(i==0,i%1280==1279,23,i);
   if(i%19==0)begin @(negedge clk);v=0;end
  end
  @(negedge clk);v=0;repeat(3)@(negedge clk);
  if(fault||count!=921600||ends!=1)$fatal(1,"capture full frame count/fault");
  for(test=1;test<=5;test=test+1)begin
   reset_dut();
   case(test)
   1:send(0,0,1,0);
   2:begin send(1,0,1,0);send(1,0,1,0);end
   3:begin send(1,0,1,0);send(0,0,2,0);end
   4:begin send(1,0,1,0);send(0,1,1,0);end
   5:begin for(i=0;i<1280;i=i+1)send(i==0,0,1,0);end
   endcase
   @(negedge clk);v=0;repeat(3)@(negedge clk);
   if(!fault||code!==(test==5?4:test))$fatal(1,"missing fault case%0d code%0d",test,code);
   send(1,0,1,0);@(negedge clk);v=0;repeat(3)@(negedge clk);
   if(ov||oe||!fault)$fatal(1,"fault not quarantined");
  end
  reset_dut();send(1,0,23,0);@(negedge clk);v=0;repeat(3)@(negedge clk);
  if(fault)$fatal(1,"reset did not recover");
  $display("HD720_CAPTURE PASS pixels=%0d malformed=5 quarantine=1 reset_recovery=1",checks);$finish;
 end
 initial begin #15000000;$fatal(1,"capture timeout");end
endmodule
