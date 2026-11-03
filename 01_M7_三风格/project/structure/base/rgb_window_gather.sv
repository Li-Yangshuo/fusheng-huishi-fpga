// Consume H3b's held five-window packet in place, one position per cycle.
// Assemble channel0/1/2 windows into one RGB pixel, retaining full metadata.
module rgb_window_gather #(
 parameter WIDTH=1280,HEIGHT=720,XW=$clog2(WIDTH+1),YW=$clog2(HEIGHT+1)
)(
 input wire clk,rst,input wire start_valid,output wire start_ready,input wire [31:0] start_frame,
 input wire in_valid,output wire in_ready,input wire [4:0] in_mask,input wire [359:0] in_windows,
 input wire [5*XW-1:0] in_x,input wire [9:0] in_channel,input wire [YW-1:0] in_y,
 input wire [31:0] in_frame,input wire in_eol,in_last,
 output wire out_valid,input wire out_ready,output reg [215:0] out_windows,
 output reg [XW-1:0] out_x,output reg [YW-1:0] out_y,output reg [31:0] out_frame,
 output reg out_eol,out_last,output reg done,protocol_error
);
 reg active,valid,input_done,output_done;reg [2:0] pos;reg [1:0] channel;
 reg [XW-1:0] x;reg [YW-1:0] y;reg [31:0] frame;
 wire advance=!valid || out_ready;
 wire step=!rst && active && !input_done && in_valid && advance;
 assign start_ready=!rst && !active && !valid && pos==0;
 assign in_ready=step && pos==4;assign out_valid=!rst && valid;
 wire [XW-1:0] ix=in_x[pos*XW+:XW];wire [1:0] ic=in_channel[pos*2+:2];
 wire tail=(in_mask>>(pos+1'b1))==0;
 wire expected_eol=x==WIDTH-1 && channel==2;
 wire expected_last=expected_eol && y==HEIGHT-1;
 always @(posedge clk)begin
  if(rst)begin
   active<=0;valid<=0;input_done<=0;output_done<=0;pos<=0;channel<=0;x<=0;y<=0;frame<=0;
   out_windows<=0;out_x<=0;out_y<=0;out_frame<=0;out_eol<=0;out_last<=0;done<=0;protocol_error<=0;
  end else begin
   done<=0;
   if(start_valid && start_ready)begin active<=1;input_done<=0;output_done<=0;pos<=0;channel<=0;x<=0;y<=0;frame<=start_frame;end
   if(out_valid && out_ready)begin valid<=0;if(out_last)output_done<=1;end
   if(step)begin
    if(pos==4)begin pos<=0;if(in_last)input_done<=1;end else pos<=pos+1'b1;
    if(in_mask[pos])begin
     if(ix!=x || ic!=channel || in_y!=y || in_frame!=frame || y>=HEIGHT ||
       (tail && (in_eol!=expected_eol || in_last!=expected_last)))protocol_error<=1;
     out_windows[channel*72+:72]<=in_windows[pos*72+:72];
     if(channel==2)begin
      valid<=1;out_x<=x;out_y<=y;out_frame<=frame;out_eol<=expected_eol;out_last<=expected_last;channel<=0;
      if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
     end else channel<=channel+1'b1;
    end
   end
   if(active && input_done && output_done)begin active<=0;done<=1;if(channel!=0 || y!=HEIGHT)protocol_error<=1;end
  end
 end
endmodule
