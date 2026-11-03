// Core-to-DDR complete-result DMA. A descriptor is committed only after
// every beat is checked and the FINAL successful B response is received.
// RGB888x bytes stay 00,B,G,R; no result commit on error. Reset fabric too
// if reset aborts AW/W/B. No timeout withdrawal of an AXI VALID transaction.
module ab05_native_writer #(
 parameter WIDTH=1280,HEIGHT=720,BB=16,WDOG=100000
)(
 input wire clk,rstn,start,input wire [31:0] base,id,
 output wire busy,output reg done,error,
 input wire valid,output wire ready,input wire [162:0] payload,
 output wire [3:0] awid,output reg [31:0] awaddr,
 output wire [7:0] awlen,output wire [2:0] awsize,
 output wire [1:0] awburst,output wire awvalid,input wire awready,
 output wire [127:0] wdata,output wire [15:0] wstrb,
 output wire wlast,wvalid,input wire wready,
 input wire [3:0] bid,input wire [1:0] bresp,input wire bvalid,output wire bready,
 output reg [31:0] accepted_beats,committed_bursts,wait_cycles
);
 localparam N=WIDTH*HEIGHT/4,LINE=WIDTH/4;
 localparam IDLE=0,FILL=1,AW=2,DATA=3,RESP=4,HALT=5;
 reg [2:0] state;reg [31:0] fid,index,line_beat,fill,send,watchdog;
 // Same transaction FSM; synchronous RAM is prefetched on AW acceptance.
 localparam RAM_AW=(BB>1)?$clog2(BB):1;
 wire [127:0] ram_data;
 wire [RAM_AW-1:0] ram_write_addr=fill[RAM_AW-1:0];
 wire [RAM_AW-1:0] ram_read_addr=(state==AW)?{RAM_AW{1'b0}}:send[RAM_AW-1:0]+1'b1;

 wire marks=payload[162:131]==fid&&payload[130]==(index==0)&&
  payload[129]==(line_beat==LINE-1)&&payload[128]==(index==N-1);
 wire ram_write=rstn&&state==FILL&&valid&&ready&&marks;
 wire ram_read=rstn&&((state==AW&&awready)||(state==DATA&&wready&&send!=BB-1));
 // A shallow shift FIFO uses the FPGA SRL fabric instead of wide BRAM.
 // FILL pushes all BB words; DATA handshake advances the oldest word.
 wire burst_shift=ram_write||(rstn&&state==DATA&&wready&&send!=BB-1);
 reg [127:0] burst_pipe[0:BB-1];integer pipe_index;
 always @(posedge clk)if(burst_shift)begin
  burst_pipe[0]<=ram_write?payload[127:0]:128'd0;
  for(pipe_index=1;pipe_index<BB;pipe_index=pipe_index+1)
   burst_pipe[pipe_index]<=burst_pipe[pipe_index-1];
 end
 assign ram_data=burst_pipe[BB-1];
 assign busy=state!=IDLE;assign ready=state==FILL&&!error;
 assign awid=6;assign awlen=BB-1;assign awsize=4;assign awburst=1;assign awvalid=state==AW;
 assign wvalid=state==DATA;assign wdata=ram_data;assign wstrb=16'hffff;
 assign wlast=send==BB-1;assign bready=state==RESP;
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin state<=IDLE;fid<=0;index<=0;line_beat<=0;fill<=0;send<=0;watchdog<=0;
   awaddr<=0;done<=0;error<=0;accepted_beats<=0;committed_bursts<=0;wait_cycles<=0;end
  else begin
   done<=0;
   case(state)
    IDLE:if(start&&!error)begin fid<=id;awaddr<=base;index<=0;line_beat<=0;fill<=0;
     send<=0;watchdog<=0;accepted_beats<=0;committed_bursts<=0;wait_cycles<=0;state<=FILL;end
    FILL:if(valid&&ready)begin
     if(!marks)begin error<=1;state<=HALT;end
     else begin
      index<=index+1;accepted_beats<=accepted_beats+1;
      line_beat<=(line_beat==LINE-1)?0:line_beat+1;
      if(fill==BB-1)begin fill<=0;state<=AW;end else fill<=fill+1;
     end
    end else wait_cycles<=wait_cycles+1;
    AW:if(awready)begin send<=0;state<=DATA;end else wait_cycles<=wait_cycles+1;
    DATA:if(wready)begin if(send==BB-1)begin state<=RESP;watchdog<=0;end else send<=send+1;end
     else wait_cycles<=wait_cycles+1;
    RESP:if(bvalid)begin
     if(error||bid!=6||bresp!=0)begin error<=1;state<=HALT;end
     else begin
      committed_bursts<=committed_bursts+1;
      if(index==N)begin done<=1;state<=IDLE;end
      else begin awaddr<=awaddr+BB*16;state<=FILL;end
     end
    end else begin
     wait_cycles<=wait_cycles+1;
     if(watchdog==WDOG-1)error<=1;else watchdog<=watchdog+1;
    end
    HALT:begin end
   endcase
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(rstn&&ram_write&&ram_read)$fatal(1,"single-port writer concurrent read/write");
 initial if(WIDTH%4||N%BB||256%BB||BB<1||BB>256)$fatal(1,"native_writer dimensions/burst");
 // synthesis translate_on
endmodule
