// Configurable 2->3 head + exact signed INT8 M17 + synchronous RGB LUT.
// Native A pixel bits: [31:24]=R,[23:16]=G,[15:8]=B,[7:0]=0.
// LUT values and scales are loader data, not a frozen C-model/tanh contract.
module rgb_head #(
 parameter WIDTH=1280,HEIGHT=720,XW=$clog2(WIDTH+1),YW=$clog2(HEIGHT+1),PT=XW+YW,MT=PT+1,QT=PT+2
)(
 input wire clk,rst,
 input wire cfg_valid,output wire cfg_ready,input wire [1:0] cfg_kind,
 input wire [9:0] cfg_index,input wire [63:0] cfg_data,input wire [31:0] cfg_model,
 input wire start_valid,output wire start_ready,input wire [31:0] start_task,start_frame,start_model,
 input wire in_valid,output wire in_ready,input wire signed [7:0] in_data,
 input wire [XW-1:0] in_x,input wire [YW-1:0] in_y,input wire [0:0] in_channel,
 input wire [31:0] in_task,in_frame,in_model,input wire in_eol,in_last,
 output wire out_valid,input wire out_ready,output reg [31:0] out_pixel,
 output reg [XW-1:0] out_x,output reg [YW-1:0] out_y,
 output wire [31:0] out_task,out_frame,out_model,output reg out_eol,out_last,
 output wire busy,error,output wire [5:0] error_code,output reg done,frame_ok
);
 reg active,cfg_error,input_error,mac_error,overflow_error,output_error,descriptor_error;
 reg have_model;reg [31:0] table_model,task_tag,frame_tag,model_tag;
 reg [2:0] loaded_w,loaded_q;reg [9:0] lut_count;
 reg [15:0] weights[0:2];reg [31:0] biases[0:2];reg [23:0] quant[0:2];
 (* syn_ramstyle="block_ram" *) reg [7:0] table_rgb[0:1023];
 reg [XW-1:0] ix,px;reg [YW-1:0] iy,py;
 reg [0:0] ic;reg [1:0] pack_channel;reg input_end;
 reg [7:0] first_byte;reg pair_valid,pair_first;reg [15:0] pair_data;reg [PT-1:0] pair_position;
 reg half_valid;reg [PT-1:0] half_position;reg signed [17:0] half_sum[0:2];
 reg lookup_valid;reg [7:0] lookup_value;reg [QT-1:0] lookup_tag;
 reg rgb_valid;reg [15:0] partial_rg;
 reg [31:0] input_scalars,output_pixels;
 wire [2:0] mr,mv;wire [MT-1:0] mtags[0:2];wire signed [23:0] p0[0:2],p1[0:2];
 wire vector_ready,ser_valid,ser_ready,ser_overflow;
 wire [95:0] vector_data;wire [2:0] vector_overflow;wire [PT-1:0] ser_tag;
 wire signed [31:0] ser_data;wire [1:0] ser_channel;
 wire q_valid,q_ready;wire signed [7:0] q_result;wire [QT-1:0] q_tag;
 wire lookup_ready;
 wire all_loaded=have_model&&(&loaded_w)&&(&loaded_q)&&lut_count==768;
 wire empty=!pair_valid&&!(|mv)&&!half_valid&&!ser_valid&&!q_valid&&!lookup_valid&&!rgb_valid;
 assign error_code={descriptor_error,output_error,overflow_error,mac_error,input_error,cfg_error};
 assign error=|error_code;assign busy=active;
 assign start_ready=!rst&&!active&&!error&&all_loaded&&empty;
 wire go=start_valid&&start_ready;
 assign cfg_ready=!rst&&!active&&!error&&!go&&empty;
 wire ct=cfg_valid&&cfg_ready;
 wire good_cfg_bank=have_model&&cfg_model==table_model&&!all_loaded;
 wire lut_write=ct&&cfg_kind==2&&good_cfg_bank&&cfg_index==lut_count&&lut_count<768;
 wire expected_eol=ix==WIDTH-1&&ic==1;
 wire expected_last=expected_eol&&iy==HEIGHT-1;
 wire input_tags_ok={in_task,in_frame,in_model,in_y,in_x,in_channel,in_eol,in_last}==
  {task_tag,frame_tag,model_tag,iy,ix,ic,expected_eol,expected_last};
 wire pair_ready=&mr;
 assign in_ready=!rst&&active&&!error&&!input_end&&(!ic[0]||!pair_valid||pair_ready);
 wire take_in=in_valid&&in_ready;
 wire first_product=1'b0;
 wire mac_ready=first_product?1'b1:vector_ready;
 wire mac_valid=&mv;
 wire second_take=mac_valid&&mac_ready&&!first_product;
 wire first_take=mac_valid&&mac_ready&&first_product;
 genvar g;
 generate for(g=0;g<3;g=g+1)begin:head_products
  wire signed [7:0] w0=weights[g][7:0];
  wire signed [7:0] w1=weights[g][15:8];
  dual_int8_mul #(.TAG_W(MT)) mul(clk,rst,pair_valid,mr[g],pair_data[7:0],w0,pair_data[15:8],w1,
   {pair_first,pair_position},mv[g],mac_ready,p0[g],p1[g],mtags[g]);
  wire signed [24:0] pair_sum=$signed({p0[g][23],p0[g]})+$signed({p1[g][23],p1[g]});
  wire signed [33:0] combined=$signed({{9{pair_sum[24]}},pair_sum})+$signed({{2{biases[g][31]}},biases[g]});
  assign vector_data[g*32+:32]=combined[31:0];
  assign vector_overflow[g]=combined[33:31]!={3{combined[31]}};
  always @(posedge clk)if(first_take)half_sum[g]<=pair_sum[17:0];
 end endgenerate
 vector_serialize #(.CHANNELS(3),.TAG_W(PT)) serialize(
  clk,rst,mac_valid&&!first_product,vector_ready,vector_data,vector_overflow,mtags[0][PT-1:0],
  ser_valid,ser_ready,ser_data,ser_overflow,ser_channel,ser_tag);
 reg [23:0] selected_q;integer qi;
 always @(*)begin selected_q=0;for(qi=0;qi<3;qi=qi+1)if(ser_channel==qi)selected_q=quant[qi];end
 requant_int8_m17 #(.TAG_W(QT)) requant(
  clk,rst,ser_valid,ser_ready,ser_data,selected_q[16:0],selected_q[22:17],1'b0,{ser_tag,ser_channel},
  q_valid,q_ready,q_result,q_tag);
 assign q_ready=!lookup_valid||lookup_ready;
 assign lookup_ready=!rst&&active&&(pack_channel!=2||!rgb_valid||out_ready);
 assign out_valid=!rst&&rgb_valid;
 assign out_task=task_tag;assign out_frame=frame_tag;assign out_model=model_tag;
 wire [1:0] lc=lookup_tag[1:0];
 wire [XW-1:0] lx=lookup_tag[2+:XW];wire [YW-1:0] ly=lookup_tag[2+XW+:YW];
 wire last_output_take=out_valid&&out_ready&&out_last;
 wire bad_final=!input_end||input_scalars!=WIDTH*HEIGHT*2||output_pixels!=WIDTH*HEIGHT-1||
  pair_valid||(|mv)||half_valid||ser_valid||q_valid||lookup_valid;
 // No reset on the memory output data: retain a real synchronous block-RAM read.
 always @(posedge clk)begin
  if(lut_write)table_rgb[cfg_index]<=cfg_data[7:0];
  if(q_valid&&q_ready)lookup_value<=table_rgb[{q_tag[1:0],q_result[7:0]}];
 end
 integer c;
 always @(posedge clk)begin
  if(rst)begin
   active<=0;cfg_error<=0;input_error<=0;mac_error<=0;overflow_error<=0;output_error<=0;descriptor_error<=0;
   have_model<=0;table_model<=0;loaded_w<=0;loaded_q<=0;lut_count<=0;
   task_tag<=0;frame_tag<=0;model_tag<=0;ix<=0;iy<=0;ic<=0;input_end<=0;
   pair_valid<=0;pair_first<=0;pair_data<=0;pair_position<=0;first_byte<=0;
   half_valid<=0;half_position<=0;lookup_valid<=0;lookup_tag<=0;
   rgb_valid<=0;partial_rg<=0;pack_channel<=0;px<=0;py<=0;
   input_scalars<=0;output_pixels<=0;done<=0;frame_ok<=0;
   out_pixel<=0;out_x<=0;out_y<=0;out_eol<=0;out_last<=0;
  end else begin
   done<=0;frame_ok<=0;
   if(ct)begin
    if(cfg_kind==3)begin
     have_model<=1;table_model<=cfg_model;loaded_w<=0;loaded_q<=0;lut_count<=0;
     if(cfg_index!=0)cfg_error<=1;
    end else if(!good_cfg_bank)cfg_error<=1;
    else case(cfg_kind)
     0:if(cfg_index<3&&!loaded_w[cfg_index])begin weights[cfg_index]<=cfg_data[15:0];loaded_w[cfg_index]<=1;end else cfg_error<=1;
     1:if(cfg_index<3&&!loaded_q[cfg_index]&&!cfg_data[55])begin biases[cfg_index]<=cfg_data[31:0];quant[cfg_index]<=cfg_data[55:32];loaded_q[cfg_index]<=1;end else cfg_error<=1;
     2:if(lut_write)lut_count<=lut_count+1'b1;else cfg_error<=1;
    endcase
   end
   if(go)begin
    active<=1;task_tag<=start_task;frame_tag<=start_frame;model_tag<=start_model;
    ix<=0;iy<=0;ic<=0;input_end<=0;input_scalars<=0;output_pixels<=0;
    pack_channel<=0;px<=0;py<=0;
    if(start_model!=table_model)descriptor_error<=1;
   end
   if(pair_valid&&pair_ready)pair_valid<=0;
   if(take_in)begin
    if(!input_tags_ok)input_error<=1;
    else begin
     input_scalars<=input_scalars+1'b1;
     if(!ic[0])first_byte<=in_data;
     else begin pair_valid<=1;pair_first<=1'b0;pair_data<={in_data,first_byte};pair_position<={iy,ix};end
     if(ic==1)begin
      ic<=0;if(ix==WIDTH-1)begin ix<=0;if(iy==HEIGHT-1)input_end<=1;else iy<=iy+1'b1;end else ix<=ix+1'b1;
     end else ic<=ic+1'b1;
    end
   end
   if(first_take)begin
    if(half_valid)mac_error<=1;half_valid<=1;half_position<=mtags[0][PT-1:0];
   end
   if(second_take)begin
    half_valid<=0;
   end
   if(mac_valid&&mac_ready&&(mtags[0]!=mtags[1]||mtags[0]!=mtags[2]))mac_error<=1;
   if(ser_valid&&ser_ready&&ser_overflow)overflow_error<=1;
   if(q_ready)begin lookup_valid<=q_valid;if(q_valid)lookup_tag<=q_tag;end
   if(out_valid&&out_ready)begin rgb_valid<=0;output_pixels<=output_pixels+1'b1;end
   if(lookup_valid&&lookup_ready)begin
    if(lc!=pack_channel||lx!=px||ly!=py)output_error<=1;
    if(pack_channel==0)begin partial_rg[15:8]<=lookup_value;pack_channel<=1;end
    else if(pack_channel==1)begin partial_rg[7:0]<=lookup_value;pack_channel<=2;end
    else begin
     out_pixel<={partial_rg,lookup_value,8'h00};out_x<=px;out_y<=py;
     out_eol<=px==WIDTH-1;out_last<=px==WIDTH-1&&py==HEIGHT-1;rgb_valid<=1;pack_channel<=0;
     if(px==WIDTH-1)begin px<=0;if(py!=HEIGHT-1)py<=py+1'b1;end else px<=px+1'b1;
    end
   end
   if(last_output_take)begin
    done<=1;frame_ok<=!error&&!bad_final;
    if(bad_final)output_error<=1;
    if(!error&&!bad_final)active<=0;
   end
  end
 end
 // synthesis translate_off
 initial if(WIDTH<1||HEIGHT<1)$fatal(1,"head positive geometry required");
 // synthesis translate_on
endmodule
