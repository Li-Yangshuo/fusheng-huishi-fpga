// A camera/DDR/NN/display SERVICE top, not a vendor CSI/HDMI/fabric top.
// No B neural core or test stub is instantiated. All B ports are core_clk domain.
// Pixel outputs are AXI-domain streams; real HDMI needs row CDC/prefetch/QoS.
// Reset all three domains AND external AXI fabric together. Quarantine never
// withdraws accepted/held AXI transactions or silently frees a leased slot.
module ab05_video_pipeline_shared #(
 parameter WIDTH=1280,HEIGHT=720,SLOTS=3,BB=16,CAP_FIFO_AW=9,CORE_FIFO_AW=5,
 parameter TOTAL_CYCLES=100000000,NO_PROGRESS_CYCLES=5000000,
 parameter [31:0] SLOT_BYTES=32'h00400000,INPUT_BASE=32'h02000000,OUTPUT_BASE=32'h04000000,
 parameter EXTERNAL_NN_PROGRESS=0,MEM_BYTES=268435456,
 parameter [31:0] TASK_FIRST=1,FEATURE_BYTES=32'h00200000,FEATURE0=32'h06000000,FEATURE1=32'h06200000,
 parameter ASSET_FILE="board_assets.mem",ASSET_WORDS=1124,
 parameter [31:0] ASSET_CRC=32'h44405515,MODEL0=32'hc2b00001,MODEL1=32'hc2b10001,MODEL2=32'h544e3031,
 parameter [255:0] BASES=256'h0000015400000138000000fe000000b0000000620000002e0000001500000000,
 parameter [127:0] COUNTS=128'h03070008000e00120012000e00080005
)(
 input wire axi_clk,axi_rstn,core_clk,core_rstn,cam_clk,cam_rstn,
 input wire capture_valid,output wire capture_ready,input wire [31:0] capture_id,input wire [63:0] capture_timestamp,
 input wire cam_valid,cam_sof,cam_eol,cam_eof,input wire [23:0] cam_pixel,input wire [31:0] cam_frame_id,output wire cam_armed,
 input wire left_boundary,right_boundary,external_fault,input wire render_invert,
 input wire weight_we,weight_bias,models_ready,input wire [5:0] weight_addr,input wire [511:0] weight_data,
  input wire [31:0] cfg_model,output wire catalog_ready,loader_error,network_busy,
 output wire [7:0] loader_error_code,network_stream_error_code,output wire [72:0] network_error_code,
 output wire error,output wire [7:0] ownership_error_code,output wire [3:0] capture_error_code,
 output wire [15:0] input_allocated_mask,output_allocated_mask,
 output wire [31:0] capture_commits,nn_commits,left_scans,right_scans,capture_blocked_cycles,missed_left_ticks,missed_right_ticks,
 output wire [3:0] watchdog_trips,output wire [31:0] camera_skipped_frames,camera_selected_frames,
 output wire left_pixel_valid,input wire left_pixel_ready,
 output wire [23:0] left_pixel_rgb,output wire [31:0] left_pixel_frame_id,
 output wire [10:0] left_pixel_x,output wire [9:0] left_pixel_y,
 output wire left_pixel_sof,left_pixel_eol,left_pixel_eof,
 output wire [31:0] right_pixel_model,nn_result_model,output wire nn_result_valid,
 output wire right_pixel_valid,input wire right_pixel_ready,
 output wire [23:0] right_pixel_rgb,output wire [31:0] right_pixel_frame_id,
 output wire [10:0] right_pixel_x,output wire [9:0] right_pixel_y,
 output wire right_pixel_sof,right_pixel_eol,right_pixel_eof,
 output wire [3:0] arid,
 output wire [31:0] araddr,
 output wire [7:0] arlen,
 output wire [2:0] arsize,
 output wire [1:0] arburst,
 output wire arvalid,
 input wire arready,
 input wire [3:0] rid,
 input wire [127:0] rdata,
 input wire [1:0] rresp,
 input wire rlast,
 input wire rvalid,
 output wire rready,
 output wire [3:0] awid,
 output wire [31:0] awaddr,
 output wire [7:0] awlen,
 output wire [2:0] awsize,
 output wire [1:0] awburst,
 output wire awvalid,
 input wire awready,
 output wire [127:0] wdata,
 output wire [15:0] wstrb,
 output wire wlast,
 output wire wvalid,
 input wire wready,
 input wire [3:0] bid,
 input wire [1:0] bresp,
 input wire bvalid,
 output wire bready,
 // axi_clk domain: actual external NN feature R/W/B transfers only.
 // Default-off keeps existing named-port A users safe when this is unconnected.
 input wire external_nn_progress
);
wire arst=!(axi_rstn&&core_rstn&&cam_rstn);
(* async_reg="true" *) reg [1:0] axrun;
always @(posedge axi_clk or posedge arst) if(arst)axrun<=0;else axrun<={axrun[0],1'b1};
wire run=axrun[1];
wire owner_error,cap_error,link_error;
wire [1:0] display_error;
wire own_cap_ready,cap_arm_ready,selector_arm_ready,cap_done;
wire ingress_armed,selection_armed;
wire selected_valid,selected_sof,selected_eol,selected_eof;
wire [23:0] selected_pixel;wire [31:0] selected_frame_id;
wire [31:0] cap_base,cap_done_id;
wire cap_accept=capture_valid&&capture_ready;
wire nn_valid,nn_ready,link_ready,nn_done;
wire [31:0] nn_ib,nn_ob,nn_id,nn_done_id;
wire [63:0] nn_time;
wire [3:0] wd_ready;
wire nn_launch=nn_valid&&nn_ready;
wire [1:0] dv,dr,dd;
wire [31:0] df[0:1],db[0:1],done_f[0:1];
wire [63:0] dt[0:1];wire [3:0] de[0:1];
wire [3:0] dq;
assign error=external_fault||owner_error||cap_error||link_error||(|display_error)||(|watchdog_trips);
assign capture_ready=run&&own_cap_ready&&cap_arm_ready&&selector_arm_ready&&wd_ready[0]&&!error;
assign cam_armed=ingress_armed&&selection_armed;
reg offered_model_valid;
assign nn_ready=run&&link_ready&&wd_ready[1]&&!error&&offered_model_valid;

wire [3:0] n_arid;
wire [3:0] l_arid;
wire [3:0] q_arid;
wire [31:0] n_araddr;
wire [31:0] l_araddr;
wire [31:0] q_araddr;
wire [7:0] n_arlen;
wire [7:0] l_arlen;
wire [7:0] q_arlen;
wire [2:0] n_arsize;
wire [2:0] l_arsize;
wire [2:0] q_arsize;
wire [1:0] n_arburst;
wire [1:0] l_arburst;
wire [1:0] q_arburst;
wire n_arvalid;
wire l_arvalid;
wire q_arvalid;
wire n_arready;
wire l_arready;
wire q_arready;
wire [3:0] n_rid;
wire [3:0] l_rid;
wire [3:0] q_rid;
wire [127:0] n_rdata;
wire [127:0] l_rdata;
wire [127:0] q_rdata;
wire [1:0] n_rresp;
wire [1:0] l_rresp;
wire [1:0] q_rresp;
wire n_rlast;
wire l_rlast;
wire q_rlast;
wire n_rvalid;
wire l_rvalid;
wire q_rvalid;
wire n_rready;
wire l_rready;
wire q_rready;
wire [3:0] c_awid;
wire [3:0] n_awid;
wire [31:0] c_awaddr;
wire [31:0] n_awaddr;
wire [7:0] c_awlen;
wire [7:0] n_awlen;
wire [2:0] c_awsize;
wire [2:0] n_awsize;
wire [1:0] c_awburst;
wire [1:0] n_awburst;
wire c_awvalid;
wire n_awvalid;
wire c_awready;
wire n_awready;
wire [127:0] c_wdata;
wire [127:0] n_wdata;
wire [15:0] c_wstrb;
wire [15:0] n_wstrb;
wire c_wlast;
wire n_wlast;
wire c_wvalid;
wire n_wvalid;
wire c_wready;
wire n_wready;
wire [3:0] c_bid;
wire [3:0] n_bid;
wire [1:0] c_bresp;
wire [1:0] n_bresp;
wire c_bvalid;
wire n_bvalid;
wire c_bready;
wire n_bready;
ab05_video_ownership #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.SLOTS(SLOTS),.SLOT_BYTES(SLOT_BYTES),
 .INPUT_BASE(INPUT_BASE),.OUTPUT_BASE(OUTPUT_BASE)) ownership(
 .clk(axi_clk),.rstn(run),.external_fault(error&&!owner_error),
 .capture_start_valid(capture_valid&&cap_arm_ready&&selector_arm_ready&&wd_ready[0]&&!error),.capture_start_ready(own_cap_ready),.capture_id(capture_id),
 .capture_timestamp(capture_timestamp),.capture_base(cap_base),
 .capture_done(cap_done),.capture_done_id(cap_done_id),.capture_ok(!cap_error),
 .nn_job_valid(nn_valid),.nn_job_ready(nn_ready),.nn_input_base(nn_ib),.nn_output_base(nn_ob),
 .nn_frame_id(nn_id),.nn_timestamp(nn_time),.nn_done(nn_done),.nn_done_id(nn_done_id),.nn_ok(!link_error),
 .left_boundary(left_boundary),.left_desc_valid(dv[0]),.left_desc_ready(dr[0]),
 .left_frame_id(df[0]),.left_base(db[0]),.left_timestamp(dt[0]),
 .left_done(dd[0]),.left_done_id(done_f[0]),.left_ok(de[0]==0),
 .right_boundary(right_boundary),.right_desc_valid(dv[1]),.right_desc_ready(dr[1]),
 .right_frame_id(df[1]),.right_base(db[1]),.right_timestamp(dt[1]),
 .right_done(dd[1]),.right_done_id(done_f[1]),.right_ok(de[1]==0),
 .error(owner_error),.error_code(ownership_error_code),
 .input_allocated_mask(input_allocated_mask),.output_allocated_mask(output_allocated_mask),
 .capture_commits(capture_commits),.nn_commits(nn_commits),.left_scans(left_scans),.right_scans(right_scans),
 .capture_blocked_cycles(capture_blocked_cycles),.missed_left_ticks(missed_left_ticks),.missed_right_ticks(missed_right_ticks));
