// Common-clock statistics store. One update each clock, with forwarding for
// consecutive updates to the same channel. Layer clear resets only validity.
// Software reads only after busy is false and the sequencer publishes WAIT.
`timescale 1ns/1ps
module nst_stats_ram #(parameter SUM_W=48)(
    input wire clk, srst, clear,
    input wire update,
    input wire [4:0] channel,
    input wire signed [31:0] value,
    input wire signed [63:0] square,
    input wire [6:0] query_idx,
    output wire [63:0] query_word,
    output wire busy
);
    localparam DW=SUM_W+64;
    (* ram_style="block" *) reg [DW-1:0] mem [0:31];
    reg [DW-1:0] read_data;
    reg [31:0] seen;
    reg d_valid,d_fresh;
    reg [4:0] d_channel;
    reg signed [31:0] d_value;
    reg signed [63:0] d_square;
    reg previous_valid;
    reg [4:0] previous_channel;
    reg [DW-1:0] previous_data;
    reg query_known,query_square,query_read;
    wire [DW-1:0] base_data = d_fresh ? {DW{1'b0}} :
        (previous_valid && previous_channel==d_channel) ? previous_data : read_data;
    wire signed [SUM_W-1:0] next_sum = $signed(base_data[DW-1:64]) + d_value;
    wire [63:0] next_square = base_data[63:0] + d_square;
    wire [DW-1:0] next_data = {next_sum,next_square};
    always @(posedge clk)begin
        read_data <= mem[update ? channel : query_idx[5:1]];
        if(!srst && !clear && d_valid)mem[d_channel]<=next_data;
    end
    always @(posedge clk)begin
        if(srst || clear)begin
            seen<=0;d_valid<=0;previous_valid<=0;query_known<=0;
            query_read<=0;query_square<=0;
        end else begin
            d_valid<=update;
            if(update)begin
                seen[channel]<=1;
                d_channel<=channel;d_value<=value;d_square<=square;
                d_fresh<=!seen[channel];
            end
            previous_valid<=d_valid;
            if(d_valid)begin
                previous_channel<=d_channel;previous_data<=next_data;
            end
            query_read<=!update;
            query_known<=seen[query_idx[5:1]] && !query_idx[6];
            query_square<=query_idx[0];
        end
    end
    assign busy=update || d_valid;
    assign query_word=(!query_read || !query_known) ? 64'd0 :
        query_square ? read_data[63:0] :
        {{(64-SUM_W){read_data[DW-1]}},read_data[DW-1:64]};
endmodule
