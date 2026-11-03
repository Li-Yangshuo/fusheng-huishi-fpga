// Fixed-format IPv4/UDP style control. Broadcast delivery avoids a static ARP entry.
// Validate MAC/IP/port/length, IPv4 checksum, optional UDP checksum, payload CRC,
// full Ethernet FCS and RX error before publishing a command. No packet RAM.
module m7_control_rx #(
 parameter [47:0] PC_MAC=48'hc03532547f9b,BOARD_MAC=48'h026000000560,
 parameter [31:0] PC_IP=32'hc0a80505,BOARD_IP=32'hc0a8053c,
 parameter [15:0] CONTROL_PORT=18501
)(input wire clk,rstn,dv,err,input wire [7:0] data,
 output reg [31:0] sequence_id,output reg [1:0] style,
 output reg [31:0] accepted,rejected);
 reg packet,bad,prev_dv,have_seq;reg [10:0] pos;
 reg [31:0] eth_crc,payload_crc,received_crc,seq;
 reg [1:0] requested;reg [7:0] previous;
 reg [19:0] ipsum,udpsum;reg [15:0] udpcheck;
 reg [31:0] destip;
 localparam [31:0] BROADCAST_IP={BOARD_IP[31:8],8'hff};
 function automatic [31:0] crc8(input [31:0] c,input [7:0] d);
 reg [31:0] v;integer i;begin v=c^{24'b0,d};for(i=0;i<8;i=i+1)v=v[0]?(v>>1)^32'hedb88320:(v>>1);crc8=v;end endfunction
 function automatic checksum_ok(input [19:0] s);
 reg [20:0] a;begin a={5'b0,s[15:0]}+s[19:16];a={5'b0,a[15:0]}+a[20:16];checksum_ok=a[15:0]==16'hffff;end endfunction
 wire [31:0] delta=seq-sequence_id;
 wire [19:0] udp_total=udpsum+PC_IP[31:16]+PC_IP[15:0]+destip[31:16]+destip[15:0]+20'd41;
 always @(posedge clk or negedge rstn)
 if(!rstn)begin packet<=0;bad<=0;prev_dv<=0;have_seq<=0;pos<=0;eth_crc<=32'hffffffff;
 payload_crc<=32'hffffffff;received_crc<=0;seq<=0;requested<=0;previous<=0;ipsum<=0;udpsum<=0;udpcheck<=0;destip<=0;
 sequence_id<=0;style<=0;accepted<=0;rejected<=0;end
 else begin
 prev_dv<=dv;
 if(!dv)begin
 if(prev_dv&&packet)begin
 if(!bad&&pos==64&&eth_crc==32'hdebb20e3&&checksum_ok(ipsum)&&
 (udpcheck==0||checksum_ok(udp_total))&&received_crc==~payload_crc&&seq!=0&&
 (!have_seq||(delta!=0&&!delta[31])))begin
 sequence_id<=seq;style<=requested;accepted<=accepted+1;have_seq<=1;
 end else rejected<=rejected+1;
 end
 packet<=0;pos<=0;bad<=0;
 end else if(!packet)begin
 if(data==8'hd5)begin packet<=1;pos<=0;eth_crc<=32'hffffffff;payload_crc<=32'hffffffff;
 bad<=err;ipsum<=0;udpsum<=0;udpcheck<=0;seq<=0;received_crc<=0;destip<=0;end
 end else begin
 if(pos<2047)pos<=pos+1;else bad<=1;
 eth_crc<=crc8(eth_crc,data);previous<=data;if(err)bad<=1;
 // Destination broadcast is intentional; unicast BOARD_MAC is also accepted by mask below.
 if(pos<6&&data!=8'hff)bad<=1;
 if(pos>=6&&pos<12&&data!=(PC_MAC>>(8*(11-pos))&8'hff))bad<=1;
 case(pos)
 12:if(data!=8'h08)bad<=1;13:if(data!=0)bad<=1;
 14:if(data!=8'h45)bad<=1;
 16:if(data!=0)bad<=1;17:if(data!=44)bad<=1;
 20:if((data&8'hbf)!=0)bad<=1;21:if(data!=0)bad<=1;
 23:if(data!=17)bad<=1;
 26:if(data!=PC_IP[31:24])bad<=1;27:if(data!=PC_IP[23:16])bad<=1;
 28:if(data!=PC_IP[15:8])bad<=1;29:if(data!=PC_IP[7:0])bad<=1;
 30,31,32,33:begin destip<={destip[23:0],data};if(data!=(BROADCAST_IP>>(8*(33-pos))&8'hff))bad<=1;end
 36:if(data!=CONTROL_PORT[15:8])bad<=1;37:if(data!=CONTROL_PORT[7:0])bad<=1;
 38:if(data!=0)bad<=1;39:if(data!=24)bad<=1;
 40:udpcheck[15:8]<=data;41:udpcheck[7:0]<=data;
 42:if(data!="M")bad<=1;43:if(data!="7")bad<=1;44:if(data!="C")bad<=1;45:if(data!="T")bad<=1;
 46,47,48,49:seq<={seq[23:0],data};
 50:begin requested<=data[1:0];if(data>2)bad<=1;end
 51:if(data!=1)bad<=1;52,53:if(data!=0)bad<=1;
 54,55,56,57:received_crc<={received_crc[23:0],data};
 default:begin end
 endcase
 if(pos>=14&&pos<34&&pos[0])ipsum<=ipsum+{previous,data};
 if(pos>=34&&pos<58&&pos[0])udpsum<=udpsum+{previous,data};
 if(pos>=42&&pos<54)payload_crc<=crc8(payload_crc,data);
 end
 end
endmodule
