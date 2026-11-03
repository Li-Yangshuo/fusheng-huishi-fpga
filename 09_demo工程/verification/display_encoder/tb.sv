`timescale 1ns/1fs
module tb_display_chain;
 reg core_clk=0;always #5 core_clk=~core_clk;
 reg hdmi_tx_slow_clk=0;always #6.734006734 hdmi_tx_slow_clk=~hdmi_tx_slow_clk;
 reg i_arstn=0,i_pll_locked=1,pll_locked=1,user_pll_locked=1,cal_done=0,i_view_key_n=1;
 wire base_rstn=i_arstn&i_pll_locked&pll_locked&user_pll_locked;
 wire axi_rstn,pix_rstn,diag_rstn,monitor_rstn;
 ab09_reset_release diag_reset(.clk(hdmi_tx_slow_clk),.arstn(i_arstn&user_pll_locked),.rstn(diag_rstn));
 ab09_reset_release monitor_reset(.clk(core_clk),.arstn(i_arstn&i_pll_locked),.rstn(monitor_rstn));
 ab09_reset_release sys_reset(.clk(core_clk),.arstn(base_rstn&cal_done),.rstn(axi_rstn));
 ab09_reset_release pix_reset(.clk(hdmi_tx_slow_clk),.arstn(base_rstn&cal_done),.rstn(pix_rstn));
 localparam MODEL0=32'h50503031,MODEL1=32'h54493031,MODEL2=32'h544e3031;
 reg i_style_key_n=1,i_style_alt_key_n=1; wire osd_enable=1; wire [127:0] osd_cpu_text; wire [9:0] ink_fps_x10;

assign osd_cpu_text[63:0]=64'h3032375830383231;
assign osd_cpu_text[95:64]=32'h3a535046;
assign osd_cpu_text[103:96]=8'd48+ink_fps_x10/100;
assign osd_cpu_text[111:104]=8'd48+(ink_fps_x10/10)%10;
assign osd_cpu_text[119:112]=8'h2e; assign osd_cpu_text[127:120]=8'd48+ink_fps_x10%10;
wire [1:0] demo_mode,style_mode;wire key_sync,key_press,style_key_sync,style_key_press;
demo_key key_control(.clk(core_clk),.rstn(axi_rstn),.key_n(i_view_key_n),.mode(demo_mode),.key_sync(key_sync),.press(key_press));
demo_key #(.MODES(3)) style_key_control(.clk(core_clk),.rstn(axi_rstn),.key_n(i_style_key_n&i_style_alt_key_n),.mode(style_mode),.key_sync(style_key_sync),.press(style_key_press));
wire [31:0] active_model=style_mode==1?MODEL1:style_mode==2?MODEL2:MODEL0;
 defparam key_control.DEBOUNCE_CYCLES=10; defparam style_key_control.DEBOUNCE_CYCLES=10;

 reg [3:0] net_rxd_hi=0,net_rxd_lo=0;reg net_rx_dv_hi=0,net_rx_dv_lo=0;
 reg net_rxc=0;always #4 net_rxc=~net_rxc;wire net_phy_rst_n,net_tx_en_hi,net_tx_en_lo,net_txc_hi,net_txc_lo;wire [3:0] net_txd_hi,net_txd_lo;
 wire left_pixel_valid,right_pixel_valid,left_pixel_ready,right_pixel_ready;
 wire [23:0] left_pixel_rgb,right_pixel_rgb;
 wire [31:0] left_pixel_frame_id,right_pixel_frame_id,right_pixel_model;
 wire [10:0] left_pixel_x,right_pixel_x;wire [9:0] left_pixel_y,right_pixel_y;
 wire left_pixel_sof,left_pixel_eol,left_pixel_eof,right_pixel_sof,right_pixel_eol,right_pixel_eof;
 wire left_boundary,right_boundary,snapshot_busy,snapshot_valid;wire [639:0] snapshot_data;
 wire snapshot_request=0,cam_valid=0,cam_eof=0;
 reg nn_result_valid=0;integer fps_event_ticks=0;
 always @(posedge core_clk)begin
  nn_result_valid<=0;
  if(!axi_rstn)fps_event_ticks<=0;else if(fps_event_ticks>=(demo_mode==0?33332:demo_mode==1?39999:29999))begin fps_event_ticks<=0;nn_result_valid<=1;end else fps_event_ticks<=fps_event_ticks+1;
 end
 defparam fps_meter.CLOCK_HZ=1000000;
 wire [31:0] nn_result_model=active_model;wire [7:0] camera_fps_measured,nn_fps_measured;
 reg ready=0;wire [1:0] source_ink=style_mode;
hdmi_source_fixture #(.RIGHT(0)) left_fixture(.style(source_ink),.model(),.clk(core_clk),.rstn(axi_rstn),.boundary(left_boundary),.ready(left_pixel_ready),
 .valid(left_pixel_valid),.rgb(left_pixel_rgb),.frame_id(left_pixel_frame_id),.x(left_pixel_x),.y(left_pixel_y),.sof(left_pixel_sof),.eol(left_pixel_eol),.eof(left_pixel_eof));
hdmi_source_fixture #(.RIGHT(1)) right_fixture(.style(source_ink),.model(right_pixel_model),.clk(core_clk),.rstn(axi_rstn),.boundary(right_boundary),.ready(right_pixel_ready),
 .valid(right_pixel_valid),.rgb(right_pixel_rgb),.frame_id(right_pixel_frame_id),.x(right_pixel_x),.y(right_pixel_y),.sof(right_pixel_sof),.eol(right_pixel_eol),.eof(right_pixel_eof));
wire fs,hs,vs,de;wire[11:0] px,py;
wire[23:0] hdmi_rgb;wire hdmi_hs,hdmi_vs,hdmi_de;
ab05_hdmi_timing #(.H_ACTIVE(1280),.H_FP(110),.H_SYNC(40),.H_BP(220),.V_ACTIVE(720),.V_FP(5),.V_SYNC(5),.V_BP(20)) timing(
 .pix_clk(hdmi_tx_slow_clk),.pix_rstn(diag_rstn),.frame_start(fs),.hs(hs),.vs(vs),.de(de),.x(px),.y(py));
wire [1:0] mode_sync;
reg [1:0] mode_pix;
ab09_fps_cdc #(.WIDTH(2)) mode_cdc(.sclk(core_clk),.srstn(axi_rstn),.sdata(demo_mode),.dclk(hdmi_tx_slow_clk),.drstn(diag_rstn),.ddata(mode_sync));
always @(posedge hdmi_tx_slow_clk or negedge diag_rstn)
 if(!diag_rstn)mode_pix<=0;else if(fs)mode_pix<=mode_sync;
wire net_lv,net_rv;wire [23:0] net_lr,net_rr;wire [9:0] net_lx,net_rx;wire [8:0] net_y;
wire [31:0] net_lid,net_rid;
wire [31:0] tagged_right_id={(right_pixel_model==MODEL0||right_pixel_model==MODEL1||right_pixel_model==MODEL2),right_pixel_frame_id[30:0]};
ab05_dual_preview_hdmi #(.VIEW_W(640),.VIEW_H(360),.ACTIVE_W(1280),.ACTIVE_H(720),.X0(0),.Y0(0),.MIN_START_PIXELS(640)) display(
 .axi_clk(core_clk),.axi_rstn(axi_rstn),.pix_clk(hdmi_tx_slow_clk),.pix_rstn(pix_rstn),.demo_mode(mode_pix),
 .frame_start(fs),.pix_hs(hs),.pix_vs(vs),.pix_de(de),.pix_x(px),.pix_y(py),
 .left_pixel_valid(left_pixel_valid),.left_pixel_ready(left_pixel_ready),.left_pixel_rgb(left_pixel_rgb),.left_pixel_frame_id(left_pixel_frame_id),.left_pixel_x(left_pixel_x),.left_pixel_y(left_pixel_y),.left_pixel_sof(left_pixel_sof),.left_pixel_eol(left_pixel_eol),.left_pixel_eof(left_pixel_eof),
 .right_pixel_valid(right_pixel_valid),.right_pixel_ready(right_pixel_ready),.right_pixel_rgb(right_pixel_rgb),.right_pixel_frame_id(tagged_right_id),.right_pixel_x(right_pixel_x),.right_pixel_y(right_pixel_y),.right_pixel_sof(right_pixel_sof),.right_pixel_eol(right_pixel_eol),.right_pixel_eof(right_pixel_eof),
 .left_boundary(left_boundary),.right_boundary(right_boundary),.hdmi_rgb(hdmi_rgb),.hdmi_hs(hdmi_hs),.hdmi_vs(hdmi_vs),.hdmi_de(hdmi_de),
 .left_display_frame_id(),.right_display_frame_id(),.left_fifo_high_water(),.right_fifo_high_water(),.left_pix_available(),.right_pix_available(),
 .snapshot_request(snapshot_request),.snapshot_busy(snapshot_busy),.snapshot_valid(snapshot_valid),.snapshot_data(snapshot_data),
 .net_lv(net_lv),.net_rv(net_rv),.net_lr(net_lr),.net_rr(net_rr),.net_lx(net_lx),.net_rx(net_rx),.net_y(net_y),.net_lid(net_lid),.net_rid(net_rid));
// PHY straps select gigabit autonegotiation; no MDIO override in this experiment.
reg [21:0] net_powerup;
always @(posedge core_clk or negedge i_arstn)
 if(!i_arstn)net_powerup<=0;else if(!(&net_powerup))net_powerup<=net_powerup+1;
assign net_phy_rst_n=&net_powerup;
wire net_arst=!(net_phy_rst_n&&pix_rstn);
(* async_reg="true" *) reg [1:0] net_prun,net_trun;
always @(posedge hdmi_tx_slow_clk or posedge net_arst)
 if(net_arst)net_prun<=0;else net_prun<={net_prun[0],1'b1};
always @(posedge net_rxc or posedge net_arst)
 if(net_arst)net_trun<=0;else net_trun<={net_trun[0],1'b1};
wire [7:0] net_tx_data;wire net_tx_en;
// Official Ti60 DDR input alignment: previous HI is low nibble, current LO is high nibble.
reg [3:0] net_rx_hi_q;reg net_rx_dv_hi_q;
always @(posedge net_rxc)begin net_rx_hi_q<=net_rxd_hi;net_rx_dv_hi_q<=net_rx_dv_hi;end
wire [31:0] rx_command_seq;wire [1:0] rx_command_style;
m7_control_rx control_rx(.clk(net_rxc),.rstn(net_trun[1]),.dv(net_rx_dv_lo),
 .err(net_rx_dv_lo^net_rx_dv_hi_q),.data({net_rxd_lo,net_rx_hi_q}),
 .sequence_id(rx_command_seq),.style(rx_command_style),.accepted(),.rejected());
ab09_fps_cdc #(.WIDTH(34)) remote_control_cdc(.sclk(net_rxc),.srstn(net_trun[1]),
 .sdata({rx_command_seq,rx_command_style}),.dclk(core_clk),.drstn(axi_rstn),.ddata(remote_command_core));
reg [7:0] committed_style;
always @(posedge core_clk or negedge axi_rstn)
 if(!axi_rstn)committed_style<=255;
 else if(nn_result_valid)committed_style<=nn_result_model==MODEL1?1:nn_result_model==MODEL2?2:0;
wire [41:0] net_control_status;
ab09_fps_cdc #(.WIDTH(42)) control_status_cdc(.sclk(core_clk),.srstn(axi_rstn),
 .sdata({applied_seq,style_mode,committed_style}),.dclk(net_rxc),.drstn(net_trun[1]),.ddata(net_control_status));
m7_udp_video network_video(.control_sequence(net_control_status[41:10]),.selected_style(net_control_status[9:8]),
 .committed_style(net_control_status[7:0]),.pclk(hdmi_tx_slow_clk),.prstn(net_prun[1]),.tclk(net_rxc),.trstn(net_trun[1]),
 .lvalid(net_lv),.rvalid(net_rv),.lx(net_lx),.rx(net_rx),.ly(net_y),.ry(net_y),.lrgb(net_lr),.rrgb(net_rr),.lfid(net_lid),.rfid(net_rid),
 .tx_data(net_tx_data),.tx_en(net_tx_en),.packets_sent(),.left_drops(),.right_drops());
assign net_txd_hi=net_tx_data[3:0];assign net_txd_lo=net_tx_data[7:4];
assign net_tx_en_hi=net_tx_en;assign net_tx_en_lo=net_tx_en;
assign net_txc_hi=1'b1;assign net_txc_lo=1'b0;
wire [7:0] cam_fps,pp_fps,ink_fps;wire [9:0] fps_pix;
demo_fps fps_meter(.clk(core_clk),.rstn(axi_rstn),.camera_eof(cam_valid&&cam_eof),.pp_done(nn_result_valid&&nn_result_model==MODEL0),.ink_done(nn_result_valid&&(nn_result_model==MODEL0||nn_result_model==MODEL1||nn_result_model==MODEL2)),.cam_fps(cam_fps),.pp_fps(pp_fps),.ink_fps(ink_fps),.ink_fps_x10(ink_fps_x10));
assign camera_fps_measured=cam_fps;assign nn_fps_measured=ink_fps;
ab09_fps_cdc #(.WIDTH(10)) fps_cdc(.sclk(core_clk),.srstn(axi_rstn),.sdata(ink_fps_x10),.dclk(hdmi_tx_slow_clk),.drstn(diag_rstn),.ddata(fps_pix));
reg [11:0] dx1,dy1,dx2,dy2;reg fs1,fs2;
always @(posedge hdmi_tx_slow_clk or negedge diag_rstn)
 if(!diag_rstn)begin dx1<=0;dy1<=0;dx2<=0;dy2<=0;fs1<=0;fs2<=0;end
 else begin dx1<=px;dy1<=py;dx2<=dx1;dy2<=dy1;fs1<=fs;fs2<=fs1;end
wire osd_enable_pix;wire [127:0] osd_cpu_text_pix;
 ab09_fps_cdc #(.WIDTH(129)) osd_enable_cdc(.sclk(core_clk),.srstn(axi_rstn),.sdata({osd_enable,osd_cpu_text}),
 .dclk(hdmi_tx_slow_clk),.drstn(diag_rstn),.ddata({osd_enable_pix,osd_cpu_text_pix}));
 wire [23:0] osd_rgb;wire osd_de,osd_hs,osd_vs;
demo_osd #(.CPU_TEXT(1)) osd(.clk(hdmi_tx_slow_clk),.rstn(diag_rstn),.frame_start(fs2),.x(dx2),.y(dy2),.de(hdmi_de),.hs(hdmi_hs),.vs(hdmi_vs),.rgb(hdmi_rgb),
 .enable(osd_enable_pix),.cpu_text(osd_cpu_text_pix),.fps(fps_pix),.o_rgb(osd_rgb),.o_de(osd_de),.o_hs(osd_hs),.o_vs(osd_vs));
wire[9:0] tmds_data0,tmds_data1,tmds_data2,tmds_clk;
dvi_encoder hdmi(.pixelclk(hdmi_tx_slow_clk),.rst_p(!diag_rstn),.i_bdata(osd_rgb[7:0]),.i_gdata(osd_rgb[15:8]),.i_rdata(osd_rgb[23:16]),.i_de(osd_de),.i_hs(osd_hs),.i_vs(osd_vs),.video_format(2'd0),.video_VIC(7'd4),
 .audio_L(24'd0),.audio_R(24'd0),.audio_valid(1'b0),.audio_N(20'd6144),.audio_CTS(20'd74250),.audio_sample_frequency(3'd2),.audio_word_length(4'd11),.tmds_data0(tmds_data0),.tmds_data1(tmds_data1),.tmds_data2(tmds_data2),.tmds_clk(tmds_clk));
 reg [23:0] rgb_delay [0:63];reg de_delay[0:63];integer q,p;
 integer tmds_pixels=0,tmds_mismatch[57:60],all_pix[57:60];
 function [7:0] td(input [9:0] t);
 reg [7:0] bits8;
 begin bits8=t[9]?~t[7:0]:t[7:0];td[0]=bits8[0];td[7:1]=t[8]?(bits8[7:1]^bits8[6:0]):~(bits8[7:1]^bits8[6:0]);end
 endfunction
 reg [23:0] tmds_decoded;
 initial begin for(q=0;q<64;q=q+1)begin rgb_delay[q]=0;de_delay[q]=0;end for(q=57;q<61;q=q+1)begin tmds_mismatch[q]=0;all_pix[q]=0;end end
 always @(negedge hdmi_tx_slow_clk) begin
  for(p=63;p>0;p=p-1)begin rgb_delay[p]=rgb_delay[p-1];de_delay[p]=de_delay[p-1];end
  rgb_delay[0]=osd_rgb;de_delay[0]=osd_de;
  tmds_decoded={td(tmds_data2),td(tmds_data1),td(tmds_data0)};
  if(ready)begin
   for(p=57;p<61;p=p+1)if(de_delay[p])begin
    all_pix[p]=all_pix[p]+1;
    if(tmds_decoded!==rgb_delay[p])begin
     tmds_mismatch[p]=tmds_mismatch[p]+1;
     if(tmds_mismatch[p]<=2)$display("TMDS_MISMATCH latency=%0d pixel=%0d encoded=%h%h%h decoded=%h%h%h expected=%h",p,all_pix[p],tmds_data2,tmds_data1,tmds_data0,td(tmds_data2),td(tmds_data1),td(tmds_data0),rgb_delay[p]);
    end
   end
  end
 end

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
