// Two independent 9-tap signed INT8 sums, nine physical dual DSPs.
// Bias is looked up after the reduction by the layer-locked parent, so 64 bias
// bits are not repeated through every pipeline stage for every pair.
module dw9_pair_sum #(parameter TAG_W=40)(
 input wire clk,rst,in_valid,output wire in_ready,
 input wire [143:0] in_windows,in_weights,input wire [TAG_W-1:0] in_tag,
 output wire out_valid,input wire out_ready,
 output wire signed [19:0] sum0,sum1,output wire [TAG_W-1:0] out_tag
);
 wire [8:0] mr,mv;wire signed [23:0] p0[0:8],p1[0:8];wire [TAG_W-1:0] mt;
 reg [3:0] valid;reg [TAG_W-1:0] tags[0:3];
 reg signed [16:0] a0[0:4],a1[0:4];reg signed [17:0] b0[0:2],b1[0:2];
 reg signed [18:0] c0[0:1],c1[0:1];reg signed [19:0] d0,d1;
 wire advance=!valid[3]||out_ready;
 assign in_ready=&mr;assign out_valid=!rst&&valid[3];assign sum0=d0;assign sum1=d1;assign out_tag=tags[3];
 genvar g;
 generate for(g=0;g<9;g=g+1)begin:tap
  if(g==0)begin
   dual_int8_mul #(.TAG_W(TAG_W)) mul(clk,rst,in_valid,mr[g],in_windows[g*8+:8],in_weights[g*8+:8],in_windows[72+g*8+:8],in_weights[72+g*8+:8],in_tag,mv[g],advance,p0[g],p1[g],mt);
  end else begin
   wire unused_tag;
   dual_int8_mul #(.TAG_W(1)) mul(clk,rst,in_valid,mr[g],in_windows[g*8+:8],in_weights[g*8+:8],in_windows[72+g*8+:8],in_weights[72+g*8+:8],1'b0,mv[g],advance,p0[g],p1[g],unused_tag);
  end
 end endgenerate
 integer i;
 always @(posedge clk)begin
  if(rst)valid<=0;
  else if(advance)begin
   valid<={valid[2:0],mv[0]};tags[0]<=mt;for(i=1;i<4;i=i+1)tags[i]<=tags[i-1];
   for(i=0;i<4;i=i+1)begin
    a0[i]<=$signed({p0[2*i][15],p0[2*i][15:0]})+$signed({p0[2*i+1][15],p0[2*i+1][15:0]});
    a1[i]<=$signed({p1[2*i][15],p1[2*i][15:0]})+$signed({p1[2*i+1][15],p1[2*i+1][15:0]});
   end
   a0[4]<=$signed({p0[8][15],p0[8][15:0]});a1[4]<=$signed({p1[8][15],p1[8][15:0]});
   for(i=0;i<2;i=i+1)begin
    b0[i]<=$signed({a0[2*i][16],a0[2*i]})+$signed({a0[2*i+1][16],a0[2*i+1]});
    b1[i]<=$signed({a1[2*i][16],a1[2*i]})+$signed({a1[2*i+1][16],a1[2*i+1]});
   end
   b0[2]<=$signed({a0[4][16],a0[4]});b1[2]<=$signed({a1[4][16],a1[4]});
   c0[0]<=$signed({b0[0][17],b0[0]})+$signed({b0[1][17],b0[1]});c0[1]<=$signed({b0[2][17],b0[2]});
   c1[0]<=$signed({b1[0][17],b1[0]})+$signed({b1[1][17],b1[1]});c1[1]<=$signed({b1[2][17],b1[2]});
   d0<=$signed({c0[0][18],c0[0]})+$signed({c0[1][18],c0[1]});
   d1<=$signed({c1[0][18],c1[0]})+$signed({c1[1][18],c1[1]});
  end
 end
endmodule
