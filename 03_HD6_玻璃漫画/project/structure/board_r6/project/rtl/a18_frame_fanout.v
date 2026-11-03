// Two immutable source descriptors, two readers, exact-id reference counting.
// Descriptor: {frame_id[31:0], base[31:0], stride[31:0], width[15:0],
//              height[15:0], format[7:0]} (136 bits).
// A17 display is consumer0; A18 resize DMA is consumer1. Both must release
// before the source writer receives credit. All ports use the same AXI clock.
module a18_frame_fanout (
 input wire clk,rstn,input wire in_valid,output wire in_ready,input wire [135:0] in_desc,
 output reg c0_valid,input wire c0_ready,output reg [135:0] c0_desc,
 output reg c1_valid,input wire c1_ready,output reg [135:0] c1_desc,
 input wire c0_release_valid,output wire c0_release_ready,input wire [31:0] c0_release_id,
 input wire c1_release_valid,output wire c1_release_ready,input wire [31:0] c1_release_id,
 output reg release_valid,input wire release_ready,output reg [31:0] release_id,
 output reg fault
);
 reg [1:0] owned,delivered0,delivered1,returned0,returned1;
 reg [135:0] desc0,desc1;
 reg [31:0] ticket0,ticket1,next_ticket;
 reg c0_slot,c1_slot,release_slot;
 wire [1:0] pending0=owned & ~delivered0;
 wire [1:0] pending1=owned & ~delivered1;
 wire oldest1=$signed(ticket1-ticket0)<0;
 wire choose0=pending0[1] && (!pending0[0] || oldest1);
 wire choose1=pending1[1] && (!pending1[0] || oldest1);
 wire [1:0] finished=owned & delivered0 & delivered1 & returned0 & returned1;
 assign in_ready=rstn && !fault && owned!=2'b11;
 assign c0_release_ready=rstn && !fault;assign c1_release_ready=rstn && !fault;
 always @(posedge clk or negedge rstn) begin
  if(!rstn) begin
   owned<=0;delivered0<=0;delivered1<=0;returned0<=0;returned1<=0;
   desc0<=0;desc1<=0;ticket0<=0;ticket1<=0;next_ticket<=0;
   c0_valid<=0;c1_valid<=0;c0_desc<=0;c1_desc<=0;c0_slot<=0;c1_slot<=0;
   release_valid<=0;release_id<=0;release_slot<=0;fault<=0;
  end else if(!fault) begin
   if(in_valid && in_ready) begin
    if((owned[0] && desc0[135:104]==in_desc[135:104]) ||
       (owned[1] && desc1[135:104]==in_desc[135:104])) fault<=1;
    else if(!owned[0]) begin
     owned[0]<=1;desc0<=in_desc;ticket0<=next_ticket;
     delivered0[0]<=0;delivered1[0]<=0;returned0[0]<=0;returned1[0]<=0;
    end else begin
     owned[1]<=1;desc1<=in_desc;ticket1<=next_ticket;
     delivered0[1]<=0;delivered1[1]<=0;returned0[1]<=0;returned1[1]<=0;
    end
    next_ticket<=next_ticket+1'b1;
   end
   if(!c0_valid && pending0!=0) begin
    c0_slot<=choose0;c0_desc<=choose0 ? desc1 : desc0;c0_valid<=1;
   end else if(c0_valid && c0_ready) begin c0_valid<=0;delivered0[c0_slot]<=1;end
   if(!c1_valid && pending1!=0) begin
    c1_slot<=choose1;c1_desc<=choose1 ? desc1 : desc0;c1_valid<=1;
   end else if(c1_valid && c1_ready) begin c1_valid<=0;delivered1[c1_slot]<=1;end
   if(c0_release_valid && c0_release_ready) begin
    if(owned[0] && delivered0[0] && !returned0[0] && desc0[135:104]==c0_release_id) returned0[0]<=1;
    else if(owned[1] && delivered0[1] && !returned0[1] && desc1[135:104]==c0_release_id) returned0[1]<=1;
    else fault<=1;
   end
   if(c1_release_valid && c1_release_ready) begin
    if(owned[0] && delivered1[0] && !returned1[0] && desc0[135:104]==c1_release_id) returned1[0]<=1;
    else if(owned[1] && delivered1[1] && !returned1[1] && desc1[135:104]==c1_release_id) returned1[1]<=1;
    else fault<=1;
   end
   if(!release_valid && finished!=0) begin
    release_slot<=!finished[0];release_id<=finished[0] ? desc0[135:104] : desc1[135:104];release_valid<=1;
   end else if(release_valid && release_ready) begin release_valid<=0;owned[release_slot]<=0;end
  end else begin
   // Freeze admission on fault, but each already offered mailbox may still
   // complete once. Never repeatedly deliver a held valid after the fault.
   if(c0_valid && c0_ready)c0_valid<=0;
   if(c1_valid && c1_ready)c1_valid<=0;
   if(release_valid && release_ready)begin release_valid<=0;owned[release_slot]<=0;end
  end
 end
endmodule
