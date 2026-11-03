// Streaming RGB gray-world white balance before both display and CNN.
// Statistics use ORIGINAL RGB, exclude dark/clipped/high-chroma pixels.
// Two sequential divisions per frame; no combinational division hardware.
// New gains apply atomically at SOF, including that first pixel.
module pp2_white_balance #(
 parameter MIN_SAMPLES=1024,
 parameter TRIM_R_Q8=256,TRIM_G_Q8=256,TRIM_B_Q8=256
)(
 input wire clk,rstn,
 input wire i_valid,i_sof,i_eol,i_eof,input wire [23:0] i_rgb,input wire [31:0] i_frame_id,
 output reg o_valid,o_sof,o_eol,o_eof,output reg [23:0] o_rgb,output reg [31:0] o_frame_id,
 output wire [11:0] gain_r_q8,gain_g_q8,gain_b_q8,
 output reg calibrated,output reg [19:0] last_sample_count
);
 wire [7:0] ir=i_rgb[23:16],ig=i_rgb[15:8],ib=i_rgb[7:0];
 wire [7:0] mn=ir<ig?(ir<ib?ir:ib):(ig<ib?ig:ib);
 wire [7:0] mx=ir>ig?(ir>ib?ir:ib):(ig>ib?ig:ib);
 wire [9:0] triple_min={2'd0,mn}+{1'b0,mn,1'b0};
 wire sample_ok=mn>=8&&mx>=48&&mx<=240&&{2'd0,mx}<=triple_min;
 reg [27:0] sr,sg,sb,frame_r,frame_g,frame_b;
 reg [19:0] samples;
 wire [27:0] nr=(i_sof?28'd0:sr)+(sample_ok?{20'd0,ir}:28'd0);
 wire [27:0] ng=(i_sof?28'd0:sg)+(sample_ok?{20'd0,ig}:28'd0);
 wire [27:0] nb=(i_sof?28'd0:sb)+(sample_ok?{20'd0,ib}:28'd0);
 wire [19:0] ns=(i_sof?20'd0:samples)+(sample_ok?20'd1:20'd0);
 reg [11:0] active_r,active_b,pending_r,pending_b,target_r;
 reg pending_valid;
 localparam IDLE=0,RINIT=1,RDIV=2,RFIN=3,BINIT=4,BDIV=5,BFIN=6;
 reg [2:0] state;reg [5:0] left;
 reg [35:0] dividend,divisor,quotient;reg [36:0] remainder;
 wire [36:0] shifted={remainder[35:0],dividend[35]};
 wire take=shifted>={1'b0,divisor};
 function automatic [11:0] bounded(input [35:0] q);
  begin bounded=q<128?12'd128:q>1024?12'd1024:q[11:0];end
 endfunction
 function automatic [11:0] smooth(input [11:0] old_gain,target,input established);
  begin
   if(!established)smooth=target;
   else if(target>=old_gain)smooth=old_gain+((target-old_gain+12'd2)>>2);
   else smooth=old_gain-((old_gain-target+12'd2)>>2);
  end
 endfunction
 function automatic [11:0] trim(input [11:0] auto_gain,input integer value);
  reg [31:0] p;
  begin p=auto_gain*value+128;p=p>>8;trim=p>4095?12'd4095:p[11:0];end
 endfunction
 wire [11:0] use_r=(i_sof&&pending_valid)?pending_r:active_r;
 wire [11:0] use_b=(i_sof&&pending_valid)?pending_b:active_b;
 wire [11:0] gr=trim(use_r,TRIM_R_Q8),gg=TRIM_G_Q8,gb=trim(use_b,TRIM_B_Q8);
 assign gain_r_q8=trim(active_r,TRIM_R_Q8);assign gain_g_q8=TRIM_G_Q8;assign gain_b_q8=trim(active_b,TRIM_B_Q8);
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin
   sr<=0;sg<=0;sb<=0;samples<=0;frame_r<=0;frame_g<=0;frame_b<=0;last_sample_count<=0;
   active_r<=256;active_b<=256;pending_r<=256;pending_b<=256;pending_valid<=0;calibrated<=0;target_r<=256;
   state<=IDLE;left<=0;dividend<=0;divisor<=0;quotient<=0;remainder<=0;
  end else begin
   if(i_valid)begin
    sr<=nr;sg<=ng;sb<=nb;samples<=ns;
    if(i_sof&&pending_valid)begin active_r<=pending_r;active_b<=pending_b;pending_valid<=0;calibrated<=1;end
    if(i_eof)begin
     last_sample_count<=ns;
     if(state==IDLE&&ns>=MIN_SAMPLES&&nr!=0&&nb!=0)begin frame_r<=nr;frame_g<=ng;frame_b<=nb;state<=RINIT;end
    end
   end
   case(state)
    RINIT,BINIT:begin
     dividend<={frame_g,8'd0}+((state==RINIT?{8'd0,frame_r}:{8'd0,frame_b})>>1);
     divisor<=state==RINIT?{8'd0,frame_r}:{8'd0,frame_b};
     quotient<=0;remainder<=0;left<=35;state<=state==RINIT?RDIV:BDIV;
    end
    RDIV,BDIV:begin
     remainder<=take?(shifted-{1'b0,divisor}):shifted;
     quotient<={quotient[34:0],take};dividend<={dividend[34:0],1'b0};
     if(left==0)state<=state==RDIV?RFIN:BFIN;else left<=left-1'b1;
    end
    RFIN:begin target_r<=bounded(quotient);state<=BINIT;end
    BFIN:begin pending_r<=smooth(active_r,target_r,calibrated);pending_b<=smooth(active_b,bounded(quotient),calibrated);pending_valid<=1;state<=IDLE;end
    default:begin end
   endcase
  end
 end
 reg v1,s1,l1,e1;reg [31:0] id1;
 reg [19:0] pr,pg,pb;
 function automatic [7:0] sat(input [19:0] product);
  reg [20:0] q;
  begin q={1'b0,product}+21'd128;sat=q>=21'd65536 ? 8'd255:q[15:8];end
 endfunction
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin v1<=0;s1<=0;l1<=0;e1<=0;id1<=0;pr<=0;pg<=0;pb<=0;
   o_valid<=0;o_sof<=0;o_eol<=0;o_eof<=0;o_rgb<=0;o_frame_id<=0;end
  else begin
   v1<=i_valid;s1<=i_sof;l1<=i_eol;e1<=i_eof;id1<=i_frame_id;
   pr<=ir*gr;pg<=ig*gg;pb<=ib*gb;
   o_valid<=v1;o_sof<=s1;o_eol<=l1;o_eof<=e1;o_frame_id<=id1;o_rgb<={sat(pr),sat(pg),sat(pb)};
  end
 end
 // synthesis translate_off
 initial if(MIN_SAMPLES<1||TRIM_R_Q8<0||TRIM_R_Q8>1024||TRIM_G_Q8<0||TRIM_G_Q8>1024||TRIM_B_Q8<0||TRIM_B_Q8>1024)$fatal(1,"white balance parameters");
 // synthesis translate_on
endmodule
