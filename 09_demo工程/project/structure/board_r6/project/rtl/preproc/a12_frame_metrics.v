`timescale 1ns/1ps
module a12_frame_metrics #(
    parameter integer RGB_LINE_BEATS=960,
    parameter integer RGB_LINES=1080,
    parameter integer PP_PIXELS=307200
)(
    input wire clk,rstn,rgb_vs,rgb_de,pp_sof,pp_de,cvo_underflow,capture_fault,
    input wire [31:0] raw_samples,raw_ddr_beats,
    input wire raw_ready,video_ready,
    input wire raw_stable,input wire [3:0] writer_error,
    input wire [15:0] cvo_uf_v,cvo_uf_h,
    output wire [415:0] metrics
);
    reg vs_d,de_d,uf_d,rgb_armed,pp_armed,frozen;
    reg [15:0] uf_count,frame_count;
    reg [31:0] rgb_count,pp_count,last_rgb_count,last_pp_count;
    reg [15:0] line_count,row_count,bad_count,bad_length;
    reg [15:0] last_rows,last_bad,last_bad_length;
    reg rgb_valid,pp_valid;
    reg [287:0] fault_hold;
    wire boundary=rgb_vs && !vs_d;
    wire line_end=de_d && !rgb_de && line_count!=0;
    wire open_line=line_count!=0;
    wire [15:0] closed_rows=row_count+(open_line ? 16'd1:16'd0);
    wire [15:0] closed_bad=bad_count+((open_line && line_count!=RGB_LINE_BEATS) ? 16'd1:16'd0);
    wire [31:0] status={26'd0,capture_fault,
        (pp_valid && last_pp_count==PP_PIXELS),
        (rgb_valid && last_rgb_count==RGB_LINE_BEATS*RGB_LINES && last_rows==RGB_LINES && last_bad==0),
        pp_valid,rgb_valid,frozen};
    // A14: [287:256] = raster position {v_cnt,h_cnt} of the first read underflow.
    // All A12/A13 bit positions are unchanged, so the lower 256 bits keep their meaning.
    wire [287:0] live={{cvo_uf_v,cvo_uf_h},status,{16'd0,frame_count},last_pp_count,
        {16'd0,last_bad_length},{16'd0,last_bad},{16'd0,last_rows},
        last_rgb_count,{16'd0,uf_count}};
    // Keep the old fault snapshot while new source-side evidence and writer
    // error code remain live.  This distinguishes a short RAW frame from an
    // AXI starvation case after the first CVO fault freezes the old fields.
    assign metrics={{30'd0,video_ready,raw_ready},{27'd0,raw_stable,writer_error},raw_ddr_beats,
                    raw_samples,(frozen ? fault_hold : live)};
    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            vs_d<=0;de_d<=0;uf_d<=0;rgb_armed<=0;pp_armed<=0;frozen<=0;
            uf_count<=0;frame_count<=0;rgb_count<=0;pp_count<=0;
            line_count<=0;row_count<=0;bad_count<=0;bad_length<=0;
            last_rgb_count<=0;last_pp_count<=0;last_rows<=0;
            last_bad<=0;last_bad_length<=0;rgb_valid<=0;pp_valid<=0;fault_hold<=0;
        end else begin
            vs_d<=rgb_vs;de_d<=rgb_de;uf_d<=cvo_underflow;
            if(cvo_underflow && !uf_d && uf_count!=16'hffff) uf_count<=uf_count+1'b1;
            if(boundary) begin
                if(rgb_armed) begin
                    last_rgb_count<=rgb_count;last_rows<=closed_rows;last_bad<=closed_bad;
                    last_bad_length<=(open_line && line_count!=RGB_LINE_BEATS) ? line_count : bad_length;
                    rgb_valid<=1;
                    if(frame_count!=16'hffff) frame_count<=frame_count+1'b1;
                end
                rgb_armed<=1;rgb_count<=rgb_de ? 32'd1:32'd0;
                line_count<=rgb_de ? 16'd1:16'd0;row_count<=0;bad_count<=0;bad_length<=0;
            end else if(rgb_armed) begin
                if(rgb_de) begin rgb_count<=rgb_count+1'b1;line_count<=line_count+1'b1;end
                if(line_end) begin
                    row_count<=row_count+1'b1;line_count<=0;
                    if(line_count!=RGB_LINE_BEATS) begin
                        bad_count<=bad_count+1'b1;bad_length<=line_count;
                    end
                end
            end
            if(pp_sof) begin
                if(pp_armed) begin last_pp_count<=pp_count;pp_valid<=1;end
                pp_armed<=1;pp_count<=pp_de ? 32'd1:32'd0;
            end else if(pp_armed && pp_de) pp_count<=pp_count+1'b1;
            // Fault arrives one cycle after the SOF which closes the PP sample.
            if(capture_fault && !frozen) begin
                frozen<=1;fault_hold<=live | (288'd1<<224);
            end
        end
    end
endmodule

// Bundled-data handshake: source bus is held until the receiver acknowledges.
module a12_snapshot_cdc #(parameter WIDTH=288)(
    input wire src_clk,src_rstn,input wire [WIDTH-1:0] src_data,
    input wire dst_clk,dst_rstn,output reg [WIDTH-1:0] dst_data
);
    reg [WIDTH-1:0] src_hold;
    reg request,ack;
    (* async_reg="true" *) reg [2:0] ack_sync,req_sync;
    always @(posedge src_clk or negedge src_rstn) begin
        if(!src_rstn) begin src_hold<=0;request<=0;ack_sync<=0;end
        else begin
            ack_sync<={ack_sync[1:0],ack};
            if(ack_sync[2]==request) begin src_hold<=src_data;request<=~request;end
        end
    end
    always @(posedge dst_clk or negedge dst_rstn) begin
        if(!dst_rstn) begin dst_data<=0;req_sync<=0;ack<=0;end
        else begin
            req_sync<={req_sync[1:0],request};
            if(req_sync[2]!=ack) begin dst_data<=src_hold;ack<=req_sync[2];end
        end
    end
endmodule
