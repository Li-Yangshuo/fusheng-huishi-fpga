// ABI1 dense HWC S8, source AND destination rows are 16-byte aligned.
// Runtime CI2/4/8 geometry, single AXI clock, one read/write burst outstanding.
// Issued AXI VALID transactions survive quarantine; reset fabric with core.
module board_stage_dma_owner #(parameter BB=16,WDOG=100000)(
 input wire clk,rst,
 input wire job_valid,output wire job_ready,input wire engine_ready,input wire [7:0] job_abi,
 input wire [127:0] job_descriptor,input wire [63:0] job_session,
 input wire [31:0] job_source,job_destination,job_source_capacity,job_destination_capacity,
 input wire [11:0] job_width,job_height,input wire [3:0] job_ci,job_co,
 input wire job_stride2,job_up2,job_residual,
 output wire source_valid,input wire source_ready,output wire [63:0] source_data,
 output wire [7:0] source_mask,output wire [11:0] source_row,output wire [9:0] source_word,
 output wire source_eol,source_last,output wire [127:0] source_descriptor,output wire [63:0] source_session,
 input wire sink_valid,output wire sink_ready,input wire [63:0] sink_data,input wire [7:0] sink_mask,
 input wire [31:0] sink_pixel,input wire sink_last,input wire [127:0] sink_descriptor,input wire [63:0] sink_session,
 input wire retire_valid,output wire retire_ready,input wire [127:0] retire_descriptor,
 input wire [63:0] retire_session,input wire retire_error,core_fault,
 output reg complete_valid,input wire complete_ready,output wire [127:0] complete_descriptor,
 output wire [63:0] complete_session,output wire [31:0] complete_destination,
 output wire busy,error,output reg [7:0] error_code,
 output wire [3:0] arid,output reg [31:0] araddr,output wire [7:0] arlen,output wire [2:0] arsize,
 output wire [1:0] arburst,output wire arvalid,input wire arready,
 input wire [127:0] rdata,input wire [3:0] rid,input wire [1:0] rresp,input wire rlast,rvalid,output wire rready,
 output wire [3:0] awid,output reg [31:0] awaddr,output wire [7:0] awlen,output wire [2:0] awsize,
 output wire [1:0] awburst,output wire awvalid,input wire awready,
 output wire [127:0] wdata,output wire [15:0] wstrb,output wire wlast,wvalid,input wire wready,
 input wire [3:0] bid,input wire [1:0] bresp,input wire bvalid,output wire bready,
 output reg [31:0] read_beats,write_beats,write_responses
);
 localparam RI=0,RA=1,RD=2,RP=3,RS=4,RH=5;
 localparam WI=0,WF=1,WP=2,WA=3,WW=4,WB=5,WH=6;
 reg [2:0] rs,ws;reg active;
 reg [127:0] descriptor;reg [63:0] session;reg [31:0] destination;
 reg [31:0] rremaining,wremaining,source_count,sink_count,total_source_words,total_sink_words;
 reg [8:0] rn,wn,rcount,wfill,wsend,rpad,wpad,rsend;
 reg [31:0] rwatch,wwatch;reg source_half,sink_half;
 reg [63:0] sink_low;
 reg [11:0] srow;reg [9:0] sword;reg [9:0] row_words;
 reg [2:0] ppv_shift;
 reg saw_r,saw_source,saw_sink,saw_compute,saw_b;
 wire [11:0] ow=job_up2?(job_width<<1):job_stride2?((job_width>>1)+job_width[0]):job_width;
 wire [11:0] oh=job_up2?(job_height<<1):job_stride2?((job_height>>1)+job_height[0]):job_height;
 wire [15:0] sbytes={4'd0,job_width}<<((job_ci==2)?1:(job_ci==4)?2:3);
 wire [15:0] dbytes={4'd0,ow}<<((job_co==2)?1:(job_co==4)?2:3);
 wire [31:0] ssize=sbytes*job_height,dsize=dbytes*oh;
 wire [32:0] se={1'b0,job_source}+{1'b0,job_source_capacity};
 wire [32:0] de={1'b0,job_destination}+{1'b0,job_destination_capacity};
 wire geometry_ok=job_abi==2&&(job_ci==2||job_ci==4||job_ci==8)&&(job_co==2||job_co==4||job_co==8)&&
   job_width!=0&&job_height!=0&&sbytes<=5120&&sbytes[3:0]==0&&dbytes[3:0]==0&&
   (!job_up2||(job_width<=2047&&job_height<=2047))&&!(job_stride2&&job_up2)&&
   !(job_ci==2&&job_co==8)&&(!job_residual||(job_ci==8&&job_co==8));
 wire address_ok=job_source[3:0]==0&&job_destination[3:0]==0&&
   job_source_capacity>=ssize&&job_destination_capacity>=dsize&&
   se<=33'h100000000&&de<=33'h100000000&&(se<={1'b0,job_destination}||de<={1'b0,job_source});
 wire mode_ok=geometry_ok&&address_ok;
 assign error=|error_code;assign busy=active;
 assign job_ready=!rst&&!active&&!complete_valid&&!error&&mode_ok&&engine_ready;
 wire go=job_valid&&job_ready;
 assign source_descriptor=descriptor;assign sink_ready=!rst&&active&&ws==WF&&!error;
 assign source_session=session;assign complete_descriptor=descriptor;assign complete_session=session;
 assign complete_destination=destination;
 function [8:0] burst(input [31:0] address,input [31:0] remaining);
 reg [8:0] page_beats;reg [31:0] n;
 begin page_beats=9'd256-{1'b0,address[11:4]};n=remaining<BB?remaining:BB;burst=(n>page_beats)?page_beats:n[8:0];end endfunction
 assign arid=5;assign arlen=rn-1'b1;assign arsize=4;assign arburst=1;
 assign arvalid=!rst&&rs==RA;assign rready=!rst&&rs==RD;
 assign awid=6;assign awlen=wn-1'b1;assign awsize=4;assign awburst=1;
 assign awvalid=!rst&&ws==WA;assign wvalid=!rst&&ws==WW;assign bready=!rst&&ws==WB;
 assign wstrb=16'hffff;assign wlast=wsend==wn-1'b1;
 wire rt=rvalid&&rready,at=arvalid&&arready,wt=wvalid&&wready,bt=bvalid&&bready;
 wire rgood=rid==5&&rresp==0&&rlast==(rcount==rn-1'b1);
 wire bgood=bid==6&&bresp==0;
 assign source_valid=!rst&&rs==RS;
 assign source_mask=8'hff;assign source_row=srow;assign source_word=sword;
 assign source_eol=sword==row_words-1'b1;assign source_last=source_count==total_source_words-1'b1;
 wire st=source_valid&&source_ready,kt=sink_valid&&sink_ready;
 wire sinkgood=sink_descriptor==descriptor&&sink_session==session&&sink_mask==8'hff&&
   sink_pixel==(sink_count<<ppv_shift)&&sink_last==(sink_count==total_sink_words-1'b1);
 assign retire_ready=!rst&&active&&!saw_compute&&!error&&!complete_valid;
 wire ct=retire_valid&&retire_ready;
 wire source_end_now=st&&source_last;
 wire sink_end_now=kt&&sinkgood&&sink_last;
 wire retiregood=!retire_error&&retire_descriptor==descriptor&&retire_session==session&&
                 (saw_source||source_end_now)&&(saw_sink||sink_end_now);
 wire rtimeout=(rs==RA&&!arready)||(rs==RD&&!rvalid);
 wire wtimeout=(ws==WA&&!awready)||(ws==WW&&!wready)||(ws==WB&&!bvalid);
 wire rfault=rtimeout&&rwatch==WDOG-1,wfault=wtimeout&&wwatch==WDOG-1;
 wire [7:0] fault_bits={1'b0,wfault,(bt&&!bgood),(active&&!complete_valid&&(core_fault||(ct&&!retiregood))),
                       (kt&&!sinkgood),rfault,(rt&&!rgood),1'b0};
 wire fault_now=|fault_bits;
 // Two shared shallow SRL queues. Full burst is buffered before the address
 // for writes, or before local source publication for reads.
 reg [127:0] read_pipe[0:BB-1],write_pipe[0:BB-1];integer i;
 wire rpush=rt&&rgood&&!error&&!fault_now;
 wire ralign=rs==RP&&rpad!=0&&!error&&!fault_now;
 wire rshift=rpush||ralign||(st&&source_half&&!error&&!fault_now);
 wire wpush=kt&&sinkgood&&sink_half&&!error&&!fault_now;
 wire walign=ws==WP&&wpad!=0&&!error&&!fault_now;
 wire wshift=wpush||walign||(wt&&wsend!=wn-1'b1);
 always @(posedge clk)begin
  if(rshift)begin
   read_pipe[0]<=rpush?rdata:128'd0;
   for(i=1;i<BB;i=i+1)read_pipe[i]<=read_pipe[i-1];
  end
  if(wshift)begin
   write_pipe[0]<=wpush?{sink_data,sink_low}:128'd0;
   for(i=1;i<BB;i=i+1)write_pipe[i]<=write_pipe[i-1];
  end
 end
 assign source_data=source_half?read_pipe[BB-1][127:64]:read_pipe[BB-1][63:0];
 assign wdata=write_pipe[BB-1];
 wire all_barriers=saw_r&&saw_source&&saw_sink&&saw_compute&&saw_b;
 always @(posedge clk)begin
  if(rst)begin
   rs<=RI;ws<=WI;active<=0;descriptor<=0;session<=0;destination<=0;complete_valid<=0;error_code<=0;
   rremaining<=0;wremaining<=0;source_count<=0;sink_count<=0;total_source_words<=0;total_sink_words<=0;
   rn<=0;wn<=0;rcount<=0;wfill<=0;wsend<=0;rpad<=0;wpad<=0;rsend<=0;rwatch<=0;wwatch<=0;
   source_half<=0;sink_half<=0;sink_low<=0;srow<=0;sword<=0;row_words<=0;ppv_shift<=0;
   saw_r<=0;saw_source<=0;saw_sink<=0;saw_compute<=0;saw_b<=0;araddr<=0;awaddr<=0;
   read_beats<=0;write_beats<=0;write_responses<=0;
  end else begin
   error_code<=error_code|fault_bits|((job_valid&&!active&&!mode_ok)?8'h01:8'h00);
   if(go)begin
    active<=1;descriptor<=job_descriptor;session<=job_session;destination<=job_destination;
    rs<=RA;ws<=WF;araddr<=job_source;awaddr<=job_destination;
    rn<=burst(job_source,ssize>>4);wn<=burst(job_destination,dsize>>4);rremaining<=ssize>>4;wremaining<=dsize>>4;
    source_count<=0;sink_count<=0;total_source_words<=ssize>>3;total_sink_words<=dsize>>3;
    rcount<=0;wfill<=0;wsend<=0;rsend<=0;rpad<=0;wpad<=0;source_half<=0;sink_half<=0;
    srow<=0;sword<=0;row_words<=sbytes>>3;ppv_shift<=job_co==2?2:job_co==4?1:0;
    saw_r<=0;saw_source<=0;saw_sink<=0;saw_compute<=0;saw_b<=0;
    rwatch<=0;wwatch<=0;read_beats<=0;write_beats<=0;write_responses<=0;
   end
   if(rtimeout&&!error)rwatch<=rwatch+1'b1;else rwatch<=0;
   if(wtimeout&&!error)wwatch<=wwatch+1'b1;else wwatch<=0;
   if(rt)read_beats<=read_beats+1'b1;
   if(wt)write_beats<=write_beats+1'b1;
   if(bt)write_responses<=write_responses+1'b1;
   if(ct&&retiregood&&!fault_now&&!error)saw_compute<=1;
   if(complete_valid&&complete_ready)begin complete_valid<=0;active<=0;end
   if(active&&!complete_valid&&all_barriers&&!error&&!fault_now)complete_valid<=1;
   case(rs)
    RA:if(at)begin rs<=RD;rcount<=0;end
    RD:if(rt)begin
     if(error||fault_now||!rgood)begin if(rlast)rs<=RH;end
     else if(rcount==rn-1'b1)begin
      if(rremaining==rn)saw_r<=1;
      rsend<=0;source_half<=0;
      if(rn<BB)begin rpad<=BB-rn;rs<=RP;end else rs<=RS;
     end else rcount<=rcount+1'b1;
    end
    RP:if(error||fault_now)rs<=RH;
       else if(rpad<=1)begin rpad<=0;rs<=RS;end else rpad<=rpad-1'b1;
    RS:if(st)begin
     if(error||fault_now)rs<=RH;
     else begin
      source_count<=source_count+1'b1;
      if(source_eol)begin sword<=0;srow<=srow+1'b1;end else sword<=sword+1'b1;
      if(source_last)begin saw_source<=1;rs<=RI;end
      else if(source_half)begin
       source_half<=0;
       if(rsend==rn-1'b1)begin
        rremaining<=rremaining-rn;araddr<=araddr+(rn<<4);rn<=burst(araddr+(rn<<4),rremaining-rn);rs<=RA;
       end else rsend<=rsend+1'b1;
      end else source_half<=1;
     end
    end
    default:begin end
   endcase
   case(ws)
    WF:if(error||fault_now)ws<=WH;
       else if(kt)begin
        sink_count<=sink_count+1'b1;
        if(sink_last)saw_sink<=1;
        if(sink_half)begin
         sink_half<=0;
         if(wfill==wn-1'b1)begin
          wfill<=0;wsend<=0;
          if(wn<BB)begin wpad<=BB-wn;ws<=WP;end else ws<=WA;
         end else wfill<=wfill+1'b1;
        end else begin sink_low<=sink_data;sink_half<=1;end
       end
    WP:if(error||fault_now)ws<=WH;
       else if(wpad<=1)begin wpad<=0;ws<=WA;end else wpad<=wpad-1'b1;
    WA:if(awvalid&&awready)begin wsend<=0;ws<=WW;end
    WW:if(wt)begin if(wlast)ws<=WB;else wsend<=wsend+1'b1;end
    WB:if(bt)begin
     if(error||fault_now||!bgood)ws<=WH;
     else if(wremaining==wn)begin saw_b<=1;ws<=WI;end
     else begin
      wremaining<=wremaining-wn;awaddr<=awaddr+(wn<<4);wn<=burst(awaddr+(wn<<4),wremaining-wn);ws<=WF;
     end
    end
    default:begin end
   endcase
  end
 end
 // synthesis translate_off
 initial if(BB<1||BB>256||WDOG<2)$fatal(1,"stage_dma_owner parameters");
 // synthesis translate_on
endmodule
