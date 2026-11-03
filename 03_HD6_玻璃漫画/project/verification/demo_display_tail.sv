 reg [11:0] dx3,dy3;reg [23:0] raw_delay;
 integer frames=0,raw_checks=0,sync_checks=0,bottom_checks=0;reg seen250=0,seen300=0,seen333=0;
 always @(posedge hdmi_tx_slow_clk)if(diag_rstn)begin if(fps_pix==250)seen250<=1;if(fps_pix==300)seen300<=1;if(fps_pix==333)seen333<=1;end
 integer coverage[0:2];reg [1:0] frame_mode=0,last_mode=0;
 reg [2:0] ed=0,eh=0,ev=0;
 always @(posedge hdmi_tx_slow_clk)begin ed<={ed[1:0],de};eh<={eh[1:0],hs};ev<={ev[1:0],vs};end
 function automatic [23:0] expected_image(input integer x,y,input bit ink);
 reg [7:0] xx,yy;
 begin xx=x;yy=y;
 expected_image=ink?{(xx^yy),yy,xx}:{(8'h40|{2'd0,xx[5:0]}),yy,(xx^yy)};
 end endfunction
 reg [23:0] exp_rgb;reg ink_pixel;
 always @(negedge hdmi_tx_slow_clk)if(ready)begin
 if(fs)frames=frames+1;
 if(mode_pix!=last_mode&&!fs1)$fatal(1,"mode changed during frame");
 last_mode=mode_pix;
 if(frames>=2)begin
 sync_checks=sync_checks+1;
 if(osd_de!==ed[2]||osd_hs!==eh[2]||osd_vs!==ev[2])$fatal(1,"sync delay mismatch");
 if(hdmi_de)begin
 if(dx2==0&&dy2==0)frame_mode=mode_pix;
 if(mode_pix!==frame_mode)$fatal(1,"tearing mode");
 if(display.left_display_frame_id[30:0]!==display.right_display_frame_id[30:0])$fatal(1,"unpaired scene");
 raw_checks=raw_checks+1;coverage[mode_pix]=coverage[mode_pix]+1;
 ink_pixel=(mode_pix==2)||(mode_pix==0&&dx2>=640);
 exp_rgb=expected_image(dx2/2,dy2/2,ink_pixel);
 if(hdmi_rgb!==exp_rgb)$fatal(1,"display mismatch frame%0d mode%0d x%0d y%0d got%h expected%h U%0d/%0d",frames,mode_pix,dx2,dy2,hdmi_rgb,exp_rgb,display.l_under,display.r_under);
 if(dy2==719)bottom_checks=bottom_checks+1;
 end
 if(osd_de&&!(dx3>=8&&dx3<152&&dy3>=8&&dy3<56)&&osd_rgb!==raw_delay)$fatal(1,"unexpected overlay outside data box");
 end
 end
 always @(posedge hdmi_tx_slow_clk)begin dx3<=dx2;dy3<=dy2;raw_delay<=hdmi_rgb;end
 task press_key;
 begin i_view_key_n=0;repeat(40)@(negedge core_clk);i_view_key_n=1;repeat(40)@(negedge core_clk);end endtask
 initial begin
 coverage[0]=0;coverage[1]=0;coverage[2]=0;
 repeat(8)@(negedge hdmi_tx_slow_clk);i_arstn=1;cal_done=1;
 wait(diag_rstn);@(negedge hdmi_tx_slow_clk);ready=1;
 wait(frames==2&&de&&py==200&&px==100);press_key();wait(demo_mode==1);wait(mode_pix==1);
 wait(frames==4&&de&&py==400&&px==700);press_key();wait(demo_mode==2);wait(mode_pix==2);
 wait(frames==6&&de&&py==719&&px==1200);press_key();wait(demo_mode==0);wait(mode_pix==0);
 wait(frames==9);repeat(200)@(negedge hdmi_tx_slow_clk);
 if(coverage[0]<2*1280*720||coverage[1]<1280*720||coverage[2]<1280*720||bottom_checks<6*1280)$fatal(1,"missing three-mode or bottom row coverage");
 if(display.l_under!=1||display.r_under!=1||display.l_tag||display.r_tag||display.l_srcerr||display.r_srcerr)$fatal(1,"steady-state scan errors");
 if(!(seen250&&seen300&&seen333))$fatal(1,"decimal FPS CDC values did not change");
 $display("DECIMAL_FPS_CDC PASS values=25.0,30.0,33.3 changed=1");
 $display("DEMO_DISPLAY PASS raw_pixels=%0d split=%0d original=%0d ink=%0d bottom_row_pixels=%0d frame_boundary_switch=1",raw_checks,coverage[0],coverage[1],coverage[2],bottom_checks);
 `ifdef WITH_ENCODER
 if(tmds_mismatch[59]!=0||all_pix[59]<8*1280*720)$fatal(1,"TMDS compare mismatch %0d of %0d",tmds_mismatch[59],all_pix[59]);
 $display("DEMO_TMDS PASS decoded_pixels=%0d mismatches=0",all_pix[59]);
 `endif
 $finish;
 end
 initial begin #190000000;$fatal(1,"display timeout");end
endmodule
