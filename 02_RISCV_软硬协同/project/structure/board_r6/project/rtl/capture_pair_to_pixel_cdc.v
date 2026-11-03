// A1 pair stream -> legacy one-pixel stream, through a Gray-pointer FIFO.
// Use rclk=2*wclk (e.g. 148.5 / 74.25 MHz), or prove the actual service bound.
// No upstream backpressure: FIFO full is sticky fail-stop; reset both domains.
// Asserting either reset resets both FIFO pointers and output prefetch state.
module capture_pair_to_pixel_cdc #(parameter integer AW=4)(
 input wire wclk,wrstn,in_valid,in_sof,in_eol,
 input wire [47:0] in_data,input wire [31:0] in_frame_id,
 input wire rclk,rrstn,
 output wire out_valid,out_sof,out_eol,output wire [23:0] out_data,
 output wire [31:0] out_frame_id,
 output reg write_fault,output wire read_fault,
 output wire fifo_full,output wire fifo_empty
);
 wire arst=!(wrstn && rrstn);
 reg [1:0] wrun,rrun;
 (* async_reg="true" *) reg [1:0] wf_sync;
 reg [AW:0] wb,wg,rb,rg;
 (* async_reg="true" *) reg [AW:0] rg1,rg2,wg1,wg2;
 wire [AW:0] wn=wb+1'b1,rn=rb+1'b1;
 assign fifo_full=(wg=={~rg2[AW:AW-1],rg2[AW-2:0]});
 assign fifo_empty=(rg==wg2);
 assign read_fault=wf_sync[1];
 (* syn_ramstyle="block_ram" *) reg [81:0] mem[0:(1<<AW)-1];
 reg [81:0] ram_data,q0,q1;
 reg [1:0] count;
 reg phase,pending;
 wire pop=(count!=0 && phase);
 wire [2:0] projected={1'b0,count}+pending-pop;
 wire re=rrun[1] && !read_fault && !fifo_empty && projected<2;
 wire we=wrun[1] && !write_fault && in_valid && !fifo_full;
 assign out_valid=rrun[1] && !read_fault && count!=0;
 assign out_data=phase ? q0[47:24] : q0[23:0];
 assign out_sof=out_valid && !phase && q0[48];
 assign out_eol=out_valid && phase && q0[49];
 assign out_frame_id=q0[81:50];
 // synopsys translate_off
 initial if(AW<2) $fatal(1,"capture CDC AW must be >=2");
 // synopsys translate_on
 always @(posedge wclk or posedge arst) begin
  if(arst) begin wb<=0;wg<=0;rg1<=0;rg2<=0;wrun<=0;write_fault<=0;end
  else begin
   wrun<={wrun[0],1'b1};rg1<=rg;rg2<=rg1;
   if(wrun[1] && in_valid && fifo_full) write_fault<=1;
   if(we) begin wb<=wn;wg<=(wn>>1)^wn;end
  end
 end
 always @(posedge wclk) if(we) mem[wb[AW-1:0]]<={in_frame_id,in_eol,in_sof,in_data};
 always @(posedge rclk) if(re) ram_data<=mem[rb[AW-1:0]];
 always @(posedge rclk or posedge arst) begin
  if(arst) begin rb<=0;rg<=0;wg1<=0;wg2<=0;rrun<=0;wf_sync<=0;
   q0<=0;q1<=0;count<=0;phase<=0;pending<=0;
  end else begin
   rrun<={rrun[0],1'b1};wf_sync<={wf_sync[0],write_fault};wg1<=wg;wg2<=wg1;
   pending<=re;
   if(re) begin rb<=rn;rg<=(rn>>1)^rn;end
   if(out_valid) phase<=!phase;
   case({pop,pending})
    2'b01:begin if(count==0) q0<=ram_data;else q1<=ram_data;count<=count+1'b1;end
    2'b10:begin q0<=q1;count<=count-1'b1;end
    2'b11:begin if(count==1) q0<=ram_data;else begin q0<=q1;q1<=ram_data;end end
    default:begin end
   endcase
  end
 end
endmodule
