`timescale 1ns/1ps
module tb_r8_control;
 reg clk=0;always #5 clk=~clk;
 reg rstn=0,write=0,key_layout=0,key_style=0,network_busy=0,result_done=0;
 reg [15:0] addr=0;reg [31:0] wdata=0,command_seq=0;reg [1:0] command_style=0;
 reg camera_busy=0,camera_done=0,camera_error=0;reg [9:0] measured_fps=301;
 wire [31:0] rdata,applied_seq,cfg_model;wire remote_event,capture_enable,camera_start,camera_ready;
 wire [23:0] camera_command;wire weight_we,weight_bias,models_ready,irq,osd_enable;
 wire [5:0] weight_addr;wire [511:0] weight_data;wire [127:0] osd_text;wire [1:0] style,layout;
 r8_control dut(.*);
 task wr(input [15:0] a,input [31:0] d);
 begin @(negedge clk);addr=a;wdata=d;write=1;@(negedge clk);write=0;end endtask
 task rd(input [15:0] a,input [31:0] d);
 begin @(negedge clk);addr=a;#1;if(rdata!==d)$fatal(1,"MMIO %h got %h expected %h",a,rdata,d);end endtask
 integer i,j,rows=0;reg [511:0] expected;
 always @(negedge clk)if(weight_we)begin
  expected=0;for(j=0;j<16;j=j+1)expected[j*32+:32]=rows*16+j;
  if(weight_data!==expected||weight_bias!==(rows>=63)||weight_addr!==(rows>=63?rows-63:rows))$fatal(1,"parameter ordering row%0d",rows);
  rows=rows+1;
 end
 initial begin
  repeat(4)@(negedge clk);rstn=1;wr(16'h08,1);rd(16'h08,0);
  wr(16'h60,5);if(models_ready)$fatal(1,"incomplete model accepted");
  wr(16'h58,0);network_busy=1;wr(16'h5c,1);network_busy=0;rd(16'h58,0);
  wr(16'h58,0);for(i=0;i<1152;i=i+1)wr(16'h5c,i);
  repeat(2)@(negedge clk);if(rows!=72)$fatal(1,"missing weight rows");
  wr(16'h60,5);if(!models_ready||!osd_enable)$fatal(1,"valid model rejected");
  for(i=0;i<166;i=i+1)begin
   wr(16'h50,24'h010203+i);if(!camera_start)$fatal(1,"camera command rejected");
   camera_busy=1;@(negedge clk);camera_busy=0;camera_done=1;@(negedge clk);camera_done=0;@(negedge clk);
  end
  wr(16'h54,8);if(!camera_ready)$fatal(1,"camera not ready");
  wr(16'h08,1);if(!capture_enable)$fatal(1,"ready start rejected");
  wr(16'h58,0);wr(16'h5c,32'hbad0bad0);rd(16'h58,1152);
  if(rows!=72)$fatal(1,"runtime weight write escaped lock");
  wr(16'h08,0);wr(16'h58,0);wr(16'h5c,0);rd(16'h58,1152);
  if(!models_ready)$fatal(1,"runtime reset escaped sticky started lock");
  wr(16'h64,11);rd(16'h64,11);wr(16'h64,15);rd(16'h64,11);
  wr(16'h0c,16'h0f39);if(osd_text[127:120]!==8'h39)$fatal(1,"OSD char missing");
  wr(16'h0c,16'h1041);if(osd_text[127:120]!==8'h39)$fatal(1,"OSD index wrap");rd(16'h0c,301);
  wr(16'h68,1);
  @(negedge clk);addr=16'h6c;wdata=1;write=1;result_done=1;
  @(negedge clk);write=0;result_done=0;if(!irq)$fatal(1,"IRQ W1C lost concurrent event");
  wr(16'h6c,1);if(irq)$fatal(1,"IRQ clear failed");
  @(negedge clk);addr=16'h4c;wdata=3;write=1;key_layout=1;key_style=1;
  @(negedge clk);write=0;key_layout=0;key_style=0;rd(16'h4c,3);
  wr(16'h4c,3);rd(16'h4c,0);
  command_seq=3;command_style=1;wr(16'h7c,2);if(!remote_event)$fatal(1,"stale ACK accepted");
  wr(16'h7c,3);if(remote_event)$fatal(1,"valid ACK rejected");
  wr(16'h08,1);camera_error=1;repeat(2)@(negedge clk);if(capture_enable)$fatal(1,"camera error did not stop");
  $display("R8_CONTROL PASS ordered_parameter_rows=72 runtime_write_lock=1 incomplete_reject=1 W1C_set_wins=1 stale_ack_reject=1 OSD_bounds=1");$finish;
 end
 initial begin #1000000;$fatal(1,"unit timeout");end
endmodule
