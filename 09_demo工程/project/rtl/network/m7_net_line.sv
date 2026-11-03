// Two line mailboxes. Pixel producer never backpressures the display.
// Descriptors and RAM are held stable from request toggle through acknowledge.
module m7_net_line #(parameter W=640)(
 input wire pclk,prstn,valid,input wire [9:0] x,input wire [8:0] y,
 input wire [23:0] rgb,input wire [31:0] fid,
 input wire tclk,trstn,input wire [1:0] ack,
 output reg [1:0] ready,input wire bank,input wire [9:0] address,
 output wire [15:0] data,
 output wire [31:0] desc_fid,desc_crc,output wire [8:0] desc_y,
 output reg [31:0] dropped_lines
);
 reg [1:0] req;
 (* async_reg="true" *) reg [1:0] a1,a2,r1;
 reg wb,active;reg [9:0] expected_x;reg [31:0] current_crc;
 reg [31:0] ids[0:1],crcs[0:1];reg [8:0] rows[0:1];
 wire free_bank=req[wb]==a2[wb];
 wire start=valid&&x==0&&free_bank;
 wire cont=active&&x==expected_x&&fid==ids[wb]&&y==rows[wb];
 wire write_pixel=prstn&&valid&&(start||(x!=0&&cont));
 wire [15:0] pixel={rgb[23:19],rgb[15:10],rgb[7:3]};
 function automatic [31:0] crc8(input [31:0] c,input [7:0] d);
 reg [31:0] v;integer i;begin v=c^{24'b0,d};for(i=0;i<8;i=i+1)v=v[0]?(v>>1)^32'hedb88320:(v>>1);crc8=v;end endfunction
 wire [31:0] next_crc=crc8(crc8(start?32'hffffffff:current_crc,pixel[7:0]),pixel[15:8]);
 simple_dual_port_ram #(.DATA_WIDTH(16),.ADDR_WIDTH(11),.OUTPUT_REG("FALSE")) pixels(
 .wclk(pclk),.we(write_pixel),.waddr({wb,x}),.wdata(pixel),
 .rclk(tclk),.re(1'b1),.raddr({bank,address}),.rdata(data));
 assign desc_fid=ids[bank];assign desc_crc=crcs[bank];assign desc_y=rows[bank];
 always @(posedge pclk or negedge prstn)
 if(!prstn)begin req<=0;a1<=0;a2<=0;wb<=0;active<=0;expected_x<=0;current_crc<=0;dropped_lines<=0;
 ids[0]<=0;ids[1]<=0;rows[0]<=0;rows[1]<=0;crcs[0]<=0;crcs[1]<=0;end
 else begin
 a1<=ack;a2<=a1;
 if(valid)begin
 if(x==0)begin active<=free_bank;expected_x<=1;
 if(free_bank)begin ids[wb]<=fid;rows[wb]<=y;end
 else dropped_lines<=dropped_lines+1;
 end else if(active)begin
 if(!cont)begin active<=0;dropped_lines<=dropped_lines+1;end
 else expected_x<=expected_x+1;
 end
 if(write_pixel)begin current_crc<=next_crc;
 if(x==W-1)begin crcs[wb]<=~next_crc;req[wb]<=~req[wb];wb<=~wb;active<=0;end
 end
 end
 end
 always @(posedge tclk or negedge trstn)
 if(!trstn)begin r1<=0;ready<=0;end else begin r1<=req;ready<=r1;end
endmodule
