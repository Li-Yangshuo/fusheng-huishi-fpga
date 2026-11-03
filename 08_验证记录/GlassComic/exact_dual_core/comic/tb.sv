`timescale 1ns/1ps
module tb;
 parameter FAULT=0,CASES=4,INK=0;
 localparam LW=320,LH=180,CH=8,OC=3;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,fv=0,fdready=0;wire fr,fd,busy,error;
 reg [31:0] frame=1;wire [31:0] done_frame,done_dest,done_task,done_model;wire [63:0] done_session;
 wire [3:0] arid,awid;wire [31:0] araddr,awaddr;wire [7:0] arlen,awlen;wire [2:0] arsize,awsize;
 wire [1:0] arburst,awburst;wire arvalid,rready,awvalid,wvalid,wlast,bready;
 reg arready=0,awready=0,wready=0,rvalid=0,rlast=0,bvalid=0;
 reg [127:0] rdata=0;reg [3:0] rid=0,bid=0;reg [1:0] rresp=0,bresp=0;
 wire [127:0] wdata;wire [15:0] wstrb;
 wire [31:0] rb,wb,wr;
 dualstyle_frame_engine #(.WIDTH(1280),.HEIGHT(720),.BB(32)) dut(
 .clk(clk),.rst(rst),.external_fault(1'b0),.frame_valid(fv),.frame_ready(fr),
 .frame_task(32'h1234),.frame_id(frame),.frame_model(32'h50503031),.frame_source(32'h02000000),.frame_destination(32'h04000000),.frame_session(64'h7890),
 .frame_done_valid(fd),.frame_done_ready(fdready),.done_task(done_task),.done_frame(done_frame),.done_model(done_model),.done_destination(done_dest),.done_session(done_session),
 .busy(busy),.error(error),.catalog_ready(),.loader_error(),.loader_error_code(),.dma_error_code(),.compute_error_code(),.active_layer(),
 .total_read_beats(rb),.total_write_beats(wb),.total_write_responses(wr),
 .arid(arid),.araddr(araddr),.arlen(arlen),.arsize(arsize),.arburst(arburst),.arvalid(arvalid),.arready(arready),
 .rdata(rdata),.rid(rid),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),
 .awid(awid),.awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),.awvalid(awvalid),.awready(awready),
 .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),.bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready));
 reg [23:0] input_rgb[0:921599],expect_rgb[0:921599],pool_unused[0:57599];
 reg [7:0] pool[0:230399],l3[0:172799];
 reg [7:0] l0[0:460799],l1[0:460799],l2[0:460799];
 reg [31:0] rng=32'h12345678;
 integer rleft=0,rindex=0,wleft=0,windex=0,bdelay=0;
 integer cycle=0,output_pixels=0,pool_checks=0,hidden_checks=0,low_checks=0;
 integer i,k,l,n,c,caseid,startcycle,elapsed;
 integer ml,mg,mx,my;
 reg ractive=0,wactive=0,bpending=0;
 reg held_w=0,held_ar=0,held_aw=0;reg [127:0] oldw;reg oldwl;reg [31:0] oldar,oldaw;reg [7:0] oldarl,oldawl;
 always @(posedge clk)begin
  cycle=cycle+1;
  if(!rst)begin
   if(held_w&&(!wvalid||wdata!==oldw||wlast!==oldwl))$fatal(1,"W unstable under stall");
   if(held_ar&&(!arvalid||araddr!==oldar||arlen!==oldarl))$fatal(1,"AR unstable under stall");
   if(held_aw&&(!awvalid||awaddr!==oldaw||awlen!==oldawl))$fatal(1,"AW unstable under stall");
   held_w=wvalid&&!wready;oldw=wdata;oldwl=wlast;
   held_ar=arvalid&&!arready;oldar=araddr;oldarl=arlen;
   held_aw=awvalid&&!awready;oldaw=awaddr;oldawl=awlen;
   if(arvalid&&arready)begin
    if(ractive||arsize!=4||arburst!=1||arid!=2||araddr[3:0]!=0||araddr<32'h02000000||araddr+(arlen+1)*16>32'h02384000)$fatal(1,"AR protocol/range");
    ractive=1;rleft=arlen+1;rindex=(araddr-32'h02000000)/4;rid=arid;
   end
   if(rvalid&&rready)begin rleft=rleft-1;rindex=rindex+4;if(rleft==0)ractive=0;end
   if(awvalid&&awready)begin
    if(wactive||bpending||bvalid||awsize!=4||awburst!=1||awid!=6||awaddr[3:0]!=0||awaddr<32'h04000000||awaddr+(awlen+1)*16>32'h04384000)$fatal(1,"AW protocol/range");
    wactive=1;wleft=awlen+1;windex=(awaddr-32'h04000000)/4;bid=awid;
   end
   if(wvalid&&wready)begin
    if(!wactive||wlast!=(wleft==1)||wstrb!=16'hffff)$fatal(1,"W protocol");
    for(i=0;i<4;i=i+1)begin
     if(wdata[i*32+:32]!=={expect_rgb[windex+i],8'h00})$fatal(1,"RGB mismatch case%0d px%0d got%h expected%h",caseid,windex+i,wdata[i*32+:32],{expect_rgb[windex+i],8'h00});
    end
    output_pixels=output_pixels+4;windex=windex+4;wleft=wleft-1;
    if(wleft==0)begin wactive=0;bpending=1;bdelay=3+(rng%23);end
   end
   if(bvalid&&bready)begin bvalid<=0;end

   if(dut.comic_core.take&&dut.comic_core.pixel_x[1:0]==3&&dut.comic_core.pixel_y[1:0]==3)begin
    n=(dut.comic_core.pixel_y/4)*LW+dut.comic_core.pixel_x/4;
    if(dut.comic_core.pooled_rgb!=={pool[n*4],pool[n*4+1],pool[n*4+2]})$fatal(1,"pool RGB %0d",n);
    pool_checks=pool_checks+1;
   end
   if(dut.comic_core.state==8)begin
    ml=dut.comic_core.layer;mx=ml==0?dut.comic_core.c0_x:dut.comic_core.c1_x;my=ml==0?dut.comic_core.c0_y:dut.comic_core.c1_y;
    for(l=0;l<(ml==3?OC:CH);l=l+1)begin
     n=(my*LW+mx)*(ml==3?OC:CH)+l;
     if(ml==0&&dut.comic_core.quant_vector[l*8+:8]!==l0[n])$fatal(1,"L0 y%0d x%0d c%0d got%0d expected%0d",my,mx,l,dut.comic_core.quant_vector[l*8+:8],l0[n]);
     if(ml==1&&dut.comic_core.quant_vector[l*8+:8]!==l1[n])$fatal(1,"L1 y%0d x%0d c%0d got%0d expected%0d",my,mx,l,dut.comic_core.quant_vector[l*8+:8],l1[n]);
     if(ml==2&&dut.comic_core.quant_vector[l*8+:8]!==l2[n])$fatal(1,"L2 y%0d x%0d c%0d",my,mx,l);
     if(ml==3&&dut.comic_core.quant_vector[l*8+:8]!==l3[n])$fatal(1,"L3 y%0d x%0d c%0d",my,mx,l);
     if(ml==3)low_checks=low_checks+1;else hidden_checks=hidden_checks+1;
    end
    if(ml==0&&dut.comic_core.edge_feature(1,1)!==pool[(my*LW+mx)*4+3])$fatal(1,"edge y%0d x%0d",my,mx);
   end
  end
 end
 always @(negedge clk)begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  arready=!rst&&!ractive&&rng[2:0]!=0;
  awready=!rst&&!wactive&&!bpending&&!bvalid&&rng[5:3]!=0;
  wready=!rst&&wactive&&rng[8:6]!=0;
  if(!rvalid||rready)begin
   rvalid=!rst&&ractive&&rng[11:9]!=0;rlast=rleft==1;
   rresp=(FAULT==1&&rindex==0)?2:0;
   for(k=0;k<4;k=k+1)rdata[k*32+:32]={input_rgb[rindex+k],8'h00};
  end
  if(bpending&&!bvalid)begin
   if(bdelay==0)begin bpending=0;bvalid=1;bresp=FAULT==2?2:0;end else bdelay=bdelay-1;
  end
 end
 initial begin
  repeat(8)@(negedge clk);rst=0;
  for(caseid=0;caseid<CASES;caseid=caseid+1)begin
   $readmemh($sformatf("C:/Users/Lenovo/Documents/Codex/2026-10-26/ab/branches/tinycomic_m8/evidence/comic_engine_1280x720/vectors/case%0d_input.hex",caseid),input_rgb);
   $readmemh($sformatf("C:/Users/Lenovo/Documents/Codex/2026-10-26/ab/branches/tinycomic_m8/evidence/comic_engine_1280x720/vectors/case%0d_output.hex",caseid),expect_rgb);
   $readmemh($sformatf("C:/Users/Lenovo/Documents/Codex/2026-10-26/ab/branches/tinycomic_m8/evidence/comic_engine_1280x720/vectors/case%0d_pool.hex",caseid),pool);
   $readmemh($sformatf("C:/Users/Lenovo/Documents/Codex/2026-10-26/ab/branches/tinycomic_m8/evidence/comic_engine_1280x720/vectors/case%0d_l0.hex",caseid),l0);
   $readmemh($sformatf("C:/Users/Lenovo/Documents/Codex/2026-10-26/ab/branches/tinycomic_m8/evidence/comic_engine_1280x720/vectors/case%0d_l1.hex",caseid),l1);
   $readmemh($sformatf("C:/Users/Lenovo/Documents/Codex/2026-10-26/ab/branches/tinycomic_m8/evidence/comic_engine_1280x720/vectors/case%0d_l2.hex",caseid),l2);
   $readmemh($sformatf("C:/Users/Lenovo/Documents/Codex/2026-10-26/ab/branches/tinycomic_m8/evidence/comic_engine_1280x720/vectors/case%0d_l3.hex",caseid),l3);
   output_pixels=0;pool_checks=0;hidden_checks=0;low_checks=0;
   wait(fr);@(negedge clk);fv=1;startcycle=cycle;
   @(negedge clk);fv=0;
   if(FAULT!=0)begin
    wait(error);repeat(1000)begin @(negedge clk);if(fd)$fatal(1,"commit on AXI fault");end
    $display("HD720_FAULT PASS mode=%0d",FAULT);$finish;
   end
   wait(fd);elapsed=cycle-startcycle;
   if(error||done_frame!=frame||done_dest!=32'h04000000||done_task!=32'h1234||done_model!=(32'h50503031)||done_session!=64'h7890)$fatal(1,"completion metadata");
   if(output_pixels!=921600||pool_checks!=LW*LH||hidden_checks!=LW*LH*CH*3||low_checks!=LW*LH*OC||rb!=230400||wb!=230400||wr!=7200)$fatal(1,"check counts %0d %0d %0d %0d",output_pixels,pool_checks,hidden_checks,low_checks);
   if(elapsed>3333333)$fatal(1,"frame budget exceeded %0d",elapsed);
   repeat(17)begin @(negedge clk);if(!fd||done_frame!=frame)$fatal(1,"completion unstable");end
   $display("HD720_FRAME PASS case=%0d cycles=%0d pixels=%0d pool=%0d hidden=%0d low=%0d",caseid,elapsed,output_pixels,pool_checks,hidden_checks,low_checks);
   fdready=1;@(negedge clk);fdready=0;frame=frame+1;
  end
  $display("HD720_ENGINE PASS cases=%0d",CASES);$finish;
 end
 initial begin #500000000;$fatal(1,"simulation timeout");end
endmodule
