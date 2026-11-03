`timescale 1ns/1fs
module tb_scanout_service;
 parameter STYLE=0,FRAMES=12;
 reg clk=0,rstn=0;always #5 clk=~clk;
 reg capture_valid=0,cam_valid=0,cam_sof=0,cam_eol=0,cam_eof=0;
 reg [31:0] capture_id=1,cam_frame_id=1;reg [23:0] cam_pixel=0;
 wire capture_ready,cam_armed,error;wire [7:0] oerr;wire [3:0] cerr,wd;
 wire [31:0] caps,nns,ls,rs;wire lpv,rpv;wire [23:0] lrgb,rrgb;wire [31:0] lfid,rfid;
 wire [10:0] lx,rx;wire [9:0] ly,ry;wire lsof,leol,leof,rsof,reol,reof;
 localparam MODEL0=32'h50503031,MODEL1=32'h54493031,MODEL2=32'h544e3031; wire core_clk=clk,axi_rstn=rstn; reg i_view_key_n=1,i_style_key_n=1,i_style_alt_key_n=1;
wire [1:0] demo_mode,style_mode; wire key_sync,key_press,style_key_sync,style_key_press;
demo_key key_control(.clk(core_clk),.rstn(axi_rstn),.key_n(i_view_key_n),.mode(demo_mode),.key_sync(key_sync),.press(key_press));
demo_key #(.MODES(3)) style_key_control(.clk(core_clk),.rstn(axi_rstn),.key_n(i_style_key_n&i_style_alt_key_n),.mode(style_mode),.key_sync(style_key_sync),.press(style_key_press));
wire [31:0] active_model=style_mode==1?MODEL1:style_mode==2?MODEL2:MODEL0;
 defparam key_control.DEBOUNCE_CYCLES=8; defparam style_key_control.DEBOUNCE_CYCLES=8;
 wire [31:0] cfg_model=active_model;wire [31:0] rmodel,done_model;wire done_valid;
 reg [31:0] launch_model[0:FRAMES],complete_model[0:FRAMES];integer pcount=0,icount=0,ncount=0;
 wire boundary,right_boundary,lready;
 wire right_ready;
 wire [3:0] arid,awid;wire [31:0] araddr,awaddr;wire [7:0] arlen,awlen;wire [2:0] arsize,awsize;
 wire [1:0] arburst,awburst;wire arvalid,rready,awvalid,wvalid,wlast,bready;
 reg arready=0,awready=0,wready=0,rvalid=0,rlast=0,bvalid=0;
 reg [127:0] rdata=0;reg [3:0] rid=0,bid=0;reg [1:0] rresp=0,bresp=0;
 wire [127:0] wdata;wire [15:0] wstrb;
 a_b_video_renderer_shared #(.WIDTH(1280),.HEIGHT(720),.SLOTS(4),.BB(32),.MODEL0(32'h50503031),.MODEL1(32'h54493031)) dut(
 .weight_we(1'b0),.weight_bias(1'b0),.weight_addr(6'd0),.weight_data(512'd0),.models_ready(1'b1),.axi_clk(clk),.axi_rstn(rstn),.core_clk(clk),.core_rstn(rstn),.cam_clk(clk),.cam_rstn(rstn),
 .capture_valid(capture_valid),.capture_ready(capture_ready),.capture_id(capture_id),.capture_timestamp(64'd123),
 .cam_valid(cam_valid),.cam_sof(cam_sof),.cam_eol(cam_eol),.cam_eof(cam_eof),.cam_pixel(cam_pixel),.cam_frame_id(cam_frame_id),.cam_armed(cam_armed),
 .left_boundary(boundary),.right_boundary(right_boundary),.external_fault(1'b0),.error(error),.ownership_error_code(oerr),.capture_error_code(cerr),.watchdog_trips(wd),
 .capture_commits(caps),.nn_commits(nns),.left_scans(ls),.right_scans(rs),.cfg_model(cfg_model),.right_pixel_model(rmodel),.nn_result_valid(done_valid),.nn_result_model(done_model),
 .left_pixel_valid(lpv),.left_pixel_ready(lready),.left_pixel_rgb(lrgb),.left_pixel_frame_id(lfid),.left_pixel_x(lx),.left_pixel_y(ly),.left_pixel_sof(lsof),.left_pixel_eol(leol),.left_pixel_eof(leof),
 .right_pixel_valid(rpv),.right_pixel_ready(right_ready),.right_pixel_rgb(rrgb),.right_pixel_frame_id(rfid),.right_pixel_x(rx),.right_pixel_y(ry),.right_pixel_sof(rsof),.right_pixel_eol(reol),.right_pixel_eof(reof),
 .arid(arid),.araddr(araddr),.arlen(arlen),.arsize(arsize),.arburst(arburst),.arvalid(arvalid),.arready(arready),
 .rid(rid),.rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),
 .awid(awid),.awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),.awvalid(awvalid),.awready(awready),
 .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),.bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready));
 // Separate master RREADY and right consumer ready (named below).
 reg [23:0] input_rgb[0:921599],expect_rgb[0:921599];
 reg [23:0] input_rgb1[0:921599],expect_rgb1[0:921599];
 reg [23:0] ink_rgb[0:921599],ink_rgb1[0:921599];
 reg [23:0] neon_rgb[0:921599],neon_rgb1[0:921599];
 reg [31:0] memory[0:8388607];

 reg pclk=0;always #6.734006734 pclk=~pclk;
 wire fs,hs,vs,de;wire [11:0] px,py;
 reg [1:0] requested_mode=0,display_mode=0;reg [3:0] mode_coverage=0;reg [11:0] model_layout_coverage=0;
 always @(negedge clk)if(rstn)begin
  if(nns<(STYLE==3?6:3))requested_mode=0;else if(nns<(STYLE==3?12:6))requested_mode=1;else if(nns<(STYLE==3?18:9))requested_mode=2;else requested_mode=3;
 end
 always @(posedge pclk)if(!rstn)display_mode<=0;else if(fs)display_mode<=requested_mode;
 wire [23:0] display_rgb;wire display_de,display_hs,display_vs;
 wire [31:0] display_lid,display_rid;
 ab05_hdmi_timing #(.H_ACTIVE(1280),.H_FP(110),.H_SYNC(40),.H_BP(220),.V_ACTIVE(720),.V_FP(5),.V_SYNC(5),.V_BP(20)) timing(
 .pix_clk(pclk),.pix_rstn(rstn),.frame_start(fs),.hs(hs),.vs(vs),.de(de),.x(px),.y(py));
 ab05_dual_preview_hdmi #(.VIEW_W(640),.VIEW_H(360),.ACTIVE_W(1280),.ACTIVE_H(720),.Y0(0),.MIN_START_PIXELS(640)) display(
 .axi_clk(clk),.axi_rstn(rstn),.pix_clk(pclk),.pix_rstn(rstn),.demo_mode(display_mode),
 .frame_start(fs),.pix_hs(hs),.pix_vs(vs),.pix_de(de),.pix_x(px),.pix_y(py),
 .left_pixel_valid(lpv),.left_pixel_ready(lready),.left_pixel_rgb(lrgb),.left_pixel_frame_id(lfid),.left_pixel_x(lx),.left_pixel_y(ly),.left_pixel_sof(lsof),.left_pixel_eol(leol),.left_pixel_eof(leof),
 .right_pixel_valid(rpv),.right_pixel_ready(right_ready),.right_pixel_rgb(rrgb),.right_pixel_frame_id(rfid|32'h80000000),.right_pixel_x(rx),.right_pixel_y(ry),.right_pixel_sof(rsof),.right_pixel_eol(reol),.right_pixel_eof(reof),
 .left_boundary(boundary),.right_boundary(right_boundary),.hdmi_rgb(display_rgb),.hdmi_de(display_de),.hdmi_hs(display_hs),.hdmi_vs(display_vs),.left_display_frame_id(display_lid),.right_display_frame_id(display_rid),
 .left_fifo_high_water(),.right_fifo_high_water(),.left_pix_available(),.right_pix_available(),.snapshot_request(1'b0),.snapshot_busy(),.snapshot_valid(),.snapshot_data());
 reg [11:0] qx1,qx2,qy1,qy2;
 always @(posedge pclk)begin qx1<=px;qx2<=qx1;qy1<=py;qy2<=qy1;end
 reg [FRAMES:1] dlseen=0,drseen=0;
 integer display_lunique=0,display_runique=0,display_lpixels=0,display_rpixels=0,bottom_checks=0;
 integer lrow_pixels=0,rrow_pixels=0,display_index,display_id;
 function automatic [7:0] reference_lift(input [7:0] c);
 integer value;
 begin value=c;reference_lift=value+((value<128?value:255-value)/2);end
 endfunction
 reg lstarted=0,rstarted=0;reg [23:0] display_expected;
 always @(negedge pclk)if(rstn&&display_de)begin
  if(display_mode==3)display_index=(qy2/2)*2*1280+(qx2%640)*2;
  else display_index=(qy2/2)*2*1280+(qx2/2)*2;
  display_id=(qx2<640?display_lid:display_rid)&32'h7fffffff;
  if(qx2==0)begin
   lrow_pixels=0;
   if(qy2==0&&display_id!=0)lstarted=1;
  end
  if(qx2==640)begin
   rrow_pixels=0;
   if(qy2==0&&display_id!=0)rstarted=1;
  end
  if(qx2<640&&lstarted || qx2>=640&&rstarted)begin
   mode_coverage[display_mode]=1;model_layout_coverage[(complete_model[display_id]==32'h544e3031 ? 8:complete_model[display_id]==32'h54493031 ? 4:0)+display_mode]=1;
   if(display_lid[30:0]!==display_rid[30:0])$fatal(1,"source/style frame not paired %h/%h",display_lid,display_rid);
   if(display_id<1||display_id>FRAMES)$fatal(1,"display bad/missing ID x%0d y%0d id%h",qx2,qy2,display_id);
   display_expected=(display_mode==0||((display_mode==1||display_mode==3)&&qx2<640))?(display_id[0]?input_rgb[display_index]:input_rgb1[display_index]):(complete_model[display_id]==32'h544e3031 ? (display_id[0]?neon_rgb[display_index]:neon_rgb1[display_index]):complete_model[display_id]==32'h54493031 ? (display_id[0]?ink_rgb[display_index]:ink_rgb1[display_index]):(display_id[0]?expect_rgb[display_index]:expect_rgb1[display_index]));
   display_expected={reference_lift(display_expected[23:16]),reference_lift(display_expected[15:8]),reference_lift(display_expected[7:0])};
   if(display_rgb!==display_expected)$fatal(1,"display pixel mismatch x%0d y%0d id%0d got%h expected%h U%0d/%0d T%0d/%0d",qx2,qy2,display_id,display_rgb,display_expected,display.l_under,display.r_under,display.l_tag,display.r_tag);
   if(qx2<640)begin display_lpixels=display_lpixels+1;lrow_pixels=lrow_pixels+1;end
   else begin display_rpixels=display_rpixels+1;rrow_pixels=rrow_pixels+1;end
   if(qy2==719)bottom_checks=bottom_checks+1;
   if(qy2==719&&qx2==639&&!dlseen[display_id])begin dlseen[display_id]=1;display_lunique=display_lunique+1;end
   if(qy2==719&&qx2==1279&&!drseen[display_id])begin drseen[display_id]=1;display_runique=display_runique+1;end
  end else if(display_rgb!==0)$fatal(1,"nonblack startup");
 end

 function integer memindex(input [31:0] ad);
  begin
   if(ad>=32'h02000000&&ad<32'h03000000)memindex=(ad-32'h02000000)>>2;
   else if(ad>=32'h04000000&&ad<32'h05000000)memindex=4194304+((ad-32'h04000000)>>2);
   else begin $fatal(1,"DDR address outside frame slots %h",ad);memindex=0;end
  end
 endfunction
 reg [31:0] rng=32'h12345678;reg ractive=0,wactive=0,bpending=0;
 integer read_delay=0,rleft=0,rindex=0,wleft=0,windex=0,bdelay=0;
 integer cycle=0,i,j,k,f,n,accepted=0,basecycle,finishedcycle;
 integer lpixels=0,rpixels=0,lframes=0,rframes=0,nnprev=0,nnlastcycle=0,nnmaxgap=0,nngap;
 integer nnstart=0,nnlatency=0,nnmaxlatency=0; integer nsfirst=0,nsprev=0,nsmaxgap=0,nscount=0;
 reg [FRAMES:1] lseen=0,rseen=0;
 integer lunique=0,runique=0,lfirst=0,llast=0,rfirst=0,rlast_unique=0,nnfirst=0;
 always @(posedge clk)begin
  cycle=cycle+1;
  if(rstn)begin
   if(error)$fatal(1,"service error o=%h c=%h w=%h net=%h",oerr,cerr,wd,dut.network_error_code);
   if(dut.pipeline.nn_launch)begin nnstart=cycle;launch_model[dut.pipeline.nn_id]=dut.pipeline.offered_model;end
   if(done_valid)begin
    if(done_model!==launch_model[dut.pipeline.nn_done_id])$fatal(1,"model changed during job");
    complete_model[dut.pipeline.nn_done_id]=done_model;
    if(done_model==32'h50503031)pcount=pcount+1;else if(done_model==32'h54493031)icount=icount+1;else if(done_model==32'h544e3031)ncount=ncount+1;else $fatal(1,"bad model");
   end
   if(dut.pipeline.nn_done)begin
    if(dut.pipeline.nn_done_id>=3)begin
     nscount=nscount+1;
     if(nsfirst==0)nsfirst=cycle;
     if(nsprev!=0&&cycle-nsprev>nsmaxgap)nsmaxgap=cycle-nsprev;
     nsprev=cycle;
    end
    if(nnfirst==0)nnfirst=cycle;nnlatency=cycle-nnstart;if(nnlatency>nnmaxlatency)nnmaxlatency=nnlatency;
    if(nnlastcycle!=0)begin nngap=cycle-nnlastcycle;if(nngap>nnmaxgap)nnmaxgap=nngap;end
    nnlastcycle=cycle;$display("DUALSTYLE_SERVICE_COMMIT id=%0d cycle=%0d job_cycles=%0d",dut.pipeline.nn_done_id,cycle,nnlatency);
   end
   if(lpv&&lready)begin
    n=(ly*2)*1280+lx*2;
    if(lfid<1||lfid>FRAMES||lrgb!==(lfid[0]?input_rgb[n]:input_rgb1[n])||lsof!=(n==0)||leol!=(lx==639)||leof!=(lx==639&&ly==359))$fatal(1,"left RGB/marks %0d id%0d",n,lfid);
    lpixels=lpixels+1;if(leof)begin lframes=lframes+1;
    if(!lseen[lfid])begin lseen[lfid]=1;lunique=lunique+1;if(lfirst==0)lfirst=cycle;llast=cycle;end end
   end
   if(rpv&&right_ready)begin
    n=(ry*2)*1280+rx*2;
    if(rmodel!==complete_model[rfid])$fatal(1,"preview model tag mismatch id%0d got%h expected%h",rfid,rmodel,complete_model[rfid]);
    if(rfid<1||rfid>FRAMES||rrgb!==(rmodel==32'h544e3031 ? (rfid[0]?neon_rgb[n]:neon_rgb1[n]):rmodel==32'h54493031 ? (rfid[0]?ink_rgb[n]:ink_rgb1[n]):(rfid[0]?expect_rgb[n]:expect_rgb1[n]))||rsof!=(n==0)||reol!=(rx==639)||reof!=(rx==639&&ry==359))$fatal(1,"right RGB/marks %0d id%0d",n,rfid);
    rpixels=rpixels+1;if(reof)begin rframes=rframes+1;
    if(!rseen[rfid])begin rseen[rfid]=1;runique=runique+1;if(rfirst==0)rfirst=cycle;rlast_unique=cycle;end end
   end
   if(arvalid&&arready)begin
    if(ractive||arsize!=4||arburst!=1||araddr[3:0]!=0||({1'b0,araddr[11:0]}+((arlen+1)*16))>4096)$fatal(1,"AR protocol");
    read_delay=24+(rng%9);ractive=1;rleft=arlen+1;rindex=memindex(araddr);rid=arid;
   end
   if(rvalid&&rready)begin rleft=rleft-1;rindex=rindex+4;if(rleft==0)ractive=0;end
   if(awvalid&&awready)begin
    if(wactive||bpending||bvalid||awsize!=4||awburst!=1||awaddr[3:0]!=0||({1'b0,awaddr[11:0]}+((awlen+1)*16))>4096)$fatal(1,"AW protocol");
    wactive=1;wleft=awlen+1;windex=memindex(awaddr);bid=awid;
   end
   if(wvalid&&wready)begin
    if(!wactive||wlast!=(wleft==1)||wstrb!=16'hffff)$fatal(1,"W protocol");
    for(i=0;i<4;i=i+1)memory[windex+i]=wdata[i*32+:32];
    windex=windex+4;wleft=wleft-1;
    if(wleft==0)begin wactive=0;bpending=1;bdelay=3+(rng%23);end
   end
   if(bvalid&&bready)bvalid<=0;
  end
 end
 always @(negedge clk)begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  arready=rstn&&!ractive&&rng[2:0]!=0;
  awready=rstn&&!wactive&&!bpending&&!bvalid&&rng[5:3]!=0;
  wready=rstn&&wactive&&rng[8:6]!=0;

  if(STYLE==3&&rstn&&nnstart>0)begin if(cycle==nnstart+100)begin if(dut.pipeline.nn_id[0])i_style_alt_key_n=0;else i_style_key_n=0;end if(cycle==nnstart+140)begin i_style_key_n=1;i_style_alt_key_n=1;end end

  if(!rvalid||rready)begin
   if(read_delay>0)read_delay=read_delay-1;
   rvalid=rstn&&ractive&&read_delay==0&&rng[11:9]!=0;rlast=rleft==1;
   for(k=0;k<4;k=k+1)rdata[k*32+:32]=memory[rindex+k];
  end
  if(bpending&&!bvalid)begin
   if(bdelay==0)begin bpending=0;bvalid=1;end else bdelay=bdelay-1;
  end
 end
 initial begin
  $readmemh("vectors/case0_input.hex",input_rgb);$readmemh("vectors/case0_output.hex",expect_rgb);
  $readmemh("vectors/case1_input.hex",input_rgb1);$readmemh("vectors/case1_output.hex",expect_rgb1);
  $readmemh("vectors/ink0_output.hex",ink_rgb);$readmemh("vectors/ink1_output.hex",ink_rgb1);
  $readmemh("vectors/neon0_output.hex",neon_rgb);$readmemh("vectors/neon1_output.hex",neon_rgb1);

  repeat(30)@(negedge clk);rstn=1;repeat(30)@(negedge clk);if(STYLE!=3)repeat(STYLE)begin i_style_key_n=0;repeat(40)@(negedge clk);i_style_key_n=1;repeat(40)@(negedge clk);end
  for(f=1;f<=FRAMES;f=f+1)begin
   basecycle=cycle;capture_id=f;cam_frame_id=f;
   if(capture_ready)begin capture_valid=1;accepted=accepted+1;end
   @(negedge clk);capture_valid=0;repeat(100)@(negedge clk);
   for(j=0;j<921600;j=j+1)begin
    cam_valid=1;cam_sof=j==0;cam_eol=j%1280==1279;cam_eof=j==921599;cam_pixel=f[0]?input_rgb[j]:input_rgb1[j];
    @(negedge clk);cam_valid=0;cam_sof=0;cam_eol=0;cam_eof=0;repeat(2)@(negedge clk);
   end
   while(cycle-basecycle<3333333)@(negedge clk);
  end
  wait(nns==accepted&&display_lunique==FRAMES&&display_runique==FRAMES);
  repeat(1000)@(negedge clk);
  if(display.l_srcerr||display.r_srcerr||display.l_tag||display.r_tag||display.l_scan||display.r_scan||display.l_bover||display.r_bover)$fatal(1,"scanout protocol counters");
  if(display.left_scanout.poisoned||display.right_scanout.poisoned)$fatal(1,"scanout poisoned after startup");
  if(mode_coverage!=4'b1111)$fatal(1,"not all modes seen with actual service");
  if(STYLE==3&&model_layout_coverage!=12'hfff)$fatal(1,"not all model/layout combinations seen");
  $display("SWITCH_CADENCE_MEASURED style=%0d models_pp=%0d models_ink=%0d models_neon=%0d model_layout_bitmap=%h max_commit_gap_ms=%0.6f",STYLE,pcount,icount,ncount,model_layout_coverage,nnmaxgap/100000.0);
  $display("SCANOUT_SERVICE PASS display_left_unique=%0d display_right_unique=%0d checked_left_pixels=%0d checked_right_pixels=%0d last_row_checks=%0d left_startup_underflows=%0d right_startup_underflows=%0d",display_lunique,display_runique,display_lpixels,display_rpixels,bottom_checks,display.l_under,display.r_under);
  if(bottom_checks<FRAMES*640*2)$fatal(1,"missing full-height bottom-row coverage");
  if(STYLE==3&&(pcount<2||icount<2||ncount<2))$fatal(1,"missing both model coverage pp%0d ink%0d",pcount,icount);
  if(caps!=accepted||nns!=accepted||accepted<4||lframes<4||rframes<4||nnmaxlatency>3333333||(STYLE==3 ? nnmaxgap>5000000 : (nnmaxgap>4000000||nsmaxgap>3500000)))$fatal(1,"service totals caps%0d nn%0d accepted%0d L%0d R%0d latency%0d gap%0d",caps,nns,accepted,lframes,rframes,nnmaxlatency,nnmaxgap);
  if(accepted!=FRAMES||lunique!=FRAMES||runique!=FRAMES)$fatal(1,"dropped unique frames accepted%0d left%0d right%0d",accepted,lunique,runique);
  if(STYLE!=3)begin
   if(STYLE==0&&pcount!=FRAMES||STYLE==1&&icount!=FRAMES||STYLE==2&&ncount!=FRAMES)$fatal(1,"wrong style commits");
   if((nscount-1)*100000000.0/(nsprev-nsfirst)<29.95)$fatal(1,"not 30fps sustainable");
  end
  $display("HD720_STEADY PASS warmup_commits=2 steady_commits=%0d nn_steady_fps=%0.6f max_steady_gap=%0d max_all_run_gap=%0d",nscount,(nscount-1)*100000000.0/(nsprev-nsfirst),nsmaxgap,nnmaxgap);
  $display("HD720_RATE PASS style=%0d frames=%0d left_unique=%0d right_unique=%0d left_fps=%0.6f right_fps=%0.6f nn_fps=%0.6f max_job_cycles=%0d max_commit_gap=%0d",STYLE,FRAMES,lunique,runique,(FRAMES-1)*100000000.0/(llast-lfirst),(FRAMES-1)*100000000.0/(rlast_unique-rfirst),(FRAMES-1)*100000000.0/(nnlastcycle-nnfirst),nnmaxlatency,nnmaxgap);
  $display("DUALSTYLE_SERVICE PASS captures=%0d unique_nn=%0d left_frames=%0d right_frames=%0d left_pixels=%0d right_pixels=%0d max_job_cycles=%0d max_commit_gap=%0d",caps,nns,lframes,rframes,lpixels,rpixels,nnmaxlatency,nnmaxgap);
  $finish;
 end
 initial begin #800000000;$fatal(1,"service timeout");end
endmodule
