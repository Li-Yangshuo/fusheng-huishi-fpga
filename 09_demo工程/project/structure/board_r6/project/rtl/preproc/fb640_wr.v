// A16 complete-frame writer. Two buffers remain owned until exact-id release.
// No credit at SOF: discard the whole input frame and count it. No no-drop claim.
// Fail-stop on malformed frames, overflow, bad BID/BRESP, or invalid release.
// Reset of either clock domain resets the pair; AXI fabric must be reset too
// if reset interrupts a bus transaction. Descriptor/release are in axi_clk.
module fb640_wr #(
 parameter integer DATA_WIDTH=128,ADDR_WIDTH=32,
 parameter [31:0] BASE_ADDR=32'h02000000,FRAME_STRIDE=32'h0012c000,
 parameter integer BURST_BEATS=16,FRAME_BEATS=76800,
 parameter integer FRAME_WIDTH=640,FRAME_HEIGHT=480,FIFO_AW=9
)(
 input wire pclk,prstn,in_de,in_sof,input wire [23:0] din,
 input wire axi_clk,axi_rstn,
 output wire [3:0] m_axi_awid,output reg [ADDR_WIDTH-1:0] m_axi_awaddr,
 output wire [7:0] m_axi_awlen,output wire [2:0] m_axi_awsize,
 output wire [1:0] m_axi_awburst,output wire m_axi_awvalid,input wire m_axi_awready,
 output wire [DATA_WIDTH-1:0] m_axi_wdata,output wire [15:0] m_axi_wstrb,
 output wire m_axi_wlast,m_axi_wvalid,input wire m_axi_wready,
 input wire [3:0] m_axi_bid,input wire [1:0] m_axi_bresp,input wire m_axi_bvalid,
 output wire m_axi_bready,output reg frame_done,o_wr_buf,output wire o_err_over,
 output reg frame_valid,input wire frame_ready,
 output reg [31:0] frame_id,frame_base,
 output wire [15:0] frame_width,frame_height,output wire [31:0] frame_stride_bytes,
 output wire [7:0] frame_format,input wire release_valid,output wire release_ready,
 input wire [31:0] release_frame_id,output reg [31:0] dropped_frames_gray,
 output reg [3:0] error_code
);
 localparam PIXELS=FRAME_BEATS*4;
 localparam FILL=0,AW=1,W=2,B=3,STOP=4;
 wire arst=~(prstn & axi_rstn);
 (* async_reg="true" *) reg [1:0] p_run,a_run;
 always @(posedge pclk or posedge arst)
  if(arst) p_run<=0;else p_run<={p_run[0],1'b1};
 always @(posedge axi_clk or posedge arst)
  if(arst) a_run<=0;else a_run<={a_run[0],1'b1};
 // synopsys translate_off
 initial begin
  if(DATA_WIDTH!=128 || ADDR_WIDTH!=32 || BURST_BEATS<1 || BURST_BEATS>256 ||
   FRAME_BEATS<1 || FRAME_BEATS%BURST_BEATS!=0 || 256%BURST_BEATS!=0 ||
   FRAME_WIDTH*FRAME_HEIGHT!=PIXELS || FRAME_STRIDE<FRAME_BEATS*16 ||
   BASE_ADDR%(BURST_BEATS*16)!=0 || FRAME_STRIDE%(BURST_BEATS*16)!=0 || FIFO_AW<2)
    $fatal(1,"fb640_wr parameter contract");
 end
 // synopsys translate_on
 assign frame_width=FRAME_WIDTH;assign frame_height=FRAME_HEIGHT;
 assign frame_stride_bytes=FRAME_WIDTH*4;assign frame_format=8'd1;
 assign m_axi_awid=0;assign m_axi_awlen=BURST_BEATS-1;
 assign m_axi_awsize=4;assign m_axi_awburst=1;assign m_axi_wstrb=16'hffff;
 // Reservation mailbox is stable until this frame's last write response.
 reg grant_toggle,grant_buf,grant_active;
 reg [31:0] grant_id,next_id;
 (* async_reg="true" *) reg [1:0] grant_sync,halt_sync;
 reg grant_seen,credit,capturing,skip_frame;
 reg [31:0] px_count,dropped;
 reg [1:0] phase;reg [95:0] pack;
 reg [129:0] fifo_wdata;reg fifo_we,p_fault;
 reg [3:0] p_code;
 wire fifo_full,fifo_empty;wire [129:0] fifo_rdata;
 reg a_fault;
 (* async_reg="true" *) reg [1:0] fault_sync;
 reg [3:0] code_sync1,code_sync2;

 assign o_err_over=a_fault | fault_sync[1];
 always @(posedge pclk or posedge arst) begin
  if(arst) begin
   grant_sync<=0;halt_sync<=0;grant_seen<=0;credit<=0;capturing<=0;
   skip_frame<=0;px_count<=0;phase<=0;pack<=0;fifo_we<=0;fifo_wdata<=0;
   p_fault<=0;p_code<=0;dropped<=0;dropped_frames_gray<=0;
  end else begin
   grant_sync<={grant_sync[0],grant_toggle};halt_sync<={halt_sync[0],a_fault};fifo_we<=0;
   if(p_run[1]) begin
    if(grant_sync[1]!=grant_seen) begin grant_seen<=grant_sync[1];credit<=1;end
    if(fifo_we && fifo_full) begin p_fault<=1;p_code<=1;end
    if(!p_fault && !halt_sync[1] && !(fifo_we && fifo_full)) begin
     if(in_sof) begin
      if(!in_de) begin p_fault<=1;p_code<=2;end
      else if(capturing) begin p_fault<=1;p_code<=3;end
      else if(credit) begin
       credit<=0;capturing<=1;skip_frame<=0;px_count<=1;phase<=1;pack[31:0]<={din,8'h00};
      end else begin skip_frame<=1;dropped<=dropped+1;dropped_frames_gray<=((dropped+1)>>1)^(dropped+1);end
     end else if(in_de && capturing) begin
      case(phase)
       0:pack[31:0]<={din,8'h00};1:pack[63:32]<={din,8'h00};2:pack[95:64]<={din,8'h00};
       3:begin fifo_wdata<={(px_count==PIXELS-1),(px_count==3),din,8'h00,pack};fifo_we<=1;end
      endcase
      phase<=phase+1'b1;px_count<=px_count+1;
      if(px_count==PIXELS-1) capturing<=0;
     end else if(in_de && !skip_frame && !credit && px_count==PIXELS) begin p_fault<=1;p_code<=4;end
    end
   end
  end
 end
 reg [2:0] state;reg [8:0] fill_count,send_count;reg pop_pending;
 reg [31:0] frame_beat;reg [127:0] burst_mem[0:BURST_BEATS-1];
 reg [1:0] owned,exported;reg [31:0] id0,id1;
 wire fifo_re=(state==FILL) && grant_active && a_run[1] && !o_err_over &&
  !fifo_empty && !pop_pending && fill_count<BURST_BEATS;
 fb640_async_fifo #(.DW(130),.AW(FIFO_AW)) u_fifo (
  .arst(arst),.wclk(pclk),.rclk(axi_clk),.we(fifo_we && !p_fault),.wdata(fifo_wdata),
  .re(fifo_re),.full(fifo_full),.empty(fifo_empty),.rdata(fifo_rdata));
 assign m_axi_awvalid=(state==AW);assign m_axi_wvalid=(state==W);
 assign m_axi_wdata=burst_mem[send_count];assign m_axi_wlast=(send_count==BURST_BEATS-1);
 assign m_axi_bready=(state==B);assign release_ready=a_run[1];
 always @(posedge axi_clk or posedge arst) begin
  if(arst) begin
   state<=FILL;fill_count<=0;send_count<=0;pop_pending<=0;frame_beat<=0;
   m_axi_awaddr<=0;frame_done<=0;o_wr_buf<=0;frame_valid<=0;frame_id<=0;frame_base<=0;
   owned<=0;exported<=0;id0<=0;id1<=0;grant_toggle<=0;grant_active<=0;grant_buf<=0;
   grant_id<=0;next_id<=1;a_fault<=0;fault_sync<=0;code_sync1<=0;code_sync2<=0;error_code<=0;
  end else begin
   fault_sync<={fault_sync[0],p_fault};code_sync1<=p_code;code_sync2<=code_sync1;
   frame_done<=0;pop_pending<=fifo_re;
   if(a_run[1]) begin
    if(fault_sync[1] && !a_fault) begin a_fault<=1;error_code<=code_sync2;end
    if(frame_valid && frame_ready) begin
     frame_valid<=0;if(frame_id==id0) exported[0]<=1;else exported[1]<=1;
    end
    if(release_valid && release_ready) begin
     if(owned[0] && exported[0] && release_frame_id==id0) begin owned[0]<=0;exported[0]<=0;end
     else if(owned[1] && exported[1] && release_frame_id==id1) begin owned[1]<=0;exported[1]<=0;end
     else begin a_fault<=1;error_code<=7;end
    end
    if(!grant_active && !frame_valid && !o_err_over && owned!=2'b11) begin
     grant_buf<=owned[0];o_wr_buf<=owned[0];
     if(!owned[0]) begin owned[0]<=1;id0<=next_id;end
     else begin owned[1]<=1;id1<=next_id;end
     grant_id<=next_id;next_id<=next_id+1;grant_toggle<=~grant_toggle;grant_active<=1;
    end
    case(state)
     FILL:begin
      if(o_err_over) state<=STOP;
      else if(pop_pending) begin
       if(fifo_rdata[128]!=(frame_beat+fill_count==0) ||
        fifo_rdata[129]!=(frame_beat+fill_count==FRAME_BEATS-1)) begin
         a_fault<=1;error_code<=5;state<=STOP;
       end else begin
        burst_mem[fill_count]<=fifo_rdata[127:0];fill_count<=fill_count+1;
        if(fill_count==BURST_BEATS-1) begin
         m_axi_awaddr<=BASE_ADDR+(grant_buf?FRAME_STRIDE:0)+frame_beat*16;state<=AW;
        end
       end
      end
     end
     AW:if(m_axi_awready) begin send_count<=0;state<=W;end
     W:if(m_axi_wready) begin
      if(send_count==BURST_BEATS-1) state<=B;else send_count<=send_count+1;
     end
     B:if(m_axi_bvalid) begin
      fill_count<=0;
      if(m_axi_bresp!=0 || m_axi_bid!=0) begin a_fault<=1;error_code<=6;state<=STOP;end
      else if(o_err_over) state<=STOP;
      else if(frame_beat+BURST_BEATS==FRAME_BEATS) begin
       frame_valid<=1;frame_done<=1;frame_id<=grant_id;
       frame_base<=BASE_ADDR+(grant_buf?FRAME_STRIDE:0);
       grant_active<=0;frame_beat<=0;state<=FILL;
      end else begin frame_beat<=frame_beat+BURST_BEATS;state<=FILL;end
     end
     STOP:begin end
     default:state<=STOP;
    endcase
   end
  end
 end
endmodule
