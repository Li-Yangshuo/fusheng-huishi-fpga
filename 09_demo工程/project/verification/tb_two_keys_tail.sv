
 integer k;reg[1:0] saved_mode,saved_style;
 task ticks(input integer n);repeat(n)@(negedge core_clk);endtask
 task click(input integer key);
 begin case(key)1:i_view_key_n=0;2:i_style_key_n=0;3:i_style_alt_key_n=0;endcase ticks(20);
 case(key)1:i_view_key_n=1;2:i_style_key_n=1;3:i_style_alt_key_n=1;endcase ticks(20);end endtask
 task check_style(input integer wanted);
 begin if(style_mode!=wanted||active_model!=(wanted==0?MODEL0:wanted==1?MODEL1:MODEL2))$fatal(1,"model selection");end endtask
 initial begin
 ticks(4);axi_rstn=1;ticks(4);check_style(0);
 for(k=0;k<12;k=k+1)begin
  saved_mode=demo_mode;saved_style=style_mode;
  if(k%2)begin i_style_key_n=0;ticks(2);i_style_key_n=1;end
  else begin i_style_alt_key_n=0;ticks(2);i_style_alt_key_n=1;end
  ticks(4);check_style(saved_style);
  if(k%2)i_style_key_n=0;else i_style_alt_key_n=0;
  ticks(20);check_style((k+1)%3);if(demo_mode!=saved_mode)$fatal(1,"style changed layout");
  ticks(40);check_style((k+1)%3);
  i_style_key_n=1;i_style_alt_key_n=1;ticks(20);click(1);
  if(demo_mode!=(k+1)%4)$fatal(1,"layout");check_style((k+1)%3);
 end
 i_style_key_n=0;i_style_alt_key_n=0;ticks(20);check_style(1);
 i_style_key_n=1;ticks(20);check_style(1);i_style_alt_key_n=1;ticks(20);click(2);check_style(2);click(3);check_style(0);
 i_view_key_n=0;i_style_key_n=0;ticks(20);if(demo_mode!=1)$fatal(1,"simultaneous");check_style(1);
 i_view_key_n=1;i_style_key_n=1;ticks(20);axi_rstn=0;ticks(3);check_style(0);if(demo_mode!=0)$fatal(1,"reset");
 $display("THREE_STYLE_KEYS PASS 3_models_wrap_bounce_hold_independent_simultaneous_reset_key3_alias=1");$finish;
 end
 initial begin #1000000;$fatal(1,"keys timeout");end
endmodule
