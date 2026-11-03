// Non-overlapping one-second windows in the real 100MHz service clock.
// NN uses successful unique result commits, not HDMI refresh or busy cycles.
module pp2_fps_meter #(parameter CLOCK_HZ=100000000)(
 input wire clk,rstn,camera_eof,input wire [31:0] nn_commits,
 output reg [7:0] camera_fps,nn_fps
);
 localparam CW=CLOCK_HZ<2?1:$clog2(CLOCK_HZ);
 reg [CW-1:0] ticks;reg [8:0] camera_count;reg [31:0] previous_nn;
 wire [8:0] camera_next=camera_count+(camera_eof?9'd1:9'd0);
 wire [31:0] nn_delta=nn_commits-previous_nn;
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin ticks<=0;camera_count<=0;previous_nn<=0;camera_fps<=0;nn_fps<=0;end
  else if(ticks==CLOCK_HZ-1)begin
   ticks<=0;camera_count<=0;previous_nn<=nn_commits;
   camera_fps<=camera_next>255?8'd255:camera_next[7:0];
   nn_fps<=nn_delta>255?8'd255:nn_delta[7:0];
  end else begin ticks<=ticks+1'b1;if(camera_eof&&camera_count<255)camera_count<=camera_count+1'b1;end
 end
endmodule
