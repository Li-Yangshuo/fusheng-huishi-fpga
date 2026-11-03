`timescale 1ns/1ps
module tb;
 reg clk=0,rstn=0;always #5 clk=~clk;
 reg v=0,sof=0,eol=0,eof=0;reg [23:0] rgb=0;reg [31:0] fid=0;
 wire ov,os,ol,oe;wire [23:0] orgb;wire [31:0] oid;wire [11:0] gr,gg,gb;wire calibrated;wire [19:0] samples;
 pp2_white_balance dut(.clk(clk),.rstn(rstn),.i_valid(v),.i_sof(sof),.i_eol(eol),.i_eof(eof),.i_rgb(rgb),.i_frame_id(fid),
 .o_valid(ov),.o_sof(os),.o_eol(ol),.o_eof(oe),.o_rgb(orgb),.o_frame_id(oid),.gain_r_q8(gr),.gain_g_q8(gg),.gain_b_q8(gb),.calibrated(calibrated),.last_sample_count(samples));
 localparam N=3072,FRAMES=12;
 reg [23:0] inputs[0:N*FRAMES-1],expected[0:N*FRAMES-1];reg [11:0] gains_r[0:FRAMES-1],gains_b[0:FRAMES-1];
 reg [19:0] counts[0:FRAMES-1];
 integer sent=0,checked=0,f,p,cycle=0;
 reg [31:0] rng=32'h12345678;
 always @(posedge clk)begin
  cycle=cycle+1;
  if(rstn)begin
   #1;
   if(ov)begin
    if(orgb!==expected[checked]||oid!=checked/N+1||os!=(checked%N==0)||ol!=(checked%64==63)||oe!=(checked%N==N-1))$fatal(1,"WB pixel/marks mismatch %0d got%h expect%h",checked,orgb,expected[checked]);
    if(gr!==gains_r[checked/N]||gb!==gains_b[checked/N]||gg!=256)$fatal(1,"WB gain mismatch frame%0d R%0d B%0d expected%0d/%0d",checked/N,gr,gb,gains_r[checked/N],gains_b[checked/N]);
    checked=checked+1;
   end
  end
 end
 task idle;
  begin v=0;sof=0;eol=0;eof=0;@(negedge clk);end
 endtask
 initial begin
  $readmemh("color_inputs.hex",inputs);$readmemh("color_expected.hex",expected);$readmemh("color_r.hex",gains_r);$readmemh("color_b.hex",gains_b);$readmemh("color_counts.hex",counts);
  repeat(5)@(negedge clk);rstn=1;
  for(f=0;f<FRAMES;f=f+1)begin
   for(p=0;p<N;p=p+1)begin
    rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
    if(rng[2:0]==0)idle();
    v=1;sof=p==0;eol=p%64==63;eof=p==N-1;rgb=inputs[sent];fid=f+1;sent=sent+1;@(negedge clk);
   end
   repeat(100)idle();
   if(samples!=counts[f])$fatal(1,"Sample count frame%0d got%0d expected%0d",f,samples,counts[f]);
  end
  repeat(4)idle();if(checked!=N*FRAMES)$fatal(1,"WB missing pixels");
  rstn=0;repeat(3)@(negedge clk);rstn=1;repeat(3)@(negedge clk);
  if(calibrated||gr!=256||gb!=256||ov)$fatal(1,"WB reset recovery");
  $display("COLOR_FPS_WB PASS frames=%0d pixels=%0d exact_RGB_marks_ID_gain_boundary_reset=1",FRAMES,checked);$finish;
 end
 initial begin #10000000;$fatal(1,"WB timeout");end
endmodule

module tb_fps;
 reg clk=0,rstn=0,cam=0;always #5 clk=~clk;reg [31:0] commits=0;
 wire [7:0] cf,nf;
 pp2_fps_meter #(.CLOCK_HZ(100)) dut(.clk(clk),.rstn(rstn),.camera_eof(cam),.nn_commits(commits),.camera_fps(cf),.nn_fps(nf));
 integer w,k,checks=0;reg[31:0] base;
 initial begin
  repeat(3)@(negedge clk);rstn=1;
  for(w=0;w<5;w=w+1)begin
   base=commits;
   for(k=0;k<100;k=k+1)begin
    cam=(w==0||w==1)?k%10==9:w==3?1:0;
    if(w==0&&k%20==19)commits=commits+1;
    if(w==1&&k==99)commits=commits+1;
    if(w==3&&k==99)commits=commits+300;
    if(w==4&&k==99)commits=commits+32'hffffffff;
    @(negedge clk);
   end
   if(cf!==((w==0||w==1)?10:w==3?100:0)||nf!==(w==0?5:w==1?1:w==3||w==4?255:0))$fatal(1,"FPS window%0d CAM%0d NN%0d",w,cf,nf);
   checks=checks+1;
  end
  rstn=0;@(negedge clk);if(cf||nf)$fatal(1,"FPS reset");
  $display("COLOR_FPS_METER PASS windows=%0d window_boundary_zero_stop_overflow_reset=1",checks);$finish;
 end
endmodule
