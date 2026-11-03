// RISC-V owns camera deployment, model deployment, UI and frame admission.
// Every register below is on the existing 100 MHz CPU APB clock.
module r8_control #(parameter [31:0] MODEL0=32'h50503031,MODEL1=32'h54493031,MODEL2=32'h544e3031)(
 input wire clk,rstn,input wire [15:0] addr,input wire write,input wire [31:0] wdata,
 output reg [31:0] rdata,input wire key_layout,key_style,
 input wire [31:0] command_seq,input wire [1:0] command_style,
 output reg [31:0] applied_seq,output wire remote_event,
 output reg [1:0] style,layout,output wire [31:0] cfg_model,
 output reg capture_enable,input wire network_busy,result_done,
 output reg camera_start,output reg [23:0] camera_command,
 input wire camera_busy,camera_done,camera_error,output reg camera_ready,
 output reg weight_we,weight_bias,output reg [5:0] weight_addr,output wire [511:0] weight_data,
 output reg models_ready,output wire irq,output reg osd_enable,
 input wire [9:0] measured_fps,output reg [127:0] osd_text
);
 reg [1:0] key_pending;reg done_pending,irq_enable,started,load_fault;
 reg [7:0] camera_count;reg camera_done_q,camera_pending;
 reg [10:0] loaded_words;reg [511:0] staging;reg [31:0] software_status;
 assign weight_data=staging;
 assign cfg_model=style==1?MODEL1:style==2?MODEL2:MODEL0;
 assign remote_event=command_seq!=0&&command_seq!=applied_seq;
 assign irq=done_pending&&irq_enable;
 always @*begin
  rdata=0;
  case(addr)
   16'h08:rdata={31'd0,capture_enable};
   16'h0c:rdata={22'd0,measured_fps};
   16'h4c:rdata={28'd0,done_pending,remote_event,key_pending};
   16'h50:rdata={8'd0,camera_command};
   16'h54:rdata={16'd0,camera_count,4'd0,camera_ready,camera_error,camera_done,camera_pending|camera_busy};
   16'h58:rdata={21'd0,loaded_words};
   16'h60:rdata={5'd0,loaded_words,12'd0,started,osd_enable,load_fault,models_ready};
   16'h64:rdata={28'd0,style,layout};
   16'h68:rdata={31'd0,irq_enable};
   16'h6c:rdata={31'd0,done_pending};
   16'h70:rdata=command_seq;
   16'h74:rdata={30'd0,command_style};
   16'h78:rdata=software_status;
   16'h7c:rdata=applied_seq;
   default:;
  endcase
 end
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin
   style<=0;layout<=0;applied_seq<=0;capture_enable<=0;started<=0;
   camera_start<=0;camera_command<=0;camera_ready<=0;camera_count<=0;
   camera_pending<=0;camera_done_q<=0;
   weight_we<=0;weight_bias<=0;weight_addr<=0;staging<=0;loaded_words<=0;
   models_ready<=0;osd_enable<=0;load_fault<=0;software_status<=0;osd_text<={16{8'h20}};
   key_pending<=0;done_pending<=0;irq_enable<=0;
  end else begin
   camera_start<=0;weight_we<=0;camera_done_q<=camera_done;
   if(camera_busy)camera_pending<=0;
   if(camera_done&&!camera_done_q&&!camera_error&&camera_count<166)camera_count<=camera_count+1'b1;
   if(write)case(addr)
    16'h08:if(!wdata[0])capture_enable<=0;
      else if(camera_ready&&models_ready&&!load_fault&&!camera_error)begin capture_enable<=1;started<=1;end
    16'h0c:if(wdata[15:8]<16)osd_text[8*wdata[11:8]+:8]<=wdata[7:0];
    16'h4c:key_pending<=key_pending&~wdata[1:0];
    16'h50:if(!started&&!camera_busy&&!camera_pending&&!camera_error&&camera_count<166)begin
      camera_command<=wdata[23:0];camera_start<=1;camera_pending<=1;
     end
    16'h54:if(wdata[3]&&camera_count==166&&!camera_busy&&!camera_pending&&!camera_error)camera_ready<=1;
    16'h58:if(!started&&!network_busy)begin loaded_words<=0;models_ready<=0;load_fault<=0;staging<=0;end
    16'h5c:if(!started&&!network_busy&&!models_ready&&loaded_words<1152)begin
      staging<={wdata,staging[511:32]};loaded_words<=loaded_words+1'b1;
      if(loaded_words[3:0]==15)begin
       weight_we<=1;weight_bias<=loaded_words>=1008;
       weight_addr<=loaded_words>=1008?(loaded_words-1008)>>4:loaded_words>>4;
      end
     end else if(!started)load_fault<=1;
    16'h60:begin
      osd_enable<=wdata[2];
      if(wdata[0]&&!started)begin
       if(loaded_words==1152&&!load_fault)models_ready<=1;else load_fault<=1;
      end
     end
    16'h64:if(wdata[3:2]<3)begin style<=wdata[3:2];layout<=wdata[1:0];end
    16'h68:irq_enable<=wdata[0];
    16'h6c:if(wdata[0])done_pending<=0;
    16'h78:software_status<=wdata;
    16'h7c:if(wdata==command_seq)applied_seq<=wdata;
    default:;
   endcase
   // Set wins simultaneous software acknowledgment. Events cannot disappear.
   if(key_layout)key_pending[0]<=1;
   if(key_style)key_pending[1]<=1;
   if(result_done)done_pending<=1;
   if(camera_error||load_fault)capture_enable<=0;
  end
 end
endmodule
