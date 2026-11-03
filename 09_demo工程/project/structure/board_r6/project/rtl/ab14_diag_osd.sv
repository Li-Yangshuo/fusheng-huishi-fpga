// A27 board diagnostics. This block needs only the pixel clock and reset.
// Caller contract: i_x/i_y and RGB/sync describe the same input pixel; status
// buses and i_test_pattern are already transferred coherently to this domain.
// All diagnostics are frozen on i_frame_start. No DDR/CPU progress is needed.
// The TEST pattern verifies display only; it is never a camera/NN result.
module ab14_diag_osd #(
 parameter integer ACTIVE_W=1920
)(
 input wire clk,rstn,
 input wire i_frame_start,
 input wire [11:0] i_x,i_y,
 input wire i_de,i_hs,i_vs,
 input wire [23:0] i_rgb,
 input wire i_test_pattern,
 input wire [7:0] i_cam_fps,i_nn_fps,
 input wire [31:0] i_status,i_cam_frames,i_capture_commits,i_nn_commits,i_heartbeat,i_errors,i_resets,i_cpu_info,i_trap_value,
 output reg o_de,o_hs,o_vs,
 output reg [23:0] o_rgb
);
 reg [31:0] status_q,cam_q,capture_q,nn_q,heartbeat_q,errors_q,resets_q,cpu_q,trap_q;
 reg test_q;reg [7:0] camera_fps_q,nn_fps_q;
 always @(posedge clk or negedge rstn) begin
  if(!rstn)begin status_q<=0;cam_q<=0;capture_q<=0;nn_q<=0;heartbeat_q<=0;errors_q<=0;resets_q<=0;cpu_q<=0;trap_q<=0;test_q<=0;camera_fps_q<=0;nn_fps_q<=0;end
  else if(i_frame_start)begin
   camera_fps_q<=i_cam_fps>99?8'd99:i_cam_fps;nn_fps_q<=i_nn_fps>99?8'd99:i_nn_fps;
   status_q<=i_status;cam_q<=i_cam_frames;capture_q<=i_capture_commits;
   nn_q<=i_nn_commits;heartbeat_q<=i_heartbeat;errors_q<=i_errors;resets_q<=i_resets;cpu_q<=i_cpu_info;trap_q<=i_trap_value;test_q<=i_test_pattern;
  end
 end

 function automatic [23:0] bar_colour(input [2:0] bar_index);
  begin
   case(bar_index)
    0:bar_colour=24'hffffff;1:bar_colour=24'hffff00;
    2:bar_colour=24'h00ffff;3:bar_colour=24'h00ff00;
    4:bar_colour=24'hff00ff;5:bar_colour=24'hff0000;
    6:bar_colour=24'h0000ff;default:bar_colour=24'h000000;
   endcase
  end
 endfunction
 function automatic [3:0] dec_tens(input [7:0] v);
  begin dec_tens=v>=90?9:v>=80?8:v>=70?7:v>=60?6:v>=50?5:v>=40?4:v>=30?3:v>=20?2:v>=10?1:0;end
 endfunction
 function automatic [7:0] hex_char(input [3:0] nibble);
  begin hex_char=(nibble<10)?(8'd48+nibble):(8'd65+nibble-10);end
 endfunction
 // Seven rows of five pixels, most significant row at the top.
 function automatic [34:0] font(input [7:0] ch);
  begin
   case(ch)
    "0":font={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
    "1":font={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
    "2":font={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
    "3":font={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
    "4":font={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
    "5":font={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
    "6":font={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
    "7":font={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
    "8":font={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
    "9":font={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
    "A":font={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
    "B":font={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
    "C":font={5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
    "D":font={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
    "E":font={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
    "F":font={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
    "F":font={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
    "M":font={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
    "X":font={5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
    "H":font={5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
    "I":font={5'b01110,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
    "L":font={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
    "N":font={5'b10001,5'b11001,5'b11001,5'b10101,5'b10011,5'b10011,5'b10001};
    "P":font={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
    "S":font={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
    "T":font={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
    "V":font={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
    ":":font={5'b00000,5'b00100,5'b00100,5'b00000,5'b00100,5'b00100,5'b00000};
    default:font=35'd0;
   endcase
  end
 endfunction

 wire in_box=i_de&&(i_x>=8)&&(i_x<248)&&(i_y>=8)&&(i_y<232);
 wire in_text=i_de&&(i_x>=16)&&(i_x<240)&&(i_y>=16)&&(i_y<208);
 wire [11:0] tx=i_x-12'd16,ty=i_y-12'd16;
 wire [3:0] col=tx[7:4],row=ty[7:4];
 wire [2:0] font_x=tx[3:1],font_y=ty[3:1];
 reg [7:0] ch;
 reg [31:0] row_data;
 reg [23:0] ink;
 reg [34:0] glyph;
 reg [2:0] full_bar;
 reg [23:0] mixed_rgb;
 always @* begin
  row_data=0;ink=24'hffffff;
  case(row)
   3:begin row_data=status_q;ink=24'hffff00;end
   4:begin row_data=cam_q;ink=24'h00ffff;end
   5:begin row_data=capture_q;ink=24'h00ff00;end
   6:begin row_data=nn_q;ink=24'hff00ff;end
   7:begin row_data=heartbeat_q;ink=24'hffffff;end
   8:begin row_data=errors_q;ink=24'hff8000;end
   9:begin row_data=resets_q;ink=24'h80c0ff;end
   10:begin row_data=cpu_q;ink=24'hffff80;end
   11:begin row_data=trap_q;ink=24'hc080ff;end
   default:begin row_data=0;ink=test_q?24'hff8000:24'hffffff;end
  endcase
  ch=" ";
  if(row==0)begin
   case(col)
    0:ch="T";1:ch="I";2:ch="1";
    4:ch=test_q?"T":"L";5:ch=test_q?"E":"I";
    6:ch=test_q?"S":"V";7:ch=test_q?"T":"E";
    default:ch=" ";
   endcase
  end else if(row==1)begin
   case(col)0:ch="6";1:ch="4";2:ch="0";3:ch="X";4:ch="4";5:ch="8";6:ch="0";default:ch=" ";endcase
  end else if(row==2)begin
   case(col)
    0:ch="F";1:ch="P";2:ch="S";3:ch=":";
    4:ch=8'd48+dec_tens(nn_fps_q);5:ch=8'd48+(nn_fps_q-dec_tens(nn_fps_q)*10);
    7:ch="C";8:ch="A";9:ch="M";10:ch=":";
    11:ch=8'd48+dec_tens(camera_fps_q);12:ch=8'd48+(camera_fps_q-dec_tens(camera_fps_q)*10);
    default:ch=" ";
   endcase
   ink=24'hffffff;
  end else if(row<=11)begin
   if(col==0)case(row)3:ch="S";4:ch="C";5:ch="P";6:ch="N";7:ch="H";8:ch="E";9:ch="D";10:ch="T";default:ch="V";endcase
   else if(col==1)ch=":";
   else if(col>=2&&col<10)ch=hex_char((row_data >> ((9-col)*4)) & 4'hf);
  end
  glyph=font(ch);
  if(i_x<ACTIVE_W/8)full_bar=0;
  else if(i_x<ACTIVE_W*2/8)full_bar=1;
  else if(i_x<ACTIVE_W*3/8)full_bar=2;
  else if(i_x<ACTIVE_W*4/8)full_bar=3;
  else if(i_x<ACTIVE_W*5/8)full_bar=4;
  else if(i_x<ACTIVE_W*6/8)full_bar=5;
  else if(i_x<ACTIVE_W*7/8)full_bar=6;
  else full_bar=7;
  mixed_rgb=i_rgb;
  if(i_de&&test_q)mixed_rgb=bar_colour(full_bar);
  if(in_box)mixed_rgb=0;
  if(in_text&&font_x<5&&font_y<7)
   if(glyph[34-(font_y*5)-font_x])mixed_rgb=ink;
  // Always-visible eight-colour reference, independent of the source video.
  if(i_de&&i_x>=16&&i_x<144&&i_y>=216&&i_y<224)mixed_rgb=bar_colour(tx[6:4]);
  if(i_de&&i_x>=160&&i_x<176&&i_y>=216&&i_y<224)mixed_rgb=test_q?24'hff8000:24'h00ff00;
 end
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin o_de<=0;o_hs<=0;o_vs<=0;o_rgb<=0;end
  else begin o_de<=i_de;o_hs<=i_hs;o_vs<=i_vs;o_rgb<=mixed_rgb;end
 end
 // synthesis translate_off
 initial if(ACTIVE_W<248||ACTIVE_W>4096||ACTIVE_W%8)$fatal(1,"diagnostic ACTIVE_W");
 // synthesis translate_on
endmodule
