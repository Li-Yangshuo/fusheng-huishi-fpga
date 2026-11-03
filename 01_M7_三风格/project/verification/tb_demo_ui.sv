`timescale 1ns/1ps
module tb_key_fps;
 reg clk=0;always #5 clk=~clk;reg rstn=0,key_n=1;wire [1:0] mode;wire press;
 demo_key #(.DEBOUNCE_CYCLES(8)) key_control(.clk(clk),.rstn(rstn),.key_n(key_n),.mode(mode),.press(press),.key_sync());
 integer presses=0,i,t;always @(negedge clk)if(press)presses=presses+1;
 task ticks(input integer n);repeat(n)@(negedge clk);endtask
 reg ce=0,pp=0,ink=0;wire [7:0] cf,pf,inf;reg [7:0] c=0,p=0,k=0;
 demo_fps #(.CLOCK_HZ(100)) meter(.clk(clk),.rstn(rstn),.camera_eof(ce),.pp_done(pp),.ink_done(ink),.cam_fps(cf),.pp_fps(pf),.ink_fps(inf));
 initial begin ticks(3);rstn=1;ticks(3);
 for(i=0;i<8;i=i+1)begin
 key_n=0;ticks(2);key_n=1;ticks(4);if(mode!==i%4)$fatal(1,"bounce changed mode");
 key_n=0;ticks(16);if(mode!==(i+1)%4)$fatal(1,"press failed");ticks(30);if(presses!=i+1)$fatal(1,"held key retriggered");
 key_n=1;ticks(2);key_n=0;ticks(4);key_n=1;ticks(16);
 end
 rstn=0;ticks(3);if(mode!==0)$fatal(1,"reset mode");rstn=1;
 for(t=0;t<500;t=t+1)begin
 ce=t%3==0;pp=t%5==0;ink=t%7==0;c=c+ce;p=p+pp;k=k+ink;ticks(1);
 if(t%100==99)begin if(cf!==c||pf!==p||inf!==k)$fatal(1,"FPS window expected %0d/%0d/%0d got %0d/%0d/%0d",c,p,k,cf,pf,inf);c=0;p=0;k=0;end
 end
 $display("DEMO_UI PASS debounce_bounce_hold_release_cycle_reset=1 fps_windows=5");$finish;
 end
endmodule
module tb_osd;
 reg clk=0;always #5 clk=~clk;reg rstn=0,fs=0;reg [11:0] x=0,y=0;reg de=0,hs=0,vs=0;reg [9:0] fps=0;
 wire [23:0] rgb;wire od,oh,ov;reg [23:0] expected[0:230399];integer f,n,outfile;integer values[0:3];
 demo_osd dut(.clk(clk),.rstn(rstn),.frame_start(fs),.x(x),.y(y),.de(de),.hs(hs),.vs(vs),.rgb(24'h335577),.fps(fps),.o_rgb(rgb),.o_de(od),.o_hs(oh),.o_vs(ov));
 initial begin
 $readmemh("osd_expected.hex",expected);outfile=$fopen("osd_actual.hex","w");values[0]=298;values[1]=301;values[2]=0;values[3]=1023;
 repeat(3)@(negedge clk);rstn=1;
 for(f=0;f<4;f=f+1)begin fps=values[f];fs=1;@(negedge clk);fs=0;fps=530;
 for(n=0;n<160*360;n=n+1)begin x=n%360;y=n/360;de=1;hs=n%5==0;vs=n%7==0;
 @(negedge clk);if(rgb!==expected[f*57600+n]||od!==de||oh!==hs||ov!==vs)$fatal(1,"OSD RGB/sync f%0d x%0d y%0d got%h expected%h",f,x,y,rgb,expected[f*57600+n]);$fdisplay(outfile,"%06h",rgb);
 end end
 $fclose(outfile);$display("DEMO_OSD PASS pixels=230400 only_resolution_and_frame_latched_FPS=1");$finish;
 end
endmodule
