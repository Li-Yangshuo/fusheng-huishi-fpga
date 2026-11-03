`timescale 1ns/1ps
module tb;
reg core_clk=0,axi_rstn=0,i_view_key_n=1,i_style_key_n=1;
always #5 core_clk=~core_clk;
localparam MODEL0=32'h50503031,MODEL1=32'h54473031;
 wire [1:0] demo_mode;wire key_sync,key_press;
 demo_key #(.MODES(4)) view_key(.clk(core_clk),.rstn(axi_rstn),.key_n(i_view_key_n),.mode(demo_mode),.key_sync(key_sync),.press(key_press));
 wire view_key_mode=demo_mode!=1;
 wire [1:0] style_mode;wire style_key_sync,style_key_press;
 demo_key #(.MODES(2)) style_key(.clk(core_clk),.rstn(axi_rstn),.key_n(i_style_key_n),.mode(style_mode),.key_sync(style_key_sync),.press(style_key_press));
 wire [31:0] active_model=style_mode[0]?MODEL0:MODEL1;

defparam view_key.DEBOUNCE_CYCLES=8;
defparam style_key.DEBOUNCE_CYCLES=8;
integer view_presses=0,style_presses=0;
always @(posedge core_clk)begin if(key_press)view_presses=view_presses+1;if(style_key_press)style_presses=style_presses+1;end
task press1;begin @(negedge core_clk);i_view_key_n=0;repeat(20)@(negedge core_clk);i_view_key_n=1;repeat(20)@(negedge core_clk);end endtask
task press2;begin @(negedge core_clk);i_style_key_n=0;repeat(20)@(negedge core_clk);i_style_key_n=1;repeat(20)@(negedge core_clk);end endtask
initial begin
repeat(4)@(negedge core_clk);axi_rstn=1;repeat(20)@(negedge core_clk);
if(demo_mode!==0||active_model!==MODEL1)$fatal(1,"reset original/Glass");
repeat(5)begin i_style_key_n=0;repeat(2)@(negedge core_clk);i_style_key_n=1;repeat(2)@(negedge core_clk);end
repeat(20)@(negedge core_clk);if(style_mode!==0)$fatal(1,"bounce counted");
press1();if(demo_mode!==1||active_model!==MODEL1)$fatal(1,"KEY1 half scene");
press2();if(demo_mode!==1||active_model!==MODEL0)$fatal(1,"KEY2 original Comic model");
press1();if(demo_mode!==2||active_model!==MODEL0)$fatal(1,"KEY1 full render");
press1();if(demo_mode!==3||active_model!==MODEL0)$fatal(1,"KEY1 tall pair");
press1();if(demo_mode!==0||active_model!==MODEL0)$fatal(1,"KEY1 wrap");
i_style_key_n=0;repeat(200)@(negedge core_clk);if(style_mode!==0||active_model!==MODEL1||style_presses!=2)$fatal(1,"long hold repeat");
i_style_key_n=1;repeat(20)@(negedge core_clk);
if(view_presses!=4||style_presses!=2)$fatal(1,"press counts");
$display("PRODUCTION_KEY12_PASS four_layouts=1 original_models=1 independent=1 bounce_rejected=1 hold_once=1");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
