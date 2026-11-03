// Held-data request/ack mailbox. Diagnostic counters cross atomically;
// independent pixel-domain drop counters survive DDR/service resets.
module ab14_diag_mailbox #(parameter DEBOUNCE_CYCLES=742500, parameter BOOT_TEST_CYCLES=742500000)(
 input wire sclk,srstn,input wire[255:0] sdata,
 input wire dclk,drstn,cal_done,base_rstn,key_n,
 output reg[255:0] ddata,output wire[31:0] reset_counts,output wire test_pattern
);
 wire arst=!(srstn&&drstn);
 reg req,ack;reg[255:0] held;
 (* async_reg="true" *)reg[1:0] requests,acks;
 always @(posedge sclk or posedge arst)
  if(arst)begin req<=0;acks<=0;held<=0;end
  else begin acks<={acks[0],ack};if(req==acks[1])begin held<=sdata;req<=!req;end end
 always @(posedge dclk or posedge arst)
  if(arst)begin requests<=0;ack<=0;ddata<=0;end
  else begin requests<={requests[0],req};if(requests[1]!=ack)begin ddata<=held;ack<=requests[1];end end
 (* async_reg="true" *)reg[1:0] cs,bs,ks;
 reg cp,bp,key_stable,key_pattern;
 localparam BW=(BOOT_TEST_CYCLES<2)?1:$clog2(BOOT_TEST_CYCLES+1);
 reg[BW-1:0] boot_cycles;
 assign test_pattern=key_pattern || ((BOOT_TEST_CYCLES!=0)&&(boot_cycles<BOOT_TEST_CYCLES));
 always @(posedge dclk or negedge drstn)
  if(!drstn)boot_cycles<=0;
  else if(boot_cycles<BOOT_TEST_CYCLES)boot_cycles<=boot_cycles+1'b1;
 reg[19:0] debounce;
 reg[15:0] cal_falls,base_falls;
 assign reset_counts={base_falls,cal_falls};
 always @(posedge dclk or negedge drstn)
  if(!drstn)begin cs<=0;bs<=0;ks<=3;cp<=0;bp<=0;cal_falls<=0;base_falls<=0;
   key_stable<=1;debounce<=0;key_pattern<=0;end
  else begin
   cs<={cs[0],cal_done};bs<={bs[0],base_rstn};ks<={ks[0],key_n};cp<=cs[1];bp<=bs[1];
   if(cp&&!cs[1]&&cal_falls!=16'hffff)cal_falls<=cal_falls+1'b1;
   if(bp&&!bs[1]&&base_falls!=16'hffff)base_falls<=base_falls+1'b1;
   if(ks[1]!=key_stable)begin
    if(debounce==DEBOUNCE_CYCLES-1)begin
     key_stable<=ks[1];debounce<=0;if(key_stable&&!ks[1])key_pattern<=!key_pattern;
    end else debounce<=debounce+1'b1;
   end else debounce<=0;
  end
endmodule
