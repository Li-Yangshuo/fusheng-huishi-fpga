// TinyComic fused native RGB -> 4x4 RGB+edge pooling -> 3x3 -> depthwise
// 3x3 -> 1x1 -> 1x1 INT8 network -> palette/ink postprocess.
// Pooled RGB and first hidden activations are row-streamed in BRAM; no full
// intermediate activation frame is stored. Eight signed terms per output in each
// synchronous 512-bit word feed 64 shared MAC lanes.
module tinycomic_fused_core #(parameter integer W=1280,H=720,
 parameter WEIGHTS="hd_weights.mem",BIASES="hd_bias.mem")(
 input wire clk,rst,start,
 input wire pixel_valid,output wire pixel_ready,input wire [23:0] pixel_rgb,
 input wire [10:0] pixel_x,input wire [9:0] pixel_y,
 output wire result_valid,input wire result_ready,output wire [127:0] result_data,
 output wire result_sof,result_eol,result_eof,output wire busy,output reg done,
 output reg [31:0] cycles
);
 localparam integer LW=W/4,LH=H/4;
 localparam [4:0] IDLE=0,POOL=1,C0_READ=2,C0_CAPTURE=3,
  BIAS_READ=4,BIAS_LOAD=5,WEIGHT_READ=6,MAC=7,QUANT=8,
  H0_READ=9,H0_CAPTURE=10,OSEND=11,OREAD=12;
 reg [4:0] state;
 reg [1:0] phase,layer;
 reg [3:0] chunk;
 reg [7:0] low_y,c0_y,c1_y;
 reg [8:0] c0_x,c1_x;
 reg [1:0] subrow;
 reg [8:0] out_x;
 reg input_finished;
 reg [10:0] sx_r,sy_r,sz_r;
 (* syn_ramstyle="block_ram" *) reg [47:0] vsums[0:LW-1];reg [47:0] vsumq;
 wire [12:0] xsum_r={2'b0,sx_r}+pixel_rgb[23:16];
 wire [12:0] xsum_g={2'b0,sy_r}+pixel_rgb[15:8];
 wire [12:0] xsum_b={2'b0,sz_r}+pixel_rgb[7:0];
 wire [15:0] ysum_r=(pixel_y[1:0]==0?16'd0:vsumq[47:32])+xsum_r;
 wire [15:0] ysum_g=(pixel_y[1:0]==0?16'd0:vsumq[31:16])+xsum_g;
 wire [15:0] ysum_b=(pixel_y[1:0]==0?16'd0:vsumq[15:0])+xsum_b;
 wire [15:0] rounded_r=ysum_r+16'd8,rounded_g=ysum_g+16'd8,rounded_b=ysum_b+16'd8;
 wire [23:0] pooled_rgb={rounded_r[11:4],rounded_g[11:4],rounded_b[11:4]};

 (* syn_ramstyle="block_ram" *) reg [23:0] pool0[0:LW-1];
 (* syn_ramstyle="block_ram" *) reg [23:0] pool1[0:LW-1];
 (* syn_ramstyle="block_ram" *) reg [23:0] pool2[0:LW-1];
 (* syn_ramstyle="block_ram" *) reg [23:0] pool3[0:LW-1];
 (* syn_ramstyle="block_ram" *) reg [71:0] hidden0_0[0:LW-1];
 (* syn_ramstyle="block_ram" *) reg [71:0] hidden0_1[0:LW-1];
 (* syn_ramstyle="block_ram" *) reg [71:0] hidden0_2[0:LW-1];
 (* syn_ramstyle="block_ram" *) reg [23:0] outrow[0:LW-1];reg [23:0] outq;
 (* syn_ramstyle="block_ram" *) reg [511:0] weights[0:8];
 (* syn_ramstyle="block_ram" *) reg [511:0] biases[0:3];
 reg [23:0] rgbq0,rgbq1,rgbq2,rgbq3;
 reg [71:0] hq0,hq1,hq2;
 reg [383:0] rgb_patch;
 reg [127:0] lum_patch;
 reg [575:0] hpatch;
 reg [511:0] biasq,weightq,activationq;
 reg [31:0] acc[0:7];
 reg [63:0] mid_activation,high_activation;
 reg [7:0] output_edge;
 reg [23:0] output_rgb;
 reg [23:0] edge_patch;
 wire [4:0] weight_base=layer==0?0:layer==1?5:layer==2?7:8;
 wire [3:0] layer_chunks=layer==0?5:layer==1?2:1;
 wire [8:0] rgb_read_x=clamp_x($signed({1'b0,c0_x})-1+phase);
 wire [7:0] rgb_read_y0=clamp_y($signed({1'b0,c0_y})-1);
 wire [7:0] rgb_read_y1=clamp_y($signed({1'b0,c0_y}));
 wire [7:0] rgb_read_y2=clamp_y($signed({1'b0,c0_y})+1);
 wire [7:0] rgb_read_y3=clamp_y($signed({1'b0,c0_y})+2);
 wire [8:0] h_read_x=clamp_x($signed({1'b0,c1_x})-1+phase);
 wire [7:0] h_read_y0=clamp_y3($signed({1'b0,c1_y})-1);
 wire [7:0] h_read_y1=clamp_y3($signed({1'b0,c1_y}));
 wire [7:0] h_read_y2=clamp_y3($signed({1'b0,c1_y})+1);
 function automatic [8:0] clamp_x(input integer value);
  begin if(value<0)clamp_x=0;else if(value>=LW)clamp_x=LW-1;else clamp_x=value[8:0];end
 endfunction
 function automatic [7:0] clamp_y(input integer value);
  begin if(value<0)clamp_y=0;else if(value>=LH)clamp_y=LH-1;else clamp_y=value[7:0];end
 endfunction
 function automatic [7:0] clamp_y3(input integer value);
  begin if(value<0)clamp_y3=0;else if(value>=LH)clamp_y3=LH-1;else clamp_y3=value[7:0];end
 endfunction
 function automatic [7:0] lum(input [23:0] rgb);
  integer value;
  begin value=77*rgb[23:16]+150*rgb[15:8]+29*rgb[7:0]+128;lum=value>>8;end
 endfunction
 function automatic [7:0] edge_feature(input integer ky,input integer kx);
  reg [1:0] ix0,ix1,iy0,iy1;
  reg [7:0] dxv,dyv,mx;
  reg [7:0] here_l,right_l,down_l;
  begin
   ix0=(c0_x==0&&kx==0)||(c0_x==LW-1&&kx==2)?2'd1:kx;
   iy0=(c0_y==0&&ky==0)||(c0_y==LH-1&&ky==2)?2'd1:ky;
   ix1=((c0_x==LW-1&&kx>=1)||(c0_x==LW-2&&kx==2))?ix0-2'd1:ix0+2'd1;
   iy1=((c0_y==LH-1&&ky>=1)||(c0_y==LH-2&&ky==2))?iy0-2'd1:iy0+2'd1;
   here_l=lum_patch[(iy0*4+ix0)*8+:8];
   right_l=lum_patch[(iy0*4+ix1)*8+:8];
   down_l=lum_patch[(iy1*4+ix0)*8+:8];
   dxv=(here_l>right_l)?here_l-right_l:right_l-here_l;
   dyv=(here_l>down_l)?here_l-down_l:down_l-here_l;
   mx=(dxv>dyv)?dxv:dyv;
   edge_feature=(mx>127)?8'hff:(mx<<1);
  end
 endfunction
 function automatic [7:0] activation(input [1:0] l,input [3:0] ch,input integer output_lane,input integer lane);
  reg [6:0] term;
  begin
   term=ch*8+lane;activation=0;
   if(l==0)begin
    case(term)
     7'd0:activation=rgb_patch[(0)*24+16+:8];
     7'd1:activation=rgb_patch[(1)*24+16+:8];
     7'd2:activation=rgb_patch[(2)*24+16+:8];
     7'd3:activation=rgb_patch[(4)*24+16+:8];
     7'd4:activation=rgb_patch[(5)*24+16+:8];
     7'd5:activation=rgb_patch[(6)*24+16+:8];
     7'd6:activation=rgb_patch[(8)*24+16+:8];
     7'd7:activation=rgb_patch[(9)*24+16+:8];
     7'd8:activation=rgb_patch[(10)*24+16+:8];
     7'd9:activation=rgb_patch[(0)*24+8+:8];
     7'd10:activation=rgb_patch[(1)*24+8+:8];
     7'd11:activation=rgb_patch[(2)*24+8+:8];
     7'd12:activation=rgb_patch[(4)*24+8+:8];
     7'd13:activation=rgb_patch[(5)*24+8+:8];
     7'd14:activation=rgb_patch[(6)*24+8+:8];
     7'd15:activation=rgb_patch[(8)*24+8+:8];
     7'd16:activation=rgb_patch[(9)*24+8+:8];
     7'd17:activation=rgb_patch[(10)*24+8+:8];
     7'd18:activation=rgb_patch[(0)*24+0+:8];
     7'd19:activation=rgb_patch[(1)*24+0+:8];
     7'd20:activation=rgb_patch[(2)*24+0+:8];
     7'd21:activation=rgb_patch[(4)*24+0+:8];
     7'd22:activation=rgb_patch[(5)*24+0+:8];
     7'd23:activation=rgb_patch[(6)*24+0+:8];
     7'd24:activation=rgb_patch[(8)*24+0+:8];
     7'd25:activation=rgb_patch[(9)*24+0+:8];
     7'd26:activation=rgb_patch[(10)*24+0+:8];
     7'd27:activation=edge_feature(0,0);
     7'd28:activation=edge_feature(0,1);
     7'd29:activation=edge_feature(0,2);
     7'd30:activation=edge_feature(1,0);
     7'd31:activation=edge_feature(1,1);
     7'd32:activation=edge_feature(1,2);
     7'd33:activation=edge_feature(2,0);
     7'd34:activation=edge_feature(2,1);
     7'd35:activation=edge_feature(2,2);
     default:activation=0;
    endcase
   end else if(l==1)begin
    if(term<9&&output_lane<8)activation=hpatch[(term)*64+(output_lane*8)+:8];
   end else if(l==2)begin if(term<8)activation=mid_activation[term*8+:8];end
   else if(term<8)activation=high_activation[term*8+:8];
  end
 endfunction
 function automatic [7:0] requant(input signed [31:0] value,input [1:0] l);
  reg signed [31:0] shifted;
  reg [3:0] amount;
  begin
   case(l)0:amount=5;1:amount=3;2:amount=5;default:amount=7;endcase
   shifted=(value+(32'sd1<<<(amount-1)))>>>amount;
   requant=shifted<0?0:shifted>255?255:shifted[7:0];
  end
 endfunction
 function automatic [7:0] palette(input [7:0] v);
  begin if(v>=230)palette=255;else if(v>=179)palette=204;else if(v>=128)palette=153;else if(v>=77)palette=102;else if(v>=26)palette=51;else palette=0;end
 endfunction
 integer oi,ti;
 wire signed [19:0] dot[0:7];
 genvar lane,term;
 generate for(lane=0;lane<8;lane=lane+1)begin:dot_lane
  wire signed [16:0] prod[0:7];
  for(term=0;term<8;term=term+1)begin:mul
   assign prod[term]=$signed({1'b0,activationq[(lane*8+term)*8+:8]})*$signed(weightq[(lane*8+term)*8+:8]);
  end
  wire signed [17:0] a=prod[0]+prod[1],b=prod[2]+prod[3],c=prod[4]+prod[5],d=prod[6]+prod[7];
  wire signed [18:0] e=a+b,f=c+d;
  assign dot[lane]=e+f;
 end endgenerate
 wire [63:0] quant_vector;
 generate for(lane=0;lane<8;lane=lane+1)begin:quant_lane
  assign quant_vector[lane*8+:8]=requant(acc[lane],layer);
 end endgenerate
 wire [63:0] quant_h0=quant_vector[63:0];
 wire [8:0] out_read_x=(state==OREAD||out_x==LW-1)?9'd0:out_x+9'd1;
 wire take=pixel_valid&&pixel_ready;
 assign pixel_ready=state==POOL;
 assign result_valid=state==OSEND;
 assign result_data={4{outq,8'd0}};
 assign result_sof=(out_x==0&&c1_y==0&&subrow==0);
 assign result_eol=(out_x==LW-1);
 assign result_eof=(out_x==LW-1&&c1_y==LH-1&&subrow==3);
 assign busy=state!=IDLE;
 initial begin $readmemh(WEIGHTS,weights);$readmemh(BIASES,biases);end
 always @(posedge clk)begin
  if(state==C0_READ)begin
   rgbq0<=pool0[rgb_read_x];rgbq1<=pool1[rgb_read_x];rgbq2<=pool2[rgb_read_x];rgbq3<=pool3[rgb_read_x];
  end
  if(state==H0_READ)begin
   hq0<=hidden0_0[h_read_x];hq1<=hidden0_1[h_read_x];hq2<=hidden0_2[h_read_x];
  end
  if(state==C0_READ)biasq<=biases[0];
  if(state==H0_READ)biasq<=biases[1];
  if(state==MAC&&chunk+1>=layer_chunks&&layer==1)biasq<=biases[2];
  if(state==MAC&&chunk+1>=layer_chunks&&layer==2)biasq<=biases[3];
  if(state==WEIGHT_READ || (state==MAC&&chunk+1<layer_chunks))begin
   weightq<=weights[weight_base+(state==MAC?chunk+1:chunk)];
   for(oi=0;oi<8;oi=oi+1)for(ti=0;ti<8;ti=ti+1)
    activationq[(oi*8+ti)*8+:8]<=activation(layer,(state==MAC?chunk+1:chunk),oi,ti);
  end
  if(take&&pixel_x[1:0]==0)vsumq<=vsums[pixel_x[10:2]];
  if(take&&pixel_x[1:0]==3)begin
   vsums[pixel_x[10:2]]<={ysum_r,ysum_g,ysum_b};
   if(pixel_y[1:0]==3)case(pixel_y[3:2])0:pool0[pixel_x[10:2]]<=pooled_rgb;1:pool1[pixel_x[10:2]]<=pooled_rgb;2:pool2[pixel_x[10:2]]<=pooled_rgb;3:pool3[pixel_x[10:2]]<=pooled_rgb;endcase
  end
  if(state==QUANT&&layer==0)case(c0_y%3)0:hidden0_0[c0_x]<={edge_feature(1,1),quant_h0};1:hidden0_1[c0_x]<={edge_feature(1,1),quant_h0};2:hidden0_2[c0_x]<={edge_feature(1,1),quant_h0};endcase
  if(state==QUANT&&layer==3)outrow[c1_x]<=output_edge>110?24'h0c0c10:{palette(quant_vector[7:0]),palette(quant_vector[15:8]),palette(quant_vector[23:16])};
  if(state==OREAD||(state==OSEND&&result_ready))outq<=outrow[out_read_x];
 end
 integer i;
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;phase<=0;layer<=0;chunk<=0;low_y<=0;c0_y<=0;c1_y<=0;c0_x<=0;c1_x<=0;subrow<=0;
   input_finished<=0;sx_r<=0;sy_r<=0;sz_r<=0;out_x<=0;
   mid_activation<=0;high_activation<=0;output_edge<=0;output_rgb<=0;done<=0;cycles<=0;
   for(i=0;i<8;i=i+1)acc[i]<=0;
  end else begin
   done<=0;if(busy)cycles<=cycles+1'b1;
   case(state)
    IDLE:if(start)begin
     state<=POOL;low_y<=0;input_finished<=0;sx_r<=0;sy_r<=0;sz_r<=0;
     c0_x<=0;c0_y<=0;c1_x<=0;c1_y<=0;subrow<=0;
    end
    POOL:if(take)begin
     sx_r<=pixel_x[1:0]==3?0:xsum_r[10:0];sy_r<=pixel_x[1:0]==3?0:xsum_g[10:0];sz_r<=pixel_x[1:0]==3?0:xsum_b[10:0];
     if(pixel_y==H-1&&pixel_x==W-1)input_finished<=1;
     if(pixel_x==W-1&&pixel_y[1:0]==3)begin
      low_y<=low_y+1'b1;
      if(low_y>=2)begin c0_y<=low_y-2;c0_x<=0;phase<=0;state<=C0_READ;end
     end
    end
    C0_READ:begin phase<=phase;state<=C0_CAPTURE;end
    C0_CAPTURE:begin
     case(rgb_read_y0[1:0])0:lum_patch[(phase)*8+:8]<=lum(rgbq0);1:lum_patch[(phase)*8+:8]<=lum(rgbq1);2:lum_patch[(phase)*8+:8]<=lum(rgbq2);3:lum_patch[(phase)*8+:8]<=lum(rgbq3);endcase
     case(rgb_read_y1[1:0])0:lum_patch[(4+phase)*8+:8]<=lum(rgbq0);1:lum_patch[(4+phase)*8+:8]<=lum(rgbq1);2:lum_patch[(4+phase)*8+:8]<=lum(rgbq2);3:lum_patch[(4+phase)*8+:8]<=lum(rgbq3);endcase
     case(rgb_read_y2[1:0])0:lum_patch[(8+phase)*8+:8]<=lum(rgbq0);1:lum_patch[(8+phase)*8+:8]<=lum(rgbq1);2:lum_patch[(8+phase)*8+:8]<=lum(rgbq2);3:lum_patch[(8+phase)*8+:8]<=lum(rgbq3);endcase
     case(rgb_read_y3[1:0])0:lum_patch[(12+phase)*8+:8]<=lum(rgbq0);1:lum_patch[(12+phase)*8+:8]<=lum(rgbq1);2:lum_patch[(12+phase)*8+:8]<=lum(rgbq2);3:lum_patch[(12+phase)*8+:8]<=lum(rgbq3);endcase
     case(rgb_read_y0[1:0])0:rgb_patch[(phase)*24+:24]<=rgbq0;1:rgb_patch[(phase)*24+:24]<=rgbq1;2:rgb_patch[(phase)*24+:24]<=rgbq2;3:rgb_patch[(phase)*24+:24]<=rgbq3;endcase
     case(rgb_read_y1[1:0])0:rgb_patch[(4+phase)*24+:24]<=rgbq0;1:rgb_patch[(4+phase)*24+:24]<=rgbq1;2:rgb_patch[(4+phase)*24+:24]<=rgbq2;3:rgb_patch[(4+phase)*24+:24]<=rgbq3;endcase
     case(rgb_read_y2[1:0])0:rgb_patch[(8+phase)*24+:24]<=rgbq0;1:rgb_patch[(8+phase)*24+:24]<=rgbq1;2:rgb_patch[(8+phase)*24+:24]<=rgbq2;3:rgb_patch[(8+phase)*24+:24]<=rgbq3;endcase
     case(rgb_read_y3[1:0])0:rgb_patch[(12+phase)*24+:24]<=rgbq0;1:rgb_patch[(12+phase)*24+:24]<=rgbq1;2:rgb_patch[(12+phase)*24+:24]<=rgbq2;3:rgb_patch[(12+phase)*24+:24]<=rgbq3;endcase
     if(phase==3)begin for(i=0;i<8;i=i+1)acc[i]<=biasq[i*32+:32];layer<=0;chunk<=0;state<=WEIGHT_READ;end
     else begin phase<=phase+1'b1;state<=C0_READ;end
    end
    H0_READ:state<=H0_CAPTURE;
    H0_CAPTURE:begin
     case(h_read_y0%3)0:hpatch[(phase)*64+:64]<=hq0[63:0];1:hpatch[(phase)*64+:64]<=hq1[63:0];2:hpatch[(phase)*64+:64]<=hq2[63:0];endcase
     case(h_read_y1%3)0:hpatch[(3+phase)*64+:64]<=hq0[63:0];1:hpatch[(3+phase)*64+:64]<=hq1[63:0];2:hpatch[(3+phase)*64+:64]<=hq2[63:0];endcase
     case(h_read_y2%3)0:hpatch[(6+phase)*64+:64]<=hq0[63:0];1:hpatch[(6+phase)*64+:64]<=hq1[63:0];2:hpatch[(6+phase)*64+:64]<=hq2[63:0];endcase
     case(h_read_y1%3)0:edge_patch[(phase)*8+:8]<=hq0[71:64];1:edge_patch[(phase)*8+:8]<=hq1[71:64];2:edge_patch[(phase)*8+:8]<=hq2[71:64];endcase
     if(phase==2)output_edge<=edge_patch[(1)*8+:8];
     if(phase==2)begin for(i=0;i<8;i=i+1)acc[i]<=biasq[i*32+:32];layer<=1;chunk<=0;state<=WEIGHT_READ;end
     else begin phase<=phase+1'b1;state<=H0_READ;end
    end
    BIAS_READ:state<=BIAS_LOAD;
    BIAS_LOAD:begin for(i=0;i<8;i=i+1)acc[i]<=biasq[i*32+:32];chunk<=0;state<=WEIGHT_READ;end
    WEIGHT_READ:state<=MAC;
    MAC:begin
     for(i=0;i<8;i=i+1)acc[i]<=acc[i]+{{12{dot[i][19]}},dot[i]};
     if(chunk+1>=layer_chunks)state<=QUANT;
     else chunk<=chunk+1'b1;
    end
    QUANT:begin
     if(layer==0)begin
      if(c0_x==LW-1)begin
       c0_x<=0;
       if(c0_y==0)begin if(input_finished)begin c0_y<=c0_y+1'b1;state<=C0_READ;end else state<=POOL;end
       else begin c1_y<=c0_y-1'b1;c1_x<=0;phase<=0;state<=H0_READ;end
      end else begin
       c0_x<=c0_x+1'b1;phase<=3;state<=C0_READ;
       for(i=0;i<4;i=i+1)begin
        rgb_patch[(i*4)*24+:24]<=rgb_patch[(i*4+1)*24+:24];rgb_patch[(i*4+1)*24+:24]<=rgb_patch[(i*4+2)*24+:24];rgb_patch[(i*4+2)*24+:24]<=rgb_patch[(i*4+3)*24+:24];
        lum_patch[(i*4)*8+:8]<=lum_patch[(i*4+1)*8+:8];lum_patch[(i*4+1)*8+:8]<=lum_patch[(i*4+2)*8+:8];lum_patch[(i*4+2)*8+:8]<=lum_patch[(i*4+3)*8+:8];
       end
      end
     end else if(layer==1)begin mid_activation<=quant_vector[63:0];for(i=0;i<8;i=i+1)acc[i]<=biasq[i*32+:32];layer<=2;chunk<=0;state<=WEIGHT_READ;end
     else if(layer==2)begin high_activation<=quant_vector[63:0];for(i=0;i<8;i=i+1)acc[i]<=biasq[i*32+:32];layer<=3;chunk<=0;state<=WEIGHT_READ;end
     else begin
      if(c1_x!=LW-1)begin
       c1_x<=c1_x+1'b1;phase<=2;state<=H0_READ;
       edge_patch[(0)*8+:8]<=edge_patch[(1)*8+:8];edge_patch[(1)*8+:8]<=edge_patch[(2)*8+:8];
       for(i=0;i<3;i=i+1)begin hpatch[(i*3)*64+:64]<=hpatch[(i*3+1)*64+:64];hpatch[(i*3+1)*64+:64]<=hpatch[(i*3+2)*64+:64];end

      end
      else begin subrow<=0;out_x<=0;state<=OREAD;end
     end
    end
    OREAD:state<=OSEND;
    OSEND:if(result_ready)begin
     if(out_x!=LW-1)out_x<=out_x+1'b1;
     else begin
      out_x<=0;
      if(subrow!=3)subrow<=subrow+1'b1;
      else begin
       subrow<=0;
       c1_x<=0;
       if(c0_y==LH-1)begin
        if(c1_y!=LH-1)begin c1_y<=c1_y+1'b1;phase<=0;state<=H0_READ;end
        else begin done<=1;state<=IDLE;end
       end else if(input_finished)begin c0_y<=c0_y+1'b1;c0_x<=0;phase<=0;state<=C0_READ;end
       else state<=POOL;
      end
     end
    end
    default:state<=IDLE;
   endcase
  end
 end
 // synthesis translate_off
 initial if(W<16||H<16||W>1280||H>720||W%4||H%4)$fatal(1,"TinyComic unsupported geometry");
 // synthesis translate_on
endmodule
