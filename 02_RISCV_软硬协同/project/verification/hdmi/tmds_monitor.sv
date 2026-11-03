 reg [23:0] rgb_delay [0:63];reg de_delay[0:63];integer q,p;
 integer tmds_pixels=0,tmds_mismatch[57:60],all_pix[57:60];
 function [7:0] td(input [9:0] t);
 reg [7:0] bits8;
 begin bits8=t[9]?~t[7:0]:t[7:0];td[0]=bits8[0];td[7:1]=t[8]?(bits8[7:1]^bits8[6:0]):~(bits8[7:1]^bits8[6:0]);end
 endfunction
 reg [23:0] tmds_decoded;
 initial begin for(q=0;q<64;q=q+1)begin rgb_delay[q]=0;de_delay[q]=0;end for(q=57;q<61;q=q+1)begin tmds_mismatch[q]=0;all_pix[q]=0;end end
 always @(negedge hdmi_tx_slow_clk) begin
  for(p=63;p>0;p=p-1)begin rgb_delay[p]=rgb_delay[p-1];de_delay[p]=de_delay[p-1];end
  rgb_delay[0]={osd_r,osd_g,osd_b};de_delay[0]=osd_de;
  tmds_decoded={td(tmds_data2),td(tmds_data1),td(tmds_data0)};
  if(ready)begin
   for(p=57;p<61;p=p+1)if(de_delay[p])begin
    all_pix[p]=all_pix[p]+1;
    if(tmds_decoded!==rgb_delay[p])begin
     tmds_mismatch[p]=tmds_mismatch[p]+1;
     if(tmds_mismatch[p]<=2)$display("TMDS_MISMATCH latency=%0d pixel=%0d encoded=%h%h%h decoded=%h%h%h expected=%h",p,all_pix[p],tmds_data2,tmds_data1,tmds_data0,td(tmds_data2),td(tmds_data1),td(tmds_data0),rgb_delay[p]);
    end
   end
  end
 end
