`timescale 1ns/1ps
module tb_key12_control;
  reg clk=0, rstn=0;
  reg key1_n=1, key2_n=1;
  wire [1:0] layout_mode, style_mode;
  wire key1_sync,key1_press,key2_sync,key2_press;
  always #5 clk=~clk;

  demo_key #(.DEBOUNCE_CYCLES(4),.MODES(4)) key1(
    .clk(clk),.rstn(rstn),.key_n(key1_n),.mode(layout_mode),
    .key_sync(key1_sync),.press(key1_press));
  demo_key #(.DEBOUNCE_CYCLES(4),.MODES(2)) key2(
    .clk(clk),.rstn(rstn),.key_n(key2_n),.mode(style_mode),
    .key_sync(key2_sync),.press(key2_press));

  task automatic tap1;
    begin
      @(negedge clk); key1_n=0;
      repeat(8) @(posedge clk);
      @(negedge clk); key1_n=1;
      repeat(8) @(posedge clk);
    end
  endtask
  task automatic tap2;
    begin
      @(negedge clk); key2_n=0;
      repeat(8) @(posedge clk);
      @(negedge clk); key2_n=1;
      repeat(8) @(posedge clk);
    end
  endtask

  initial begin
    repeat(3) @(posedge clk); rstn=1;
    repeat(2) @(posedge clk);
    if(layout_mode!==0 || style_mode!==0) $fatal(1,"reset modes");
    tap1(); if(layout_mode!==1 || style_mode!==0) $fatal(1,"KEY1 first layout");
    tap2(); if(layout_mode!==1 || style_mode!==1) $fatal(1,"KEY2 style toggle");
    tap1(); if(layout_mode!==2 || style_mode!==1) $fatal(1,"KEY1 full render");
    tap1(); if(layout_mode!==3 || style_mode!==1) $fatal(1,"KEY1 tall pair");
    tap1(); if(layout_mode!==0 || style_mode!==1) $fatal(1,"KEY1 wrap");
    tap2(); if(layout_mode!==0 || style_mode!==0) $fatal(1,"KEY2 wrap");
    $display("KEY12_CONTROL_PASS key1_layout_modes=4 key2_style_modes=2 independent=1");
    $finish;
  end
endmodule
