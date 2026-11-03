module demo_fps #(parameter integer CLOCK_HZ=100000000)(
 input wire clk,rstn,camera_eof,pp_done,ink_done,output reg [7:0] cam_fps,pp_fps,ink_fps,output wire [9:0] ink_fps_x10);
 demo_fps_period #(.CLOCK_HZ(CLOCK_HZ)) precise(.clk(clk),.rstn(rstn),.frame_done(ink_done),.fps_x10(ink_fps_x10));
 reg [31:0] ticks;reg [7:0] c,p,i;
 function [7:0] add(input [7:0] n,input e);add=(e&&n!=255)?n+1'b1:n;endfunction
 always @(posedge clk or negedge rstn)
 if(!rstn)begin ticks<=0;c<=0;p<=0;i<=0;cam_fps<=0;pp_fps<=0;ink_fps<=0;end
 else if(ticks==CLOCK_HZ-1)begin ticks<=0;cam_fps<=add(c,camera_eof);pp_fps<=add(p,pp_done);ink_fps<=add(i,ink_done);c<=0;p<=0;i<=0;end
 else begin ticks<=ticks+1'b1;c<=add(c,camera_eof);p<=add(p,pp_done);i<=add(i,ink_done);end
endmodule

// Eight actual completed-frame intervals; rounded to nearest tenth.
// Sequential restoring divider avoids a large combinational / operator.
module demo_fps_period #(parameter integer CLOCK_HZ=100000000)(
 input wire clk,rstn,frame_done,output reg [9:0] fps_x10);
 localparam [33:0] NUMERATOR=64'd80*CLOCK_HZ;
 reg seen;reg [2:0] intervals;reg [31:0] elapsed,idle;
 reg dividing;reg [5:0] remaining;
 reg [33:0] dividend,quotient;reg [32:0] remainder;reg [31:0] divisor;
 wire [32:0] shifted={remainder[31:0],dividend[33]};
 wire subtract=shifted>={1'b0,divisor};
 wire [33:0] next_quotient={quotient[32:0],subtract};
 always @(posedge clk or negedge rstn)
 if(!rstn)begin
  seen<=0;intervals<=0;elapsed<=0;idle<=0;fps_x10<=0;
  dividing<=0;remaining<=0;dividend<=0;quotient<=0;remainder<=0;divisor<=1;
 end else begin
  if(seen)elapsed<=elapsed+1'b1;
  if(dividing)begin
   dividend<={dividend[32:0],1'b0};quotient<=next_quotient;
   remainder<=subtract?shifted-{1'b0,divisor}:shifted;
   remaining<=remaining-1'b1;
   if(remaining==1)begin dividing<=0;fps_x10<=next_quotient>999?10'd999:next_quotient[9:0];end
  end
  if(frame_done)begin
   idle<=0;
   if(!seen)begin seen<=1;intervals<=0;elapsed<=0;end
   else if(intervals==7)begin
    intervals<=0;elapsed<=0;divisor<=elapsed+1'b1;
    dividend<=NUMERATOR+((elapsed+1'b1)>>1);quotient<=0;remainder<=0;remaining<=34;dividing<=1;
   end else intervals<=intervals+1'b1;
  end else if(idle==CLOCK_HZ-1)begin
   // No complete result for one second: immediately report 0.0 and rearm.
   seen<=0;intervals<=0;elapsed<=0;fps_x10<=0;dividing<=0;
  end else idle<=idle+1'b1;
 end
endmodule