ab05_camera_selector selector(
 .axi_clk(axi_clk),.axi_rstn(run),.cam_clk(cam_clk),.cam_rstn(cam_rstn&&core_rstn),
 .arm_valid(cap_accept),.arm_ready(selector_arm_ready),.arm_frame_id(capture_id),
 .raw_valid(cam_valid),.raw_pixel(cam_pixel),.raw_frame_id(cam_frame_id),
 .raw_sof(cam_sof),.raw_eol(cam_eol),.raw_eof(cam_eof),.ingress_armed(ingress_armed),
 .selected_valid(selected_valid),.selected_pixel(selected_pixel),.selected_frame_id(selected_frame_id),
 .selected_sof(selected_sof),.selected_eol(selected_eol),.selected_eof(selected_eof),
 .selection_armed(selection_armed),.skipped_frames(camera_skipped_frames),.selected_frames(camera_selected_frames));
ab05_capture_ingress #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BB(BB),.FIFO_AW(CAP_FIFO_AW)) capture(
 .axi_clk(axi_clk),.axi_rstn(run),.cam_clk(cam_clk),.cam_rstn(cam_rstn&&core_rstn),
 .arm_valid(cap_accept),.arm_ready(cap_arm_ready),.arm_frame_id(capture_id),.arm_base(cap_base),
 .cam_valid(selected_valid),.cam_pixel(selected_pixel),.cam_frame_id(selected_frame_id),
 .cam_sof(selected_sof),.cam_eol(selected_eol),.cam_eof(selected_eof),.cam_armed(ingress_armed),
 .error(cap_error),.error_code(capture_error_code),.done(cap_done),.done_id(cap_done_id),
 .accepted_frames(),.dropped_frames(),.completed_frames(),.fifo_high(),.awid(c_awid),.awaddr(c_awaddr),.awlen(c_awlen),.awsize(c_awsize),.awburst(c_awburst),.awvalid(c_awvalid),.awready(c_awready),.wdata(c_wdata),.wstrb(c_wstrb),.wlast(c_wlast),.wvalid(c_wvalid),.wready(c_wready),.bid(c_bid),.bresp(c_bresp),.bvalid(c_bvalid),.bready(c_bready));

