// One immutable compact ROM, CRC boot and typed per-layer configuration lease.
module board_model_loader #(
 parameter WORDS=1124,AW=$clog2(WORDS),INIT_FILE="board_assets.mem",
 parameter [31:0] EXPECTED_CRC=32'h44405515,MODEL0=32'hc2b00001,MODEL1=32'hc2b10001,
 parameter [255:0] BASES=256'h0000015400000138000000fe000000b0000000620000002e0000001500000000,
 parameter [127:0] COUNTS=128'h03070008000e00120012000e00080005
)(
 input wire clk,rst,abort,output reg catalog_ready,output wire error,output wire [7:0] error_code,output wire lease_active,
 input wire req_valid,output wire req_ready,input wire [2:0] req_layer,input wire [127:0] req_descriptor,input wire [63:0] req_session,
 output wire cfg_valid,input wire cfg_ready,output wire [1:0] cfg_target,output wire cfg_stage,
 output wire [1:0] cfg_kind,output wire [9:0] cfg_index,output wire [255:0] cfg_data,output wire [31:0] cfg_model,
 output wire loaded_valid,input wire loaded_ready,output wire [2:0] loaded_layer,
 output wire [127:0] loaded_descriptor,output wire [63:0] loaded_session,
 input wire retire_valid,output wire retire_ready,input wire [2:0] retire_layer,
 input wire [127:0] retire_descriptor,input wire [63:0] retire_session,input wire retire_ok
);
 localparam BREQ=0,BWAIT=1,BBYTES=2,BDONE=3,BFAIL=4;
 localparam IDLE=0,HREQ=1,HWAIT=2,HEADER=3,DREQ=4,DWAIT=5,DATA=6,EMIT=7,ACK=8,RETIRED=9,FAIL=10;
 reg [2:0] boot;reg [AW-1:0] boot_addr;reg [2:0] byte_index;reg [39:0] boot_word;reg [31:0] crc;reg boot_error;
 reg [3:0] state;reg lease;reg [7:0] fault;reg [2:0] layer;reg [127:0] descriptor;reg [63:0] session;
 reg [AW:0] pc,limit;reg [9:0] records;reg [2:0] words_left,word_index;
 reg [1:0] target,kind;reg stage;reg [9:0] index;reg [8:0] bits_needed;reg [279:0] payload;
 function [31:0] crc_byte(input [31:0] c,input [7:0] b);
 reg [31:0] x;integer j;begin x=c^b;for(j=0;j<8;j=j+1)x=x[0]?(x>>1)^32'hedb88320:x>>1;crc_byte=x;end endfunction
 function [AW:0] base(input [2:0] l);begin base=BASES>>(l*32);end endfunction
 function [9:0] count(input [2:0] l);begin count=COUNTS>>(l*16);end endfunction
 function layout_ok;
 integer j;reg [31:0] a,b;begin
  layout_ok=WORDS>0&&BASES[31:0]==0;
  for(j=0;j<8;j=j+1)begin a=BASES>>(j*32);b=j==7?WORDS:BASES>>((j+1)*32);if(a>=b||b>WORDS||((COUNTS>>(j*16))&16'hffff)==0)layout_ok=0;end
 end endfunction
 wire reading=!error&&!abort&&(state==HREQ||state==DREQ)&&pc<limit;
 wire ren=boot==BREQ||reading;wire [AW-1:0] ra=boot==BREQ?boot_addr:pc[AW-1:0];wire [39:0] rd;
 model_asset_rom #(.WORDS(WORDS),.AW(AW),.INIT_FILE(INIT_FILE)) rom(clk,ren,ra,rd);
 wire [31:0] next_crc=crc_byte(crc,boot_word[byte_index*8+:8]);
 assign error=boot_error||(|fault);assign error_code=boot_error?8'h01:fault;assign lease_active=lease;
 always @(posedge clk)begin
  if(rst)begin boot<=BREQ;boot_addr<=0;byte_index<=0;boot_word<=0;crc<=32'hffffffff;boot_error<=0;catalog_ready<=0;end
  else case(boot)
   BREQ:boot<=BWAIT;
   BWAIT:begin boot_word<=rd;byte_index<=0;boot<=BBYTES;end
   BBYTES:begin
    crc<=next_crc;
    if(byte_index==4)begin
     if(boot_addr==WORDS-1)begin
      if((~next_crc)==EXPECTED_CRC&&MODEL0!=MODEL1&&layout_ok())begin catalog_ready<=1;boot<=BDONE;end
      else begin boot_error<=1;boot<=BFAIL;end
     end else begin boot_addr<=boot_addr+1'b1;boot<=BREQ;end
    end else byte_index<=byte_index+1'b1;
   end
   default:begin end
  endcase
 end
 wire model_ok=req_descriptor[63:32]==MODEL0||req_descriptor[63:32]==MODEL1;
 assign req_ready=!rst&&catalog_ready&&!lease&&!error&&!abort&&state==IDLE&&model_ok;
 assign cfg_valid=!rst&&state==EMIT;assign cfg_target=target;assign cfg_stage=stage;assign cfg_kind=kind;
 assign cfg_index=index;assign cfg_data=payload[255:0];assign cfg_model=descriptor[63:32];
 assign loaded_valid=!rst&&state==ACK;assign loaded_layer=layer;assign loaded_descriptor=descriptor;assign loaded_session=session;
 assign retire_ready=!rst&&state==RETIRED&&lease&&!error&&!abort;
 wire [1:0] ht=rd[32:31],hk=rd[29:28];wire hs=rd[30];wire [9:0] hi=rd[27:18];wire [2:0] hn=rd[17:15];
 reg type_ok;reg [8:0] expected_bits;reg [3:0] ci,co;
 always @(*)begin
  case(layer)1:begin ci=2;co=4;end 2:begin ci=4;co=8;end 3,4:begin ci=8;co=8;end 5:begin ci=8;co=4;end default:begin ci=4;co=2;end endcase
  type_ok=0;expected_bits=0;
  if(layer==0)begin
   if(ht==0&&!hs)case(hk)
    3:type_ok=hi==0;
    0:begin type_ok=hi<2;expected_bits=216;end
    1:begin type_ok=hi<2;expected_bits=56;end
    default:begin end
   endcase
  end else if(layer==7)begin
   if(ht==2&&!hs)case(hk)
    3:type_ok=hi==0;
    0:begin type_ok=hi<3;expected_bits=16;end
    1:begin type_ok=hi<3;expected_bits=56;end
    2:begin type_ok=hi<768;expected_bits=8;end
   endcase
  end else if(ht==1)begin
   if(hk==3)type_ok=hi==0;
   else if(!hs&&hk==0)begin type_ok=hi<(ci>>1);expected_bits=256;end
   else if(hs&&hk==0)begin type_ok=hi<(ci>>1);expected_bits=co<<4;end
   else if(hs&&hk==1)begin type_ok=hi<co;expected_bits=56;end
  end
 end
 wire [3:0] expected_words=expected_bits<=8?0:(expected_bits+39)/40;
 wire header_bad=rd[39:36]!=4'ha||rd[35:33]!=layer||rd[14:8]!=0||!type_ok||hn!=expected_words||
                  (hn!=0&&rd[7:0]!=0)||(expected_bits==0&&rd[7:0]!=0);
 wire [8:0] tail_bits=bits_needed-word_index*40;
 wire tail_bad=words_left==1&&tail_bits<40&&(rd>>tail_bits)!=0;
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;lease<=0;fault<=0;layer<=0;descriptor<=0;session<=0;pc<=0;limit<=0;records<=0;
   words_left<=0;word_index<=0;target<=0;kind<=0;stage<=0;index<=0;bits_needed<=0;payload<=0;
  end else begin
   if(abort&&lease)fault[1]<=1;
   if(req_valid&&!lease&&!model_ok)fault[2]<=1;
   if(error||abort)begin
    // Preserve any already offered config/prepared token until acknowledged.
    if((state==EMIT&&!cfg_ready)||(state==ACK&&!loaded_ready))state<=state;
    else state<=FAIL;
   end else case(state)
    IDLE:if(req_valid&&req_ready)begin
     lease<=1;layer<=req_layer;descriptor<=req_descriptor;session<=req_session;
     pc<=base(req_layer);limit<=req_layer==7?WORDS:base(req_layer+1'b1);records<=0;state<=HREQ;
    end
    HREQ,DREQ:begin
     if(pc>=limit||pc>=WORDS)begin fault[3]<=1;state<=FAIL;end
     else begin pc<=pc+1'b1;state<=state==HREQ?HWAIT:DWAIT;end
    end
    HWAIT:state<=HEADER;
    HEADER:begin
     if(header_bad)begin fault[4]<=1;state<=FAIL;end
     else begin target<=ht;stage<=hs;kind<=hk;index<=hi;bits_needed<=expected_bits;
      payload<={272'd0,rd[7:0]};words_left<=hn;word_index<=0;state<=hn==0?EMIT:DREQ;
     end
    end
    DWAIT:state<=DATA;
    DATA:begin
     if(tail_bad)begin fault[5]<=1;state<=FAIL;end
     else begin payload[word_index*40+:40]<=rd;word_index<=word_index+1'b1;words_left<=words_left-1'b1;state<=words_left==1?EMIT:DREQ;end
    end
    EMIT:if(cfg_ready)begin
     if(records==count(layer)-1)begin
      if(pc!=limit)begin fault[6]<=1;state<=FAIL;end else state<=ACK;
     end else begin records<=records+1'b1;state<=HREQ;end
    end
    ACK:if(loaded_ready)state<=RETIRED;
    RETIRED:if(retire_valid&&retire_ready)begin
     if(!retire_ok||retire_layer!=layer||retire_descriptor!=descriptor||retire_session!=session)begin fault[7]<=1;state<=FAIL;end
     else begin lease<=0;state<=IDLE;end
    end
    default:begin end
   endcase
  end
 end
endmodule
