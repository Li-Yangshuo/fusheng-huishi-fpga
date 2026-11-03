// Immutable configuration image; one explicit synchronous 40-bit memory port.
module model_asset_rom #(parameter WORDS=4096,AW=$clog2(WORDS),INIT_FILE="model_assets.mem")(
 input wire clk,rd_en,input wire [AW-1:0] rd_addr,output reg [39:0] rd_data
);
 (* syn_ramstyle="block_ram" *) reg [39:0] mem[0:WORDS-1];
 initial $readmemh(INIT_FILE,mem);
 always @(posedge clk)if(rd_en)rd_data<=mem[rd_addr];
endmodule