// Sole A-side task allocator, plus an epoch retained through functional resets.
// FPGA reconfiguration is a new fabric epoch; AXI/core reset is coordinated.
reg [31:0] next_task;reg [31:0] offered_model;
reg [63:0] session_counter=64'd0;reg previous_reset=1'b0;
always @(posedge axi_clk)begin
 previous_reset<=!run;
 if((!run&&!previous_reset)||nn_launch)session_counter<=session_counter+64'd16;
end
always @(posedge axi_clk or negedge run)begin
 if(!run)begin next_task<=TASK_FIRST;offered_model_valid<=0;offered_model<=0;end
 else begin
  if(!offered_model_valid&&nn_valid&&!network_busy)begin offered_model<=cfg_model;offered_model_valid<=1;end
  if(nn_launch)begin next_task<=next_task+1'b1;offered_model_valid<=0;end
 end
end
wire frame_done_valid;wire [31:0] done_task,done_model,done_destination;wire [63:0] done_session;
wire [7:0] dma_code;wire [31:0] compute_code;wire [2:0] active_layer;
assign nn_done=frame_done_valid;
assign nn_result_valid=frame_done_valid;assign nn_result_model=done_model;
 reg [SLOTS-1:0] result_tag_valid;
 reg [31:0] result_tag_id[0:SLOTS-1],result_tag_model[0:SLOTS-1];
 integer tag_slot;integer tm;
 always @(posedge axi_clk or negedge run)begin
  if(!run)result_tag_valid<=0;
  else if(frame_done_valid)begin
   tag_slot=(done_destination-OUTPUT_BASE)/SLOT_BYTES;
   if(tag_slot<SLOTS)begin result_tag_valid[tag_slot]<=1;result_tag_id[tag_slot]<=nn_done_id;result_tag_model[tag_slot]<=done_model;end
  end
 end
 reg [31:0] right_model_mux;
 always @*begin
  right_model_mux=0;
  for(integer k=0;k<SLOTS;k=k+1)if(result_tag_valid[k]&&result_tag_id[k]==right_pixel_frame_id)right_model_mux=result_tag_model[k];
 end
 assign right_pixel_model=right_model_mux;

