// Two ordered burst banks decouple AXI R from the downstream pixel stream.
// Every AR reserves a complete bank; RREADY is independent of pixel_ready.
// Banks are fixed-tap SRLs, including zero padding for partial/page bursts.
// A fault preserves a stalled pixel and an offered AR, drains the bus to its
// actual RLAST, and quarantines the descriptor until coordinated reset.
module ab05_rgbx_axi_reader_prefetch #(
 parameter integer WIDTH=1280,HEIGHT=720,PREVIEW=1,MAX_BEATS=16,WATCHDOG=100000,
 parameter [3:0] AXI_ID=4'd3
)(
 input wire clk,rstn,
 input wire desc_valid,output wire desc_ready,
 input wire [31:0] desc_frame_id,desc_base,desc_stride,
 output wire [3:0] m_arid,output wire [31:0] m_araddr,
 output wire [7:0] m_arlen,output wire [2:0] m_arsize,
 output wire [1:0] m_arburst,output wire m_arvalid,input wire m_arready,
 input wire [3:0] m_rid,input wire [127:0] m_rdata,
 input wire [1:0] m_rresp,input wire m_rlast,m_rvalid,output wire m_rready,
 output wire pixel_valid,input wire pixel_ready,
 output wire [23:0] pixel_rgb,output wire [31:0] pixel_frame_id,
 output wire [10:0] pixel_x,output wire [9:0] pixel_y,
 output wire pixel_sof,pixel_eol,pixel_eof,
 output wire done_valid,input wire done_ready,
 output wire [31:0] done_frame_id,output wire [3:0] done_error,
 output reg quarantined,
 output reg [31:0] accepted_beats,ar_commands,max_ar_wait,output_stall_cycles
);
 localparam OUT_W=PREVIEW==2?WIDTH/2:PREVIEW?WIDTH*3/4:WIDTH,OUT_H=PREVIEW==2?HEIGHT/2:PREVIEW?HEIGHT*3/4:HEIGHT;
 localparam G_IDLE=0,G_RUN=1,G_DONE=2,G_POISON=3;
 localparam R_IDLE=0,R_AR=1,R_READ=2,R_PAD=3,R_DRAIN=4,R_AR_POISON=5;
 reg [1:0] state;reg [2:0] rstate;
 reg [31:0] fid,stride,row_base,addr;
 reg [9:0] read_y;reg [1:0] row_phase;
 reg [8:0] row_left,burst_len,burst_left,pad_left;
 reg producer_done;
 reg wr_bank,rd_bank;reg [1:0] bank_busy,bank_ready;
 reg [8:0] bank_words[0:1];
 reg [3:0] error_code;
 reg [31:0] wait_cycles,ar_wait;
 reg pvalid;reg [23:0] prgb;reg [10:0] px;reg [9:0] py;
 reg psof,peol,peof;
 reg [10:0] ox;reg [9:0] oy;reg [1:0] part;
 reg consumer_done;
 wire [63:0] frame_end={32'd0,desc_base}+({32'd0,desc_stride}*(HEIGHT-1))+(WIDTH*4);
 function automatic [8:0] choose_len(input [31:0] address,input [8:0] remaining);
  reg [8:0] page_beats,chosen;
  begin
   page_beats=(13'd4096-{1'b0,address[11:0]})>>4;
   chosen=(remaining>MAX_BEATS)?MAX_BEATS:remaining;
   choose_len=(chosen>page_beats)?page_beats:chosen;
  end
 endfunction
 assign desc_ready=state==G_IDLE;
 assign m_arid=AXI_ID;assign m_araddr=addr;assign m_arlen=burst_len-1'b1;
 assign m_arsize=3'd4;assign m_arburst=2'b01;
 assign m_arvalid=rstate==R_AR||rstate==R_AR_POISON;
 assign m_rready=rstate==R_READ||rstate==R_DRAIN;
 assign pixel_valid=pvalid;assign pixel_rgb=prgb;assign pixel_frame_id=fid;
 assign pixel_x=px;assign pixel_y=py;
 assign pixel_sof=psof;assign pixel_eol=peol;assign pixel_eof=peof;
 assign done_valid=state==G_DONE;assign done_frame_id=fid;assign done_error=error_code;
 reg [3:0] fault_now;
 always @*begin
  fault_now=0;
  if(rstate==R_AR&&!m_arready&&ar_wait==WATCHDOG-1)fault_now=2;
  else if(rstate==R_READ)begin
   if(m_rvalid)begin
    if(m_rid!=AXI_ID)fault_now=3;
    else if(m_rresp!=0)fault_now=4;
    else if(m_rlast!=(burst_left==1))fault_now=5;
   end else if(wait_cycles==WATCHDOG-1)fault_now=6;
  end
 end
 wire load_pixel=state==G_RUN&&error_code==0&&fault_now==0&&!consumer_done&&
  (!pvalid||pixel_ready)&&bank_ready[rd_bank];
 wire pop_word=load_pixel&&part==(PREVIEW?2:3);
 wire fill_word=rstate==R_READ&&m_rvalid&&fault_now==0;
 wire pad_word=rstate==R_PAD;
 wire [127:0] bank_tap[0:1];
 genvar b;
 generate for(b=0;b<2;b=b+1)begin:bank
  reg [127:0] words[0:MAX_BEATS-1];integer j;
  wire filling=fill_word&&wr_bank==b;
  wire shifting=filling||(pad_word&&wr_bank==b)||(pop_word&&rd_bank==b);
  always @(posedge clk)if(rstn&&shifting)begin
   words[0]<=filling?m_rdata:128'd0;
   for(j=1;j<MAX_BEATS;j=j+1)words[j]<=words[j-1];
  end
  assign bank_tap[b]=words[MAX_BEATS-1];
 end endgenerate
 wire [127:0] head=bank_tap[rd_bank];
 wire [31:0] next_addr=addr+({23'd0,burst_len}<<4);
 wire [31:0] next_row=row_base+(PREVIEW==2?(stride<<1):((PREVIEW&&row_phase==2)?(stride<<1):stride));
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin
   state<=G_IDLE;rstate<=R_IDLE;fid<=0;stride<=0;row_base<=0;addr<=0;
   read_y<=0;row_phase<=0;row_left<=0;burst_len<=0;burst_left<=0;pad_left<=0;
   producer_done<=0;wr_bank<=0;rd_bank<=0;bank_busy<=0;bank_ready<=0;
   bank_words[0]<=0;bank_words[1]<=0;error_code<=0;quarantined<=0;
   wait_cycles<=0;ar_wait<=0;accepted_beats<=0;ar_commands<=0;max_ar_wait<=0;
   output_stall_cycles<=0;pvalid<=0;prgb<=0;px<=0;py<=0;psof<=0;peol<=0;peof<=0;
   ox<=0;oy<=0;part<=0;consumer_done<=0;
  end else begin
   // The elastic output keeps a previously offered pixel stable through faults.
   if(pvalid&&pixel_ready)pvalid<=0;
   if(pvalid&&!pixel_ready)output_stall_cycles<=output_stall_cycles+1;
   if(load_pixel)begin
    pvalid<=1;prgb<=head[part*32+8+:24];px<=ox;py<=oy;
    psof<=ox==0&&oy==0;peol<=ox==OUT_W-1;peof<=ox==OUT_W-1&&oy==OUT_H-1;
    if(ox==OUT_W-1)begin ox<=0;oy<=oy+1'b1;end else ox<=ox+1'b1;
    if(ox==OUT_W-1&&oy==OUT_H-1)consumer_done<=1;
    if(pop_word)begin
     part<=0;bank_words[rd_bank]<=bank_words[rd_bank]-1'b1;
     if(bank_words[rd_bank]==1)begin
      bank_ready[rd_bank]<=0;bank_busy[rd_bank]<=0;rd_bank<=!rd_bank;
     end
    end else part<=part+(PREVIEW==2?2:1);
   end
   if(fault_now!=0&&error_code==0)begin error_code<=fault_now;quarantined<=1;end
   if(m_rvalid&&m_rready)accepted_beats<=accepted_beats+1;
   case(state)
    G_IDLE:if(desc_valid)begin
     fid<=desc_frame_id;stride<=desc_stride;row_base<=desc_base;addr<=desc_base;
     read_y<=0;row_phase<=0;row_left<=WIDTH/4;producer_done<=0;
     wr_bank<=0;rd_bank<=0;bank_busy<=0;bank_ready<=0;
     ox<=0;oy<=0;part<=0;consumer_done<=0;error_code<=0;quarantined<=0;
     accepted_beats<=0;ar_commands<=0;max_ar_wait<=0;output_stall_cycles<=0;
     pvalid<=0;wait_cycles<=0;ar_wait<=0;rstate<=R_IDLE;
     if(desc_base[3:0]!=0||desc_stride[3:0]!=0||desc_stride<WIDTH*4||frame_end>64'h100000000)begin
      error_code<=1;state<=G_DONE;
     end else state<=G_RUN;
    end
    G_RUN:begin
     if(error_code!=0)begin
      if(rstate==R_IDLE&&!pvalid)state<=G_DONE;
     end else if(producer_done&&consumer_done&&!pvalid&&rstate==R_IDLE)state<=G_DONE;
     case(rstate)
      R_IDLE:if(error_code==0&&!producer_done&&!bank_busy[wr_bank])begin
       // Reservation happens before AR is exposed; never stop a valid R burst
       // merely because either display FIFO is full.
       bank_busy[wr_bank]<=1;burst_len<=choose_len(addr,row_left);
       ar_wait<=0;rstate<=R_AR;
      end
      R_AR:if(m_arready)begin
       burst_left<=burst_len;ar_commands<=ar_commands+1;wait_cycles<=0;rstate<=R_READ;
       if(ar_wait>max_ar_wait)max_ar_wait<=ar_wait;
      end else if(fault_now!=0)begin
       rstate<=R_AR_POISON;if(ar_wait>max_ar_wait)max_ar_wait<=ar_wait;
      end else ar_wait<=ar_wait+1;
      R_READ:if(m_rvalid)begin
       wait_cycles<=0;
       if(fault_now!=0)rstate<=m_rlast?R_IDLE:R_DRAIN;
       else begin
        burst_left<=burst_left-1'b1;
        if(burst_left==1)begin
         bank_words[wr_bank]<=burst_len;
         if(burst_len<MAX_BEATS)begin pad_left<=MAX_BEATS-burst_len;rstate<=R_PAD;end
         else begin bank_ready[wr_bank]<=1;wr_bank<=!wr_bank;rstate<=R_IDLE;end
         if(row_left==burst_len)begin
          if(read_y==OUT_H-1)producer_done<=1;
          else begin
           read_y<=read_y+1'b1;row_phase<=(row_phase==2)?0:row_phase+1'b1;
           row_base<=next_row;addr<=next_row;row_left<=WIDTH/4;
          end
         end else begin addr<=next_addr;row_left<=row_left-burst_len;end
        end
       end
      end else if(fault_now!=0)rstate<=R_DRAIN;
      else wait_cycles<=wait_cycles+1;
      R_PAD:begin
       pad_left<=pad_left-1'b1;
       if(pad_left==1)begin bank_ready[wr_bank]<=1;wr_bank<=!wr_bank;rstate<=R_IDLE;end
      end
      R_DRAIN:if(m_rvalid&&m_rlast)rstate<=R_IDLE;
      R_AR_POISON:if(m_arready)begin ar_commands<=ar_commands+1;rstate<=R_DRAIN;end
      default:begin rstate<=R_IDLE;error_code<=7;quarantined<=1;end
     endcase
    end
    G_DONE:if(done_ready)state<=quarantined?G_POISON:G_IDLE;
    G_POISON:begin end
    default:begin state<=G_POISON;quarantined<=1;end
   endcase
  end
 end
 // synthesis translate_off
 initial if(WIDTH<4||WIDTH>2044||HEIGHT<4||HEIGHT>1023||WIDTH%4||
  (PREVIEW&&HEIGHT%4)||MAX_BEATS<1||MAX_BEATS>256||WATCHDOG<1)$fatal(1,"reader geometry");
 always @(posedge clk)if(rstn)begin
  if(fill_word&&pop_word&&wr_bank==rd_bank)$fatal(1,"bank ownership collision");
  if(m_rready&&rstate==R_READ&&(!bank_busy[wr_bank]||bank_ready[wr_bank]))$fatal(1,"unreserved R bank");
 end
 // synthesis translate_on
endmodule
