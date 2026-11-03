// Complete-frame ownership and continuous service scheduling, AXI clock domain.
// This block moves descriptors, never pixels. Completion must already include
// the appropriate last-DDR-B / core-OK barrier in the connected service.
// Fault quarantines every allocated slot until coordinated fabric reset.
module ab05_video_ownership #(
 parameter WIDTH=1280,HEIGHT=720,SLOTS=3,
 parameter [31:0] SLOT_BYTES=32'h00400000,
 parameter [31:0] INPUT_BASE=32'h02000000,OUTPUT_BASE=32'h04000000
)(
 input wire clk,rstn,external_fault,
 input wire capture_start_valid,output wire capture_start_ready,
 input wire [31:0] capture_id,input wire [63:0] capture_timestamp,
 output wire [31:0] capture_base,
 input wire capture_done,input wire [31:0] capture_done_id,input wire capture_ok,
 output reg nn_job_valid,input wire nn_job_ready,
 output reg [31:0] nn_input_base,nn_output_base,nn_frame_id,
 output reg [63:0] nn_timestamp,
 input wire nn_done,input wire [31:0] nn_done_id,input wire nn_ok,
 input wire left_boundary,output reg left_desc_valid,input wire left_desc_ready,
 output reg [31:0] left_frame_id,left_base,output reg [63:0] left_timestamp,
 input wire left_done,input wire [31:0] left_done_id,input wire left_ok,
 input wire right_boundary,output reg right_desc_valid,input wire right_desc_ready,
 output reg [31:0] right_frame_id,right_base,output reg [63:0] right_timestamp,
 input wire right_done,input wire [31:0] right_done_id,input wire right_ok,
 output reg error,output reg [7:0] error_code,
 output reg [15:0] input_allocated_mask,output_allocated_mask,
 output reg [31:0] capture_commits,nn_commits,left_scans,right_scans,
 output reg [31:0] capture_blocked_cycles,missed_left_ticks,missed_right_ticks
);
 reg [SLOTS-1:0] ia,ic,np,nh,lp,oa,obusy,op;
 reg [31:0] iid[0:SLOTS-1],oid[0:SLOTS-1];
 reg [63:0] its[0:SLOTS-1],ots[0:SLOTS-1];
 // Only pending queues are compared. With SLOTS<=16, at most 2*SLOTS
 // admissions can separate pending entries: a blocked input or output queue
 // fills before a 128-admission distance is possible. Display-current leases
 // can be old, but have lp/op cleared and never participate in this comparison.
 reg [7:0] iseq[0:SLOTS-1],oseq[0:SLOTS-1];
 reg [7:0] next_seq;
 reg nn_active,left_scan_active,right_scan_active,left_current,right_current;
 integer nni,nno,lcur,rcur;
 integer free_i,free_o,cap_match,pick_nn,pick_l,pick_r;
 reg duplicate;reg [7:0] min_nn,min_l,min_r;
 function older(input [7:0] a,b);
  reg signed [7:0] distance;
  begin distance=a-b;older=distance[7];end
 endfunction
 reg fault_now;reg [7:0] fault_code;
 integer i;
 reg [1:0] boundary_pending;
 wire pair_boundary=&(boundary_pending|{right_boundary,left_boundary});
 always @*begin
  free_i=-1;free_o=-1;cap_match=-1;pick_nn=-1;pick_l=-1;pick_r=-1;
  duplicate=0;min_nn=8'hff;min_l=8'hff;min_r=8'hff;
  input_allocated_mask=0;output_allocated_mask=0;
  for(integer k=0;k<SLOTS;k=k+1)begin
   input_allocated_mask[k]=ia[k];output_allocated_mask[k]=oa[k];
   if(!ia[k]&&free_i<0)free_i=k;
   if(!oa[k]&&free_o<0)free_o=k;
   if((ia[k]&&iid[k]==capture_id)||(oa[k]&&oid[k]==capture_id))duplicate=1;
   if(ia[k]&&!ic[k]&&iid[k]==capture_done_id)cap_match=k;
   if(ia[k]&&ic[k]&&np[k]&&(pick_nn<0||older(iseq[k],min_nn)))begin min_nn=iseq[k];pick_nn=k;end
   if(ia[k]&&ic[k]&&lp[k]&&(pick_l<0||older(iseq[k],min_l)))begin min_l=iseq[k];pick_l=k;end
   if(oa[k]&&op[k]&&(pick_r<0||older(oseq[k],min_r)))begin min_r=oseq[k];pick_r=k;end
  end
  // Pair the unchanged source with its completed style result. Keep source
  // lp leased until the pair is displayed, so moving edges meet at x=640.
  pick_l=-1;
  for(integer k=0;k<SLOTS;k=k+1)
   if(pick_r>=0&&ia[k]&&ic[k]&&iid[k]==oid[pick_r])pick_l=k;
  fault_now=0;fault_code=0;
  if(external_fault)begin fault_now=1;fault_code=10;end
  else if(capture_start_valid&&free_i>=0&&duplicate)begin fault_now=1;fault_code=9;end
  else if(capture_done&&(cap_match<0||!capture_ok))begin fault_now=1;fault_code=capture_ok?1:2;end
  else if(nn_done&&(!nn_active||nn_done_id!=nn_frame_id||!nn_ok))begin fault_now=1;fault_code=nn_ok?3:4;end
  else if(left_done&&(!left_scan_active||left_done_id!=left_frame_id||!left_ok))begin fault_now=1;fault_code=left_ok?5:6;end
  else if(right_done&&(!right_scan_active||right_done_id!=right_frame_id||!right_ok))begin fault_now=1;fault_code=right_ok?7:8;end
 end
 assign capture_start_ready=rstn&&!error&&!fault_now&&free_i>=0;
 assign capture_base=(free_i<0)?32'b0:INPUT_BASE+free_i*SLOT_BYTES;
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin
   ia<=0;ic<=0;np<=0;nh<=0;lp<=0;oa<=0;obusy<=0;op<=0;next_seq<=0;boundary_pending<=0;
   nn_active<=0;left_scan_active<=0;right_scan_active<=0;left_current<=0;right_current<=0;
   nni<=0;nno<=0;lcur<=0;rcur<=0;
   nn_job_valid<=0;left_desc_valid<=0;right_desc_valid<=0;
   nn_input_base<=0;nn_output_base<=0;nn_frame_id<=0;nn_timestamp<=0;
   left_frame_id<=0;left_base<=0;left_timestamp<=0;right_frame_id<=0;right_base<=0;right_timestamp<=0;
   error<=0;error_code<=0;capture_commits<=0;nn_commits<=0;left_scans<=0;right_scans<=0;
   capture_blocked_cycles<=0;missed_left_ticks<=0;missed_right_ticks<=0;
   for(i=0;i<SLOTS;i=i+1)begin iid[i]<=0;oid[i]<=0;its[i]<=0;ots[i]<=0;iseq[i]<=0;oseq[i]<=0;end
  end else if(error||fault_now)begin
   if(!error)begin error<=1;error_code<=fault_code;end
   // An existing stalled offer is irrevocable: preserve it until accepted.
   // No completion in quarantine releases, publishes or reuses any slot.
   if(nn_job_valid&&nn_job_ready)begin nn_job_valid<=0;nn_active<=1;end
   if(left_desc_valid&&left_desc_ready)begin left_desc_valid<=0;left_scan_active<=1;end
   if(right_desc_valid&&right_desc_ready)begin right_desc_valid<=0;right_scan_active<=1;end
  end else begin
   boundary_pending<=pair_boundary?2'b00:(boundary_pending|{right_boundary,left_boundary});
   if(capture_start_valid&&!capture_start_ready)capture_blocked_cycles<=capture_blocked_cycles+1;
   if(capture_start_valid&&capture_start_ready)begin
    ia[free_i]<=1;ic[free_i]<=0;np[free_i]<=0;nh[free_i]<=0;lp[free_i]<=0;
    iid[free_i]<=capture_id;its[free_i]<=capture_timestamp;iseq[free_i]<=next_seq;next_seq<=next_seq+1;
   end
   if(capture_done)begin
    ic[cap_match]<=1;np[cap_match]<=1;lp[cap_match]<=1;capture_commits<=capture_commits+1;
   end
   if(!nn_active&&!nn_job_valid&&pick_nn>=0&&free_o>=0)begin
    nni<=pick_nn;nno<=free_o;np[pick_nn]<=0;nh[pick_nn]<=1;
    oa[free_o]<=1;obusy[free_o]<=1;op[free_o]<=0;
    oid[free_o]<=iid[pick_nn];ots[free_o]<=its[pick_nn];oseq[free_o]<=iseq[pick_nn];
    nn_input_base<=INPUT_BASE+pick_nn*SLOT_BYTES;nn_output_base<=OUTPUT_BASE+free_o*SLOT_BYTES;
    nn_frame_id<=iid[pick_nn];nn_timestamp<=its[pick_nn];nn_job_valid<=1;
   end
   if(nn_job_valid&&nn_job_ready)begin nn_job_valid<=0;nn_active<=1;end
   if(nn_done)begin nn_active<=0;nh[nni]<=0;obusy[nno]<=0;op[nno]<=1;nn_commits<=nn_commits+1;end
   if(left_desc_valid&&left_desc_ready)begin left_desc_valid<=0;left_scan_active<=1;left_scans<=left_scans+1;end
   if(right_desc_valid&&right_desc_ready)begin right_desc_valid<=0;right_scan_active<=1;right_scans<=right_scans+1;end
   if(left_done)left_scan_active<=0;
   if(right_done)right_scan_active<=0;
   if(pair_boundary)begin
    if(left_scan_active||left_desc_valid||right_scan_active||right_desc_valid)begin
     missed_left_ticks<=missed_left_ticks+1;missed_right_ticks<=missed_right_ticks+1;
    end else if(pick_l>=0&&pick_r>=0)begin
     left_current<=1;lcur<=pick_l;lp[pick_l]<=0;left_desc_valid<=1;
     left_frame_id<=iid[pick_l];left_base<=INPUT_BASE+pick_l*SLOT_BYTES;left_timestamp<=its[pick_l];
     right_current<=1;rcur<=pick_r;op[pick_r]<=0;right_desc_valid<=1;
     right_frame_id<=oid[pick_r];right_base<=OUTPUT_BASE+pick_r*SLOT_BYTES;right_timestamp<=ots[pick_r];
    end else if(left_current&&right_current)begin
     left_desc_valid<=1;left_frame_id<=iid[lcur];left_base<=INPUT_BASE+lcur*SLOT_BYTES;left_timestamp<=its[lcur];
     right_desc_valid<=1;right_frame_id<=oid[rcur];right_base<=OUTPUT_BASE+rcur*SLOT_BYTES;right_timestamp<=ots[rcur];
    end
   end
   // Conservative next-cycle reclamation. Current display leases persist
   // between refreshes; changing current at an idle boundary releases old.
   for(i=0;i<SLOTS;i=i+1)begin
    if(ia[i]&&ic[i]&&!np[i]&&!nh[i]&&!lp[i]&&!(left_current&&lcur==i))begin ia[i]<=0;ic[i]<=0;end
    if(oa[i]&&!obusy[i]&&!op[i]&&!(right_current&&rcur==i))oa[i]<=0;
   end
  end
 end
 // synthesis translate_off
 initial if(SLOTS<2||SLOTS>16||WIDTH<1||HEIGHT<1||WIDTH*HEIGHT*4>SLOT_BYTES||INPUT_BASE%256||OUTPUT_BASE%256)
  $fatal(1,"ownership geometry/address parameters");
 // synthesis translate_on
endmodule
