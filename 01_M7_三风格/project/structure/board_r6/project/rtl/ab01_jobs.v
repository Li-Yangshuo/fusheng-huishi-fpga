// One compute job plus two result slots. Slots are returned only by display
// release after old reads drain. B FRAME_CNT is the hardware all_done count.
module ab01_jobs(
 input wire clk,rstn,
 input wire input_valid,output wire input_ready,
 input wire [31:0] input_id,input_base,input_stride,input_bytes,
 input wire [15:0] input_width,input_height,input_format,
 output reg source_release_valid,input wire source_release_ready,
 output reg [31:0] source_release_id,
 input wire [31:0] completed_count,input wire b_busy,input wire [7:0] b_fault,
 output reg frame_valid,input wire frame_ready,
 output reg [31:0] frame_id,frame_base,
 input wire release_valid,output wire release_ready,input wire [31:0] release_id,
 input wire [31:0] local_addr,local_wdata,input wire local_write,
 output reg [127:0] local_rdata,
 output reg [31:0] job_id,job_in_base,job_out_base,jobs_done,error_bits,
 output wire active
);
 reg enable;reg [1:0] state,owned;reg slot;
 reg [31:0] slot_id0,slot_id1,start_count;
 wire free0=!owned[0],free1=!owned[1];
 assign active=state==1;
 assign input_ready=enable&&state==0&&(free0||free1)&&error_bits==0;
 assign release_ready=1;
 always @(*)begin
  local_rdata=0;
  case(local_addr)
   0:local_rdata={32'h00000100,32'h00000001,32'h20261018,32'h41423130};
   4:local_rdata={jobs_done,error_bits,completed_count,26'd0,b_busy,owned,state,enable};
   8:local_rdata={32'd147456,job_out_base,job_in_base,job_id};
   12:local_rdata={32'd1024,32'd196608,32'd192,32'd256};
   default:local_rdata=0;
  endcase
 end
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin enable<=0;state<=0;owned<=0;slot<=0;slot_id0<=0;slot_id1<=0;start_count<=0;job_id<=0;job_in_base<=0;job_out_base<=0;jobs_done<=0;error_bits<=0;source_release_valid<=0;source_release_id<=0;frame_valid<=0;frame_id<=0;frame_base<=0;end
  else begin
   if(local_write&&local_addr==4)enable<=local_wdata[0];
   if(source_release_valid&&source_release_ready)source_release_valid<=0;
   if(frame_valid&&frame_ready)frame_valid<=0;
   if(release_valid)begin
    if((state==1||state==3)&&release_id==job_id)error_bits[1]<=1;
    else if(owned[0]&&release_id==slot_id0)owned[0]<=0;
    else if(owned[1]&&release_id==slot_id1)owned[1]<=0;
    else error_bits[1]<=1;
   end
   // Fault stays sticky until coordinated global reset. Retain the active
   // source/result credit; a display-owned older slot is never reclaimed here.
   if(|b_fault)begin
    error_bits[3]<=1'b1;error_bits[15:8]<=b_fault;enable<=0;
    if(state==1)state<=3;
   end else case(state)
    0:if(input_valid&&input_ready)begin
     if(input_width!=256||input_height!=192||input_stride!=768||input_bytes!=147456||input_format!=2||
       (input_base!=32'h02400000&&input_base!=32'h02424000))begin error_bits[0]<=1;enable<=0;end
     else begin
      job_id<=input_id;job_in_base<=input_base;slot<=!free0;
      job_out_base<=free0?32'h02800000:32'h02830000;
      if(free0)begin owned[0]<=1;slot_id0<=input_id;end
      else begin owned[1]<=1;slot_id1<=input_id;end
      start_count<=completed_count;state<=1;
     end
    end
    1:if(completed_count!=start_count)begin
     if(completed_count!=start_count+32'd1)begin error_bits[2]<=1;enable<=0;end
     else if(!b_busy)begin
      frame_id<=job_id;frame_base<=job_out_base;frame_valid<=1;
      source_release_id<=job_id;source_release_valid<=1;
      jobs_done<=jobs_done+1'b1;state<=2;
     end
    end
    2:if(!frame_valid&&!source_release_valid)state<=0;
    3:state<=3;
    default:state<=0;
   endcase
  end
 end
endmodule
