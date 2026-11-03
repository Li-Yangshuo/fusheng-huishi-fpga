// Best-effort resize subscriber between a18_frame_fanout consumer1 and DMA.
// Accept an immutable source only when the DMA can start; otherwise return
// this subscriber's credit after the descriptor handshake. Display credit is
// still owned exclusively by fanout consumer0. All ports share the AXI clock.
// Never return an accepted DMA source until its exact source-release ID arrives.
module resize_frame_gate(
 input wire clk,rstn,
 input wire input_valid,output wire input_ready,input wire [135:0] input_desc,
 output reg dma_valid,input wire dma_ready,output reg [135:0] dma_desc,
 input wire dma_fault,
 input wire dma_release_valid,output wire dma_release_ready,input wire [31:0] dma_release_id,
 output reg release_valid,input wire release_ready,output reg [31:0] release_id,
 output reg fault,
 output reg [31:0] forward_count,skip_count,complete_count
);
 reg active,dispatched,drop_pending;
 reg [31:0] active_id,drop_id;
 wire return_open=rstn && !fault && !release_valid;
 wire bad_return=dma_release_valid && return_open &&
                  (!active || !dispatched || dma_release_id!=active_id);
 wire conflict=input_valid && ((active && input_desc[135:104]==active_id) ||
                              (release_valid && input_desc[135:104]==release_id));
 assign input_ready=rstn && !fault && !dma_valid && !drop_pending && !bad_return && !conflict;
 assign dma_release_ready=return_open;
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin
   dma_valid<=0;dma_desc<=0;release_valid<=0;release_id<=0;
   active<=0;dispatched<=0;drop_pending<=0;active_id<=0;drop_id<=0;fault<=0;
   forward_count<=0;skip_count<=0;complete_count<=0;
  end else begin
   // Already offered mailboxes may complete once, even after a protocol fault.
   if(dma_valid && dma_ready)begin dma_valid<=0;dispatched<=1;end
   if(release_valid && release_ready)release_valid<=0;
   if(!fault)begin
    if(bad_return || conflict)fault<=1;
    else begin
     if(dma_release_valid && dma_release_ready)begin
      release_valid<=1;release_id<=active_id;active<=0;dispatched<=0;
      complete_count<=complete_count+1'b1;
     end else if(!release_valid && drop_pending)begin
      release_valid<=1;release_id<=drop_id;drop_pending<=0;
     end
     if(input_valid && input_ready)begin
      if(!active && dma_ready && !dma_fault)begin
       dma_desc<=input_desc;dma_valid<=1;active<=1;active_id<=input_desc[135:104];dispatched<=0;
       forward_count<=forward_count+1'b1;
      end else begin
       drop_pending<=1;drop_id<=input_desc[135:104];skip_count<=skip_count+1'b1;
      end
     end
    end
   end
  end
 end
endmodule
