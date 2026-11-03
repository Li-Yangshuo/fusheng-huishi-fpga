// A18.3 INPUT DIAG ONLY. Consumes a complete immutable packed RGB frame.
// The rolling hash is an activity digest, NOT a golden-content comparison/CRC.
// On any error keep ownership; drain the current response if possible. A
// global fabric reset is required for recovery. Never withdraw stalled ARVALID.
module a18_input_diag #(
 parameter integer WIDTH=256,HEIGHT=192,
 parameter [31:0] BASE=32'h02400000,SLOT_BYTES=32'h24000,
 parameter integer WATCHDOG=100000000,
 parameter [3:0] AXI_ID=4'd3
)(
 input wire clk,rstn,
 input wire input_valid,output wire input_ready,
 input wire [31:0] input_id,input_base,input_stride,input_bytes,
 input wire [15:0] input_width,input_height,input_format,
 output wire release_valid,input wire release_ready,output reg [31:0] release_id,
 output reg [31:0] completed,error_bits,last_hash,total_beats,
 output wire [3:0] arid,output reg [31:0] araddr,output wire [7:0] arlen,
 output wire arvalid,input wire arready,
 input wire [3:0] rid,input wire [127:0] rdata,input wire [1:0] rresp,
 input wire rlast,rvalid,output wire rready
);
 localparam integer BYTES=WIDTH*HEIGHT*3,BEATS=BYTES/16;
 localparam IDLE=0,AR=1,R=2,RELEASE=3,DRAIN=4,STOP=5;
 reg [2:0] state;
 reg [31:0] left,watchdog,digest;
 reg [5:0] burst_beats,beat;
 wire descriptor_ok=input_width==WIDTH && input_height==HEIGHT && input_format==2 &&
     input_stride==WIDTH*3 && input_bytes==BYTES &&
     (input_base==BASE || input_base==BASE+SLOT_BYTES);
 wire [31:0] boundary_beats=(32'd4096-{20'd0,araddr[11:0]})>>4;
 wire [31:0] limited=left<32 ? left:32;
 wire [5:0] next_beats=boundary_beats<limited ? boundary_beats[5:0]:limited[5:0];
 // Four differently rotated words preserve lane/order information cheaply.
 wire [31:0] folded=rdata[31:0]^{rdata[62:32],rdata[63]}^
      {rdata[93:64],rdata[95:94]}^{rdata[124:96],rdata[127:125]};
 wire [31:0] digest_next=({digest[26:0],digest[31:27]}^folded)+32'h9e3779b9;
 wire [31:0] response_error=(rid!=AXI_ID ? 32'd2:0) |
      (rresp!=0 ? 32'd4:0) | (rlast!=(beat==burst_beats-1) ? 32'd8:0);
 wire timed_out=(watchdog>=WATCHDOG-1);
 assign input_ready=rstn && state==IDLE && error_bits==0;
 assign release_valid=rstn && state==RELEASE;
 assign arid=AXI_ID;
 assign arlen={2'd0,next_beats}-1'b1;
 assign arvalid=rstn && state==AR;
 assign rready=rstn && (state==R || state==DRAIN);
 // synthesis translate_off
 initial if(BYTES%16 || BYTES<16 || SLOT_BYTES<BYTES || BASE[3:0] || SLOT_BYTES[3:0] || WATCHDOG<2)
   $fatal(1,"input diag parameters require full 16-byte frame beats");
 // synthesis translate_on
 always @(posedge clk or negedge rstn) begin
  if(!rstn)begin
   state<=IDLE;left<=0;watchdog<=0;digest<=0;burst_beats<=0;beat<=0;
   araddr<=0;release_id<=0;completed<=0;error_bits<=0;last_hash<=0;total_beats<=0;
  end else begin
   if(state==AR || state==R || state==DRAIN)begin
    if((state==AR && arready) || (state!=AR && rvalid))watchdog<=0;
    else if(!timed_out)watchdog<=watchdog+1'b1;
    if(timed_out && !((state==AR && arready) || (state!=AR && rvalid)))
      error_bits<=error_bits|32'h10;
   end else watchdog<=0;
   case(state)
    IDLE:if(input_valid && input_ready)begin
     release_id<=input_id;araddr<=input_base;left<=BEATS;digest<=32'h183d1234;
     if(!descriptor_ok)begin error_bits<=32'd1;state<=STOP;end
     else state<=AR;
    end
    AR:if(arready)begin burst_beats<=next_beats;beat<=0;state<=R;end
    R:if(rvalid)begin
     error_bits<=error_bits|response_error;
     // A failure is never presented as successful completion or released.
     if(error_bits!=0 || response_error!=0)begin
      if(rlast)state<=STOP;else state<=DRAIN;
     end else begin
      digest<=digest_next;total_beats<=total_beats+1'b1;beat<=beat+1'b1;
      if(rlast)begin
       left<=left-burst_beats;araddr<=araddr+({26'd0,burst_beats}<<4);
       if(left==burst_beats)begin completed<=completed+1'b1;last_hash<=digest_next;state<=RELEASE;end
       else state<=AR;
      end
     end
    end
    DRAIN:if(rvalid && rlast)state<=STOP;
    RELEASE:if(release_ready)state<=IDLE;
    STOP:begin end
    default:state<=STOP;
   endcase
  end
 end
endmodule
