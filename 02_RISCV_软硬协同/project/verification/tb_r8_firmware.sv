`timescale 1ns/1ps
module tb_r8_firmware;
 parameter FAULT=0,CAM_DIV=3;
 reg clk=0;always #5 clk=~clk;
 reg rstn=0;reg key_layout=0,key_style=0,result_done=0;
 reg [31:0] command_seq=0;reg [1:0] command_style=0;
 wire [31:0] applied_seq,cfg_model;wire remote_event,capture_enable;
 wire [1:0] style,layout;wire irq,osd_enable;
 wire [15:0] addr;wire psel,penable,pwrite;wire [31:0] wdata,rdata;
 wire trap;wire [3:0] trap_cause;wire [31:0] trap_value,pc;
 reg [31:0] ticks=0;
 always @(posedge clk)if(!rstn)ticks<=0;else ticks<=ticks+1;
 wire [31:0] ctrl_rdata;
 assign rdata=addr==16'h30 ? ticks:addr==16'h10 ? 32'd0:addr==16'h08 ? {31'd0,capture_enable}:ctrl_rdata;
 ab13_rv32i_manager cpu(.clk(clk),.rstn(rstn),.irq(irq),.paddr(addr),.psel(psel),.penable(penable),.pwrite(pwrite),
  .pwdata(wdata),.pready(1'b1),.pslverr(1'b0),.prdata(rdata),.trap(trap),.trap_cause(trap_cause),.trap_value(trap_value),
  .retire(),.retire_pc(),.retire_insn(),.retire_rd(),.retire_value(),.debug_pc(pc));
 wire camera_start,camera_busy,camera_done,camera_error,camera_ready;
 wire [23:0] camera_command;wire weight_we,weight_bias,models_ready;
 wire [5:0] weight_addr;wire [511:0] weight_data;reg [9:0] measured_fps=298;wire [127:0] osd_text;
 r8_control ctrl(.clk(clk),.rstn(rstn),.addr(addr),.write(psel&&penable&&pwrite),.wdata(wdata),.rdata(ctrl_rdata),
  .key_layout(key_layout),.key_style(key_style),.command_seq(command_seq),.command_style(command_style),.applied_seq(applied_seq),
  .remote_event(remote_event),.style(style),.layout(layout),.cfg_model(cfg_model),.capture_enable(capture_enable),
  .network_busy(1'b0),.result_done(result_done),.camera_start(camera_start),.camera_command(camera_command),
  .camera_busy(camera_busy),.camera_done(camera_done),.camera_error(camera_error),.camera_ready(camera_ready),
  .weight_we(weight_we),.weight_bias(weight_bias),.weight_addr(weight_addr),.weight_data(weight_data),
  .models_ready(models_ready),.irq(irq),.osd_enable(osd_enable),.measured_fps(measured_fps),.osd_text(osd_text));
 // Faster divider shortens the full 166-write simulation only. Standalone
 // camera regression also exercises the release divider of 659.
 wire scl_o,scl_oen,sda_o,sda_oen;tri1 scl,sda;reg slave_low=0;
 assign scl=FAULT==2?1'b0:scl_oen?1'bz:scl_o;
 assign sda=sda_oen?1'bz:sda_o;assign sda=slave_low?1'b0:1'bz;
 r8_camera_mmio #(.CLK_DIV(CAM_DIV),.TIMEOUT_CYCLES(CAM_DIV==659?2000000:10000)) camera(.clk(clk),.rstn(rstn),.start(camera_start),.command(camera_command),
  .busy(camera_busy),.done(camera_done),.error(camera_error),.scl_i(scl),.sda_i(sda),.scl_o(scl_o),.scl_oen(scl_oen),.sda_o(sda_o),.sda_oen(sda_oen));
 hd720_fused_core core(.clk(clk),.rst(!rstn),.start(1'b0),.ink_mode(1'b0),.neon_mode(1'b0),
  .weight_we(weight_we),.weight_bias(weight_bias),.weight_addr(weight_addr),.weight_data(weight_data),
  .pixel_valid(1'b0),.pixel_ready(),.pixel_rgb(24'd0),.pixel_x(11'd0),.pixel_y(10'd0),
  .result_valid(),.result_ready(1'b0),.result_data(),.result_sof(),.result_eol(),.result_eof(),.busy(),.done(),.cycles());
 reg [23:0] expected_camera[0:165];reg [511:0] expected_weights[0:62],expected_bias[0:8];
 integer camera_checked=0,weights_checked=0,bias_checked=0,byte_no,bit_no,i;
 reg [7:0] byte_value;reg [31:0] transaction_value;
 initial begin
  $readmemh("camera_expected.mem",expected_camera);$readmemh("hd_weights.mem",expected_weights);$readmemh("hd_bias.mem",expected_bias);
  forever begin
   @(negedge sda);
   if(scl===1'b1&&rstn)begin
    transaction_value=0;
    for(byte_no=0;byte_no<4;byte_no=byte_no+1)begin
     byte_value=0;
     for(bit_no=0;bit_no<8;bit_no=bit_no+1)begin @(posedge scl);byte_value={byte_value[6:0],sda};end
     transaction_value={transaction_value[23:0],byte_value};
     @(negedge scl);slave_low=FAULT!=1;
     @(posedge scl);@(negedge scl);slave_low=0;
    end
    if(FAULT==0)begin
     if(transaction_value!=={8'h60,expected_camera[camera_checked]})$fatal(1,"camera transaction %0d got %h expected %h",camera_checked,transaction_value,{8'h60,expected_camera[camera_checked]});
     camera_checked=camera_checked+1;
    end
   end
  end
 end
 always @(posedge clk)if(rstn)begin
  if(trap)$fatal(1,"CPU trap cause=%0d value=%h pc=%h",trap_cause,trap_value,pc);
  if(weight_we)begin
   if(weight_bias)begin
    if(weight_addr!=bias_checked||weight_data!==expected_bias[bias_checked])$fatal(1,"bias deployment row%0d",bias_checked);
    bias_checked=bias_checked+1;
   end else begin
    if(weight_addr!=weights_checked||weight_data!==expected_weights[weights_checked])$fatal(1,"weight deployment row%0d",weights_checked);
    weights_checked=weights_checked+1;
   end
  end
 end
 task irq_completion;
  reg [31:0] old_count;
  begin
   old_count=ctrl.software_status;
   @(negedge clk);result_done=1;@(negedge clk);result_done=0;
   wait(ctrl.software_status==old_count+1);
   if(irq)$fatal(1,"IRQ not acknowledged by C ISR");
  end
 endtask
 task press_layout;
  begin @(negedge clk);key_layout=1;@(negedge clk);key_layout=0;end
 endtask
 task press_style;
  begin @(negedge clk);key_style=1;@(negedge clk);key_style=0;end
 endtask
 initial begin
  // Poison initial model memories; success must come from actual CPU writes.
  #1;for(i=0;i<63;i=i+1)core.weights[i]={512{1'b1}};
  for(i=0;i<9;i=i+1)core.biases[i]={512{1'b1}};
  repeat(10)@(negedge clk);rstn=1;
  if(FAULT!=0)begin
   wait(ctrl.software_status[31:24]==8'hee);
   if(capture_enable||models_ready||!camera_error)$fatal(1,"failed camera admitted frame/model");
   $display("R8_FIRMWARE PASS fault=%0d rejected camera; C status=%h",FAULT,ctrl.software_status);$finish;
  end
  wait(capture_enable);repeat(10)@(negedge clk);
  if(camera_checked!=166||weights_checked!=63||bias_checked!=9||!osd_enable||!camera_ready||!models_ready)$fatal(1,"incomplete deployment camera=%0d weights=%0d bias=%0d",camera_checked,weights_checked,bias_checked);
  for(i=0;i<63;i=i+1)if(core.weights[i]!==expected_weights[i])$fatal(1,"active weight mismatch");
  for(i=0;i<9;i=i+1)if(core.biases[i]!==expected_bias[i])$fatal(1,"active bias mismatch");
  wait(ctrl.software_status==32'ha8000000);irq_completion();irq_completion();
  wait(osd_text==128'h382e39323a5350463032375830383231);
  measured_fps=301;wait(osd_text[127:96]==32'h312e3033);
  measured_fps=0;wait(osd_text[127:96]==32'h302e3030);
  press_layout();wait(layout==1);press_style();wait(style==1);press_style();wait(style==2);press_style();wait(style==0);
  @(negedge clk);command_style=2;command_seq=32'd1;wait(applied_seq==1);
  if(style!=2||layout!=1||cfg_model!=32'h544e3031)$fatal(1,"remote command not applied by C");
  press_layout();wait(layout==2);press_layout();wait(layout==3);press_layout();wait(layout==0);
  irq_completion();
  if(cpu.mstatus_mie!==1'b1||cpu.mie_meie!==1'b1)$fatal(1,"mret failed to restore interrupts");
  $display("R8_FIRMWARE PASS camera=166 weights=63 bias=9 ISR=3 KEY1=4 layouts KEY2=3 styles remote=ack exact_active_parameters=1");$finish;
 end
 initial begin #500000000;$fatal(1,"timeout pc=%h status=%h camera=%0d w=%0d camera_busy=%b error=%b",pc,ctrl.software_status,camera_checked,weights_checked,camera_busy,camera_error);end
endmodule
