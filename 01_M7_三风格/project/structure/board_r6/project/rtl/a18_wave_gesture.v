// A18.9: local horizontal out-and-back motion, not a learned hand classifier.
// Observe the existing 640x480 sparse DE stream; never backpressure video/DDR.
// Coordinates advance on valid pixels, not on gaps within a preproc output line.
module a18_wave_sequence #(
 parameter integer MIN_MOTION=10,MAX_MOTION=500,MAX_GLOBAL=1200,
 parameter integer LEFT_X=27,RIGHT_X=36,WINDOW_FRAMES=45,
 parameter integer QUIET_FRAMES=6,COOL_FRAMES=45
)(
 input wire clk,rstn,frame_tick,frame_good,
 input wire [11:0] motion_count,global_count,input wire [17:0] sum_x,
 output reg wave_pulse,wave_toggle,output reg [31:0] wave_count,
 output reg armed,output reg [1:0] stage,output wire [1:0] zone,
 output reg [5:0] cooldown
);
 reg first_right;reg [5:0] age,quiet_count;
 wire local_motion=motion_count>=MIN_MOTION&&motion_count<=MAX_MOTION&&global_count<=MAX_GLOBAL;
 wire broad_motion=motion_count>MAX_MOTION||global_count>MAX_GLOBAL;
 wire [23:0] moment={6'd0,sum_x};
 wire [23:0] left_limit={12'd0,motion_count}*LEFT_X;
 wire [23:0] right_limit={12'd0,motion_count}*RIGHT_X;
 assign zone=!local_motion?2'd0:moment<=left_limit?2'd1:moment>=right_limit?2'd2:2'd0;
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin wave_pulse<=0;wave_toggle<=0;wave_count<=0;armed<=0;stage<=0;first_right<=0;age<=0;quiet_count<=0;cooldown<=0;end
  else begin
   wave_pulse<=0;
   if(frame_tick)begin
    if(cooldown!=0)cooldown<=cooldown-1'b1;
    if(!frame_good||broad_motion)begin stage<=0;age<=0;quiet_count<=0;armed<=0;end
    else if(!armed)begin
     stage<=0;age<=0;
     // No automatic re-trigger during uninterrupted waving: both quiet and cooldown required.
     if(cooldown==0&&global_count<=4)begin
      if(quiet_count>=QUIET_FRAMES-1)begin armed<=1;quiet_count<=0;end
      else quiet_count<=quiet_count+1'b1;
     end else quiet_count<=0;
    end else if(stage==0)begin
     age<=0;
     if(zone!=0)begin stage<=1;first_right<=zone==2;end
    end else if(age>=WINDOW_FRAMES-1)begin stage<=0;age<=0;end
    else begin
     age<=age+1'b1;
     if(stage==1&&zone==(first_right?2'd1:2'd2))stage<=2;
     else if(stage==2&&zone==(first_right?2'd2:2'd1))begin
      wave_pulse<=1;wave_toggle<=~wave_toggle;wave_count<=wave_count+1'b1;
      stage<=0;age<=0;armed<=0;quiet_count<=0;cooldown<=COOL_FRAMES;
     end
    end
   end
  end
 end
endmodule

module a18_wave_gesture #(
 parameter integer IN_W=640,IN_H=480,DS=10,
 parameter integer DIFF_THRESHOLD=20,QUIET_FRAMES=6,COOL_FRAMES=45
)(
 input wire clk,rstn,in_de,in_sof,input wire [23:0] din,
 output wire wave_pulse,wave_toggle,output wire [31:0] wave_count,
 output wire [31:0] debug_motion,debug_status,output reg [31:0] geometry_errors
);
 // Supported grid: 64x48. Address row stride is 64 (power of two).
 reg [9:0] x;reg [8:0] y;reg [3:0] xd,yd;reg [5:0] gx,gy;
 wire sample=in_de&&(in_sof||(xd==0&&yd==0));
 wire [11:0] addr=in_sof?12'd0:{gy,gx};
 wire [7:0] gray={2'd0,din[23:18]}+{1'b0,din[15:9]}+{2'd0,din[7:2]};
 reg pending;reg [11:0] addr_d;reg [7:0] gray_d;wire [7:0] prev;
 simple_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(12),.OUTPUT_REG("FALSE")) history(
  .wclk(clk),.we(pending),.waddr(addr_d),.wdata(gray_d),.rclk(clk),.re(sample),.raddr(addr),.rdata(prev));
 reg have_sof,compare_ready;
 reg [18:0] pixels;reg [12:0] samples;
 reg [11:0] motion,global_motion;reg [17:0] sx;
 reg frame_tick,good;reg [11:0] motion_latched,global_latched;reg [17:0] sx_latched;
 wire [7:0] delta=gray_d>prev?gray_d-prev:prev-gray_d;
 wire moved=pending&&compare_ready&&delta>DIFF_THRESHOLD;
 wire roi=addr_d[5:0]>=8&&addr_d[5:0]<56&&addr_d[11:6]>=4&&addr_d[11:6]<44;
 wire valid_geometry=have_sof&&pixels==IN_W*IN_H&&samples==3072;
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin
   x<=0;y<=0;xd<=0;yd<=0;gx<=0;gy<=0;pending<=0;addr_d<=0;gray_d<=0;
   pixels<=0;samples<=0;have_sof<=0;compare_ready<=0;motion<=0;global_motion<=0;sx<=0;
   frame_tick<=0;good<=0;motion_latched<=0;global_latched<=0;sx_latched<=0;geometry_errors<=0;
  end else begin
   pending<=sample;addr_d<=addr;gray_d<=gray;frame_tick<=0;
   if(in_sof)begin
    frame_tick<=1;good<=valid_geometry&&compare_ready;
    if(have_sof&&!valid_geometry)geometry_errors<=geometry_errors+1'b1;
    compare_ready<=valid_geometry;
    motion_latched<=motion+((moved&&roi)?12'd1:12'd0);
    global_latched<=global_motion+(moved?12'd1:12'd0);
    sx_latched<=sx+((moved&&roi)?{12'd0,addr_d[5:0]}:18'd0);
    motion<=0;global_motion<=0;sx<=0;pixels<=in_de?19'd1:19'd0;samples<=sample?13'd1:13'd0;have_sof<=1;
    x<=in_de?10'd1:10'd0;y<=0;xd<=in_de&&DS>1?4'd1:4'd0;yd<=0;gx<=in_de?6'd1:6'd0;gy<=0;
   end else begin
    if(in_de&&have_sof)begin
     if(pixels<IN_W*IN_H+1)pixels<=pixels+1'b1;
     if(sample&&samples<4096)samples<=samples+1'b1;
     if(x==IN_W-1)begin
      x<=0;xd<=0;gx<=0;
      if(y==IN_H-1)begin y<=0;yd<=0;gy<=0;end
      else begin y<=y+1'b1;if(yd==DS-1)begin yd<=0;gy<=gy+1'b1;end else yd<=yd+1'b1;end
     end else begin
      x<=x+1'b1;if(xd==DS-1)xd<=0;else xd<=xd+1'b1;
      if(sample)gx<=gx+1'b1;
     end
    end
    if(moved)begin
     if(global_motion<4095)global_motion<=global_motion+1'b1;
     if(roi)begin if(motion<4095)motion<=motion+1'b1;sx<=sx+{12'd0,addr_d[5:0]};end
    end
   end
  end
 end
 wire armed;wire [1:0] stage,zone;wire [5:0] cooldown;
 a18_wave_sequence #(.QUIET_FRAMES(QUIET_FRAMES),.COOL_FRAMES(COOL_FRAMES)) sequence_detector(
  .clk(clk),.rstn(rstn),.frame_tick(frame_tick),.frame_good(good),.motion_count(motion_latched),.global_count(global_latched),.sum_x(sx_latched),
  .wave_pulse(wave_pulse),.wave_toggle(wave_toggle),.wave_count(wave_count),.armed(armed),.stage(stage),.zone(zone),.cooldown(cooldown));
 assign debug_motion={4'd0,global_latched,4'd0,motion_latched};
 assign debug_status={8'h89,8'd0,cooldown,armed,good,2'd0,stage,zone,2'd0};
endmodule

// Rate-limited frame-domain events cross as a level toggle, never a narrow pulse.
module a18_gesture_cdc(input wire clk,rstn,event_toggle,output wire pulse);
 (* async_reg="true" *) reg meta,sync;
 reg seen;
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin meta<=0;sync<=0;seen<=0;end
  else begin meta<=event_toggle;sync<=meta;seen<=sync;end
 end
 assign pulse=sync^seen;
endmodule
