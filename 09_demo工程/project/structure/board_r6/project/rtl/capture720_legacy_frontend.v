// Integration entry for the existing debayer 2px/clock BGR stream.
// VS is active-high frame sync (as in preproc_640); frame id must come from
// the RAW capture owner, not a display VS counter (display can reread a frame).
// Output goes to fb640_wr.pclk=rclk, .in_de/.in_sof/.din. Set rclk=2*wclk.
// Output DDR geometry must be 1280x720, 5120-byte stride, FRAME_BEATS=230400.
// This wrapper does not connect AXI or publish complete-frame descriptors.
module capture720_legacy_frontend #(
 parameter integer IN_WIDTH=1920,IN_HEIGHT=1080,FIFO_AW=4
)(
 input wire wclk,wrstn,in_vs,in_de,input wire [47:0] bgr_datax2,
 input wire [31:0] source_frame_id,
 input wire rclk,rrstn,
 output wire out_valid,out_sof,out_eol,output wire [23:0] out_rgb,
 output wire [31:0] out_source_frame_id,
 output wire source_fault,output wire sink_fault,
 output wire [3:0] source_error_code
);
 wire arstn=wrstn && rrstn;
 reg vs_d,de_d,sof_pending,tap_fault,seen_vs;
 reg [15:0] pair_index;
 reg [31:0] latched_id;
 wire vs_rise=in_vs && !vs_d;
 wire input_armed=seen_vs || vs_rise;
 wire first_pair=in_de && input_armed && (sof_pending || vs_rise);
 wire last_pair=in_de && !first_pair && pair_index==IN_WIDTH/2-1;
 always @(posedge wclk or negedge arstn)begin
  if(!arstn)begin vs_d<=0;de_d<=0;sof_pending<=0;tap_fault<=0;pair_index<=0;latched_id<=0;seen_vs<=0;end
  else begin
   vs_d<=in_vs;de_d<=in_de;
   if(vs_rise)begin seen_vs<=1;sof_pending<=1;latched_id<=source_frame_id;end
   if(in_de && input_armed)begin
    if(first_pair)begin sof_pending<=0;pair_index<=1;end
    else if(last_pair)pair_index<=0;
    else pair_index<=pair_index+1'b1;
   end
   if(input_armed && !in_de && de_d && pair_index!=0)tap_fault<=1;
  end
 end
 wire pv,ps,pe,pdone,core_fault;wire [47:0] pd;wire[31:0] pfid;wire[15:0] px,py;
 wire[3:0] core_code;
 rgb1080_to720_pair #(.IN_WIDTH(IN_WIDTH),.IN_HEIGHT(IN_HEIGHT),.BGR_INPUT(1)) resize(
  .clk(wclk),.rstn(arstn),.in_valid(in_de && input_armed && !tap_fault),.in_sof(first_pair && !tap_fault),
  .in_eol(last_pair && !tap_fault),.in_data(bgr_datax2),
  .in_frame_id(vs_rise ? source_frame_id : latched_id),
  .out_valid(pv),.out_sof(ps),.out_eol(pe),.out_data(pd),.out_frame_id(pfid),
  .out_x(px),.out_y(py),.frame_done(pdone),.fault(core_fault),.error_code(core_code));
 wire cv,cs,ce,cwf,crf;wire[23:0] cd;wire[31:0] cfid;wire ff,fe;
 assign source_fault=tap_fault || core_fault || cwf;
 assign source_error_code=tap_fault ? 4'd8 : (core_fault ? core_code : (cwf ? 4'd9 : 4'd0));
 capture_pair_to_pixel_cdc #(.AW(FIFO_AW)) serial(
  .wclk(wclk),.wrstn(wrstn),.in_valid(pv && !source_fault),.in_sof(ps),.in_eol(pe),
  .in_data(pd),.in_frame_id(pfid),.rclk(rclk),.rrstn(rrstn),
  .out_valid(cv),.out_sof(cs),.out_eol(ce),.out_data(cd),.out_frame_id(cfid),
  .write_fault(cwf),.read_fault(crf),.fifo_full(ff),.fifo_empty(fe));
 (* async_reg="true" *) reg [1:0] sf_sync;
 always @(posedge rclk or negedge arstn)
  if(!arstn)sf_sync<=0;else sf_sync<={sf_sync[0],source_fault};
 assign sink_fault=sf_sync[1] || crf;
 assign out_valid=cv && !sink_fault;
 assign out_sof=cs && !sink_fault;
 assign out_eol=ce && !sink_fault;
 assign out_rgb=cd;assign out_source_frame_id=cfid;
endmodule
