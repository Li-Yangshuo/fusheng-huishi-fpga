// One-clock full C2R2 inference program: RGB stem, six fused DW/PW, RGB head.
// One physical DMA owner and two 2MiB scratch regions; no NN event peers.
module board_frame_engine #(
 parameter WIDTH=1280,HEIGHT=720,BB=16,WDOG=100000,MEM_BYTES=268435456,
 parameter [31:0] SLOT_BYTES=32'h00400000,FEATURE_BYTES=32'h00200000,
 parameter [31:0] FEATURE0=32'h06000000,FEATURE1=32'h06200000,
 parameter ASSET_FILE="board_assets.mem",ASSET_WORDS=1124,
 parameter [31:0] ASSET_CRC=32'h44405515,MODEL0=32'hc2b00001,MODEL1=32'hc2b10001,
 parameter [255:0] BASES=256'h0000015400000138000000fe000000b0000000620000002e0000001500000000,
 parameter [127:0] COUNTS=128'h03070008000e00120012000e00080005
)(
 input wire clk,rst,external_fault,
 input wire frame_valid,output wire frame_ready,input wire [31:0] frame_task,frame_id,frame_model,frame_source,frame_destination,
 input wire [63:0] frame_session,
 output wire frame_done_valid,input wire frame_done_ready,output wire [31:0] done_task,done_frame,done_model,done_destination,
 output wire [63:0] done_session,output wire busy,error,catalog_ready,
 output wire loader_error,output wire [7:0] loader_error_code,dma_error_code,output wire [31:0] compute_error_code,
 output wire [2:0] active_layer,output reg [31:0] total_read_beats,total_write_beats,total_write_responses,
 output wire [3:0] arid,output wire [31:0] araddr,output wire [7:0] arlen,output wire [2:0] arsize,
 output wire [1:0] arburst,output wire arvalid,input wire arready,
 input wire [127:0] rdata,input wire [3:0] rid,input wire [1:0] rresp,input wire rlast,rvalid,output wire rready,
 output wire [3:0] awid,output wire [31:0] awaddr,output wire [7:0] awlen,output wire [2:0] awsize,
 output wire [1:0] awburst,output wire awvalid,input wire awready,
 output wire [127:0] wdata,output wire [15:0] wstrb,output wire wlast,wvalid,input wire wready,
 input wire [3:0] bid,input wire [1:0] bresp,input wire bvalid,output wire bready
);
 localparam IDLE=0,LREQ=1,LWAIT=2,LAUNCH=3,RUN=4,LRETIRE=5,DONE=6,FAIL=7;
 reg [2:0] state,layer;reg active,frame_fault;
 reg [31:0] task_tag,frame_tag,model_tag,input_base,output_base;reg [63:0] session_tag;
 wire owner_error,core_fault,owner_busy;
 wire [31:0] read_beats,write_beats,write_responses;
 function overlaps(input [32:0] a,ae,b,be);begin overlaps=a<be&&b<ae;end endfunction
 wire [32:0] ie={1'b0,frame_source}+SLOT_BYTES,oe={1'b0,frame_destination}+SLOT_BYTES;
 wire [32:0] f0e={1'b0,FEATURE0}+FEATURE_BYTES,f1e={1'b0,FEATURE1}+FEATURE_BYTES;
 wire map_ok=WIDTH>=8&&WIDTH<=1280&&HEIGHT>=4&&HEIGHT<=720&&WIDTH%8==0&&HEIGHT%4==0&&
  SLOT_BYTES>=WIDTH*HEIGHT*4&&FEATURE_BYTES>=WIDTH*HEIGHT*2&&
  frame_source[3:0]==0&&frame_destination[3:0]==0&&FEATURE0[3:0]==0&&FEATURE1[3:0]==0&&
  ie<=MEM_BYTES&&oe<=MEM_BYTES&&f0e<=MEM_BYTES&&f1e<=MEM_BYTES&&frame_session<=64'hfffffffffffffff8&&
  !overlaps({1'b0,frame_source},ie,{1'b0,frame_destination},oe)&&
  !overlaps({1'b0,FEATURE0},f0e,{1'b0,FEATURE1},f1e)&&
  !overlaps({1'b0,frame_source},ie,{1'b0,FEATURE0},f0e)&&!overlaps({1'b0,frame_source},ie,{1'b0,FEATURE1},f1e)&&
  !overlaps({1'b0,frame_destination},oe,{1'b0,FEATURE0},f0e)&&!overlaps({1'b0,frame_destination},oe,{1'b0,FEATURE1},f1e);
 wire model_ok=frame_model==MODEL0||frame_model==MODEL1;
 assign error=frame_fault||loader_error||owner_error||core_fault;
 assign frame_ready=!rst&&!active&&!error&&!external_fault&&catalog_ready&&model_ok&&map_ok;
 wire accept=frame_valid&&frame_ready;
 assign busy=active;assign active_layer=layer;
 assign frame_done_valid=!rst&&state==DONE;
 assign done_task=task_tag;assign done_frame=frame_tag;assign done_model=model_tag;assign done_destination=output_base;assign done_session=session_tag;
 reg [11:0] job_width,job_height;reg [3:0] job_ci,job_co;reg job_stride2,job_up2,job_residual;
 wire [31:0] job_source=layer==0?input_base:layer[0]?FEATURE0:FEATURE1;
 wire [31:0] job_destination=layer==7?output_base:layer[0]?FEATURE1:FEATURE0;
 wire [31:0] job_source_capacity=layer==0?SLOT_BYTES:FEATURE_BYTES;
 wire [31:0] job_destination_capacity=layer==7?SLOT_BYTES:FEATURE_BYTES;
 wire [127:0] job_descriptor={task_tag,frame_tag,model_tag,job_destination};
 wire [63:0] job_session=session_tag+{61'd0,layer};wire [7:0] job_abi=2;
 always @(*)begin
  job_width=WIDTH;job_height=HEIGHT;job_ci=4;job_co=2;job_stride2=0;job_up2=0;job_residual=0;
  case(layer)
   1:begin job_ci=2;job_co=4;job_stride2=1;end
   2:begin job_width=WIDTH/2;job_height=HEIGHT/2;job_ci=4;job_co=8;job_stride2=1;end
   3,4:begin job_width=WIDTH/4;job_height=HEIGHT/4;job_ci=8;job_co=8;job_residual=1;end
   5:begin job_width=WIDTH/4;job_height=HEIGHT/4;job_ci=8;job_co=4;job_up2=1;end
   6:begin job_width=WIDTH/2;job_height=HEIGHT/2;job_ci=4;job_co=2;job_up2=1;end
   7:begin job_ci=2;job_co=4;end
   default:begin end
  endcase
 end
 wire req_ready,loaded_valid,loaded_ready,loader_retire_ready;wire [2:0] loaded_layer;
 wire [127:0] loaded_descriptor;wire [63:0] loaded_session;
 wire cfg_valid,cfg_ready,cfg_stage;wire [1:0] cfg_target,cfg_kind;wire [9:0] cfg_index;wire [255:0] cfg_data;wire [31:0] cfg_model;
 wire loader_lease;
 wire abort=frame_fault||owner_error||core_fault||(external_fault&&active&&state!=DONE);
 board_model_loader #(.WORDS(ASSET_WORDS),.INIT_FILE(ASSET_FILE),.EXPECTED_CRC(ASSET_CRC),.MODEL0(MODEL0),.MODEL1(MODEL1),.BASES(BASES),.COUNTS(COUNTS)) loader(
  clk,rst,abort,catalog_ready,loader_error,loader_error_code,loader_lease,
  state==LREQ,req_ready,layer,job_descriptor,job_session,
  cfg_valid,cfg_ready,cfg_target,cfg_stage,cfg_kind,cfg_index,cfg_data,cfg_model,
  loaded_valid,loaded_ready,loaded_layer,loaded_descriptor,loaded_session,
  state==LRETIRE,loader_retire_ready,layer,job_descriptor,job_session,1'b1);
 wire load_match=loaded_layer==layer&&loaded_descriptor==job_descriptor&&loaded_session==job_session;
 assign loaded_ready=state==LWAIT&&!error&&!external_fault&&load_match;
 wire job_valid=state==LAUNCH,job_ready;
 wire go=job_valid&&job_ready;
 wire complete_valid,complete_ready;wire [127:0] complete_descriptor;wire [63:0] complete_session;wire [31:0] complete_destination;
 wire complete_match=complete_descriptor==job_descriptor&&complete_session==job_session&&complete_destination==job_destination;
 assign complete_ready=state==RUN&&!error&&!external_fault&&complete_match;
 wire source_valid,source_ready,source_eol,source_last,sink_valid,sink_ready,sink_last;
 wire [63:0] source_data,sink_data,source_session,sink_session;wire [7:0] source_mask,sink_mask;
 wire [11:0] source_row;wire [9:0] source_word;wire [127:0] source_descriptor,sink_descriptor;wire [31:0] sink_pixel;
 reg retire_valid;wire retire_ready;wire [127:0] retire_descriptor=job_descriptor;wire [63:0] retire_session=job_session;
 wire retire_error=1'b0;
 wire engine_ready;
 board_stage_dma_owner #(.BB(BB),.WDOG(WDOG)) dma(
  .clk(clk),.rst(rst),.job_valid(job_valid),.job_ready(job_ready),.engine_ready(engine_ready),.job_abi(job_abi),
  .job_descriptor(job_descriptor),.job_session(job_session),.job_source(job_source),.job_destination(job_destination),
  .job_source_capacity(job_source_capacity),.job_destination_capacity(job_destination_capacity),.job_width(job_width),.job_height(job_height),
  .job_ci(job_ci),.job_co(job_co),.job_stride2(job_stride2),.job_up2(job_up2),.job_residual(job_residual),
  .source_valid(source_valid),.source_ready(source_ready),.source_data(source_data),.source_mask(source_mask),.source_row(source_row),.source_word(source_word),
  .source_eol(source_eol),.source_last(source_last),.source_descriptor(source_descriptor),.source_session(source_session),
  .sink_valid(sink_valid),.sink_ready(sink_ready),.sink_data(sink_data),.sink_mask(sink_mask),.sink_pixel(sink_pixel),.sink_last(sink_last),.sink_descriptor(sink_descriptor),.sink_session(sink_session),
  .retire_valid(retire_valid),.retire_ready(retire_ready),.retire_descriptor(retire_descriptor),.retire_session(retire_session),.retire_error(retire_error),
  .core_fault(abort||loader_error),.complete_valid(complete_valid),.complete_ready(complete_ready),.complete_descriptor(complete_descriptor),.complete_session(complete_session),.complete_destination(complete_destination),
  .busy(owner_busy),.error(owner_error),.error_code(dma_error_code),
  .arid(arid),.araddr(araddr),.arlen(arlen),.arsize(arsize),.arburst(arburst),.arvalid(arvalid),.arready(arready),.rdata(rdata),.rid(rid),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),
  .awid(awid),.awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),.awvalid(awvalid),.awready(awready),.wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),.bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready),
  .read_beats(read_beats),.write_beats(write_beats),.write_responses(write_responses));
 wire ss,ms,hs,scc,mcc,hcc,sd,md,hd,sbusy,mbusy,hbusy,serr,merr,herr;
 wire [13:0] se,he;wire [20:0] me;
 wire sv,mv,hv,sr,mr,hr,sl,ml,hl;wire [63:0] sdata,mdata,hdata,ssess,msess,hsess;
 wire [7:0] smask,mmask,hmask;wire [31:0] spx,mpx,hpx;wire [127:0] sdesc,mdesc,hdesc;
 wire selected_ready=layer==0?ss:layer==7?hs:ms;
 assign engine_ready=selected_ready&&!error&&!external_fault;
 assign core_fault=serr||merr||herr||(layer!=0&&layer!=7&&source_valid&&source_word[9]);
 assign compute_error_code=merr?{8'h02,3'd0,me}:serr?{8'h01,10'd0,se}:herr?{8'h03,10'd0,he}:32'd0;
 assign cfg_ready=state==LWAIT&&!owner_busy&&!error&&!external_fault&&(cfg_target==0?scc:cfg_target==1?mcc:cfg_target==2?hcc:1'b0);
 wire ct=cfg_valid&&cfg_ready;
 rgb_io_stage #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.HEAD(0)) stem(clk,rst,ct&&cfg_target==0,scc,cfg_kind,cfg_index,cfg_data,cfg_model,
  go&&layer==0,ss,job_descriptor,job_session,source_valid&&layer==0,sr,source_data,source_mask,source_row,source_word,source_eol,source_last,source_descriptor,source_session,
  sv,sink_ready&&layer==0,sdata,smask,spx,sl,sdesc,ssess,sbusy,serr,se,sd);
 stream_dw_pw_stage macro_core(clk,rst,ct&&cfg_target==1,mcc,cfg_stage,cfg_kind,cfg_index[3:0],cfg_data,
  go&&layer!=0&&layer!=7,ms,job_descriptor,job_session,job_width,job_height,job_ci,job_co,job_stride2,job_up2,job_residual,
  source_valid&&layer!=0&&layer!=7,mr,source_data,source_mask,source_row,source_word[8:0],source_eol,source_last,source_descriptor,source_session,
  mv,sink_ready&&layer!=0&&layer!=7,mdata,mmask,mpx,ml,mdesc,msess,mbusy,merr,me,md);
 rgb_io_stage #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.HEAD(1)) head(clk,rst,ct&&cfg_target==2,hcc,cfg_kind,cfg_index,cfg_data,cfg_model,
  go&&layer==7,hs,job_descriptor,job_session,source_valid&&layer==7,hr,source_data,source_mask,source_row,source_word,source_eol,source_last,source_descriptor,source_session,
  hv,sink_ready&&layer==7,hdata,hmask,hpx,hl,hdesc,hsess,hbusy,herr,he,hd);
 assign source_ready=layer==0?sr:layer==7?hr:mr;
 assign sink_valid=layer==0?sv:layer==7?hv:mv;assign sink_data=layer==0?sdata:layer==7?hdata:mdata;
 assign sink_mask=layer==0?smask:layer==7?hmask:mmask;assign sink_pixel=layer==0?spx:layer==7?hpx:mpx;
 assign sink_last=layer==0?sl:layer==7?hl:ml;assign sink_descriptor=layer==0?sdesc:layer==7?hdesc:mdesc;
 assign sink_session=layer==0?ssess:layer==7?hsess:msess;
 wire compute_done=layer==0?sd:layer==7?hd:md;
 always @(posedge clk)begin
  if(rst)retire_valid<=0;
  else begin if(retire_valid&&retire_ready)retire_valid<=0;if(compute_done)retire_valid<=1;end
 end
 always @(posedge clk)begin
  if(rst)begin state<=IDLE;layer<=0;active<=0;frame_fault<=0;task_tag<=0;frame_tag<=0;model_tag<=0;input_base<=0;output_base<=0;session_tag<=0;total_read_beats<=0;total_write_beats<=0;total_write_responses<=0;end
  else begin
   if(frame_valid&&!active&&(!map_ok||!model_ok))frame_fault<=1;
   if(active&&state!=DONE&&external_fault)frame_fault<=1;
   if(state==LWAIT&&loaded_valid&&!load_match)frame_fault<=1;
   if(state==RUN&&complete_valid&&!complete_match)frame_fault<=1;
   if(error||(active&&state!=DONE&&external_fault))begin
    // Preserve pending request payloads; no hidden successful child release.
    if((state==LREQ&&!req_ready)||(state==LAUNCH&&!job_ready))state<=state;
    else state<=FAIL;
   end else case(state)
    IDLE:if(accept)begin active<=1;task_tag<=frame_task;frame_tag<=frame_id;model_tag<=frame_model;input_base<=frame_source;output_base<=frame_destination;session_tag<=frame_session;layer<=0;state<=LREQ;total_read_beats<=0;total_write_beats<=0;total_write_responses<=0;end
    LREQ:if(req_ready)state<=LWAIT;
    LWAIT:if(loaded_valid&&loaded_ready)state<=LAUNCH;
    LAUNCH:if(go)state<=RUN;
    RUN:if(complete_valid&&complete_ready)begin
     total_read_beats<=total_read_beats+read_beats;total_write_beats<=total_write_beats+write_beats;total_write_responses<=total_write_responses+write_responses;state<=LRETIRE;
    end
    LRETIRE:if(loader_retire_ready)begin if(layer==7)state<=DONE;else begin layer<=layer+1'b1;state<=LREQ;end end
    DONE:if(frame_done_ready)begin active<=0;state<=IDLE;end
    default:begin end
   endcase
  end
 end
endmodule
