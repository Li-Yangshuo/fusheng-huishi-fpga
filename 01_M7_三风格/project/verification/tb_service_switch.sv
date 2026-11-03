`timescale 1ns/1ps
// Busy-mode stress: PP~20.34ms -> Ink~29.56ms adds ~9.22ms to one commit gap.
// Bound switching transient at44ms; fixed-style30fps tests retain34ms bound.
module tb_service_switch;
 parameter STYLE=2,FRAMES=12;
 reg clk=0,rstn=0;always #5 clk=~clk;
 reg capture_valid=0,cam_valid=0,cam_sof=0,cam_eol=0,cam_eof=0;
 reg [31:0] capture_id=1,cam_frame_id=1;reg [23:0] cam_pixel=0;
 wire capture_ready,cam_armed,error;wire [7:0] oerr;wire [3:0] cerr,wd;
 wire [31:0] caps,nns,ls,rs;wire lpv,rpv;wire [23:0] lrgb,rrgb;wire [31:0] lfid,rfid;
 wire [10:0] lx,rx;wire [9:0] ly,ry;wire lsof,leol,leof,rsof,reol,reof;
 reg [31:0] cfg_model=32'h50503031;wire [31:0] rmodel,done_model;wire done_valid;
 reg [31:0] launch_model[0:FRAMES],complete_model[0:FRAMES];integer pcount=0,icount=0;
 reg boundary=0;reg lready=0;
 wire right_ready=lready;
 wire [3:0] arid,awid;wire [31:0] araddr,awaddr;wire [7:0] arlen,awlen;wire [2:0] arsize,awsize;
 wire [1:0] arburst,awburst;wire arvalid,rready,awvalid,wvalid,wlast,bready;
 reg arready=0,awready=0,wready=0,rvalid=0,rlast=0,bvalid=0;
 reg [127:0] rdata=0;reg [3:0] rid=0,bid=0;reg [1:0] rresp=0,bresp=0;
 wire [127:0] wdata;wire [15:0] wstrb;
 a_b_video_renderer_shared #(.WIDTH(1280),.HEIGHT(720),.BB(32),.MODEL0(32'h50503031),.MODEL1(32'h54493031)) dut(
 .axi_clk(clk),.axi_rstn(rstn),.core_clk(clk),.core_rstn(rstn),.cam_clk(clk),.cam_rstn(rstn),
 .capture_valid(capture_valid),.capture_ready(capture_ready),.capture_id(capture_id),.capture_timestamp(64'd123),
 .cam_valid(cam_valid),.cam_sof(cam_sof),.cam_eol(cam_eol),.cam_eof(cam_eof),.cam_pixel(cam_pixel),.cam_frame_id(cam_frame_id),.cam_armed(cam_armed),
 .left_boundary(boundary),.right_boundary(boundary),.external_fault(1'b0),.error(error),.ownership_error_code(oerr),.capture_error_code(cerr),.watchdog_trips(wd),
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
 reg [31:0] memory[0:6291455];
 function integer memindex(input [31:0] ad);
  begin
   if(ad>=32'h02000000&&ad<32'h02c00000)memindex=(ad-32'h02000000)>>2;
   else if(ad>=32'h04000000&&ad<32'h04c00000)memindex=3145728+((ad-32'h04000000)>>2);
   else begin $fatal(1,"DDR address outside frame slots %h",ad);memindex=0;end
  end
 endfunction
 reg [31:0] rng=32'h12345678;reg ractive=0,wactive=0,bpending=0;
 integer rleft=0,rindex=0,wleft=0,windex=0,bdelay=0;
 integer cycle=0,i,j,k,f,n,accepted=0,basecycle,finishedcycle;
 integer lpixels=0,rpixels=0,lframes=0,rframes=0,nnprev=0,nnlastcycle=0,nnmaxgap=0,nngap;
 integer nnstart=0,nnlatency=0,nnmaxlatency=0;
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
    if(done_model==32'h50503031)pcount=pcount+1;else if(done_model==32'h54493031)icount=icount+1;else $fatal(1,"bad model");
   end
   if(dut.pipeline.nn_done)begin
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
    if(rfid<1||rfid>FRAMES||rrgb!==(rmodel==32'h54493031 ? (rfid[0]?ink_rgb[n]:ink_rgb1[n]):(rfid[0]?expect_rgb[n]:expect_rgb1[n]))||rsof!=(n==0)||reol!=(rx==639)||reof!=(rx==639&&ry==359))$fatal(1,"right RGB/marks %0d id%0d",n,rfid);
    rpixels=rpixels+1;if(reof)begin rframes=rframes+1;
    if(!rseen[rfid])begin rseen[rfid]=1;runique=runique+1;if(rfirst==0)rfirst=cycle;rlast_unique=cycle;end end
   end
   if(arvalid&&arready)begin
    if(ractive||arsize!=4||arburst!=1||araddr[3:0]!=0||({1'b0,araddr[11:0]}+((arlen+1)*16))>4096)$fatal(1,"AR protocol");
    ractive=1;rleft=arlen+1;rindex=memindex(araddr);rid=arid;
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
  lready=rstn&&cycle%4==0;
  if(STYLE==2&&rstn&&nnstart>0&&cycle==nnstart+100)cfg_model=cfg_model==32'h50503031 ? 32'h54493031:32'h50503031;
  boundary=rstn&&cycle%1666667==0;
  if(!rvalid||rready)begin
   rvalid=rstn&&ractive&&rng[11:9]!=0;rlast=rleft==1;
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
  cfg_model=STYLE==1 ? 32'h54493031 : 32'h50503031;
  repeat(30)@(negedge clk);rstn=1;repeat(30)@(negedge clk);
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
  wait(nns==accepted&&lunique==FRAMES&&runique==FRAMES);repeat(1000)@(negedge clk);
  if(STYLE==2&&(pcount<2||icount<2))$fatal(1,"missing both model coverage pp%0d ink%0d",pcount,icount);
  if(caps!=accepted||nns!=accepted||accepted<4||lframes<4||rframes<4||nnmaxlatency>3333333||nnmaxgap>4400000)$fatal(1,"service totals caps%0d nn%0d accepted%0d L%0d R%0d latency%0d gap%0d",caps,nns,accepted,lframes,rframes,nnmaxlatency,nnmaxgap);
  if(accepted!=FRAMES||lunique!=FRAMES||runique!=FRAMES)$fatal(1,"dropped unique frames accepted%0d left%0d right%0d",accepted,lunique,runique);
  if(STYLE!=2)begin
   if(STYLE==0&&pcount!=FRAMES||STYLE==1&&icount!=FRAMES)$fatal(1,"wrong style commits");
   if((FRAMES-1)*100000000.0/(llast-lfirst)<29.95||(FRAMES-1)*100000000.0/(rlast_unique-rfirst)<29.95||(FRAMES-1)*100000000.0/(nnlastcycle-nnfirst)<29.95)$fatal(1,"not 30fps sustainable");
  end
  $display("HD720_RATE PASS style=%0d frames=%0d left_unique=%0d right_unique=%0d left_fps=%0.6f right_fps=%0.6f nn_fps=%0.6f max_job_cycles=%0d max_commit_gap=%0d",STYLE,FRAMES,lunique,runique,(FRAMES-1)*100000000.0/(llast-lfirst),(FRAMES-1)*100000000.0/(rlast_unique-rfirst),(FRAMES-1)*100000000.0/(nnlastcycle-nnfirst),nnmaxlatency,nnmaxgap);
  $display("DUALSTYLE_SERVICE PASS captures=%0d unique_nn=%0d left_frames=%0d right_frames=%0d left_pixels=%0d right_pixels=%0d max_job_cycles=%0d max_commit_gap=%0d",caps,nns,lframes,rframes,lpixels,rpixels,nnmaxlatency,nnmaxgap);
  $finish;
 end
 initial begin #800000000;$fatal(1,"service timeout");end
endmodule