assign network_stream_error_code=dma_code;
assign network_error_code={25'd0,loader_error_code,dma_code,compute_code};
dualstyle_frame_engine #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BB(BB),.MEM_BYTES(MEM_BYTES),.SLOT_BYTES(SLOT_BYTES),
 .FEATURE_BYTES(FEATURE_BYTES),.FEATURE0(FEATURE0),.FEATURE1(FEATURE1),.ASSET_FILE(ASSET_FILE),.ASSET_WORDS(ASSET_WORDS),.ASSET_CRC(ASSET_CRC),
 .MODEL0(MODEL0),.MODEL1(MODEL1),.MODEL2(MODEL2),.BASES(BASES),.COUNTS(COUNTS)) network(
 .clk(axi_clk),.rst(!run),.external_fault(external_fault),.weight_we(weight_we),.weight_bias(weight_bias),.weight_addr(weight_addr),.weight_data(weight_data),.models_ready(models_ready),
 .frame_valid(nn_valid&&offered_model_valid&&wd_ready[1]&&!error),.frame_ready(link_ready),
 .frame_task(next_task),.frame_id(nn_id),.frame_model(offered_model),.frame_source(nn_ib),.frame_destination(nn_ob),.frame_session(session_counter),
 .frame_done_valid(frame_done_valid),.frame_done_ready(1'b1),.done_task(done_task),.done_frame(nn_done_id),.done_model(done_model),.done_destination(done_destination),.done_session(done_session),
 .busy(network_busy),.error(link_error),.catalog_ready(catalog_ready),.loader_error(loader_error),.loader_error_code(loader_error_code),.dma_error_code(dma_code),.compute_error_code(compute_code),.active_layer(active_layer),
 .total_read_beats(),.total_write_beats(),.total_write_responses(),
 .arid(n_arid),.araddr(n_araddr),.arlen(n_arlen),.arsize(n_arsize),.arburst(n_arburst),.arvalid(n_arvalid),.arready(n_arready),.rid(n_rid),.rdata(n_rdata),.rresp(n_rresp),.rlast(n_rlast),.rvalid(n_rvalid),.rready(n_rready),
 .awid(n_awid),.awaddr(n_awaddr),.awlen(n_awlen),.awsize(n_awsize),.awburst(n_awburst),.awvalid(n_awvalid),.awready(n_awready),.wdata(n_wdata),.wstrb(n_wstrb),.wlast(n_wlast),.wvalid(n_wvalid),.wready(n_wready),.bid(n_bid),.bresp(n_bresp),.bvalid(n_bvalid),.bready(n_bready));
ab05_rgbx_axi_reader_prefetch #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.PREVIEW((WIDTH==1280 && HEIGHT==720)?2:0),.MAX_BEATS(32),.AXI_ID(4'd3)) left_reader(
 .clk(axi_clk),.rstn(run),.desc_valid(dv[0]),.desc_ready(dr[0]),
 .desc_frame_id(df[0]),.desc_base(db[0]),.desc_stride(WIDTH*4),.m_arid(l_arid),.m_araddr(l_araddr),.m_arlen(l_arlen),.m_arsize(l_arsize),.m_arburst(l_arburst),.m_arvalid(l_arvalid),.m_arready(l_arready),.m_rid(l_rid),.m_rdata(l_rdata),.m_rresp(l_rresp),.m_rlast(l_rlast),.m_rvalid(l_rvalid),.m_rready(l_rready),
.pixel_valid(left_pixel_valid),.pixel_ready(left_pixel_ready),.pixel_rgb(left_pixel_rgb),.pixel_frame_id(left_pixel_frame_id),.pixel_x(left_pixel_x),.pixel_y(left_pixel_y),.pixel_sof(left_pixel_sof),.pixel_eol(left_pixel_eol),.pixel_eof(left_pixel_eof),
 .done_valid(dd[0]),.done_ready(1'b1),.done_frame_id(done_f[0]),.done_error(de[0]),
 .quarantined(dq[0]),.accepted_beats(),.ar_commands(),.max_ar_wait(),.output_stall_cycles());
assign display_error[0]=dq[0]||(dd[0]&&de[0]!=0);
ab05_rgbx_axi_reader_prefetch #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.PREVIEW((WIDTH==1280 && HEIGHT==720)?2:0),.MAX_BEATS(32),.AXI_ID(4'd4)) right_reader(
 .clk(axi_clk),.rstn(run),.desc_valid(dv[1]),.desc_ready(dr[1]),
 .desc_frame_id(df[1]),.desc_base(db[1]),.desc_stride(WIDTH*4),.m_arid(q_arid),.m_araddr(q_araddr),.m_arlen(q_arlen),.m_arsize(q_arsize),.m_arburst(q_arburst),.m_arvalid(q_arvalid),.m_arready(q_arready),.m_rid(q_rid),.m_rdata(q_rdata),.m_rresp(q_rresp),.m_rlast(q_rlast),.m_rvalid(q_rvalid),.m_rready(q_rready),
.pixel_valid(right_pixel_valid),.pixel_ready(right_pixel_ready),.pixel_rgb(right_pixel_rgb),.pixel_frame_id(right_pixel_frame_id),.pixel_x(right_pixel_x),.pixel_y(right_pixel_y),.pixel_sof(right_pixel_sof),.pixel_eol(right_pixel_eol),.pixel_eof(right_pixel_eof),
 .done_valid(dd[1]),.done_ready(1'b1),.done_frame_id(done_f[1]),.done_error(de[1]),
 .quarantined(dq[1]),.accepted_beats(),.ar_commands(),.max_ar_wait(),.output_stall_cycles());
assign display_error[1]=dq[1]||(dd[1]&&de[1]!=0);
ab05_axi_read_rr3 read_arb(.clk(axi_clk),.rstn(run),.s_arvalid({q_arvalid,l_arvalid,n_arvalid}),.s_araddr({q_araddr,l_araddr,n_araddr}),.s_arlen({q_arlen,l_arlen,n_arlen}),.s_arid({q_arid,l_arid,n_arid}),.s_arsize({q_arsize,l_arsize,n_arsize}),.s_arburst({q_arburst,l_arburst,n_arburst}),.s_rready({q_rready,l_rready,n_rready}),.s_arready({q_arready,l_arready,n_arready}),.s_rvalid({q_rvalid,l_rvalid,n_rvalid}),.s_rdata(n_rdata),.s_rid(n_rid),.s_rresp(n_rresp),.s_rlast(n_rlast),.m_arid(arid),.m_araddr(araddr),.m_arlen(arlen),.m_arsize(arsize),.m_arburst(arburst),.m_arvalid(arvalid),.m_arready(arready),.m_rid(rid),.m_rdata(rdata),.m_rresp(rresp),.m_rlast(rlast),.m_rvalid(rvalid),.m_rready(rready),.debug_grant());
assign l_rdata=n_rdata;
assign l_rid=n_rid;
assign l_rresp=n_rresp;
assign l_rlast=n_rlast;
assign q_rdata=n_rdata;
assign q_rid=n_rid;
assign q_rresp=n_rresp;
assign q_rlast=n_rlast;
ab05_axi_write_rr2 write_arb(.clk(axi_clk),.rstn(run),.s_awvalid({n_awvalid,c_awvalid}),.s_awaddr({n_awaddr,c_awaddr}),.s_awlen({n_awlen,c_awlen}),.s_awid({n_awid,c_awid}),.s_awsize({n_awsize,c_awsize}),.s_awburst({n_awburst,c_awburst}),.s_wvalid({n_wvalid,c_wvalid}),.s_wdata({n_wdata,c_wdata}),.s_wstrb({n_wstrb,c_wstrb}),.s_wlast({n_wlast,c_wlast}),.s_bready({n_bready,c_bready}),.s_awready({n_awready,c_awready}),.s_wready({n_wready,c_wready}),.s_bvalid({n_bvalid,c_bvalid}),.s_bid(n_bid),.s_bresp(n_bresp),.m_awid(awid),.m_awaddr(awaddr),.m_awlen(awlen),.m_awsize(awsize),.m_awburst(awburst),.m_awvalid(awvalid),.m_awready(awready),.m_wdata(wdata),.m_wstrb(wstrb),.m_wlast(wlast),.m_wvalid(wvalid),.m_wready(wready),.m_bid(bid),.m_bresp(bresp),.m_bvalid(bvalid),.m_bready(bready),.debug_grant());
assign c_bid=n_bid;
assign c_bresp=n_bresp;
ab05_job_watchdog #(.TOTAL_CYCLES(TOTAL_CYCLES),.NO_PROGRESS_CYCLES(NO_PROGRESS_CYCLES)) watchdog_0(
 .clk(axi_clk),.rstn(run),.start_valid(cap_accept),.start_ready(wd_ready[0]),.start_id(capture_id),
 .progress((c_wvalid&&c_wready)||(c_bvalid&&c_bready)),.finish_valid(cap_done),.finish_id(cap_done_id),.finish_ok(!cap_error),
 .external_fault(external_fault||cap_error),.active(),.finish_accepted(),.quarantine(watchdog_trips[0]),
 .reason(),.trip_id(),.cycles(),.no_progress());
