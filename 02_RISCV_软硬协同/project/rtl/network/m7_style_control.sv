module m7_style_control(input wire clk,rstn,key_press,
 input wire [31:0] command_seq,input wire [1:0] command_style,
 output reg [1:0] style,output reg [31:0] applied_seq,output wire remote_event);
 assign remote_event=command_seq!=0&&command_seq!=applied_seq;
 always @(posedge clk or negedge rstn)
 if(!rstn)begin style<=0;applied_seq<=0;end
 else if(remote_event)begin style<=command_style;applied_seq<=command_seq;end
 else if(key_press)style<=style==2?0:style+1'b1;
endmodule
