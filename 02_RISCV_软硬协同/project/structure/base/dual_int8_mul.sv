// Two independent signed INT8 products in one physical Titanium DSP48.
// Whole two-stage pipeline freezes under output backpressure. No accumulation
// or saturation is hidden here. Lane0 is low24, lane1 high24 on the primitive.
module dual_int8_mul # (parameter TAG_W=16)(
 input wire clk,rst,
 input wire in_valid, output wire in_ready,
 input wire signed [7:0] a0,b0,a1,b1,
 input wire [TAG_W-1:0] in_tag,
 output wire out_valid,input wire out_ready,
 output wire signed [23:0] p0,p1,
 output wire [TAG_W-1:0] out_tag
);
 reg [1:0] valid;
 reg [TAG_W-1:0] tag0,tag1;
 wire advance=!valid[1] || out_ready;
 assign in_ready=advance && !rst;
 assign out_valid=valid[1] && !rst;
 assign out_tag=tag1;
 always @(posedge clk) begin
  if(rst)valid<=0;
  else if(advance)begin
   valid<={valid[0],in_valid};tag0<=in_tag;tag1<=tag0;
  end
 end
 wire [47:0] product;
 wire [18:0] packed_a={{3{a1[7]}},a1,a0};
 wire [17:0] packed_b={{2{b1[7]}},b1,b0};
 EFX_DSP48 #(.MODE("DUAL"),.SIGNED(1),.A_REG(1),.B_REG(1),
  .P_REG(1),.C_REG(0),.OP_REG(0),.W_REG(0),.O_REG(0),
  .RST_SYNC(1),.SHIFTER(0),.P_EXT("ALIGN_RIGHT"),
  .M_SEL("P"),.N_SEL("CONST0"),.W_SEL("P")) dsp(
  .CLK(clk),.CE(advance),.RST(rst),.A(packed_a),.B(packed_b),
  .C(18'd0),.CASCIN(48'd0),.OP(2'b00),.SHIFT_ENA(1'b0),
  .O(product),.CASCOUT(),.OVFL());
 assign p0=$signed(product[23:0]);
 assign p1=$signed(product[47:24]);
endmodule
