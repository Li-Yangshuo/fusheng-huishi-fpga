// C2 stem: 3 RGB channels, 3x3, 2 outputs. Nine physical dual-INT8 DSPs.
// Replay one input channel per cycle, three issues per pixel. Config remains
// immutable until the enclosing stage retires; all pipelines freeze together.
module rgb_stem_mac_c2 #(parameter TAG_W=55,MW=TAG_W+2)(
 input wire clk,rst,input wire [431:0] weights,input wire [63:0] biases,
 input wire in_valid,output wire in_ready,input wire [215:0] in_windows,input wire [TAG_W-1:0] in_tag,
 output wire out_valid,input wire out_ready,output reg signed [31:0] acc0,acc1,
 output reg [1:0] overflow,output reg [TAG_W:0] out_tag,output reg protocol_error
);
 reg busy;reg [1:0] request;reg [215:0] pixels;reg [TAG_W-1:0] tag;
 wire [8:0] mr,mv;wire signed [23:0] p0[0:8],p1[0:8];wire [MW-1:0] meta;
 reg pair_valid;wire advance=!pair_valid||out_ready;
 assign out_valid=!rst&&pair_valid;
 assign in_ready=!rst&&(!busy||(request==2&&(&mr)));
 genvar g;
 generate for(g=0;g<9;g=g+1)begin:product
  wire signed [7:0] a=pixels[(request*9+g)*8+:8];
  wire signed [7:0] w0=weights[(request*9+g)*8+:8];
  wire signed [7:0] w1=weights[216+(request*9+g)*8+:8];
  if(g==0)begin
   dual_int8_mul #(.TAG_W(MW)) mul(clk,rst,busy,mr[g],a,w0,a,w1,{tag,request},mv[g],advance,p0[g],p1[g],meta);
  end else begin
   wire unused_tag;
   dual_int8_mul #(.TAG_W(1)) mul(clk,rst,busy,mr[g],a,w0,a,w1,1'b0,mv[g],advance,p0[g],p1[g],unused_tag);
  end
 end endgenerate
 always @(posedge clk)begin
  if(rst)begin busy<=0;request<=0;end
  else begin
   if(busy&&(&mr))begin
    if(request==2)begin busy<=0;request<=0;end else request<=request+1'b1;
   end
   if(in_valid&&in_ready)begin busy<=1;request<=0;pixels<=in_windows;tag<=in_tag;end
  end
 end
 reg [3:0] valid;reg [MW-1:0] tags[0:3];integer i;
 reg signed [16:0] s0a[0:4],s0b[0:4];
 reg signed [17:0] s1a[0:2],s1b[0:2];
 reg signed [18:0] s2a[0:1],s2b[0:1];
 reg signed [19:0] s3a,s3b;
 always @(posedge clk)begin
  if(rst)valid<=0;
  else if(advance)begin
   valid<={valid[2:0],mv[0]};tags[0]<=meta;
   for(i=1;i<4;i=i+1)tags[i]<=tags[i-1];
  end
 end
 generate for(g=0;g<5;g=g+1)begin:sum0
  if(g<4)begin
   always @(posedge clk)if(advance)begin
    s0a[g]<=$signed({p0[2*g][15],p0[2*g][15:0]})+$signed({p0[2*g+1][15],p0[2*g+1][15:0]});
    s0b[g]<=$signed({p1[2*g][15],p1[2*g][15:0]})+$signed({p1[2*g+1][15],p1[2*g+1][15:0]});
   end
  end else begin
   always @(posedge clk)if(advance)begin s0a[g]<={p0[8][15],p0[8][15:0]};s0b[g]<={p1[8][15],p1[8][15:0]};end
  end
 end
 for(g=0;g<3;g=g+1)begin:sum1
  if(g<2)begin
   always @(posedge clk)if(advance)begin
    s1a[g]<=$signed({s0a[2*g][16],s0a[2*g]})+$signed({s0a[2*g+1][16],s0a[2*g+1]});
    s1b[g]<=$signed({s0b[2*g][16],s0b[2*g]})+$signed({s0b[2*g+1][16],s0b[2*g+1]});
   end
  end else begin
   always @(posedge clk)if(advance)begin s1a[g]<={s0a[4][16],s0a[4]};s1b[g]<={s0b[4][16],s0b[4]};end
  end
 end endgenerate
 always @(posedge clk)if(advance)begin
  s2a[0]<=$signed({s1a[0][17],s1a[0]})+$signed({s1a[1][17],s1a[1]});s2a[1]<={s1a[2][17],s1a[2]};
  s2b[0]<=$signed({s1b[0][17],s1b[0]})+$signed({s1b[1][17],s1b[1]});s2b[1]<={s1b[2][17],s1b[2]};
  s3a<=$signed({s2a[0][18],s2a[0]})+$signed({s2a[1][18],s2a[1]});
  s3b<=$signed({s2b[0][18],s2b[0]})+$signed({s2b[1][18],s2b[1]});
 end
 reg signed [21:0] prefix0,prefix1;reg [TAG_W-1:0] prefix_tag;reg [1:0] expected_ci;
 wire [1:0] ci=tags[3][1:0];wire [TAG_W-1:0] result_tag=tags[3][MW-1:2];
 wire signed [22:0] total0=$signed({prefix0[21],prefix0})+$signed({{3{s3a[19]}},s3a});
 wire signed [22:0] total1=$signed({prefix1[21],prefix1})+$signed({{3{s3b[19]}},s3b});
 wire signed [32:0] biased0=$signed({{10{total0[22]}},total0})+$signed({biases[31],biases[31:0]});
 wire signed [32:0] biased1=$signed({{10{total1[22]}},total1})+$signed({biases[63],biases[63:32]});
 always @(posedge clk)begin
  if(rst)begin pair_valid<=0;protocol_error<=0;overflow<=0;expected_ci<=0;end
  else if(advance)begin
   pair_valid<=0;
   if(valid[3])begin
    if(ci!=expected_ci||(ci!=0&&prefix_tag!=result_tag))protocol_error<=1;
    expected_ci<=(ci==2)?0:ci+1'b1;
    if(ci==0)begin prefix0<={{2{s3a[19]}},s3a};prefix1<={{2{s3b[19]}},s3b};prefix_tag<=result_tag;end
    else if(ci==1)begin prefix0<=total0[21:0];prefix1<=total1[21:0];end
    else if(ci==2)begin
     pair_valid<=1;acc0<=biased0[31:0];acc1<=biased1[31:0];
     overflow<={biased1[32]!=biased1[31],biased0[32]!=biased0[31]};out_tag<={result_tag,1'b0};
    end
   end
  end
 end
endmodule
