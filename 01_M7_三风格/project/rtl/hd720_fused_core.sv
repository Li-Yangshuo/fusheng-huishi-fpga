// Native RGB -> exact model pooling -> 3x3/1x1/1x1, row-fused INT8 CNN.
// Three pooled rows, one output row, two local hidden vectors. No feature DDR.
// 16 outputs x 4 terms/clock, operand/product/accumulator pipeline.
module hd720_fused_core #(parameter W=1280,H=720,
 parameter WEIGHTS="hd_weights.mem",BIASES="hd_bias.mem")(
 input wire clk,rst,start,ink_mode,neon_mode,
 input wire pixel_valid,output wire pixel_ready,input wire [23:0] pixel_rgb,
 input wire [10:0] pixel_x,input wire [9:0] pixel_y,
 output wire result_valid,input wire result_ready,output wire [127:0] result_data,
 output wire result_sof,result_eol,result_eof,output wire busy,output reg done,output reg [31:0] cycles
);
 localparam MAX_LW=W/4;
 localparam IDLE=0,POOL=1,WREAD=2,WLOAD=3,CINIT=4,CBIAS=5,CPIPE=6,CQUANT=7,OREAD=8,OSEND=9;
 reg [3:0] state;reg ink,neon;
 wire [8:0] lw=ink?W/4:W/8;wire [7:0] lh=ink?H/4:H/8;
 wire [2:0] shift=ink?2:3;wire [3:0] period=ink?4:8;
 reg [8:0] pool_row;reg [1:0] pool_bank,mid_bank;
 reg input_finished;reg [8:0] cx,read_col;reg [7:0] cy;
 reg [1:0] window_phase,layer;reg [3:0] chunk;
 reg [8:0] obx;reg [2:0] subrow;
 (* syn_ramstyle="block_ram" *) reg [47:0] vsums[0:MAX_LW-1];reg [47:0] vsumq;
 (* syn_ramstyle="block_ram" *) reg [23:0] row0[0:MAX_LW-1];
 (* syn_ramstyle="block_ram" *) reg [23:0] row1[0:MAX_LW-1];
 (* syn_ramstyle="block_ram" *) reg [23:0] row2[0:MAX_LW-1];
 reg [23:0] rq0,rq1,rq2;
 (* syn_ramstyle="block_ram" *) reg [23:0] outrow[0:MAX_LW-1];reg [23:0] outq;
 (* syn_ramstyle="block_ram" *) reg [511:0] weights[0:62];
 (* syn_ramstyle="block_ram" *) reg [511:0] biases[0:8];reg [511:0] wq,bq;
 initial begin $readmemh(WEIGHTS,weights);$readmemh(BIASES,biases);end
 reg [23:0] win[0:8];reg [7:0] h0[0:15],h1[0:15];
 reg [15:0] hr,hg,hb;reg signed [31:0] acc[0:15];
 reg [31:0] activations;reg signed [16:0] prod[0:63];
 reg fetch_valid,prod_valid,fetch_last,prod_last;
 wire [5:0] terms=layer==0?(ink?9:27):(ink?8:16);
 wire [3:0] chunks=(terms+3)>>2;
 wire [5:0] wa=(neon?42:ink?21:0)+layer*7+chunk;
 wire [3:0] ba=(neon?6:ink?3:0)+layer;
 wire take=pixel_valid&&pixel_ready;
 wire group_first=ink?pixel_x[1:0]==0:pixel_x[2:0]==0;
 wire group_last=ink?pixel_x[1:0]==3:pixel_x[2:0]==7;
 wire row_first=ink?pixel_y[1:0]==0:pixel_y[2:0]==0;
 wire row_last=ink?pixel_y[1:0]==3:pixel_y[2:0]==7;
 wire [8:0] pool_col=pixel_x>>shift;
 wire [15:0] r16={8'd0,pixel_rgb[23:16]},g16={8'd0,pixel_rgb[15:8]},b16={8'd0,pixel_rgb[7:0]};
 wire [15:0] luma=(r16<<6)+(r16<<3)+(r16<<2)+r16+(g16<<7)+(g16<<4)+(g16<<2)+(g16<<1)+(b16<<4)+(b16<<3)+(b16<<2)+b16+16'd128;
 wire [7:0] ir=ink?luma[15:8]:pixel_rgb[23:16],ig=ink?luma[15:8]:pixel_rgb[15:8],ib=ink?luma[15:8]:pixel_rgb[7:0];
 wire [15:0] tr=(group_first?16'd0:hr)+{8'd0,ir},tg=(group_first?16'd0:hg)+{8'd0,ig},tb=(group_first?16'd0:hb)+{8'd0,ib};
 wire [15:0] vr=(row_first?16'd0:vsumq[47:32])+tr,vg=(row_first?16'd0:vsumq[31:16])+tg,vb=(row_first?16'd0:vsumq[15:0])+tb;
 wire [15:0] rr=vr+(ink?16'd8:16'd32),rg=vg+(ink?16'd8:16'd32),rb=vb+(ink?16'd8:16'd32);
 wire [23:0] pooled=ink?{rr[11:4],rg[11:4],rb[11:4]}:{rr[13:6],rg[13:6],rb[13:6]};
 wire [23:0] top_read=cy==0?0:(mid_bank==0?rq2:mid_bank==1?rq0:rq1);
 wire [23:0] mid_read=mid_bank==0?rq0:mid_bank==1?rq1:rq2;
 wire [23:0] bottom_read=cy==lh-1?0:(mid_bank==0?rq1:mid_bank==1?rq2:rq0);
 function automatic [7:0] quant(input signed [31:0] a,input [1:0] l,input im,input nm);
 reg signed [31:0] q;
 begin
 if(nm)begin
 if(l==0)q=(a+32'sd16)>>>5;else if(l==1)q=(a+32'sd8)>>>4;else q=(a+32'sd64)>>>7;
 end else if(l==2)q=(a+32'sd128)>>>8;
 else if(!im)q=(a+32'sd8)>>>4;
 else if(l==0)q=(a+32'sd16)>>>5;
 else q=(a+32'sd2)>>>2;
 quant=q<0?0:q>255?255:q[7:0];
 end endfunction
 wire [31:0] selected_activations;
 reg [7:0] act0;
 always @*begin
 act0=0;
 case(layer)
 0:if(ink)begin case(chunk)
 0:act0=win[0][23:16];
 1:act0=win[4][23:16];
 2:act0=win[8][23:16];
 endcase end else begin case(chunk)
 0:act0=win[0][23:16];
 1:act0=win[4][23:16];
 2:act0=win[8][23:16];
 3:act0=win[3][15:8];
 4:act0=win[7][15:8];
 5:act0=win[2][7:0];
 6:act0=win[6][7:0];
 endcase end
 1:case(chunk)
 0:act0=(ink&&0>=8)?0:h0[0];
 1:act0=(ink&&4>=8)?0:h0[4];
 2:act0=(ink&&8>=8)?0:h0[8];
 3:act0=(ink&&12>=8)?0:h0[12];
 endcase
 2:case(chunk)
 0:act0=(ink&&0>=8)?0:h1[0];
 1:act0=(ink&&4>=8)?0:h1[4];
 2:act0=(ink&&8>=8)?0:h1[8];
 3:act0=(ink&&12>=8)?0:h1[12];
 endcase
 endcase
 end
 assign selected_activations[0+:8]=act0;
 reg [7:0] act1;
 always @*begin
 act1=0;
 case(layer)
 0:if(ink)begin case(chunk)
 0:act1=win[1][23:16];
 1:act1=win[5][23:16];
 endcase end else begin case(chunk)
 0:act1=win[1][23:16];
 1:act1=win[5][23:16];
 2:act1=win[0][15:8];
 3:act1=win[4][15:8];
 4:act1=win[8][15:8];
 5:act1=win[3][7:0];
 6:act1=win[7][7:0];
 endcase end
 1:case(chunk)
 0:act1=(ink&&1>=8)?0:h0[1];
 1:act1=(ink&&5>=8)?0:h0[5];
 2:act1=(ink&&9>=8)?0:h0[9];
 3:act1=(ink&&13>=8)?0:h0[13];
 endcase
 2:case(chunk)
 0:act1=(ink&&1>=8)?0:h1[1];
 1:act1=(ink&&5>=8)?0:h1[5];
 2:act1=(ink&&9>=8)?0:h1[9];
 3:act1=(ink&&13>=8)?0:h1[13];
 endcase
 endcase
 end
 assign selected_activations[8+:8]=act1;
 reg [7:0] act2;
 always @*begin
 act2=0;
 case(layer)
 0:if(ink)begin case(chunk)
 0:act2=win[2][23:16];
 1:act2=win[6][23:16];
 endcase end else begin case(chunk)
 0:act2=win[2][23:16];
 1:act2=win[6][23:16];
 2:act2=win[1][15:8];
 3:act2=win[5][15:8];
 4:act2=win[0][7:0];
 5:act2=win[4][7:0];
 6:act2=win[8][7:0];
 endcase end
 1:case(chunk)
 0:act2=(ink&&2>=8)?0:h0[2];
 1:act2=(ink&&6>=8)?0:h0[6];
 2:act2=(ink&&10>=8)?0:h0[10];
 3:act2=(ink&&14>=8)?0:h0[14];
 endcase
 2:case(chunk)
 0:act2=(ink&&2>=8)?0:h1[2];
 1:act2=(ink&&6>=8)?0:h1[6];
 2:act2=(ink&&10>=8)?0:h1[10];
 3:act2=(ink&&14>=8)?0:h1[14];
 endcase
 endcase
 end
 assign selected_activations[16+:8]=act2;
 reg [7:0] act3;
 always @*begin
 act3=0;
 case(layer)
 0:if(ink)begin case(chunk)
 0:act3=win[3][23:16];
 1:act3=win[7][23:16];
 endcase end else begin case(chunk)
 0:act3=win[3][23:16];
 1:act3=win[7][23:16];
 2:act3=win[2][15:8];
 3:act3=win[6][15:8];
 4:act3=win[1][7:0];
 5:act3=win[5][7:0];
 endcase end
 1:case(chunk)
 0:act3=(ink&&3>=8)?0:h0[3];
 1:act3=(ink&&7>=8)?0:h0[7];
 2:act3=(ink&&11>=8)?0:h0[11];
 3:act3=(ink&&15>=8)?0:h0[15];
 endcase
 2:case(chunk)
 0:act3=(ink&&3>=8)?0:h1[3];
 1:act3=(ink&&7>=8)?0:h1[7];
 2:act3=(ink&&11>=8)?0:h1[11];
 3:act3=(ink&&15>=8)?0:h1[15];
 endcase
 endcase
 end
 assign selected_activations[24+:8]=act3;
 wire [23:0] quant_rgb=(ink&&!neon)?{3{quant(acc[0],2,ink,neon)}}:{quant(acc[0],2,ink,neon),quant(acc[1],2,ink,neon),quant(acc[2],2,ink,neon)};
 wire [8:0] next_obx=obx==W/4-1?0:obx+1'b1;
 wire [8:0] next_out_col=ink?next_obx:next_obx>>1;
 wire signed [18:0] dot4[0:15];
 genvar lane;generate for(lane=0;lane<16;lane=lane+1)begin:sum4
 wire signed [17:0] a=$signed(prod[lane*4])+$signed(prod[lane*4+1]);
 wire signed [17:0] b=$signed(prod[lane*4+2])+$signed(prod[lane*4+3]);
 assign dot4[lane]=$signed(a)+$signed(b);
 end endgenerate
 integer o,t;
 // RAMs have no reset. Every live row is produced before use; padding is explicit.
 always @(posedge clk)begin
 if(take&&group_first)vsumq<=vsums[pool_col];
 if(take&&group_last)begin
 vsums[pool_col]<={vr,vg,vb};
 if(row_last)case(pool_bank)0:row0[pool_col]<=pooled;1:row1[pool_col]<=pooled;2:row2[pool_col]<=pooled;endcase
 end
 if(state==WREAD)begin
 rq0<=read_col<lw?row0[read_col]:24'd0;rq1<=read_col<lw?row1[read_col]:24'd0;rq2<=read_col<lw?row2[read_col]:24'd0;
 end
 if(state==CINIT)bq<=biases[ba];
 if(state==CPIPE&&chunk<chunks)begin
 wq<=weights[wa];activations<=selected_activations;
 end
 if(fetch_valid)for(o=0;o<16;o=o+1)for(t=0;t<4;t=t+1)prod[o*4+t]<=$signed({1'b0,activations[t*8+:8]})*$signed(wq[(o*4+t)*8+:8]);
 if(state==CQUANT&&layer==2)outrow[cx]<=quant_rgb;
 if(state==OREAD)outq<=outrow[0];
 else if(state==OSEND&&result_ready)outq<=outrow[next_out_col];
 end
 assign pixel_ready=state==POOL;
 assign result_valid=state==OSEND;
 assign result_data={4{outq,8'd0}};
 assign result_sof=cy==0&&subrow==0&&obx==0;
 assign result_eol=obx==W/4-1;
 assign result_eof=cy==lh-1&&subrow==period-1&&result_eol;
 assign busy=state!=IDLE;
 always @(posedge clk)begin
 if(rst)begin
 state<=IDLE;ink<=0;neon<=0;pool_row<=0;pool_bank<=0;mid_bank<=0;input_finished<=0;cx<=0;cy<=0;read_col<=0;window_phase<=0;layer<=0;chunk<=0;obx<=0;subrow<=0;hr<=0;hg<=0;hb<=0;
 fetch_valid<=0;prod_valid<=0;fetch_last<=0;prod_last<=0;done<=0;cycles<=0;
 for(o=0;o<16;o=o+1)begin acc[o]<=0;h0[o]<=0;h1[o]<=0;end
 end else begin
 done<=0;if(busy)cycles<=cycles+1;
 fetch_valid<=0;prod_valid<=fetch_valid;prod_last<=fetch_last;
 if(prod_valid)begin
 for(o=0;o<16;o=o+1)acc[o]<=acc[o]+$signed({{13{dot4[o][18]}},dot4[o]});
 if(prod_last)state<=CQUANT;
 end
 case(state)
 IDLE:if(start)begin ink<=ink_mode;neon<=neon_mode;pool_row<=0;pool_bank<=0;mid_bank<=0;input_finished<=0;cx<=0;cy<=0;hr<=0;hg<=0;hb<=0;cycles<=0;state<=POOL;end
 POOL:if(take)begin
 hr<=tr;hg<=tg;hb<=tb;
 if(group_last&&row_last&&pixel_x==W-1)begin
 pool_row<=pool_row+1'b1;pool_bank<=pool_bank==2?0:pool_bank+1'b1;
 if(pool_row>=1)begin cx<=0;read_col<=0;window_phase<=0;layer<=0;state<=WREAD;end
 if(pixel_y==H-1)input_finished<=1;
 end end
 WREAD:state<=WLOAD;
 WLOAD:begin
 if(window_phase==0)begin
 win[0]<=0;win[3]<=0;win[6]<=0;win[1]<=top_read;win[4]<=mid_read;win[7]<=bottom_read;
 window_phase<=1;read_col<=1;state<=WREAD;
 end else begin
 if(window_phase==2)begin win[0]<=win[1];win[1]<=win[2];win[3]<=win[4];win[4]<=win[5];win[6]<=win[7];win[7]<=win[8];end
 win[2]<=top_read;win[5]<=mid_read;win[8]<=bottom_read;window_phase<=2;layer<=0;state<=CINIT;
 end end
 CINIT:state<=CBIAS;
 CBIAS:begin for(o=0;o<16;o=o+1)acc[o]<=$signed(bq[o*32+:32]);chunk<=0;state<=CPIPE;end
 CPIPE:if(chunk<chunks)begin fetch_valid<=1;fetch_last<=chunk==chunks-1;chunk<=chunk+1'b1;end
 CQUANT:begin
 if(layer==0)for(o=0;o<16;o=o+1)h0[o]<=quant(acc[o],layer,ink,neon);
 if(layer==1)for(o=0;o<16;o=o+1)h1[o]<=quant(acc[o],layer,ink,neon);
 if(layer!=2)begin layer<=layer+1'b1;state<=CINIT;end
 else if(cx==lw-1)begin obx<=0;subrow<=0;state<=OREAD;end
 else begin cx<=cx+1'b1;read_col<=cx+2;state<=WREAD;end
 end
 OREAD:state<=OSEND;
 OSEND:if(result_ready)begin
 obx<=next_obx;
 if(result_eol)begin
 if(subrow==period-1)begin
 subrow<=0;
 if(cy==lh-1)begin done<=1;state<=IDLE;end
 else begin cy<=cy+1'b1;mid_bank<=mid_bank==2?0:mid_bank+1'b1;
 if(input_finished)begin cx<=0;read_col<=0;window_phase<=0;layer<=0;state<=WREAD;end else state<=POOL;
 end end else subrow<=subrow+1'b1;
 end end
 default:state<=IDLE;
 endcase
 end end
 // synthesis translate_off
 initial if(W<16||H<16||W>1280||H>720||W%8||H%8)$fatal(1,"fused native geometry");
 // synthesis translate_on
endmodule
