// CPU APB decode. B registers occupy 0x00..0x7c. Local 128-bit scheduler
// snapshots are exposed as 32-bit words at 0x100..0x13c. No alias/truncation.
module ab10_control(
 input wire clk,rstn,input wire [15:0] addr,input wire sel,enable,write,
 input wire [31:0] wdata,output wire ready,output wire [31:0] rdata,output wire error,
 output wire [15:0] paddr,output wire psel,penable,pwrite,output wire [31:0] pwdata,
 input wire pready,pslverr,input wire [31:0] prdata,
 output wire [31:0] local_addr,local_wdata,output wire local_write,input wire [127:0] local_rdata
);
 wire aligned=addr[1:0]==0;
 wire bsel=addr<16'h80&&aligned;
 wire lsel=addr>=16'h100&&addr<16'h140&&aligned;
 wire forbidden=write&&((bsel&&addr==0&&wdata[1])||(lsel&&addr!=16'h110));
 assign paddr=addr;assign pwdata=wdata;assign pwrite=write;
 assign psel=sel&&bsel&&!forbidden;assign penable=enable&&psel;
 assign local_addr={28'd0,addr[5:4],2'b0};assign local_wdata=wdata;
 assign local_write=sel&&enable&&write&&lsel&&!forbidden;
 assign ready=bsel&&!forbidden?pready:1'b1;
 assign error=forbidden||(!bsel&&!lsel)||(bsel&&pslverr);
 assign rdata=bsel?prdata:lsel?local_rdata[32*addr[3:2]+:32]:32'd0;
endmodule
