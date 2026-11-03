// A18.6: 115200 8N1. Only complete @T\n and @Q\n commands are accepted.
// @T toggles the requested view; @Q queries the committed view.
// Reply @M,D\n / @M,F\n reports the actual frame-boundary mode.
module a18_uart_rx #(parameter integer DIV=1289)(
 input wire clk,rstn,rx,output reg [7:0] data,output reg valid,frame_error
);
 localparam integer CW=$clog2(DIV+1);
 (* async_reg="true" *) reg meta,sync;
 reg [CW-1:0] count;reg [2:0] state;reg [2:0] bit_no;reg [7:0] shift;
 always @(posedge clk or negedge rstn)
  if(!rstn)begin meta<=1;sync<=1;end else begin meta<=rx;sync<=meta;end
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin state<=0;count<=0;bit_no<=0;shift<=0;valid<=0;frame_error<=0;data<=0;end
  else begin
   valid<=0;frame_error<=0;
   case(state)
    0:if(!sync)begin count<=DIV/2-1;state<=1;end
    1:if(count!=0)count<=count-1'b1;
      else if(sync)state<=0;else begin count<=DIV-1;bit_no<=0;state<=2;end
    2:if(count!=0)count<=count-1'b1;
      else begin shift[bit_no]<=sync;count<=DIV-1;if(bit_no==7)state<=3;else bit_no<=bit_no+1'b1;end
    3:if(count!=0)count<=count-1'b1;
      else if(sync)begin data<=shift;valid<=1;state<=0;end
      else begin frame_error<=1;state<=4;end
    4:if(sync)state<=0;
    default:state<=0;
   endcase
  end
 end
endmodule

module a18_uart_tx #(parameter integer DIV=1289)(
 input wire clk,rstn,start,input wire [7:0] data,output reg tx,busy
);
 localparam integer CW=$clog2(DIV+1);
 reg [CW-1:0] count;reg [3:0] bit_no;reg [9:0] frame;
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin tx<=1;busy<=0;count<=0;bit_no<=0;frame<=10'h3ff;end
  else if(!busy)begin
   tx<=1;
   if(start)begin frame<={1'b1,data,1'b0};tx<=0;busy<=1;count<=DIV-1;bit_no<=0;end
  end else if(count!=0)count<=count-1'b1;
  else begin
   count<=DIV-1;
   if(bit_no==9)begin busy<=0;tx<=1;end
   else begin bit_no<=bit_no+1'b1;tx<=frame[bit_no+1'b1];end
  end
 end
endmodule

module a18_uart_control #(
 parameter integer CLOCK_HZ=148500000,BAUD=115200,
 parameter integer COMMAND_TIMEOUT=(CLOCK_HZ/10)
)(
 input wire clk,rstn,rx,dual_mode,output wire tx,output reg toggle_pulse
);
 localparam integer DIV=(CLOCK_HZ+BAUD/2)/BAUD;
 localparam integer TW=$clog2(COMMAND_TIMEOUT+1);
 wire [7:0] byte_in;wire byte_valid,frame_error;
 a18_uart_rx #(.DIV(DIV)) receiver(.clk(clk),.rstn(rstn),.rx(rx),.data(byte_in),.valid(byte_valid),.frame_error(frame_error));
 reg [1:0] parser;reg command_query,query_pulse;reg [TW-1:0] age;
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin parser<=0;command_query<=0;toggle_pulse<=0;query_pulse<=0;age<=0;end
  else begin
   toggle_pulse<=0;query_pulse<=0;
   if(parser!=0)begin
    if(age>=COMMAND_TIMEOUT-1)begin parser<=0;age<=0;end
    else age<=age+1'b1;
   end else age<=0;
   if(frame_error)begin parser<=0;age<=0;end
   else if(byte_valid)begin
    age<=0;
    // A fresh @ always starts a new frame, even after malformed input.
    if(byte_in==8'h40)parser<=1;
    else case(parser)
     1:if(byte_in==8'h54||byte_in==8'h51)begin command_query<=byte_in==8'h51;parser<=2;end else parser<=0;
     2:if(byte_in==8'h0a)begin
        if(command_query)query_pulse<=1;else toggle_pulse<=1;parser<=0;
       end else if(byte_in==8'h0d)parser<=3;else parser<=0;
     3:begin if(byte_in==8'h0a)begin if(command_query)query_pulse<=1;else toggle_pulse<=1;end parser<=0;end
     default:parser<=0;
    endcase
   end
  end
 end
 reg mode_seen,pending,snapshot_mode;reg [2:0] sender,index;
 reg start;reg [7:0] byte_out;wire busy;
 a18_uart_tx #(.DIV(DIV)) transmitter(.clk(clk),.rstn(rstn),.start(start),.data(byte_out),.tx(tx),.busy(busy));
 function [7:0] reply_byte;
  input [2:0] n;input mode;
  begin case(n)0:reply_byte="@";1:reply_byte="M";2:reply_byte=",";3:reply_byte=mode?"D":"F";default:reply_byte=8'h0a;endcase end
 endfunction
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin mode_seen<=1;pending<=0;snapshot_mode<=1;sender<=0;index<=0;start<=0;byte_out<=0;end
  else begin
   mode_seen<=dual_mode;start<=0;
   case(sender)
    0:if(pending)begin pending<=0;snapshot_mode<=dual_mode;index<=0;sender<=1;end
    1:if(!busy)begin byte_out<=reply_byte(index,snapshot_mode);start<=1;sender<=2;end
    2:if(busy)sender<=3;
    3:if(!busy)begin if(index==4)sender<=0;else begin index<=index+1'b1;sender<=1;end end
    default:sender<=0;
   endcase
   // A one-entry, latest-state notification queue coalesces rapid state/query events.
   if(query_pulse||mode_seen!=dual_mode)pending<=1;
  end
 end
endmodule
