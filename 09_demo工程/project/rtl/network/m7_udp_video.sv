// Static unicast IPv4 UDP transmitter, gigabit RGMII PHY clock required.
// FPGV/2 = one CRC-checked 1280-byte RGB565 row per datagram.
// No ARP/DHCP/ICMP receiver: destination IP/MAC are deployment parameters.
module m7_udp_video #(
 parameter [47:0] DST_MAC=48'hc03532547f9b,SRC_MAC=48'h026000000560,
 parameter [31:0] DST_IP=32'hc0a80505,SRC_IP=32'hc0a8053c,
 parameter [15:0] PORT=16'd18500,
 parameter W=640,H=360
)(
 input wire pclk,prstn,tclk,trstn,
 input wire [31:0] control_sequence,input wire [1:0] selected_style,
 input wire [7:0] committed_style,
 input wire lvalid,rvalid,input wire [9:0] lx,rx,input wire [8:0] ly,ry,
 input wire [23:0] lrgb,rrgb,input wire [31:0] lfid,rfid,
 output reg [7:0] tx_data,output reg tx_en,
 output reg [31:0] packets_sent,output wire [31:0] left_drops,right_drops
);
 localparam BYTES=2*W,UDP_LEN=8+40+BYTES,IP_LEN=20+UDP_LEN;
 localparam PAYLOAD=90,LAST=PAYLOAD+BYTES-1,FCS=LAST+1,END_PACKET=FCS+3;
 localparam [31:0] IP_SUM=32'h4500+IP_LEN+32'h4000+32'h4011+SRC_IP[31:16]+SRC_IP[15:0]+DST_IP[31:16]+DST_IP[15:0];
 localparam [31:0] IP_FOLD=(IP_SUM>>16)+(IP_SUM&32'hffff);
 localparam [15:0] IP_CHECK=~((IP_FOLD>>16)+(IP_FOLD&32'hffff));
 localparam [31:0] STATUS_SUM=32'h4500+44+32'h4000+32'h4011+SRC_IP[31:16]+SRC_IP[15:0]+DST_IP[31:16]+DST_IP[15:0];
 localparam [31:0] STATUS_FOLD=(STATUS_SUM>>16)+(STATUS_SUM&32'hffff);
 localparam [15:0] STATUS_CHECK=~((STATUS_FOLD>>16)+(STATUS_FOLD&32'hffff));
 reg status_mode,status_pending,status_prepare;reg [23:0] status_timer;
 reg [3:0] prep;reg [31:0] status_seq,status_crc;reg [1:0] status_style;reg [7:0] status_committed;
 wire [10:0] frame_last=status_mode?11'd67:LAST;
 wire [10:0] frame_fcs=status_mode?11'd68:FCS;
 wire [10:0] frame_end=status_mode?11'd71:END_PACKET;
 function automatic [7:0] status_byte(input [3:0] idx);
 begin case(idx)
 0:status_byte="M";1:status_byte="7";2:status_byte="S";3:status_byte="T";
 4:status_byte=status_seq[31:24];5:status_byte=status_seq[23:16];6:status_byte=status_seq[15:8];7:status_byte=status_seq[7:0];
 8:status_byte={6'b0,status_style};9:status_byte=1;10:status_byte=status_committed;11:status_byte=0;
 12:status_byte=~status_crc[31:24];13:status_byte=~status_crc[23:16];14:status_byte=~status_crc[15:8];15:status_byte=~status_crc[7:0];
 default:status_byte=0;endcase end endfunction
 reg [1:0] lack,rack;wire [1:0] lrdy,rrdy;
 reg stream,bank;reg [10:0] pos;reg busy;reg [4:0] gap;
 reg [31:0] id,row_crc,ether_crc,session,ticks;reg [8:0] row;
 reg session_set,prefer_right;
 wire [15:0] ld,rd;wire [31:0] lid,rid,lc,rc;wire [8:0] lrow,rrow;
 wire [9:0] address=(pos>=PAYLOAD-1&&pos<LAST)?((pos+1-PAYLOAD)>>1):0;
 m7_net_line #(.W(W)) left_line(.pclk(pclk),.prstn(prstn),.valid(lvalid),.x(lx),.y(ly),.rgb(lrgb),.fid(lfid),
 .tclk(tclk),.trstn(trstn),.ack(lack),.ready(lrdy),.bank(bank),.address(address),.data(ld),.desc_fid(lid),.desc_crc(lc),.desc_y(lrow),.dropped_lines(left_drops));
 m7_net_line #(.W(W)) right_line(.pclk(pclk),.prstn(prstn),.valid(rvalid),.x(rx),.y(ry),.rgb(rrgb),.fid(rfid),
 .tclk(tclk),.trstn(trstn),.ack(rack),.ready(rrdy),.bank(bank),.address(address),.data(rd),.desc_fid(rid),.desc_crc(rc),.desc_y(rrow),.dropped_lines(right_drops));
 wire [1:0] lp=lrdy^lack,rp=rrdy^rack;
 wire choose_right=(|rp)&&((!(|lp))||prefer_right);
 wire chosen_bank=choose_right?(!rp[0]):(!lp[0]);
 reg [7:0] byte_out;reg [15:0] word_pixel;integer n,k;
 function automatic [31:0] crc8(input [31:0] c,input [7:0] d);
 reg [31:0] v;integer i;begin v=c^{24'b0,d};for(i=0;i<8;i=i+1)v=v[0]?(v>>1)^32'hedb88320:(v>>1);crc8=v;end endfunction
 // All fixed network fields are compile-time constants.
 always @* begin
 byte_out=0;word_pixel=stream?rd:ld;n=pos-8;k=pos-50;
 if(pos<7)byte_out=8'h55;else if(pos==7)byte_out=8'hd5;
 else if(pos<14)byte_out=DST_MAC>>(8*(13-pos));
 else if(pos<20)byte_out=SRC_MAC>>(8*(19-pos));
 else if(pos==20)byte_out=8'h08;else if(pos==21)byte_out=0;
 else if(pos<42)case(pos)
 22:byte_out=8'h45;24:byte_out=status_mode?0:IP_LEN>>8;25:byte_out=status_mode?44:IP_LEN;
 28:byte_out=8'h40;30:byte_out=8'h40;31:byte_out=8'h11;
 32:byte_out=status_mode?STATUS_CHECK>>8:IP_CHECK>>8;33:byte_out=status_mode?STATUS_CHECK:IP_CHECK;
 34:byte_out=SRC_IP>>24;35:byte_out=SRC_IP>>16;36:byte_out=SRC_IP>>8;37:byte_out=SRC_IP;
 38:byte_out=DST_IP>>24;39:byte_out=DST_IP>>16;40:byte_out=DST_IP>>8;41:byte_out=DST_IP;
 default:byte_out=0;endcase
 else if(pos<50)case(pos)
 42,44:byte_out=PORT>>8;43,45:byte_out=PORT;46:byte_out=status_mode?0:UDP_LEN>>8;47:byte_out=status_mode?24:UDP_LEN;
 default:byte_out=0;endcase
 else if(status_mode)begin
 if(pos<66)byte_out=status_byte(pos-50);else if(pos<68)byte_out=0;else byte_out=(~ether_crc)>>(8*(pos-68));
 end else if(pos<PAYLOAD)case(k)
 0:byte_out="F";1:byte_out="P";2:byte_out="G";3:byte_out="V";
 4:byte_out=2;5:byte_out=1;6:byte_out={7'b0,stream};7:byte_out=0;
 8:byte_out=session>>24;9:byte_out=session>>16;10:byte_out=session>>8;11:byte_out=session;
 12:byte_out=id>>24;13:byte_out=id>>16;14:byte_out=id>>8;15:byte_out=id;
 16:byte_out=W>>8;17:byte_out=W;18:byte_out=H>>8;19:byte_out=H;
 20:byte_out=row>>8;21:byte_out=row;22:byte_out=H>>8;23:byte_out=H;
 24:byte_out=BYTES>>8;25:byte_out=BYTES;
 28:byte_out=(BYTES*H)>>24;29:byte_out=(BYTES*H)>>16;30:byte_out=(BYTES*H)>>8;31:byte_out=BYTES*H;
 32:byte_out=row_crc>>24;33:byte_out=row_crc>>16;34:byte_out=row_crc>>8;35:byte_out=row_crc;
 default:byte_out=0;endcase
 else if(pos<=LAST)byte_out=pos[0]?word_pixel[15:8]:word_pixel[7:0];
 else byte_out=(~ether_crc)>>(8*(pos-FCS));
 end
 // SELECT -> settle descriptor -> preamble -> frame -> FCS -> >=12 byte IFG.
 reg select_pending;
 always @(posedge tclk or negedge trstn)
 if(!trstn)begin lack<=0;rack<=0;stream<=0;bank<=0;pos<=0;busy<=0;gap<=0;
 id<=0;row_crc<=0;row<=0;ether_crc<=32'hffffffff;tx_en<=0;tx_data<=0;
 status_mode<=0;status_pending<=0;status_prepare<=0;status_timer<=0;prep<=0;status_seq<=0;status_crc<=0;status_style<=0;status_committed<=255;
 session<=0;session_set<=0;ticks<=0;prefer_right<=0;select_pending<=0;packets_sent<=0;end
 else begin
 ticks<=ticks+1;tx_en<=0;tx_data<=0;
 if(status_timer==12499999)begin status_timer<=0;status_pending<=1;end else status_timer<=status_timer+1;
 if(busy)begin
 tx_en<=1;tx_data<=byte_out;
 if(pos>=8&&pos<=frame_last)ether_crc<=crc8(ether_crc,byte_out);
 if(pos==frame_end)begin
 busy<=0;gap<=12;packets_sent<=packets_sent+1;prefer_right<=~stream;
 if(!status_mode)begin if(stream)rack[bank]<=rrdy[bank];else lack[bank]<=lrdy[bank];end
 end else pos<=pos+1;
 end else if(status_prepare)begin
 status_crc<=crc8(status_crc,status_byte(prep));
 if(prep==11)begin status_prepare<=0;busy<=1;pos<=0;ether_crc<=32'hffffffff;end else prep<=prep+1;
 end else if(select_pending)begin
 id<=stream?rid:lid;row<=stream?rrow:lrow;row_crc<=stream?rc:lc;
 select_pending<=0;busy<=1;pos<=0;ether_crc<=32'hffffffff;
 end else if(gap!=0)gap<=gap-1;
 else if(status_pending)begin
 status_pending<=0;status_mode<=1;status_seq<=control_sequence;status_style<=selected_style;
 status_committed<=committed_style;status_crc<=32'hffffffff;prep<=0;status_prepare<=1;
 end else if((|lp)||(|rp))begin
 status_mode<=0;
 stream<=choose_right;bank<=chosen_bank;select_pending<=1;
 if(!session_set)begin session<=ticks^32'h4d370200;session_set<=1;end
 end
 end
endmodule
