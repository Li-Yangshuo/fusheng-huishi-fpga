
 integer net_checks=0,net_frames_l=0,net_frames_r=0,net_packets_dumped=0;
 reg [23:0] net_expected;integer net_fd;reg net_last_en=0;
 initial net_fd=$fopen("integrated_ethernet.hex","w");
 always @(negedge net_rxc)begin
 if(net_tx_en&&net_packets_dumped<720)$fwrite(net_fd,"%02x",net_tx_data);
 if(!net_tx_en&&net_last_en)begin
 if(net_packets_dumped<720)$fwrite(net_fd,"\n");
 net_packets_dumped=net_packets_dumped+1;
 end
 net_last_en=net_tx_en;
 end
 always @(negedge hdmi_tx_slow_clk)if(ready)begin
 if(net_lv)begin
 net_expected=expected_image(net_lx,net_y,0);
 net_expected={reference_lift(net_expected[23:16]),reference_lift(net_expected[15:8]),reference_lift(net_expected[7:0])};
 if(net_lr!==net_expected)$fatal(1,"network left tap mismatch %d %d",net_lx,net_y);
 net_checks=net_checks+1;if(net_lx==639&&net_y==359)net_frames_l=net_frames_l+1;
 end
 if(net_rv)begin
 net_expected=expected_image(net_rx,net_y,1);
 net_expected={reference_lift(net_expected[23:16]),reference_lift(net_expected[15:8]),reference_lift(net_expected[7:0])};
 if(net_rr!==net_expected)$fatal(1,"network right tap mismatch %d %d",net_rx,net_y);
 net_checks=net_checks+1;if(net_rx==639&&net_y==359)net_frames_r=net_frames_r+1;
 end
 end
 reg [11:0] dx3,dy3;reg [23:0] raw_delay;
 integer frames=0,raw_checks=0,sync_checks=0,bottom_checks=0;reg seen250=0,seen300=0,seen333=0;
 always @(posedge hdmi_tx_slow_clk)if(diag_rstn)begin if(fps_pix==250)seen250<=1;if(fps_pix==300)seen300<=1;if(fps_pix==333)seen333<=1;end
 integer style_coverage[0:2][0:3];integer coverage[0:3];reg [1:0] frame_mode=0,last_mode=0;
 reg [2:0] ed=0,eh=0,ev=0;
 always @(posedge hdmi_tx_slow_clk)begin ed<={ed[1:0],de};eh<={eh[1:0],hs};ev<={ev[1:0],vs};end
 function automatic [23:0] expected_image(input integer x,y,input bit ink);
 reg [7:0] xx,yy;
 begin xx=x;yy=y;
 expected_image=ink?(right_fixture.style_q==2?{(8'hff^xx),(xx^yy),(8'hff^yy)}:right_fixture.style_q==1?{(xx^yy),yy,xx}:{yy,(8'h80|{1'b0,xx[6:0]}),(xx+yy)}):{(8'h40|{2'd0,xx[5:0]}),yy,(xx^yy)};
 end endfunction
 function automatic [7:0] reference_lift(input [7:0] c);
  integer value;
  begin value=c;reference_lift=value+((value<128?value:255-value)/4);end
 endfunction
 function automatic [7:0] reference_screen(input [7:0] c);
  integer value;
  begin value=c;reference_screen=value+((value<128?value:255-value)/2);end
 endfunction
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
 raw_checks=raw_checks+1;coverage[mode_pix]=coverage[mode_pix]+1;style_coverage[right_fixture.style_q][mode_pix]=style_coverage[right_fixture.style_q][mode_pix]+1;
 ink_pixel=(mode_pix==2)||((mode_pix==1||mode_pix==3)&&dx2>=640);
 if(mode_pix==3)exp_rgb=expected_image(dx2%640,dy2/2,ink_pixel);
 else exp_rgb=expected_image(dx2/2,dy2/2,ink_pixel);
 exp_rgb={reference_screen(exp_rgb[23:16]),reference_screen(exp_rgb[15:8]),reference_screen(exp_rgb[7:0])};
 if(hdmi_rgb!==exp_rgb)$fatal(1,"display mismatch frame%0d mode%0d x%0d y%0d got%h expected%h U%0d/%0d",frames,mode_pix,dx2,dy2,hdmi_rgb,exp_rgb,display.l_under,display.r_under);
 if(dy2==719)bottom_checks=bottom_checks+1;
 end
 if(osd_de&&!(dx3>=8&&dx3<152&&dy3>=8&&dy3<56)&&osd_rgb!==raw_delay)$fatal(1,"unexpected overlay outside data box");
 end
 end
 always @(posedge hdmi_tx_slow_clk)begin dx3<=dx2;dy3<=dy2;raw_delay<=hdmi_rgb;end
 task press_key;
 begin i_view_key_n=0;repeat(40)@(negedge core_clk);i_view_key_n=1;repeat(40)@(negedge core_clk);end endtask
 task press_style(input bit backup);
 begin if(backup)i_style_alt_key_n=0;else i_style_key_n=0;repeat(40)@(negedge core_clk);if(backup)i_style_alt_key_n=1;else i_style_key_n=1;repeat(40)@(negedge core_clk);end endtask
 integer sm,mm;
 initial begin
 for(sm=0;sm<3;sm=sm+1)for(mm=0;mm<4;mm=mm+1)style_coverage[sm][mm]=0;
 coverage[0]=0;coverage[1]=0;coverage[2]=0;coverage[3]=0;
 repeat(8)@(negedge hdmi_tx_slow_clk);i_arstn=1;cal_done=1;
 wait(diag_rstn);@(negedge hdmi_tx_slow_clk);ready=1;
 // All 12 combinations, with requests during active video.
 for(mm=0;mm<4;mm=mm+1)begin
  wait(frames==2+mm*6&&de&&py==200&&px==100);press_style(0);wait(style_mode==1);
  wait(frames==4+mm*6&&de&&py==400&&px==700);press_style(1);wait(style_mode==2);
  wait(frames==6+mm*6&&de&&py==300&&px==900);press_style(0);wait(style_mode==0);
  press_key();wait(demo_mode==((mm+1)%4));wait(mode_pix==((mm+1)%4));
 end
 wait(frames==27);repeat(200)@(negedge hdmi_tx_slow_clk);
 for(sm=0;sm<3;sm=sm+1)for(mm=0;mm<4;mm=mm+1)if(style_coverage[sm][mm]<1280*720)$fatal(1,"missing model/layout combination %0d/%0d",sm,mm);
 if(bottom_checks<16*1280)$fatal(1,"missing lower edge");
 $display("M7_SHOWCASE_GEOMETRY PASS pair_each=640x720 source_each=640x360 vertical_repeat=2 brightness_reference=independent all_styles_all_layouts=1");
 $display("DUAL_KEY_DISPLAY PASS all_12_model_layout_combinations=1 midframe_style_requests=12 key2_and_key3_alias_tested=1 layout_independent=1");
 if(display.l_under!=1||display.r_under!=1||display.l_tag||display.r_tag||display.l_srcerr||display.r_srcerr)$fatal(1,"steady-state scan errors");
 if(!(seen250&&seen300&&seen333))$fatal(1,"decimal FPS CDC values did not change");
 $display("DECIMAL_FPS_CDC PASS values=25.0,30.0,33.3 changed=1");
 $display("DEMO_DISPLAY PASS raw_pixels=%0d original=%0d same_scene_split=%0d style=%0d small_pair=%0d bottom_row_pixels=%0d frame_boundary_switch=1",raw_checks,coverage[0],coverage[1],coverage[2],coverage[3],bottom_checks);
 `ifdef WITH_ENCODER
 if(tmds_mismatch[59]!=0||all_pix[59]<16*1280*720)$fatal(1,"TMDS compare mismatch %0d of %0d",tmds_mismatch[59],all_pix[59]);
 $display("DEMO_TMDS PASS decoded_pixels=%0d mismatches=0",all_pix[59]);
 `endif
 if(net_frames_l<4||net_frames_r<4||network_video.left_drops||network_video.right_drops)$fatal(1,"network capture/drop coverage");
 $display("M7_NETWORK_TAPS PASS pixels=%0d left_frames=%0d right_frames=%0d packets=%0d zero_drops=1",net_checks,net_frames_l,net_frames_r,net_packets_dumped);
 $fclose(net_fd);
 $finish;
 end
 initial begin #600000000;$fatal(1,"display timeout");end
endmodule
