`timescale 1ns/1ps
module ab10_status_osd(input wire clk,rstn,i_de,i_hs,i_vs,overlay_enable,
 input wire [23:0] i_rgb,input wire [63:0] status,
 output reg o_de,o_hs,o_vs,output reg [23:0] o_rgb);
reg [11:0] x,y;reg de_d,vs_d;reg [63:0] view;
always @(posedge clk or negedge rstn)begin
 if(!rstn)begin x<=0;y<=0;de_d<=0;vs_d<=0;view<=0;end
 else begin
  de_d<=i_de;vs_d<=i_vs;
  if(vs_d&&!i_vs)begin x<=0;y<=0;view<=status;end
  else begin if(!i_de)x<=0;else x<=x+1'b1;if(de_d&&!i_de)y<=y+1'b1;end
 end
end
    function [55:0] glyph;
        input [7:0] c;
        begin case(c)
            "0":glyph=56'h3c66666e76663c; "1":glyph=56'h1838181818183c;
            "2":glyph=56'h3c66060c18307e; "3":glyph=56'h3c66061c06663c;
            "4":glyph=56'h0c1c3c6c7e0c0c; "5":glyph=56'h7e607c0606663c;
            "6":glyph=56'h1c30607c66663c; "7":glyph=56'h7e66060c181818;
            "8":glyph=56'h3c66663c66663c; "9":glyph=56'h3c66663e060c38;
            "A":glyph=56'h183c66667e6666; "B":glyph=56'h7c66667c66667c;
            "C":glyph=56'h3c66606060663c; "D":glyph=56'h786c6666666c78;
            "E":glyph=56'h7e60607c60607e; "F":glyph=56'h7e60607c606060;
            "M":glyph=56'h63777f6b636363;
            "H":glyph=56'h6666667e666666;
            "L":glyph=56'h6060606060607e; "P":glyph=56'h7c66667c606060;
            "R":glyph=56'h7c66667c6c6666; "S":glyph=56'h3c66603c06663c;
            "G":glyph=56'h3c66606e66663c; "W":glyph=56'h6666666e7e7666;
            "T":glyph=56'h7e181818181818; "U":glyph=56'h6666666666663c;
            ":":glyph=56'h00181800181800;
            ".":glyph=56'h00000000001818;
            default:glyph=0;
        endcase end
    endfunction
wire inside_line=overlay_enable&&i_de&&x>=1060&&x<1492&&y>=80&&y<96;
wire [5:0] col=(x-1060)>>4;
reg [7:0] character;reg [3:0] nibble;
always @(*)begin
 character=" ";nibble=0;
 case(col)
  0:character="A";1:character="B";2:character="0";3:character="5";4:character="P";
  6:character="F";7:character=":";17:character="E";18:character=":";
  default:begin
   if(col>=8&&col<=15)begin nibble=view[4*(15-col)+:4];character=nibble<10?8'd48+nibble:8'd55+nibble;end
   if(col>=19&&col<=26)begin nibble=view[32+4*(26-col)+:4];character=nibble<10?8'd48+nibble:8'd55+nibble;end
  end
 endcase
end
wire [55:0] bits_font=glyph(character);
wire dot=bits_font[55-8*((y>>1)&7)-(((x-1060)>>1)&7)];
always @(posedge clk or negedge rstn)begin
 if(!rstn)begin o_de<=0;o_hs<=1;o_vs<=1;o_rgb<=0;end
 else begin o_de<=i_de;o_hs<=i_hs;o_vs<=i_vs;
 o_rgb<=inside_line?(dot?(|view[63:32]?24'hff4040:24'hffffff):24'h101820):i_rgb;end
end
endmodule
