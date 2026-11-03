module ab09_reset_release(input wire clk,arstn,output wire rstn);
 (* async_reg="true" *) reg[2:0] run;
 always @(posedge clk or negedge arstn)if(!arstn)run<=0;else run<={run[1:0],1'b1};
 assign rstn=run[2];
endmodule
