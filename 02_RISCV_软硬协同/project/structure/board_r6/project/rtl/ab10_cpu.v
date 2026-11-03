module ab10_cpu(
 input wire clk,rstn,rx,dual_mode,input wire irq,output wire tx,output wire toggle,
 output wire [15:0] paddr,output wire psel,penable,pwrite,
 output wire [31:0] pwdata,input wire pready,pslverr,input wire [31:0] prdata,
 output wire [31:0] local_addr,local_wdata,output wire local_write,
 input wire [127:0] local_rdata,
 input wire [3:0] bid,rid,
 output wire flash_clk,flash_cs,flash_mosi,input wire flash_miso,
 output wire [3:0] awid,arid,output wire [31:0] awaddr,araddr,
 output wire [7:0] awlen,arlen,output wire awvalid,wvalid,arvalid,
 input wire awready,wready,arready,output wire [127:0] wdata,
 output wire [15:0] wstrb,output wire wlast,output wire bready,rready,
 input wire bvalid,rvalid,rlast,input wire [1:0] bresp,rresp,input wire [127:0] rdata,
 output wire [31:0] debug_pc,output wire [3:0] debug_trap_cause,
 output wire [31:0] debug_trap_value
);
// A21: RV32I management CPU with original, unmodified UART/SPI blocks.
// 0xf8100000 control map and boot image are preserved. CPU DDR was already
// disconnected in the R20 board top. Arbitrary Sapphire/CSR firmware is not
// binary compatible; use the delivered RV32I boot image and toolchain flags.
wire [31:0] ca,cd,cr;wire cs,ce,cw,cy,cerr;
wire trap;wire [3:0] trap_cause;wire [31:0] trap_value;
ab13_rv32i_manager #(.PADDR_WIDTH(32),.EXTENDED_MMIO(1)) cpu(
 .clk(clk),.rstn(rstn),.irq(irq),.paddr(ca),.psel(cs),.penable(ce),.pwrite(cw),
 .pwdata(cd),.prdata(cr),.pready(cy),.pslverr(cerr),
 .trap(trap),.trap_cause(trap_cause),.trap_value(trap_value),
 .debug_pc(debug_pc),
 .retire(),.retire_pc(),.retire_insn(),.retire_rd(),.retire_value());
wire ctl=ca[31:16]==16'hf810;
wire uart=ca[31:6]==(32'hf8010000>>6);
wire spi=ca[31:12]==(32'hf8014000>>12);
wire control_ready,control_error;wire [31:0] control_read;
ab10_control control(.clk(clk),.rstn(rstn),.addr(ca[15:0]),
 .sel(cs&&ctl),.enable(ce),.write(cw),.wdata(cd),
 .ready(control_ready),.rdata(control_read),.error(control_error),
 .paddr(paddr),.psel(psel),.penable(penable),.pwrite(pwrite),.pwdata(pwdata),
 .pready(pready),.pslverr(pslverr),.prdata(prdata),
 .local_addr(local_addr),.local_wdata(local_wdata),.local_write(local_write),.local_rdata(local_rdata));
// APB access -> one BMB command then its response. The CPU holds the entire
// request until PREADY, preventing duplicate writes while a response waits.
reg issued;
wire uc_ready,uc_valid,uc_error,sc_ready,sc_valid,sc_error;
wire [31:0] uc_data,sc_data;
wire cmd_valid=cs&&ce&&!issued;
wire response=issued&&(uart?uc_valid:sc_valid);
always @(posedge clk)begin
 if(!rstn)issued<=0;
 else if(!cs||!ce||response)issued<=0;
 else if(cmd_valid&&((uart&&uc_ready)||(spi&&sc_ready)))issued<=1;
end
assign cy=ctl?control_ready:(uart||spi)?response:1'b1;
assign cr=ctl?control_read:uart?uc_data:spi?sc_data:32'd0;
assign cerr=ctl?control_error:(uart||spi)?(uart?uc_error:sc_error):1'b1;
BmbUartCtrl uart_peripheral(
 .io_bus_cmd_valid(cmd_valid&&uart),.io_bus_cmd_ready(uc_ready),
 .io_bus_cmd_payload_last(1'b1),.io_bus_cmd_payload_fragment_opcode(cw),
 .io_bus_cmd_payload_fragment_address(ca[5:0]),.io_bus_cmd_payload_fragment_length(2'd3),
 .io_bus_cmd_payload_fragment_data(cd),.io_bus_cmd_payload_fragment_context(4'd0),
 .io_bus_rsp_valid(uc_valid),.io_bus_rsp_ready(cs&&ce&&uart&&issued),
 .io_bus_rsp_payload_last(),.io_bus_rsp_payload_fragment_opcode(uc_error),
 .io_bus_rsp_payload_fragment_data(uc_data),.io_bus_rsp_payload_fragment_context(),
 .io_uart_txd(tx),.io_uart_rxd(rx),.io_interrupt(),
 .io_systemClk(clk),.systemCd_logic_outputReset(!rstn));
BmbSpiXdrMasterCtrl spi_peripheral(
 .io_ctrl_cmd_valid(cmd_valid&&spi),.io_ctrl_cmd_ready(sc_ready),
 .io_ctrl_cmd_payload_last(1'b1),.io_ctrl_cmd_payload_fragment_opcode(cw),
 .io_ctrl_cmd_payload_fragment_address(ca[11:0]),.io_ctrl_cmd_payload_fragment_length(2'd3),
 .io_ctrl_cmd_payload_fragment_data(cd),.io_ctrl_cmd_payload_fragment_context(4'd0),
 .io_ctrl_rsp_valid(sc_valid),.io_ctrl_rsp_ready(cs&&ce&&spi&&issued),
 .io_ctrl_rsp_payload_last(),.io_ctrl_rsp_payload_fragment_opcode(sc_error),
 .io_ctrl_rsp_payload_fragment_data(sc_data),.io_ctrl_rsp_payload_fragment_context(),
 .io_spi_sclk_write(flash_clk),.io_spi_ss(flash_cs),
 .io_spi_data_0_writeEnable(),.io_spi_data_0_read(1'b1),.io_spi_data_0_write(flash_mosi),
 .io_spi_data_1_writeEnable(),.io_spi_data_1_read(flash_miso),.io_spi_data_1_write(),
 .io_spi_data_2_writeEnable(),.io_spi_data_2_read(1'b1),.io_spi_data_2_write(),
 .io_spi_data_3_writeEnable(),.io_spi_data_3_read(1'b1),.io_spi_data_3_write(),
 .io_interrupt(),.io_systemClk(clk),.systemCd_logic_outputReset(!rstn));
assign toggle=trap;
 // A25 observation only: preserve the original sticky trap behavior.
 assign debug_trap_cause=trap_cause;
 assign debug_trap_value=trap_value;
assign awid=0;assign arid=0;assign awaddr=0;assign araddr=0;
assign awlen=0;assign arlen=0;assign awvalid=0;assign arvalid=0;
assign wdata=0;assign wstrb=0;assign wvalid=0;assign wlast=0;
assign bready=0;assign rready=0;
endmodule
