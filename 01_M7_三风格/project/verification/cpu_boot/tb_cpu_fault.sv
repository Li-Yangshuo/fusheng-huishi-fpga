`timescale 1ns/1ps
// Production boot image and exact production peripherals; inject MMIO faults.
module tb_cpu_fault;
 parameter CASE=0;
 localparam BIT_CYCLES=864;
 reg clk=0,rstn=0,rx=1;always #5 clk=~clk;
 wire tx,toggle,psel,penable,pwrite,flash_clk,flash_cs,flash_mosi;
 wire [15:0] paddr;wire[31:0] pwdata;
 reg[31:0] prdata;reg capture=0;reg[7:0] fps=0;
 integer cycle=0,capture_starts=0,capture_stops=0,fps_writes=0,nchars=0;
 reg[31:0] rng=32'h3275ac41;wire pready=(CASE==2)?1'b1:|rng[1:0];
 reg fault=0;integer trace,serial;string received="";
`ifdef OBSERVE
 wire [31:0] debug_pc,debug_trap_value;wire[3:0] debug_trap_cause;
`endif
 ab10_cpu dut(.clk(clk),.rstn(rstn),.rx(rx),.dual_mode(1'b1),.tx(tx),.toggle(toggle),
  .paddr(paddr),.psel(psel),.penable(penable),.pwrite(pwrite),.pwdata(pwdata),
  .pready(pready),.pslverr(1'b0),.prdata(prdata),.local_rdata(128'd0),
  .bid(4'd0),.rid(4'd0),.flash_clk(flash_clk),.flash_cs(flash_cs),.flash_mosi(flash_mosi),.flash_miso(1'b1),
  .awready(1'b0),.wready(1'b0),.arready(1'b0),.bvalid(1'b0),.rvalid(1'b0),.rlast(1'b0),
  .bresp(2'd0),.rresp(2'd0),.rdata(128'd0)
`ifdef OBSERVE
  ,.debug_pc(debug_pc),.debug_trap_cause(debug_trap_cause),.debug_trap_value(debug_trap_value)
`endif
 );
`ifdef OBSERVE
 always @(negedge clk)if(rstn)begin
  if(debug_pc!==dut.cpu.pc || debug_trap_cause!==dut.trap_cause || debug_trap_value!==dut.trap_value)
   $fatal(1,"Observation output differs from production internal state");
 end
`endif
 always @*begin
  case(paddr)
   0:prdata=32'h41425239;
   4:prdata=32'h50503031;
   8:prdata={31'd0,capture};
   16:prdata=(fault?32'he3:32'd3)+({31'd0,capture}<<2);
   24:prdata=fault?0:cycle/3000;
   28:prdata=fault?32'h00000a0f:0;
   48:prdata=cycle*1000;
   52:prdata=0;
   56:prdata={24'd0,fps};
   60:prdata=32'hc0611cd0;
   default:prdata=0;
  endcase
 end
 always @(posedge clk)begin
  cycle<=cycle+1;rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  if(cycle>600000)$fatal(1,"CPU fault test timeout");
  if(rstn)begin
   if(dut.cs&&dut.ce&&dut.cy)
    $fdisplay(trace,"B,%08h,%0d,%08h,%0d",dut.ca,dut.cw,dut.cw?dut.cd:dut.cr,dut.cerr);
   if(psel&&penable&&pready&&pwrite)case(paddr)
    8:begin capture<=pwdata[0];if(pwdata[0])capture_starts<=capture_starts+1;else capture_stops<=capture_stops+1;end
    56:begin fps<=pwdata[7:0];fps_writes<=fps_writes+1;end
    default:;
   endcase
   if(dut.trap)$fatal(1,"Unexpected CPU trap cause=%h value=%h PC=%h instruction=%h",dut.trap_cause,dut.trap_value,dut.cpu.pc,dut.cpu.ir);
  end
 end
 always @(negedge clk)if(dut.cpu.retire)
  $fdisplay(trace,"I,%08h,%08h,%0d,%08h",dut.cpu.retire_pc,dut.cpu.retire_insn,dut.cpu.retire_rd,dut.cpu.retire_value);
 integer i;reg[7:0] ch;
 initial forever begin
  @(negedge tx);
  if(rstn)begin
   repeat(BIT_CYCLES/2)@(negedge clk);if(tx!==0)$fatal(1,"UART false start");
   for(i=0;i<8;i=i+1)begin repeat(BIT_CYCLES)@(negedge clk);ch[i]=tx;end
   repeat(BIT_CYCLES)@(negedge clk);if(tx!==1)$fatal(1,"UART stop bit");
   received={received,ch};nchars=nchars+1;$fwrite(serial,"%c",ch);
  end
 end
 initial begin
  trace=$fopen("retire.csv","w");serial=$fopen("uart.txt","wb");
  if(CASE==0 || CASE==2)fault=1;
  repeat(10)@(negedge clk);rstn=1;
  if(CASE==1)begin wait(nchars==18);fault=1;end
  wait(nchars==(CASE==1?23:18));
  repeat(30000)@(negedge clk);
  if(capture || capture_stops!=1 || (CASE==1 && capture_starts!=1) || (CASE!=1 && capture_starts!=0))
   $fatal(1,"Capture stop mismatch starts=%d stops=%d capture=%b",capture_starts,capture_stops,capture);
  if(CASE==1)begin if(received!={"ABR17 START",8'h0d,8'h0a,"RUN",8'h0d,8'h0a,"ERR",8'h0d,8'h0a})$fatal(1,"UART mismatch %s",received);end
  else if(received!={"ABR17 START",8'h0d,8'h0a,"ERR",8'h0d,8'h0a})$fatal(1,"UART mismatch %s",received);
  if(dut.cpu.pc!=32'hf9000270 || dut.cpu.ir!=32'h00000063 || toggle!==0)$fatal(1,"Fault halt state mismatch");
  $display("CPU_FAULT PASS case=%0d chars=%0d capture_starts=%0d stops=%0d trap=%b PC=%h IR=%h",CASE,nchars,capture_starts,capture_stops,toggle,dut.cpu.pc,dut.cpu.ir);
  $fclose(trace);$fclose(serial);$finish;
 end
endmodule
