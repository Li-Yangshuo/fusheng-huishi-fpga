// A16.2: do not start the video consumer until a full RAW frame has
// actually reached DDR, including every write response. No timer estimate.
module a16_raw_startup(
 input wire clk,rstn,frame_start,input wire [31:0] frame_beats,
 input wire awvalid,awready,input wire [7:0] awlen,
 input wire bvalid,bready,output reg ready
);
 (* async_reg="true" *) reg [2:0] start_sync;
 reg active;reg [31:0] expected,sent,requests,responses;
 wire boundary=start_sync[1]&&!start_sync[2];
 always @(posedge clk or negedge rstn) begin
  if(!rstn)begin start_sync<=0;active<=0;ready<=0;expected<=0;sent<=0;requests<=0;responses<=0;end
  else begin
   start_sync<={start_sync[1:0],frame_start};
   if(boundary)begin active<=frame_beats!=0;expected<=frame_beats;sent<=0;requests<=0;responses<=0;end
   else if(active)begin
    if(awvalid&&awready)begin sent<=sent+{24'd0,awlen}+32'd1;requests<=requests+1;end
    if(bvalid&&bready && responses<requests)begin
     responses<=responses+1;
     if(sent==expected && responses+1==requests)begin ready<=1;active<=0;end
    end
   end
  end
 end
endmodule
