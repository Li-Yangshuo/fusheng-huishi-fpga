`timescale 1ns/1ps
module tb_fps_decimal;
 reg clk=0;always #5 clk=~clk;reg rstn=0,event_done=0;
 wire [9:0] value;integer cases=0,changes=0,last=-1;
 demo_fps_period #(.CLOCK_HZ(30000)) dut(.clk(clk),.rstn(rstn),.frame_done(event_done),.fps_x10(value));
 task ticks(input integer n);repeat(n)@(negedge clk);endtask
 task pulse;begin event_done=1;ticks(1);event_done=0;end endtask
 task check(input integer expected);
 begin ticks(40);if(value!==expected)$fatal(1,"decimal FPS got%0d expected%0d",value,expected);
 if(last!=-1&&last!=value)changes=changes+1;last=value;cases=cases+1;
 $display("DECIMAL_FPS_SAMPLE x10=%0d",value);end endtask
 task measure(input integer period,expected);
 integer i;begin
 rstn=0;ticks(3);rstn=1;ticks(2);pulse();
 for(i=0;i<8;i=i+1)begin ticks(period-1);pulse();end
 check(expected);
 end endtask
 initial begin
 measure(1000,300);measure(1003,299);measure(1011,297);measure(1080,278);
 // Eight equal intervals with an already active running meter.
 // The 40 cycles spent checking are included in the first interval.
 ticks(1200-41);pulse();repeat(7)begin ticks(1199);pulse();end check(250);
 ticks(30000);if(value!==0)$fatal(1,"stop must show0.0 within one second");
 // Restart must acquire a fresh complete window, with no stale interval.
 pulse();repeat(8)begin ticks(999);pulse();end check(300);
 measure(50,999);
 if(changes<5)$fatal(1,"constant FPS output");
 $display("DECIMAL_FPS PASS cases=%0d changed_values=%0d measured_intervals=8 rounding=nearest_tenth stop_zero=1 restart=1 saturate=99.9",cases,changes);$finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule
