// Full-view 1280x720 scalar RGB -> 640x480 sampling, no input backpressure.
// sx=2*ox; sy=floor((3*oy+1)/2): rows 0,2 of every group of three.
// Hold each selected even pixel until the following odd pixel validates the
// source line boundary. A malformed final source EOL cannot publish an EOF.
module ab12_capture720_to_vga(
 input wire clk,rstn,
 input wire in_valid,in_sof,in_eol,input wire [23:0] in_rgb,
 input wire [31:0] in_frame_id,
 output reg out_valid,out_sof,out_eol,out_eof,output reg [23:0] out_rgb,
 output reg [31:0] out_frame_id,output reg fault,output reg [3:0] error_code
);
 reg active;
 reg [10:0] sx;
 reg [9:0] sy;
 reg [1:0] row_phase;
 reg [31:0] frame_id;
 reg selected,selected_sof;
 reg [23:0] selected_rgb;
 wire [3:0] current_error=!active?(in_sof?(in_eol?4'd4:4'd0):4'd1):
   (in_sof?4'd2:((in_frame_id!=frame_id)?4'd3:
    ((in_eol!=(sx==11'd1279))?4'd4:4'd0)));
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin
   active<=0;sx<=0;sy<=0;row_phase<=0;frame_id<=0;
   selected<=0;selected_sof<=0;selected_rgb<=0;
   out_valid<=0;out_sof<=0;out_eol<=0;out_eof<=0;out_rgb<=0;
   out_frame_id<=0;fault<=0;error_code<=0;
  end else begin
   out_valid<=0;out_sof<=0;out_eol<=0;out_eof<=0;
   if(!fault && in_valid)begin
    if(current_error!=0)begin
     fault<=1;error_code<=current_error;active<=0;selected<=0;
    end else if(!active)begin
     // Native (0,0) is always selected. The next pixel validates this pair.
     active<=1;sx<=1;sy<=0;row_phase<=0;frame_id<=in_frame_id;
     selected<=1;selected_sof<=1;selected_rgb<=in_rgb;
    end else begin
     if(!sx[0])begin
      selected<=row_phase!=1;selected_sof<=0;selected_rgb<=in_rgb;
     end else begin
      selected<=0;
      if(selected)begin
       out_valid<=1;out_sof<=selected_sof;out_eol<=sx==11'd1279;
       out_eof<=sx==11'd1279 && sy==10'd719;
       out_rgb<=selected_rgb;out_frame_id<=frame_id;
      end
     end
     if(sx==11'd1279)begin
      sx<=0;
      if(sy==10'd719)begin active<=0;sy<=0;row_phase<=0;end
      else begin sy<=sy+1'b1;row_phase<=(row_phase==2)?0:row_phase+1'b1;end
     end else sx<=sx+1'b1;
    end
   end
  end
 end
endmodule
