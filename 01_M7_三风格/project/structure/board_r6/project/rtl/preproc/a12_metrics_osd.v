`timescale 1ns/1ps
module a12_metrics_osd(
    input wire clk,rstn,i_de,i_hs,i_vs,input wire [23:0] i_rgb,
    input wire overlay_enable,
    input wire [415:0] metrics,
    input wire [31:0] display_id,display_status,display_timing,display_miss0,display_miss1,
    input wire [31:0] dma_count,dma_status,
    input wire [127:0] bdiag,
    input wire [127:0] gesture_diag,
    output reg o_de,o_hs,o_vs,output reg [23:0] o_rgb
);
    reg [11:0] x,y;
    reg de_d,vs_d;
    reg [415:0] view;
    reg [31:0] view_display_id,view_display_status,view_timing,view_miss0,view_miss1;
    reg [31:0] view_dma_count,view_dma_status;
    reg [127:0] view_bdiag,view_gesture;
    wire frame_start=vs_d && !i_vs;
    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin x<=0;y<=0;de_d<=0;vs_d<=0;view<=0;view_display_id<=0;view_display_status<=0;view_timing<=0;view_miss0<=0;view_miss1<=0;view_dma_count<=0;view_dma_status<=0;view_bdiag<=0;view_gesture<=0;end
        else begin
            de_d<=i_de;vs_d<=i_vs;
            if(frame_start) begin x<=0;y<=0;view<=metrics;view_display_id<=display_id;view_display_status<=display_status;view_timing<=display_timing;view_miss0<=display_miss0;view_miss1<=display_miss1;view_dma_count<=dma_count;view_dma_status<=dma_status;view_bdiag<=bdiag;view_gesture<=gesture_diag;end
            else begin
                if(!i_de) x<=0;else x<=x+1'b1;
                if(de_d && !i_de) y<=y+1'b1;
            end
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
    // A14: the box grew by one 16-pixel row (row 9, y=224..239) for the
    // first-underflow raster position.  Rows 0..8 keep their A12/A13 geometry.
    wire in_box=i_de && x>=1048 && x<1280 && y>=72 && y<552;
    wire in_text=i_de && x>=1060 && x<1252 && y>=80 && y<544;
    wire [4:0] row=(y-80)>>4;
    wire [3:0] col=(x-1060)>>4;
    wire [2:0] font_row=(y>>1)&7;
    wire [2:0] font_col=((x-1060)>>1)&7;
    reg [7:0] character,label0,label1;
    reg [31:0] value;
    reg [3:0] nibble;
    always @(*) begin
        label0=" ";label1=" ";value=0;
        case(row)
            1:begin label0="U";label1="F";value=view[31:0];end
            2:begin label0="R";label1="B";value=view[63:32];end
            3:begin label0="R";label1="L";value=view[95:64];end
            4:begin label0="B";label1="L";value=view[127:96];end
            5:begin label0="L";label1="L";value=view[159:128];end
            6:begin label0="P";label1="P";value=view[191:160];end
            7:begin label0="R";label1="F";value=view[223:192];end
            8:begin label0="S";label1="T";value=view[255:224];end
            // A14: first-underflow raster position, printed as VVVVHHHH.
            9:begin label0="U";label1="P";value=view[287:256];end
            10:begin label0="R";label1="C";value=view[319:288];end
            11:begin label0="R";label1="D";value=view[351:320];end
            12:begin label0="E";label1="C";value=view[383:352];end
            13:begin label0="W";label1="G";value=view[415:384];end
            14:begin label0="D";label1="U";value=view_display_status;end
            15:begin label0="D";label1="F";value=view_display_id;end
            16:begin label0="U";label1="S";value=view_miss0;end
            17:begin label0="U";label1="T";value=view_miss1;end
            18:begin label0="R";label1="T";value=view_timing;end
            19:begin label0="D";label1="A";value=view_dma_count;end
            20:begin label0="D";label1="E";value=view_dma_status;end
            21:begin label0="B";label1="C";value=view_bdiag[31:0];end
            22:begin label0="B";label1="E";value=view_bdiag[63:32];end
            23:begin label0="B";label1="H";value=view_bdiag[95:64];end
            24:begin label0="B";label1="T";value=view_bdiag[127:96];end
            25:begin label0="G";label1="C";value=view_gesture[31:0];end
            26:begin label0="G";label1="M";value=view_gesture[63:32];end
            27:begin label0="G";label1="S";value=view_gesture[95:64];end
            28:begin label0="G";label1="E";value=view_gesture[127:96];end
            default:begin end
        endcase
        character=" ";nibble=0;
        if(row==0) begin
            case(col) 0:character="A";1:character="B";2:character="1";3:character="0";4:character="S";5:character=" ";6:character=" ";default:character=" ";endcase
        end else if(col==0) character=label0;
        else if(col==1) character=label1;
        else if(col==2) character=":";
        else if(col>=4 && col<12) begin
            nibble=(value >> ((11-col)*4)) & 15;
            character=nibble<10 ? 8'd48+nibble : 8'd65+nibble-10;
        end
    end
    wire [55:0] bitmap=glyph(character);
    wire [7:0] glyph_row=font_row<7 ? (bitmap>>((6-font_row)*8)) : 8'd0;
    wire text_pixel=in_text && glyph_row[7-font_col];
    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin o_de<=0;o_hs<=0;o_vs<=0;o_rgb<=0;end
        else begin
            o_de<=i_de;o_hs<=i_hs;o_vs<=i_vs;
            o_rgb<=!overlay_enable ? i_rgb : text_pixel ? 24'hffffff : in_box ? 24'h000000 : i_rgb;
        end
    end
endmodule
