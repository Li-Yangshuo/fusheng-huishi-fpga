// Validate and retain EVERY native 1280x720 RGB pixel, no spatial decimation.
module ab720_capture_guard(input wire clk,rstn,in_valid,in_sof,in_eol,
 input wire [23:0] in_rgb,input wire [31:0] in_frame_id,
 output reg out_valid,out_sof,out_eol,out_eof,output reg [23:0] out_rgb,
 output reg [31:0] out_frame_id,output reg fault,output reg [3:0] error_code);
 reg active;reg [10:0] x;reg [9:0] y;reg [31:0] id;
 wire [3:0] err=!active?(in_sof?(in_eol?4'd4:4'd0):4'd1):in_sof?4'd2:in_frame_id!=id?4'd3:in_eol!=(x==1279)?4'd4:4'd0;
 always @(posedge clk or negedge rstn)
 if(!rstn)begin active<=0;x<=0;y<=0;id<=0;out_valid<=0;out_sof<=0;out_eol<=0;out_eof<=0;out_rgb<=0;out_frame_id<=0;fault<=0;error_code<=0;end
 else begin out_valid<=0;out_sof<=0;out_eol<=0;out_eof<=0;
 if(in_valid&&!fault)begin
 if(err!=0)begin fault<=1;error_code<=err;active<=0;end
 else begin out_valid<=1;out_sof<=in_sof;out_eol<=in_eol;out_rgb<=in_rgb;out_frame_id<=in_frame_id;
 if(!active)begin active<=1;id<=in_frame_id;x<=1;y<=0;end
 else if(x==1279)begin x<=0;if(y==719)begin out_eof<=1;active<=0;y<=0;end else y<=y+1'b1;end else x<=x+1'b1;
 end end end
endmodule
