module demo_key #(parameter integer DEBOUNCE_CYCLES=1000000,parameter integer MODES=4)(
 input wire clk,rstn,key_n,output reg [1:0] mode,output reg key_sync,output reg press);
 (* async_reg="true" *) reg meta;reg stable;reg [19:0] count;
 always @(posedge clk or negedge rstn)begin
 if(!rstn)begin meta<=1;key_sync<=1;stable<=1;count<=0;mode<=0;press<=0;end
 else begin meta<=key_n;key_sync<=meta;press<=0;
 if(key_sync==stable)count<=0;
 else if(count==DEBOUNCE_CYCLES-1)begin count<=0;stable<=key_sync;
 if(!key_sync)begin mode<=mode==MODES-1?2'd0:mode+2'd1;press<=1;end end
 else count<=count+1'b1;
 end end
endmodule
