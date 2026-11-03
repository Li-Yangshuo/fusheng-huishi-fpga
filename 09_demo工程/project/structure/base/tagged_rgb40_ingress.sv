// A n_* same-core-clock RGB {0,R,G,B} -> low-byte R/G/B padded row words.
// One input pixel per cycle when the word sink is ready. A row whose 3*WIDTH
// bytes straddle the last word uses one explicit flush cycle. Full IDs checked.
module tagged_rgb40_ingress #(
 parameter WIDTH=1280,HEIGHT=720,XW=$clog2(WIDTH+1),YW=$clog2(HEIGHT+1)
)(
 input wire clk,rst,abort,
 input wire start_valid,output wire start_ready,input wire [95:0] start_descriptor,
 input wire in_valid,output wire in_ready,input wire [31:0] in_pixel,
 input wire [XW-1:0] in_x,input wire [YW-1:0] in_y,
 input wire [31:0] in_task,in_frame,in_model,input wire in_eol,in_last,
 output wire out_valid,input wire out_ready,output reg [39:0] out_data,output reg out_eol,
 output wire busy,error,output reg [3:0] error_code,output reg done
);
 reg active,word_valid,word_last,flush_pending,flush_last;
 reg [95:0] descriptor;reg [39:0] carry;reg [2:0] count;
 reg [XW-1:0] x;reg [YW-1:0] y;reg [31:0] pixels;
 wire room=!word_valid||out_ready;
 assign start_ready=!rst&&!active&&!word_valid&&!flush_pending&&!error;
 assign in_ready=!rst&&active&&!error&&!abort&&!flush_pending&&room&&pixels<WIDTH*HEIGHT;
 assign out_valid=!rst&&word_valid;assign busy=active;assign error=|error_code;
 wire row_end=x==WIDTH-1,frame_end=row_end&&y==HEIGHT-1;
 wire marks={in_task,in_frame,in_model}==descriptor&&in_x==x&&in_y==y&&in_eol==row_end&&in_last==frame_end;
 wire [23:0] bytes_rgb={in_pixel[7:0],in_pixel[15:8],in_pixel[23:16]};
 reg [63:0] merged;
 always @(*)begin
  case(count)
   0:merged={40'b0,bytes_rgb};
   1:merged={32'b0,bytes_rgb,carry[7:0]};
   2:merged={24'b0,bytes_rgb,carry[15:0]};
   3:merged={16'b0,bytes_rgb,carry[23:0]};
   default:merged={8'b0,bytes_rgb,carry[31:0]};
  endcase
 end
 wire [3:0] total={1'b0,count}+4'd3;
 always @(posedge clk)begin
  if(rst)begin
   active<=0;word_valid<=0;word_last<=0;flush_pending<=0;flush_last<=0;descriptor<=0;
   carry<=0;count<=0;x<=0;y<=0;pixels<=0;out_data<=0;out_eol<=0;error_code<=0;done<=0;
  end else begin
   done<=0;
   if(abort&&active)error_code[3]<=1;
   if(start_valid&&start_ready)begin active<=1;descriptor<=start_descriptor;pixels<=0;x<=0;y<=0;carry<=0;count<=0;end
   if(out_valid&&out_ready)begin word_valid<=0;if(word_last&&!error&&!abort)begin active<=0;done<=1;end end
   if(flush_pending&&room&&!error&&!abort)begin
    out_data<=carry;out_eol<=1;word_last<=flush_last;word_valid<=1;flush_pending<=0;carry<=0;count<=0;
   end
   if(in_valid&&in_ready)begin
    if(!marks)error_code[0]<=1;
    else if(in_pixel[31:24]!=0)error_code[1]<=1;
    else begin
     pixels<=pixels+1'b1;
     if(row_end)begin x<=0;if(!frame_end)y<=y+1'b1;end else x<=x+1'b1;
     if(total>=5)begin
      out_data<=merged[39:0];out_eol<=row_end&&total==5;word_last<=frame_end&&total==5;word_valid<=1;
      carry<={24'b0,merged[55:40]};count<=total-5;
      if(row_end&&total>5)begin flush_pending<=1;flush_last<=frame_end;end
     end else if(row_end)begin
      out_data<=merged[39:0];out_eol<=1;word_last<=frame_end;word_valid<=1;carry<=0;count<=0;
     end else begin carry<=merged[39:0];count<=total[2:0];end
    end
   end
  end
 end
 // synthesis translate_off
 initial if(WIDTH<1||HEIGHT<1)$fatal(1,"RGB ingress geometry");
 // synthesis translate_on
endmodule
