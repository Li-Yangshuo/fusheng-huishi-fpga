// One-clock task monitor. It NEVER changes AXI VALID/READY or fabric reset.
// quarantine is a sticky REQUEST to the owner to isolate/drain/co-reset.
// rstn must be the coordinated system reset, synchronously released to clk.
module ab05_job_watchdog #(
 parameter [31:0] TOTAL_CYCLES=32'd10000000,
 parameter [31:0] NO_PROGRESS_CYCLES=32'd1000000
)(
 input wire clk,rstn,
 input wire start_valid,output wire start_ready,input wire [31:0] start_id,
 input wire progress,
 input wire finish_valid,input wire [31:0] finish_id,input wire finish_ok,
 input wire external_fault,
 output reg active,finish_accepted,quarantine,
 output reg [3:0] reason,
 output reg [31:0] trip_id,cycles,no_progress
);
 localparam [3:0] TOTAL_DEADLINE=1,NO_PROGRESS_DEADLINE=2,
   WRONG_FINISH_ID=3,FINISH_NOT_OK=4,IDLE_FINISH=5,EXTERNAL_FAULT=6;
 reg [31:0] current_id;
 function [31:0] sat_inc(input [31:0] v);
  begin sat_inc=(&v)?32'hffffffff:v+32'd1;end
 endfunction
 wire [31:0] next_cycles=sat_inc(cycles);
 wire [31:0] next_idle=progress?32'd0:sat_inc(no_progress);
 // A pending finish while idle is a protocol fault, not a new start.
 assign start_ready=rstn&&!active&&!quarantine&&!external_fault&&!finish_valid;
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin
   active<=0;finish_accepted<=0;quarantine<=0;reason<=0;
   trip_id<=0;cycles<=0;no_progress<=0;current_id<=0;
  end else begin
   finish_accepted<=0;
   if(!quarantine)begin
    if(external_fault)begin
     quarantine<=1;reason<=EXTERNAL_FAULT;trip_id<=active?current_id:32'd0;
     if(active)begin cycles<=next_cycles;no_progress<=next_idle;end
    end else if(!active)begin
     if(finish_valid)begin
      quarantine<=1;reason<=IDLE_FINISH;trip_id<=finish_id;
     end else if(start_valid&&start_ready)begin
      active<=1;current_id<=start_id;cycles<=0;no_progress<=0;
     end
    end else begin
     cycles<=next_cycles;no_progress<=next_idle;
     if(finish_valid)begin
      if(finish_id!=current_id)begin
       quarantine<=1;reason<=WRONG_FINISH_ID;trip_id<=current_id;
      end else if(!finish_ok)begin
       quarantine<=1;reason<=FINISH_NOT_OK;trip_id<=current_id;
      end else begin
       // A valid finish ON the deadline service edge is still on time.
       active<=0;finish_accepted<=1;
      end
     end else if(next_cycles>=TOTAL_CYCLES)begin
      quarantine<=1;reason<=TOTAL_DEADLINE;trip_id<=current_id;
     end else if(next_idle>=NO_PROGRESS_CYCLES)begin
      quarantine<=1;reason<=NO_PROGRESS_DEADLINE;trip_id<=current_id;
     end
    end
   end
  end
 end
 // synthesis translate_off
 initial if(TOTAL_CYCLES==0||NO_PROGRESS_CYCLES==0)
  $fatal(1,"watchdog deadlines must be >=1 cycle");
 // synthesis translate_on
endmodule
