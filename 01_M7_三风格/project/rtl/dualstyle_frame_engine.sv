// Fixed TinyInk graph; legacy parameter names are kept at the service boundary.
// The legacy C4 loader/feature stores/cores are not instantiated or compiled.
module dualstyle_frame_engine #(
 parameter WIDTH=640,HEIGHT=480,BB=16,WDOG=100000,MEM_BYTES=268435456,
 parameter [31:0] SLOT_BYTES=32'h00400000,FEATURE_BYTES=32'h00200000,
 parameter [31:0] FEATURE0=32'h06000000,FEATURE1=32'h06200000,
 parameter ASSET_FILE="unused",ASSET_WORDS=0,
 parameter [31:0] ASSET_CRC=0,MODEL0=32'h50503031,MODEL1=32'h54493031,MODEL2=32'h544e3031,
 parameter [255:0] BASES=0,parameter [127:0] COUNTS=0
)(
 input wire clk,rst,external_fault,
 input wire frame_valid,output wire frame_ready,input wire [31:0] frame_task,frame_id,frame_model,frame_source,frame_destination,
 input wire [63:0] frame_session,
 output wire frame_done_valid,input wire frame_done_ready,output wire [31:0] done_task,done_frame,done_model,done_destination,
 output wire [63:0] done_session,output wire busy,error,catalog_ready,
 output wire loader_error,output wire [7:0] loader_error_code,dma_error_code,output wire [31:0] compute_error_code,
 output wire [2:0] active_layer,output wire [31:0] total_read_beats,total_write_beats,total_write_responses,
 output wire [3:0] arid,output wire [31:0] araddr,output wire [7:0] arlen,output wire [2:0] arsize,
 output wire [1:0] arburst,output wire arvalid,input wire arready,
 input wire [127:0] rdata,input wire [3:0] rid,input wire [1:0] rresp,input wire rlast,rvalid,output wire rready,
 output wire [3:0] awid,output wire [31:0] awaddr,output wire [7:0] awlen,output wire [2:0] awsize,
 output wire [1:0] awburst,output wire awvalid,input wire awready,
 output wire [127:0] wdata,output wire [15:0] wstrb,output wire wlast,wvalid,input wire wready,
 input wire [3:0] bid,input wire [1:0] bresp,input wire bvalid,output wire bready
);
 localparam IDLE=0,START=1,RUN=2,FINISH=3,FAIL=4;
 reg [2:0] state;reg fault;
 reg [31:0] task_q,id_q,model_q,source_q,dest_q;reg [63:0] session_q;
 wire read_desc_ready,rdone;wire [3:0] rerror;wire rpoison;
 wire pv,pr;wire [23:0] rgb;wire [10:0] px;wire [9:0] py;
 wire cv,cr,csof,ceol,ceof,core_done;wire [127:0] cdata;
 wire writer_done,writer_error;reg read_finished,core_finished;
 wire [32:0] ie={1'b0,frame_source}+WIDTH*HEIGHT*4;
 wire [32:0] oe={1'b0,frame_destination}+WIDTH*HEIGHT*4;
 wire map_ok=frame_source[3:0]==0&&frame_destination[3:0]==0&&
  ie<=MEM_BYTES&&oe<=MEM_BYTES&&SLOT_BYTES>=WIDTH*HEIGHT*4&&
  !(frame_source<oe&&frame_destination<ie);
 wire model_ok=frame_model==MODEL0||frame_model==MODEL1||frame_model==MODEL2;
 assign error=fault||writer_error||rpoison||(rdone&&rerror!=0);
 assign frame_ready=!rst&&state==IDLE&&!error&&!external_fault&&map_ok&&model_ok;
 assign catalog_ready=!rst; // Static readmemh weights; no legacy loader.
 assign loader_error=0;assign loader_error_code=0;
 assign dma_error_code=writer_error?8'h20:(rpoison||(rdone&&rerror!=0))?8'h10:0;
 assign compute_error_code=fault?32'h50500001:0;
 assign busy=state!=IDLE;assign active_layer=0;
 assign frame_done_valid=state==FINISH&&!error&&!external_fault;
 assign done_task=task_q;assign done_frame=id_q;assign done_model=model_q;
 assign done_destination=dest_q;assign done_session=session_q;
 wire start=state==START;
 ab05_rgbx_axi_reader_prefetch #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.PREVIEW(0),.AXI_ID(2),.WATCHDOG(WDOG)) reader(
  .clk(clk),.rstn(!rst),.desc_valid(start),.desc_ready(read_desc_ready),
  .desc_frame_id(id_q),.desc_base(source_q),.desc_stride(WIDTH*4),
  .m_arid(arid),.m_araddr(araddr),.m_arlen(arlen),.m_arsize(arsize),.m_arburst(arburst),.m_arvalid(arvalid),.m_arready(arready),
  .m_rid(rid),.m_rdata(rdata),.m_rresp(rresp),.m_rlast(rlast),.m_rvalid(rvalid),.m_rready(rready),
  .pixel_valid(pv),.pixel_ready(pr),.pixel_rgb(rgb),.pixel_frame_id(),.pixel_x(px),.pixel_y(py),.pixel_sof(),.pixel_eol(),.pixel_eof(),
  .done_valid(rdone),.done_ready(1'b1),.done_frame_id(),.done_error(rerror),.quarantined(rpoison),
  .accepted_beats(total_read_beats),.ar_commands(),.max_ar_wait(),.output_stall_cycles());
 reg ink_selected,neon_selected;
 always @(posedge clk)if(rst)begin ink_selected<=0;neon_selected<=0;end else if(frame_valid&&frame_ready)begin ink_selected<=frame_model!=MODEL0;neon_selected<=frame_model==MODEL2;end
 hd720_fused_core #(.W(WIDTH),.H(HEIGHT)) core(.clk(clk),.rst(rst),.start(start),.ink_mode(ink_selected),.neon_mode(neon_selected),
 .pixel_valid(pv),.pixel_ready(pr),.pixel_rgb(rgb),.pixel_x(px),.pixel_y(py),.result_valid(cv),.result_ready(cr),.result_data(cdata),.result_sof(csof),.result_eol(ceol),.result_eof(ceof),.busy(),.done(core_done),.cycles());
 ab05_native_writer #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BB(BB),.WDOG(WDOG)) writer(
  .clk(clk),.rstn(!rst),.start(start),.base(dest_q),.id(id_q),.busy(),.done(writer_done),.error(writer_error),
  .valid(cv),.ready(cr),.payload({id_q,csof,ceol,ceof,cdata}),
  .awid(awid),.awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),.awvalid(awvalid),.awready(awready),
  .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),.bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready),
  .accepted_beats(total_write_beats),.committed_bursts(total_write_responses),.wait_cycles());
 always @(posedge clk)begin
  if(rst)begin state<=IDLE;fault<=0;task_q<=0;id_q<=0;model_q<=0;source_q<=0;dest_q<=0;session_q<=0;read_finished<=0;core_finished<=0;end
  else begin
   if(external_fault)fault<=1;
   if(rdone)read_finished<=rerror==0;
   if(core_done)core_finished<=1;
   case(state)
    IDLE:if(frame_valid&&!external_fault)begin
     if(!map_ok||!model_ok)begin fault<=1;state<=FAIL;end
     else if(frame_ready)begin
      task_q<=frame_task;id_q<=frame_id;model_q<=frame_model;source_q<=frame_source;dest_q<=frame_destination;session_q<=frame_session;
      read_finished<=0;core_finished<=0;state<=START;
     end
    end
    START:begin if(!read_desc_ready)fault<=1;state<=RUN;end
    RUN:begin
     if(rpoison||writer_error||(rdone&&rerror!=0))state<=FAIL;
     else if(writer_done)begin
      if(read_finished&&core_finished&&!fault&&!external_fault)state<=FINISH;
      else begin fault<=1;state<=FAIL;end
     end
    end
    FINISH:if(frame_done_ready)state<=error||external_fault?FAIL:IDLE;
    FAIL:begin end
    default:begin fault<=1;state<=FAIL;end
   endcase
  end
 end
endmodule
