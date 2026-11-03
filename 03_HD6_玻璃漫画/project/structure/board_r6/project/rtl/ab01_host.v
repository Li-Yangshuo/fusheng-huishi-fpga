// Stop-and-wait UART transport. Request: A5 5A op seq addrLE32 dataLE128 xor.
// Reply: 5A A5 seq status dataLE128 xor. XOR covers bytes after the header.
// No automatic retry: a lost write ACK requires recovery, not replay of GO.
module ab01_host #(parameter DIV=868, parameter TIMEOUT=10000000)(
 input wire clk,rstn,rx,dual_mode,output wire tx,output reg toggle,
 output wire [15:0] paddr,output reg psel,penable,pwrite,
 output wire [31:0] pwdata,input wire pready,pslverr,input wire [31:0] prdata,
 output wire [31:0] local_addr,local_wdata,output reg local_write,
 input wire [127:0] local_rdata,
 output wire [3:0] awid,arid,output wire [31:0] awaddr,araddr,
 output wire [7:0] awlen,arlen,output reg awvalid,wvalid,arvalid,
 input wire awready,wready,arready,output wire [127:0] wdata,
 output wire [15:0] wstrb,output wire wlast,output wire bready,rready,
 input wire bvalid,rvalid,rlast,input wire [1:0] bresp,rresp,input wire [127:0] rdata
);
 wire [7:0] din;wire dv,fe;
 a18_uart_rx #(.DIV(DIV)) urx(.clk(clk),.rstn(rstn),.rx(rx),.data(din),.valid(dv),.frame_error(fe));
 reg tx_start;reg [7:0] dout;wire tx_busy;
 a18_uart_tx #(.DIV(DIV)) utx(.clk(clk),.rstn(rstn),.start(tx_start),.data(dout),.tx(tx),.busy(tx_busy));
 reg [5:0] pi;reg [7:0] op,seq,check;reg [31:0] addr,age;
 reg [127:0] payload;reg request,bad_packet;
 reg [1:0] ascii_state;reg ascii_query,query;
 reg [3:0] state;reg [7:0] status;reg [127:0] answer;
 reg [5:0] ti;reg [7:0] out_xor;reg binary_reply,mode_snap;
 assign paddr=addr[15:0];assign pwdata=payload[31:0];
 assign local_addr=addr;assign local_wdata=payload[31:0];
 assign awid=4'd5;assign arid=4'd5;assign awaddr=addr;assign araddr=addr;
 assign awlen=0;assign arlen=0;assign wdata=payload;assign wstrb=16'hffff;assign wlast=1;
 assign bready=(state==5);assign rready=(state==6&&!arvalid);
 always @(posedge clk or negedge rstn) begin
  if(!rstn)begin pi<=0;op<=0;seq<=0;addr<=0;payload<=0;check<=0;request<=0;bad_packet<=0;age<=0;ascii_state<=0;ascii_query<=0;toggle<=0;query<=0;end
  else begin
   request<=0;toggle<=0;query<=0;
   if(pi!=0||ascii_state!=0)begin
    if(age>=TIMEOUT-1)begin pi<=0;ascii_state<=0;age<=0;end else age<=age+1'b1;
   end else age<=0;
   if(fe)begin pi<=0;ascii_state<=0;end
   else if(dv&&state==0)begin
    age<=0;
    if(pi!=0)begin
     case(pi)
      1:if(din==8'h5a)begin pi<=2;check<=0;end else pi<=(din==8'ha5)?1:0;
      2:begin op<=din;check<=din;pi<=3;end
      3:begin seq<=din;check<=check^din;pi<=4;end
      24:begin request<=1;bad_packet<=din!=check;pi<=0;end
      default:begin
       if(pi<8)addr[(pi-4)*8+:8]<=din;
       else payload[(pi-8)*8+:8]<=din;
       check<=check^din;pi<=pi+1'b1;
      end
     endcase
    end else if(din==8'ha5)begin pi<=1;ascii_state<=0;end
    else if(din=="@")ascii_state<=1;
    else case(ascii_state)
     1:if(din=="T"||din=="Q")begin ascii_query<=din=="Q";ascii_state<=2;end else ascii_state<=0;
     2:if(din==10)begin if(ascii_query)query<=1;else toggle<=1;ascii_state<=0;end else if(din!=13)ascii_state<=0;
     default:ascii_state<=0;
    endcase
   end
  end
 end
 wire memory_allowed=(addr>=32'h03000000 && addr<32'h03013560 && addr[3:0]==0);
 // Only the 79,200-byte style region is writable/readable from the PC.
 // Camera, result and workspace ownership cannot be bypassed through this port.
 reg mode_d,pending,binary_session;
 function [7:0] emit_byte;
  input [5:0] n;
  begin
   if(binary_reply)begin
    case(n)
     0:emit_byte=8'h5a;1:emit_byte=8'ha5;2:emit_byte=seq;3:emit_byte=status;
     20:emit_byte=out_xor;
     default:emit_byte=answer[(n-4)*8+:8];
    endcase
   end else case(n)0:emit_byte="@";1:emit_byte="M";2:emit_byte=",";3:emit_byte=mode_snap?"D":"F";default:emit_byte=10;endcase
  end
 endfunction
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin state<=0;psel<=0;penable<=0;pwrite<=0;local_write<=0;awvalid<=0;wvalid<=0;arvalid<=0;status<=0;answer<=0;ti<=0;out_xor<=0;binary_reply<=1;mode_snap<=1;tx_start<=0;dout<=0;mode_d<=1;pending<=0;binary_session<=0;end
  else begin
   tx_start<=0;local_write<=0;mode_d<=dual_mode;
   if(query||mode_d!=dual_mode)pending<=1;
   case(state)
    0:begin
     if(request)begin
      status<=0;answer<=0;binary_reply<=1;binary_session<=1;ti<=0;out_xor<=0;
      if(bad_packet)begin status<=2;state<=8;end
      else case(op)
       1,2:if((op==1 ? addr>32'h7c : addr>32'h6c)||addr[1:0]!=0)begin status<=5;state<=8;end
           else begin psel<=1;pwrite<=op==2;penable<=0;state<=1;end
       3:if(!memory_allowed)begin status<=5;state<=8;end
         else begin awvalid<=1;state<=3;end
       4:if(!memory_allowed)begin status<=5;state<=8;end
         else begin arvalid<=1;state<=6;end
       5:begin answer<=local_rdata;state<=8;end
       6:begin local_write<=1;state<=7;end
       default:begin status<=1;state<=8;end
      endcase
     end else if(pending&&!binary_session&&pi==0&&ascii_state==0&&!dv)begin
      pending<=0;binary_reply<=0;mode_snap<=dual_mode;ti<=0;state<=8;
     end
    end
    1:begin penable<=1;state<=2;end
    2:if(pready)begin psel<=0;penable<=0;answer<={96'd0,prdata};status<=pslverr?3:0;state<=8;end
    3:if(awready)begin awvalid<=0;wvalid<=1;state<=4;end
    4:if(wready)begin wvalid<=0;state<=5;end
    5:if(bvalid)begin status<=bresp!=0?4:0;state<=8;end
    6:begin
     if(arvalid&&arready)arvalid<=0;
     if(rvalid&&!arvalid)begin answer<=rdata;status<=(rresp!=0||!rlast)?4:0;state<=8;end
    end
    7:begin answer<=local_rdata;state<=8;end
    8:if(!tx_busy)begin
     dout<=emit_byte(ti);tx_start<=1;
     if(binary_reply&&ti>=2&&ti<20)out_xor<=out_xor^emit_byte(ti);
     state<=9;
    end
    9:if(tx_busy)state<=10;
    10:if(!tx_busy)begin
     if(ti==(binary_reply?20:4))state<=0;
     else begin ti<=ti+1'b1;state<=8;end
    end
    default:state<=0;
   endcase
  end
 end
endmodule
