// A18 descriptor-driven nearest-neighbour RGB888x -> packed RGB reference DMA.
// One AXI clock, one outstanding transaction, one-beat bursts. Functional
// integration candidate; not yet connected to the A17 project or FPS-qualified.
// Source descriptor must reference an immutable, complete frame. Input credit
// must come from a frame owner/refcount manager, never a second competing reader.
// Reset after a fault must also reset/drain the AXI fabric before reusing memory.
module a18_resize_packed #(
 parameter integer IN_W=640, IN_H=480, OUT_W=256, OUT_H=192,
 parameter [31:0] OUT_BASE=32'h02400000, BUFFER_BYTES=32'h00024000,
 parameter [3:0] AXI_ID=4'd2
)(
 input wire clk,rstn,
 input wire input_valid,output wire input_ready,
 input wire [31:0] input_id,input_base,input_stride,
 input wire [15:0] input_width,input_height,input_format,
 output reg source_release_valid,input wire source_release_ready,
 output reg [31:0] source_release_id,
 output reg output_valid,input wire output_ready,
 output reg [31:0] output_id,output_base,
 output wire [15:0] output_width,output_height,output_format,
 output wire [31:0] output_stride,output_bytes,
 input wire release_valid,output wire release_ready,input wire [31:0] release_id,
 output reg frame_done,output reg fault,output reg [3:0] error_code,
 output wire [3:0] arid,output reg [31:0] araddr,
 output wire [7:0] arlen,output wire [2:0] arsize,output wire [1:0] arburst,
 output wire arvalid,input wire arready,
 input wire [3:0] rid,input wire [127:0] rdata,input wire [1:0] rresp,
 input wire rlast,rvalid,output wire rready,
 output wire [3:0] awid,output wire [31:0] awaddr,
 output wire [7:0] awlen,output wire [2:0] awsize,output wire [1:0] awburst,
 output wire awvalid,input wire awready,
 output wire [127:0] wdata,output wire [15:0] wstrb,
 output wire wlast,wvalid,input wire wready,
 input wire [3:0] bid,input wire [1:0] bresp,input wire bvalid,output wire bready
);
 localparam integer BYTES=OUT_W*OUT_H*3;
 localparam integer XB=IN_W/OUT_W, XF=IN_W%OUT_W;
 localparam integer YB=IN_H/OUT_H, YF=IN_H%OUT_H;
 localparam IDLE=0,FETCH=1,AR=2,R=3,PIXEL=4,PACK=5,AW=6,W=7,B=8,ADV=9,FINISH=10,DRAIN=11,STOP=12;
 reg [3:0] state;
 reg [1:0] owned,exported;
 reg [31:0] ids0,ids1,src_base,src_stride,job_id,dst_base,write_offset;
 reg dst_slot;
 reg [15:0] ox,oy,sx,sy,xf,yf;
 wire [16:0] xsum={1'b0,xf}+XF,ysum={1'b0,yf}+YF;
 reg cache_valid;reg [31:0] cache_addr;reg [127:0] cache_data;
 reg [23:0] rgb;reg [1:0] component;
 reg [127:0] pack_word,send_word;reg [4:0] pack_count;
 reg [15:0] send_strobe;
 wire [31:0] wanted_addr=src_base+sy*src_stride+((sx>>2)<<4);
 wire [7:0] next_byte=component==0 ? rgb[23:16] : component==1 ? rgb[15:8] : rgb[7:0];
 wire [127:0] packed_next=pack_word | ({{120{1'b0}},next_byte} << (pack_count*8));
 wire final_pixel=(ox==OUT_W-1 && oy==OUT_H-1);
 wire final_byte=final_pixel && component==2;
 wire [63:0] source_end={32'd0,input_base}+(IN_H-1)*{32'd0,input_stride}+IN_W*4;
 wire [63:0] source_begin={32'd0,input_base};
 wire [63:0] destination_begin={32'd0,OUT_BASE};
 wire [63:0] destination_end=destination_begin+2*{32'd0,BUFFER_BYTES};
 wire descriptor_ok=input_width==IN_W && input_height==IN_H && input_format==1 &&
     input_base[3:0]==0 && input_stride[3:0]==0 && input_stride>=IN_W*4 &&
     source_end<=64'h100000000 &&
     !(source_begin<destination_end && source_end>destination_begin);
 wire duplicate_id=(owned[0] && ids0==input_id)||(owned[1] && ids1==input_id);
 wire release0=owned[0] && exported[0] && ids0==release_id;
 wire release1=owned[1] && exported[1] && ids1==release_id;
 wire bad_release=release_valid && release_ready && !(release0 || release1);
 assign input_ready=rstn && !fault && state==IDLE && owned!=2'b11;
 assign release_ready=rstn && !fault;
 assign output_width=OUT_W;assign output_height=OUT_H;
 assign output_format=2;assign output_stride=OUT_W*3;assign output_bytes=BYTES;
 assign arid=AXI_ID;assign arlen=0;assign arsize=4;assign arburst=1;
 assign arvalid=(state==AR);assign rready=(state==R || state==DRAIN);
 assign awid=AXI_ID;assign awlen=0;assign awsize=4;assign awburst=1;
 assign awaddr=dst_base+write_offset;assign awvalid=(state==AW);
 assign wdata=send_word;assign wstrb=send_strobe;assign wlast=1;
 assign wvalid=(state==W);assign bready=(state==B);
 // synopsys translate_off
 initial begin
  if(IN_W<1 || IN_H<1 || OUT_W<1 || OUT_H<1 || OUT_W>IN_W || OUT_H>IN_H ||
    IN_W>65535 || IN_H>65535 || BUFFER_BYTES<((BYTES+15)/16)*16 ||
    OUT_BASE[3:0]!=0 || BUFFER_BYTES[3:0]!=0 || destination_end>64'h100000000)
      $fatal(1,"A18 parameter contract");
 end
 // synopsys translate_on
 always @(posedge clk or negedge rstn) begin
  if(!rstn) begin
   state<=IDLE;owned<=0;exported<=0;ids0<=0;ids1<=0;
   src_base<=0;src_stride<=0;job_id<=0;dst_base<=0;dst_slot<=0;write_offset<=0;
   ox<=0;oy<=0;sx<=0;sy<=0;xf<=0;yf<=0;cache_valid<=0;cache_addr<=0;cache_data<=0;
   rgb<=0;component<=0;pack_word<=0;send_word<=0;pack_count<=0;send_strobe<=0;araddr<=0;
   output_valid<=0;output_id<=0;output_base<=0;
   source_release_valid<=0;source_release_id<=0;frame_done<=0;fault<=0;error_code<=0;
  end else begin
   frame_done<=0;
   if(output_valid && output_ready) begin
    output_valid<=0;
    if(dst_slot) exported[1]<=1;else exported[0]<=1;
   end
   if(source_release_valid && source_release_ready) source_release_valid<=0;
   if(release_valid && release_ready) begin
    if(release0) begin owned[0]<=0;exported[0]<=0;end
    else if(release1) begin owned[1]<=0;exported[1]<=0;end
    else begin fault<=1;error_code<=5;end
   end
   case(state)
    IDLE: if(input_valid && input_ready) begin
     if(!descriptor_ok || duplicate_id) begin fault<=1;error_code<=1;state<=STOP;end
     else begin
      job_id<=input_id;src_base<=input_base;src_stride<=input_stride;
      dst_slot<=owned[0];dst_base<=OUT_BASE+(owned[0] ? BUFFER_BYTES : 0);
      if(!owned[0]) begin owned[0]<=1;exported[0]<=0;ids0<=input_id;end
      else begin owned[1]<=1;exported[1]<=0;ids1<=input_id;end
      ox<=0;oy<=0;sx<=0;sy<=0;xf<=0;yf<=0;write_offset<=0;
      cache_valid<=0;pack_word<=0;pack_count<=0;state<=FETCH;
     end
    end
    FETCH: if(cache_valid && cache_addr==wanted_addr) state<=PIXEL;
       else begin araddr<=wanted_addr;state<=AR;end
    AR: if(arready) state<=R;
    R: if(rvalid) begin
     if(rid!=AXI_ID || rresp!=0 || !rlast) begin
      fault<=1;error_code<=2;state<=rlast ? STOP : DRAIN;
     end else begin cache_data<=rdata;cache_addr<=araddr;cache_valid<=1;state<=PIXEL;end
    end
    PIXEL: begin rgb<=cache_data[(sx[1:0]*32)+8 +:24];component<=0;state<=PACK;end
    PACK: begin
     if(pack_count==15 || final_byte) begin
      send_word<=packed_next;send_strobe<=16'hffff >> (15-pack_count);state<=AW;
     end else begin pack_word<=packed_next;pack_count<=pack_count+1'b1;
      if(component==2) state<=ADV;else component<=component+1'b1;
     end
    end
    AW: if(awready) state<=W;
    W: if(wready) state<=B;
    B: if(bvalid) begin
     if(fault || bad_release || bid!=AXI_ID || bresp!=0) begin
      fault<=1;if(!fault && !bad_release) error_code<=3;state<=STOP;
     end
     else begin
      pack_word<=0;pack_count<=0;write_offset<=write_offset+16;
      if(final_byte) begin
       output_id<=job_id;output_base<=dst_base;output_valid<=1;frame_done<=1;
       source_release_id<=job_id;source_release_valid<=1;state<=FINISH;
      end else if(component==2) state<=ADV;
      else begin component<=component+1'b1;state<=PACK;end
     end
    end
    ADV: begin
     if(ox==OUT_W-1) begin
      ox<=0;sx<=0;xf<=0;oy<=oy+1'b1;
      if(ysum>=OUT_H) begin sy<=sy+YB+1;yf<=ysum-OUT_H;end
      else begin sy<=sy+YB;yf<=ysum;end
     end else begin
      ox<=ox+1'b1;
      if(xsum>=OUT_W) begin sx<=sx+XB+1;xf<=xsum-OUT_W;end
      else begin sx<=sx+XB;xf<=xsum;end
     end
     state<=FETCH;
    end
    FINISH: if(!output_valid && !source_release_valid) state<=IDLE;
    DRAIN: if(rvalid && rlast) state<=STOP;
    STOP: state<=STOP;
    default: begin fault<=1;error_code<=4;state<=STOP;end
   endcase
   // Fault does not withdraw an accepted transaction. Finish its R/W/B first;
   // suppress publication and further input on any ownership fault.
   if(fault && state!=AR && state!=R && state!=DRAIN && state!=AW && state!=W && state!=B) begin
    state<=STOP;output_valid<=0;source_release_valid<=0;
   end
  end
 end
endmodule
