`timescale 1ns/1ps
module tb_hdmi_timing_native;
 reg pix_clk=0,pix_rstn=0;always #1 pix_clk=~pix_clk;
 wire frame_start,hs,vs,de;wire [11:0] x,y;
 ab05_hdmi_timing dut(.*);
 integer cycles=0,act=0,hsc=0,vsc=0,frames=0;
 always @(posedge pix_clk)if(pix_rstn)begin
  if(frame_start)begin
   if(frames==1)begin
    if(cycles!=2475000||act!=2073600||hsc!=49500||vsc!=11000)$fatal(1,"native timing totals");
    $display("NATIVE_TIMING PASS cycles=%0d active=%0d hs=%0d vs=%0d",cycles,act,hsc,vsc);$finish;
   end
   frames=frames+1;
  end
  cycles=cycles+1;if(de)begin act=act+1;if(x>=1920||y>=1080)$fatal(1,"native coordinates");end
  if(hs)hsc=hsc+1;if(vs)vsc=vsc+1;
 end
 initial begin repeat(4)@(negedge pix_clk);pix_rstn=1;end
 initial begin #6000000;$fatal(1,"native timeout");end
endmodule
