module demo_osd #(parameter CPU_TEXT=0)(
 input wire clk,rstn,frame_start,input wire [11:0] x,y,input wire de,hs,vs,input wire [23:0] rgb,
 input wire enable,input wire [127:0] cpu_text,input wire [9:0] fps,output reg [23:0] o_rgb,output reg o_de,o_hs,o_vs);
 reg [9:0] value;reg [127:0] text_q;
 always @(posedge clk or negedge rstn)if(!rstn)begin value<=0;text_q<=0;end
 else if(frame_start)begin value<=fps>999?999:fps;text_q<=cpu_text;end
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
    ".":font={5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b00100,5'b00100};
    default:font=35'd0;
   endcase
  end
 endfunction

 wire box=enable&&de&&x>=8&&x<152&&y>=8&&y<56;
 wire text_area=enable&&de&&x>=16&&x<144&&y>=16&&y<48;
 wire [11:0] tx=x-16,ty=y-16;
 reg [7:0] ch;reg [34:0] glyph;reg [23:0] mixed;
 always @*begin
 ch=32;
 if(ty<16)case(tx>>4)0:ch="1";1:ch="2";2:ch="8";3:ch="0";4:ch="X";5:ch="7";6:ch="2";7:ch="0";endcase
 else case(tx>>4)0:ch="F";1:ch="P";2:ch="S";3:ch=":";4:ch=48+value/100;5:ch=48+(value/10)%10;6:ch=".";7:ch=48+value%10;endcase
 if(CPU_TEXT)ch=text_q[8*((ty<16?0:8)+(tx>>4))+:8];
 glyph=font(ch);mixed=box?24'd0:rgb;
 if(text_area&&tx[3:1]<5&&ty[3:1]<7)if(glyph[34-(ty[3:1]*5)-tx[3:1]])mixed=24'hffffff;
 end
 always @(posedge clk or negedge rstn)if(!rstn)begin o_rgb<=0;o_de<=0;o_hs<=0;o_vs<=0;end
 else begin o_rgb<=de?mixed:24'd0;o_de<=de;o_hs<=hs;o_vs<=vs;end
endmodule
