// A1 full-field 3:2 nearest downsample. No crop, line RAM or source backpressure.
// Input two pixels/clock: low 24 bits is the left pixel. BGR_INPUT=1 accepts
// legacy {B,G,R} bytes. Output is always {R,G,B}, low pixel first.
// Metadata is SAME-BEAT: SOF accompanies first pair, EOL last pair of every row.
// Mapping sx=floor((3*ox+1)/2), sy=floor((3*oy+1)/2). It is NOT antialiased.
// A malformed frame is fail-stop until reset. Already emitted partial pixels
// must be discarded by the complete-frame writer if fault becomes asserted.
module rgb1080_to720_pair #(
 parameter integer IN_WIDTH=1920, IN_HEIGHT=1080, BGR_INPUT=1
)(
 input wire clk, rstn,
 input wire in_valid, in_sof, in_eol,
 input wire [47:0] in_data,
 input wire [31:0] in_frame_id,
 output reg out_valid, out_sof, out_eol,
 output reg [47:0] out_data,
 output reg [31:0] out_frame_id,
 output reg [15:0] out_x, out_y,
 output reg frame_done,
 output reg fault,
 output reg [3:0] error_code
);
 localparam integer PAIRS=IN_WIDTH/2;
 reg active;
 reg [15:0] ix, iy, ox, oy;
 reg [1:0] hp, vp;
 reg [23:0] saved_pixel;
 reg [31:0] frame_id;
 wire [15:0] cx=in_sof ? 16'd0 : ix;
 wire [15:0] cy=in_sof ? 16'd0 : iy;
 wire [1:0] ch=in_sof ? 2'd0 : hp;
 wire [1:0] cv=in_sof ? 2'd0 : vp;
 wire keep_line=(cv!=1);
 function [23:0] rgb;
  input [23:0] p;
  begin rgb=BGR_INPUT ? {p[7:0],p[15:8],p[23:16]} : p; end
 endfunction
 // synopsys translate_off
 initial if(IN_WIDTH<6 || IN_WIDTH%6!=0 || IN_HEIGHT<3 || IN_HEIGHT%3!=0 ||
            IN_WIDTH>65535 || IN_HEIGHT>65535)
  $fatal(1,"capture dimensions must be multiples of 6 x 3");
 // synopsys translate_on
 always @(posedge clk or negedge rstn) begin
  if(!rstn) begin
   active<=0;ix<=0;iy<=0;ox<=0;oy<=0;hp<=0;vp<=0;saved_pixel<=0;frame_id<=0;
   out_valid<=0;out_sof<=0;out_eol<=0;out_data<=0;out_frame_id<=0;
   out_x<=0;out_y<=0;frame_done<=0;fault<=0;error_code<=0;
  end else begin
   out_valid<=0;out_sof<=0;out_eol<=0;frame_done<=0;
   if(!fault) begin
    if(!in_valid && (in_sof || in_eol)) begin fault<=1;error_code<=1; end
    else if(in_valid) begin
     if(in_sof && active) begin fault<=1;error_code<=2; end
     else if(!active && !in_sof) begin fault<=1;error_code<=3; end
     else if(in_eol && cx!=PAIRS-1) begin fault<=1;error_code<=4; end
     else if(!in_eol && cx==PAIRS-1) begin fault<=1;error_code<=5; end
     else begin
      if(in_sof) begin active<=1;frame_id<=in_frame_id;ox<=0;oy<=0; end
      if(keep_line) begin
       case(ch)
        0: saved_pixel<=rgb(in_data[23:0]);
        1: begin
         out_valid<=1;out_data<={rgb(in_data[23:0]),saved_pixel};
         saved_pixel<=rgb(in_data[47:24]);
         out_sof<=(cy==0 && cx==1);
         out_x<=ox;out_y<=oy;out_frame_id<=frame_id;
         ox<=ox+2;
        end
        2: begin
         out_valid<=1;out_data<={rgb(in_data[47:24]),saved_pixel};
         out_eol<=in_eol;out_x<=ox;out_y<=oy;out_frame_id<=frame_id;
         ox<=ox+2;
         if(in_eol && cy==IN_HEIGHT-1) frame_done<=1;
        end
        default: begin fault<=1;error_code<=6; end
       endcase
      end
      if(in_eol) begin
       ix<=0;hp<=0;ox<=0;
       if(keep_line) oy<=oy+1;
       if(cy==IN_HEIGHT-1) begin active<=0;iy<=0;vp<=0; end
       else begin iy<=cy+1;vp<=(cv==2 ? 0 : cv+1); end
      end else begin ix<=cx+1;hp<=(ch==2 ? 0 : ch+1); end
     end
    end
   end
  end
 end
endmodule
