`ifndef NST_CPU_BOOT_MEM
`define NST_CPU_BOOT_MEM "cpu_boot.mem"
`endif
// Generic SpinalHDL RAM interfaces emitted by the installed generator.
// Synchronous read holds its output when disabled; read/write collisions are
// don't-care, as requested by every generated instance. No reset clears memory.
module Ram_1w_1rs #(
 parameter wordCount=32,wordWidth=32,clockCrossing=0,technology="auto",readUnderWrite="dontCare",
 parameter wrAddressWidth=$clog2(wordCount),wrDataWidth=wordWidth,wrMaskWidth=1,wrMaskEnable=0,
 parameter rdAddressWidth=$clog2(wordCount),rdDataWidth=wordWidth
)(input wr_clk,wr_en,input [wrMaskWidth-1:0] wr_mask,input [wrAddressWidth-1:0] wr_addr,
 input [wrDataWidth-1:0] wr_data,input rd_clk,rd_en,input [rdAddressWidth-1:0] rd_addr,
 output reg [rdDataWidth-1:0] rd_data);
 localparam RAMSTYLE="block_ram";
 (* syn_ramstyle=RAMSTYLE *) reg [wordWidth-1:0] mem[0:wordCount-1];
 localparam LANE=wordWidth/wrMaskWidth;
 genvar i;
 generate if(wrMaskEnable)begin:masked
  for(i=0;i<wrMaskWidth;i=i+1)begin:lane
   always @(posedge wr_clk)if(wr_en&&wr_mask[i])mem[wr_addr][i*LANE+:LANE]<=wr_data[i*LANE+:LANE];
  end
 end else begin:whole
  always @(posedge wr_clk)if(wr_en)mem[wr_addr]<=wr_data;
 end endgenerate
 always @(posedge rd_clk)if(rd_en)rd_data<=mem[rd_addr];
endmodule

module Ram_1wrs #(
 parameter wordCount=1024,wordWidth=32,readUnderWrite="dontCare",duringWrite="dontCare",technology="auto",
 parameter maskWidth=4,maskEnable=1
)(input clk,en,wr,input [$clog2(wordCount)-1:0] addr,input [maskWidth-1:0] mask,
 input [wordWidth-1:0] wrData,output reg [wordWidth-1:0] rdData);
 localparam RAMSTYLE="block_ram";
 (* syn_ramstyle=RAMSTYLE *) reg [wordWidth-1:0] mem[0:wordCount-1];
 `ifdef NST_CPU_BOOT_MEM
 initial $readmemh(`NST_CPU_BOOT_MEM,mem);
 `endif
 localparam LANE=wordWidth/maskWidth;
 genvar i;
 generate if(maskEnable)begin:masked
  for(i=0;i<maskWidth;i=i+1)begin:lane
   always @(posedge clk)if(en&&wr&&mask[i])mem[addr][i*LANE+:LANE]<=wrData[i*LANE+:LANE];
  end
 end else begin:whole
  always @(posedge clk)if(en&&wr)mem[addr]<=wrData;
 end endgenerate
 always @(posedge clk)if(en)rdData<=mem[addr];
endmodule

module Ram_1w_1ra #(
 parameter wordCount=32,wordWidth=32,technology="auto",readUnderWrite="dontCare",
 parameter wrAddressWidth=$clog2(wordCount),wrDataWidth=wordWidth,wrMaskWidth=1,wrMaskEnable=0,
 parameter rdAddressWidth=$clog2(wordCount),rdDataWidth=wordWidth
)(input clk,wr_en,input [wrMaskWidth-1:0] wr_mask,input [wrAddressWidth-1:0] wr_addr,
 input [wrDataWidth-1:0] wr_data,input [rdAddressWidth-1:0] rd_addr,output [rdDataWidth-1:0] rd_data);
 localparam RAMSTYLE="block_ram";
 (* syn_ramstyle=RAMSTYLE *) reg [wordWidth-1:0] mem[0:wordCount-1];
 localparam LANE=wordWidth/wrMaskWidth;
 genvar i;
 generate if(wrMaskEnable)begin:masked
  for(i=0;i<wrMaskWidth;i=i+1)begin:lane
   always @(posedge clk)if(wr_en&&wr_mask[i])mem[wr_addr][i*LANE+:LANE]<=wr_data[i*LANE+:LANE];
  end
 end else begin:whole
  always @(posedge clk)if(wr_en)mem[wr_addr]<=wr_data;
 end endgenerate
 assign rd_data=mem[rd_addr];
endmodule
