// Candidate board timing: 148.5 MHz / (2200*1125) = 60 Hz.
// Counts sync, back porch, active, front porch. frame_start precedes ROI.
module ab05_hdmi_timing #(
 parameter H_ACTIVE=1920,H_FP=88,H_SYNC=44,H_BP=148,
 parameter V_ACTIVE=1080,V_FP=4,V_SYNC=5,V_BP=36
)(
 input wire pix_clk,pix_rstn,
 output wire frame_start,hs,vs,de,
 output wire [11:0] x,y
);
 localparam HT=H_ACTIVE+H_FP+H_SYNC+H_BP;
 localparam VT=V_ACTIVE+V_FP+V_SYNC+V_BP;
 reg [11:0] hc,vc;
 always @(posedge pix_clk or negedge pix_rstn)
  if(!pix_rstn)begin hc<=0;vc<=0;end
  else if(hc==HT-1)begin hc<=0;if(vc==VT-1)vc<=0;else vc<=vc+1'b1;end
  else hc<=hc+1'b1;
 assign frame_start=pix_rstn&&(hc==0)&&(vc==0);
 assign hs=pix_rstn&&(hc<H_SYNC);
 assign vs=pix_rstn&&(vc<V_SYNC);
 assign de=pix_rstn&&(hc>=H_SYNC+H_BP)&&(hc<H_SYNC+H_BP+H_ACTIVE)&&
                    (vc>=V_SYNC+V_BP)&&(vc<V_SYNC+V_BP+V_ACTIVE);
 assign x=hc-H_SYNC-H_BP;
 assign y=vc-V_SYNC-V_BP;
 // synthesis translate_off
 initial if(HT>4096||VT>4096||H_ACTIVE<1||V_ACTIVE<1)$fatal(1,"HDMI timing dimensions");
 // synthesis translate_on
endmodule
