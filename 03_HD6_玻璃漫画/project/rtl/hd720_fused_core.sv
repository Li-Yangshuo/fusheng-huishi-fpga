// TinyGlass: exact RGB pool2, signed/clamped geometry gather, 4/8/8/3 INT8.
// A 16-row ring retains the complete +/-7 low-resolution vertical footprint.
// No feature maps in DDR. 32 shared DSPs; 15 fps design budget at 720p.
module hd720_fused_core #(parameter W=1280,H=720,
 parameter WEIGHTS="hd_weights.mem",BIASES="hd_bias.mem",GEOMETRY="hd_geometry.mem")(
 input wire clk,rst,start,ink_mode,
 input wire pixel_valid,output wire pixel_ready,input wire [23:0] pixel_rgb,
 input wire [10:0] pixel_x,input wire [9:0] pixel_y,
 output wire result_valid,input wire result_ready,output wire [127:0] result_data,
 output wire result_sof,result_eol,result_eof,output wire busy,output reg done,output reg [31:0] cycles
);
 localparam LW=W/2,LH=H/2;
 localparam IDLE=0,POOL=1,WREAD=2,WLOAD=3,CINIT=4,CBIAS=5,CPIPE=6,CQUANT=7,OREAD=8,OSEND=9,GWAIT=10;
 reg [3:0] state;reg [8:0] pool_row,cy;reg [9:0] cx;
 reg input_finished;reg [1:0] layer;reg [3:0] chunk;
 reg [8:0] obx;reg subrow;
 (* syn_ramstyle="block_ram" *) reg [47:0] vsums[0:LW-1];reg [47:0] vsumq;
 (* syn_ramstyle="block_ram" *) reg [23:0] ring[0:16*LW-1];reg [23:0] gatherq;
 (* syn_ramstyle="block_ram" *) reg [23:0] geometry[0:4095];reg [23:0] gq;
 (* syn_ramstyle="block_ram" *) reg [23:0] outrow0[0:LW/2-1],outrow1[0:LW/2-1];reg [23:0] outq0,outq1;
 (* syn_ramstyle="block_ram" *) reg [255:0] weights[0:20],biases[0:2];reg [255:0] wq,bq;
 initial begin $readmemh(WEIGHTS,weights);$readmemh(BIASES,biases);$readmemh(GEOMETRY,geometry);end
 reg [7:0] h0[0:7],h1[0:7];reg [31:0] gathered;
 reg [15:0] hr,hg,hb;reg signed [31:0] acc[0:7];
 reg [31:0] activations;reg signed [16:0] prod[0:31];
 reg fetch_valid,prod_valid,fetch_last,prod_last;
 wire [3:0] chunks=layer==0?1:2;
 wire [3:0] fetch_chunk=state==CBIAS?4'd0:chunk;
 wire [5:0] wa=layer*7+fetch_chunk;
 wire take=pixel_valid&&pixel_ready;
 wire group_first=!pixel_x[0],group_last=pixel_x[0];
 wire row_first=!pixel_y[0],row_last=pixel_y[0];
 wire [9:0] pool_col=pixel_x>>1;
 wire [15:0] tr=(group_first?16'd0:hr)+{8'd0,pixel_rgb[23:16]};
 wire [15:0] tg=(group_first?16'd0:hg)+{8'd0,pixel_rgb[15:8]};
 wire [15:0] tb=(group_first?16'd0:hb)+{8'd0,pixel_rgb[7:0]};
 wire [15:0] vr=(row_first?16'd0:vsumq[47:32])+tr;
 wire [15:0] vg=(row_first?16'd0:vsumq[31:16])+tg;
 wire [15:0] vb=(row_first?16'd0:vsumq[15:0])+tb;
 wire [15:0] rr=vr+16'd2,rg=vg+16'd2,rb=vb+16'd2;
 wire [23:0] pooled={rr[9:2],rg[9:2],rb[9:2]};
 wire signed [11:0] raw_sx=$signed({2'b00,cx})+$signed(gq[23:16]);
 wire signed [11:0] raw_sy=$signed({3'b000,cy})+$signed(gq[15:8]);
 wire [9:0] sx=raw_sx<0?0:raw_sx>=LW?LW-1:raw_sx[9:0];
 wire [8:0] sy=raw_sy<0?0:raw_sy>=LH?LH-1:raw_sy[8:0];
 wire [13:0] gather_address=sy[3:0]*LW+sx;
 wire [13:0] pool_address=pool_row[3:0]*LW+pool_col;
 function automatic [7:0] quant(input signed [31:0] a,input [1:0] l);
 reg signed [31:0] q;begin
 q=l==2?(a+32'sd64)>>>7:(a+32'sd16)>>>5;
 quant=q<0?0:q>255?255:q[7:0];end endfunction
 wire [31:0] selected_activations;
 genvar t0;generate for(t0=0;t0<4;t0=t0+1)begin:acts
 assign selected_activations[t0*8+:8]=layer==0?gathered[t0*8+:8]:layer==1?h0[fetch_chunk*4+t0]:h1[fetch_chunk*4+t0];
 end endgenerate
 wire [23:0] quant_rgb={quant(acc[0],2),quant(acc[1],2),quant(acc[2],2)};
 wire [8:0] next_obx=obx==W/4-1?0:obx+1'b1;
 // One synchronous read address per memory allows BRAM inference.
 wire [8:0] out_read_address=(state==OREAD)?9'd0:next_obx;
 wire signed [18:0] dot4[0:7];
 genvar lane;generate for(lane=0;lane<8;lane=lane+1)begin:sum4
 wire signed [17:0] a=$signed(prod[lane*4])+$signed(prod[lane*4+1]);
 wire signed [17:0] b=$signed(prod[lane*4+2])+$signed(prod[lane*4+3]);
 assign dot4[lane]=$signed(a)+$signed(b);
 end endgenerate
 integer o,t;
 always @(posedge clk)begin
 if(take&&group_first)vsumq<=vsums[pool_col];
 if(take&&group_last)begin vsums[pool_col]<={vr,vg,vb};if(row_last)ring[pool_address]<=pooled;end
 if(state==WREAD)gq<=geometry[{cy[5:0],cx[5:0]}];
 if(state==WLOAD)gatherq<=ring[gather_address];
 if(state==GWAIT)gathered<={gq[7:0],gatherq[7:0],gatherq[15:8],gatherq[23:16]};
 if(state==CINIT)bq<=biases[0];else if(state==CBIAS&&layer!=2)bq<=biases[layer+1'b1];
 if(state==CBIAS||(state==CPIPE&&chunk<chunks))begin wq<=weights[wa];activations<=selected_activations;end
 if(fetch_valid)for(o=0;o<8;o=o+1)for(t=0;t<4;t=t+1)
 prod[o*4+t]<=$signed({1'b0,activations[t*8+:8]})*$signed(wq[(o*4+t)*8+:8]);
 if(state==CQUANT&&layer==2)begin if(cx[0])outrow1[cx>>1]<=quant_rgb;else outrow0[cx>>1]<=quant_rgb;end
 if(state==OREAD||(state==OSEND&&result_ready))begin outq0<=outrow0[out_read_address];outq1<=outrow1[out_read_address];end
 end
 assign pixel_ready=state==POOL;
 assign result_valid=state==OSEND;
 assign result_data={outq1,8'd0,outq1,8'd0,outq0,8'd0,outq0,8'd0};
 assign result_sof=cy==0&&subrow==0&&obx==0;
 assign result_eol=obx==W/4-1;
 assign result_eof=cy==LH-1&&subrow&&result_eol;
 assign busy=state!=IDLE;
 always @(posedge clk)begin
 if(rst)begin
 state<=IDLE;pool_row<=0;input_finished<=0;cx<=0;cy<=0;layer<=0;chunk<=0;obx<=0;subrow<=0;hr<=0;hg<=0;hb<=0;
 fetch_valid<=0;prod_valid<=0;fetch_last<=0;prod_last<=0;done<=0;cycles<=0;
 for(o=0;o<8;o=o+1)begin acc[o]<=0;h0[o]<=0;h1[o]<=0;end
 end else begin
 done<=0;if(busy)cycles<=cycles+1;
 fetch_valid<=0;prod_valid<=fetch_valid;prod_last<=fetch_last;
 if(prod_valid)begin
 for(o=0;o<8;o=o+1)acc[o]<=acc[o]+$signed({{13{dot4[o][18]}},dot4[o]});
 if(prod_last)state<=CQUANT;
 end
 case(state)
 IDLE:if(start)begin pool_row<=0;input_finished<=0;cx<=0;cy<=0;hr<=0;hg<=0;hb<=0;cycles<=0;state<=POOL;end
 POOL:if(take)begin
 hr<=tr;hg<=tg;hb<=tb;
 if(group_last&&row_last&&pixel_x==W-1)begin
 pool_row<=pool_row+1'b1;
 if(pool_row>=7)begin cx<=0;layer<=0;state<=WREAD;end
 if(pixel_y==H-1)input_finished<=1;
 end end
 WREAD:state<=WLOAD;
 WLOAD:state<=GWAIT;
 GWAIT:state<=CINIT;
 CINIT:state<=CBIAS;
 CBIAS:begin for(o=0;o<8;o=o+1)acc[o]<=$signed(bq[o*32+:32]);chunk<=1;fetch_valid<=1;fetch_last<=chunks==1;state<=CPIPE;end
 CPIPE:if(chunk<chunks)begin fetch_valid<=1;fetch_last<=chunk==chunks-1;chunk<=chunk+1'b1;end
 CQUANT:begin
 if(layer==0)for(o=0;o<8;o=o+1)h0[o]<=quant(acc[o],layer);
 if(layer==1)for(o=0;o<8;o=o+1)h1[o]<=quant(acc[o],layer);
 if(layer!=2)begin layer<=layer+1'b1;state<=CBIAS;end
 else if(cx==LW-1)begin obx<=0;subrow<=0;state<=OREAD;end
 else begin cx<=cx+1'b1;layer<=0;state<=WREAD;end
 end
 OREAD:state<=OSEND;
 OSEND:if(result_ready)begin
 obx<=next_obx;
 if(result_eol)begin
 if(subrow)begin
 subrow<=0;
 if(cy==LH-1)begin done<=1;state<=IDLE;end
 else begin cy<=cy+1'b1;if(input_finished)begin cx<=0;layer<=0;state<=WREAD;end else state<=POOL;end
 end else subrow<=1;
 end end
 default:state<=IDLE;
 endcase
 end end
 // synthesis translate_off
 initial if(W<16||H<16||W>1280||H>720||W%4||H%2)$fatal(1,"TinyGlass geometry");
 always @(posedge clk)if(state==WLOAD)begin
 if(sy+16<pool_row||sy>=pool_row)$fatal(1,"ring lifetime sy%0d produced%0d",sy,pool_row);
 end
 // synthesis translate_on
endmodule
