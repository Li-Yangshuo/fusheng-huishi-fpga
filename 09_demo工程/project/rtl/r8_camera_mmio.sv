// One acknowledged SC431HAI register transaction per C-driver command.
module r8_camera_mmio #(parameter CLK_DIV=659,TIMEOUT_CYCLES=2000000)(
 input wire clk,rstn,start,input wire [23:0] command,
 output reg busy,done,error,
 input wire scl_i,sda_i,output wire scl_o,scl_oen,sda_o,sda_oen
);
 reg [23:0] command_q;reg issue,issued;reg [31:0] elapsed;
 wire initialized,wr_done,wr_error;wire [2:0] address;wire wr,cs,ack;wire [7:0] wd,rd;
 i2c_16addr_8data #(.CLK_DIV(CLK_DIV)) transaction(
  .clk(clk),.rst_n(rstn),.din(command_q[7:0]),.addr(command_q[23:8]),.dout(),.dev_addr(8'h60),
  .init_done(initialized),.wr_en(issue),.rd_en(1'b0),.wr_done(wr_done),.wr_error(wr_error),
  .rd_done(),.dout_valid(),.i2c_address(address),.i2c_write(wr),.i2c_writedata(wd),
  .i2c_chipselect(cs),.i2c_waitrequest(1'b0),.i2c_readdata(rd));
 i2c_master_top master(.wb_clk_i(clk),.wb_rst_i(1'b0),.arst_i(rstn),
  .wb_adr_i(address),.wb_dat_i(wd),.wb_dat_o(rd),.wb_we_i(wr),.wb_stb_i(cs),
  .wb_ack_o(ack),.wb_inta_o(),.scl_pad_i(scl_i),.scl_pad_o(scl_o),.scl_padoen_o(scl_oen),
  .sda_pad_i(sda_i),.sda_pad_o(sda_o),.sda_padoen_o(sda_oen));
 always @(posedge clk or negedge rstn)begin
  if(!rstn)begin busy<=0;done<=0;error<=0;command_q<=0;issue<=0;issued<=0;elapsed<=0;end
  else begin
   issue<=0;
   if(start&&!busy&&!error)begin command_q<=command;busy<=1;done<=0;issued<=0;elapsed<=0;end
   if(busy)begin
    elapsed<=elapsed+1'b1;
    if(initialized&&!issued)begin issue<=1;issued<=1;end
    if(wr_error||elapsed==TIMEOUT_CYCLES-1)begin error<=1;busy<=0;done<=1;end
    else if(wr_done&&issued)begin done<=1;busy<=0;end
   end
  end
 end
endmodule