wire nn_watchdog_progress=(n_rvalid&&n_rready)||(n_wvalid&&n_wready)||(n_bvalid&&n_bready)||
 (EXTERNAL_NN_PROGRESS ? external_nn_progress : 1'b0);
ab05_job_watchdog #(.TOTAL_CYCLES(TOTAL_CYCLES),.NO_PROGRESS_CYCLES(NO_PROGRESS_CYCLES)) watchdog_1(
 .clk(axi_clk),.rstn(run),.start_valid(nn_launch),.start_ready(wd_ready[1]),.start_id(nn_id),
 .progress(nn_watchdog_progress),.finish_valid(nn_done),.finish_id(nn_done_id),.finish_ok(!link_error),
 .external_fault(external_fault||link_error),.active(),.finish_accepted(),.quarantine(watchdog_trips[1]),
 .reason(),.trip_id(),.cycles(),.no_progress());
ab05_job_watchdog #(.TOTAL_CYCLES(TOTAL_CYCLES),.NO_PROGRESS_CYCLES(NO_PROGRESS_CYCLES)) watchdog_2(
 .clk(axi_clk),.rstn(run),.start_valid(dv[0]&&dr[0]),.start_ready(wd_ready[2]),.start_id(df[0]),
 .progress((left_pixel_valid&&left_pixel_ready)),.finish_valid(dd[0]),.finish_id(done_f[0]),.finish_ok(de[0]==0),
 .external_fault(external_fault||display_error[0]),.active(),.finish_accepted(),.quarantine(watchdog_trips[2]),
 .reason(),.trip_id(),.cycles(),.no_progress());
ab05_job_watchdog #(.TOTAL_CYCLES(TOTAL_CYCLES),.NO_PROGRESS_CYCLES(NO_PROGRESS_CYCLES)) watchdog_3(
 .clk(axi_clk),.rstn(run),.start_valid(dv[1]&&dr[1]),.start_ready(wd_ready[3]),.start_id(df[1]),
 .progress((right_pixel_valid&&right_pixel_ready)),.finish_valid(dd[1]),.finish_id(done_f[1]),.finish_ok(de[1]==0),
 .external_fault(external_fault||display_error[1]),.active(),.finish_accepted(),.quarantine(watchdog_trips[3]),
 .reason(),.trip_id(),.cycles(),.no_progress());
endmodule
