`timescale 1ns/1ps
// A-only self-test: initialize a static 256x192 frame in DDR, then read source
// rows into a dual-clock cache. No neural accelerator or firmware is required.
module a8_ddr_display_test #(
    parameter [31:0] BASE_ADDR = 32'h02800000,
    parameter integer VIEW_X = 1120,
    parameter integer VIEW_Y = 300
)(
    input wire axi_clk, axi_rstn, cal_done,
    output wire [3:0] awid,
    output wire [31:0] awaddr,
    output wire [7:0] awlen,
    output wire awvalid,
    input wire awready,
    output wire [127:0] wdata,
    output wire wlast, wvalid,
    input wire wready,
    input wire [1:0] bresp,
    input wire bvalid,
    output wire bready,
    output wire [3:0] arid,
    output reg [31:0] araddr,
    output wire [7:0] arlen,
    output wire arvalid,
    input wire arready,
    input wire [127:0] rdata,
    input wire [1:0] rresp,
    input wire rlast, rvalid,
    output wire rready,
    output reg init_done,
    output reg axi_error,
    input wire pix_clk, pix_rstn,
    input wire i_de, i_hs, i_vs,
    input wire [23:0] i_rgb,
    output reg o_de, o_hs, o_vs,
    output reg [23:0] o_rgb,
    output reg underflow
);
    function [23:0] test_pixel;
        input [7:0] x, y;
        begin
            if (x < 2 || x >= 254 || y < 2 || y >= 190)
                test_pixel = 24'hffffff;
            else if (y < 64) begin
                case (x[7:5])
                    0: test_pixel = 24'hff0000;
                    1: test_pixel = 24'h00ff00;
                    2: test_pixel = 24'h0000ff;
                    3: test_pixel = 24'hffff00;
                    4: test_pixel = 24'h00ffff;
                    5: test_pixel = 24'hff00ff;
                    6: test_pixel = 24'hffffff;
                    7: test_pixel = 24'h000000;
                endcase
            end else if (y < 128)
                test_pixel = {x, y[5:0], 2'b00, ~x};
            else
                test_pixel = (x[4] ^ y[4]) ? 24'h00c8c8 : 24'hb020b0;
        end
    endfunction

    localparam WAIT_CAL=0, WRITE_AW=1, WRITE_W=2, WRITE_B=3,
               IDLE=4, READ_AR=5, READ_R=6, ERROR_STOP=7;
    reg [2:0] state;
    reg [13:0] wr_index;
    reg [3:0] beat_count;
    reg [5:0] row_beat;
    reg row_bad;
    wire [7:0] pattern_x = {wr_index[5:0],2'b00};
    wire [7:0] pattern_y = wr_index[13:6];
    assign awid=4'd2;
    assign arid=4'd2;
    assign awaddr=BASE_ADDR + {14'd0,wr_index,4'd0};
    assign awlen=8'd15;
    assign arlen=8'd15;
    assign awvalid=(state==WRITE_AW);
    assign wvalid=(state==WRITE_W);
    assign wlast=(beat_count==15);
    assign wdata={test_pixel(pattern_x+8'd3,pattern_y),8'h00,
                  test_pixel(pattern_x+8'd2,pattern_y),8'h00,
                  test_pixel(pattern_x+8'd1,pattern_y),8'h00,
                  test_pixel(pattern_x,pattern_y),8'h00};
    assign bready=(state==WRITE_B);
    assign arvalid=(state==READ_AR);
    assign rready=(state==READ_R);

    // Bundled-data mailbox: req_y remains fixed until the returned ack.
    reg req_toggle;
    reg [7:0] req_y;
    (* async_reg="true" *) reg [2:0] req_sync;
    (* async_reg="true" *) reg [7:0] req_y_sync0, req_y_sync1;
    reg ack_toggle, row_good;
    always @(posedge axi_clk or negedge axi_rstn) begin
        if (!axi_rstn) begin req_sync<=0; req_y_sync0<=0; req_y_sync1<=0; end
        else begin
            req_sync<={req_sync[1:0],req_toggle};
            req_y_sync0<=req_y; req_y_sync1<=req_y_sync0;
        end
    end
    wire cache_write=(state==READ_R) && rvalid && rready;
    wire [127:0] cache_rdata;
    reg [7:0] sx, sy;
    reg [2:0] phase_x, phase_y;
    reg [10:0] vx, vy;
    wire in_window=i_de && vx>=VIEW_X && vx<VIEW_X+640 &&
                        vy>=VIEW_Y && vy<VIEW_Y+480;
    reg [7:0] cached_y;
    reg cache_valid, pending, line_good;
    wire first_window=in_window && vx==VIEW_X;
    wire usable=cache_valid && cached_y==sy && !pending;
    wire read_good=first_window ? usable : line_good;
    simple_dual_port_ram #(.DATA_WIDTH(128), .ADDR_WIDTH(6),
        .OUTPUT_REG("FALSE"), .RAM_INIT_FILE("")) u_row_cache (
        .wdata(rdata), .waddr(row_beat), .we(cache_write), .wclk(axi_clk),
        .raddr(sx[7:2]), .re(in_window && read_good), .rclk(pix_clk),
        .rdata(cache_rdata)
    );

    always @(posedge axi_clk or negedge axi_rstn) begin
        if (!axi_rstn) begin
            state<=WAIT_CAL; wr_index<=0; beat_count<=0; row_beat<=0;
            row_bad<=0; init_done<=0; axi_error<=0; araddr<=0;
            ack_toggle<=0; row_good<=0;
        end else begin
            case (state)
                WAIT_CAL: if (cal_done) state<=WRITE_AW;
                WRITE_AW: if (awready) begin beat_count<=0; state<=WRITE_W; end
                WRITE_W: if (wready) begin
                    wr_index<=wr_index+1'b1;
                    beat_count<=beat_count+1'b1;
                    if (wlast) state<=WRITE_B;
                end
                WRITE_B: if (bvalid) begin
                    if (bresp!=0) begin axi_error<=1; state<=ERROR_STOP; end
                    else if (wr_index==14'd12288) begin init_done<=1; state<=IDLE; end
                    else state<=WRITE_AW;
                end
                IDLE: if (req_sync[2]!=ack_toggle) begin
                    araddr<=BASE_ADDR + {14'd0,req_y_sync1,10'd0};
                    row_beat<=0; beat_count<=0; row_bad<=0; state<=READ_AR;
                end
                READ_AR: if (arready) begin beat_count<=0; state<=READ_R; end
                READ_R: if (rvalid) begin
                    if (rresp!=0) begin axi_error<=1; row_bad<=1; end
                    if (rlast!=(beat_count==15)) begin
                        axi_error<=1; row_good<=0; state<=ERROR_STOP;
                    end else begin
                        row_beat<=row_beat+1'b1;
                        beat_count<=beat_count+1'b1;
                        if (rlast) begin
                            if (row_beat==63) begin
                                row_good<=!row_bad && rresp==0;
                                ack_toggle<=req_sync[2]; state<=IDLE;
                            end else begin
                                araddr<=araddr+32'd256; state<=READ_AR;
                            end
                        end
                    end
                end
                ERROR_STOP: state<=ERROR_STOP;
                default: state<=ERROR_STOP;
            endcase
        end
    end

    // Control has one more stage than bundled data before consuming a mailbox.
    (* async_reg="true" *) reg [2:0] ack_sync;
    (* async_reg="true" *) reg [1:0] init_sync, err_sync, good_sync;
    reg de_prev, vs_prev;
    wire frame_start=vs_prev && !i_vs;
    wire line_end=de_prev && !i_de;
    always @(posedge pix_clk or negedge pix_rstn) begin
        if (!pix_rstn) begin
            ack_sync<=0; init_sync<=0; err_sync<=0; good_sync<=0;
        end else begin
            ack_sync<={ack_sync[1:0],ack_toggle};
            init_sync<={init_sync[0],init_done};
            err_sync<={err_sync[0],axi_error};
            good_sync<={good_sync[0],row_good};
        end
    end
    always @(posedge pix_clk or negedge pix_rstn) begin
        if (!pix_rstn) begin
            req_toggle<=0; req_y<=0; pending<=0; cached_y<=0; cache_valid<=0;
            vx<=0; vy<=0; sx<=0; sy<=0; phase_x<=0; phase_y<=0;
            de_prev<=0; vs_prev<=0; line_good<=0; underflow<=0;
        end else begin
            de_prev<=i_de; vs_prev<=i_vs;
            if (pending && ack_sync[2]==req_toggle) begin
                pending<=0; cached_y<=req_y; cache_valid<=good_sync[1];
            end else if (!pending && init_sync[1] && !err_sync[1] &&
                         (!cache_valid || cached_y!=sy) && !in_window) begin
                req_y<=sy; req_toggle<=~req_toggle; pending<=1; cache_valid<=0;
            end
            if (frame_start) begin
                vx<=0; vy<=0; sx<=0; sy<=0; phase_x<=0; phase_y<=0;
                line_good<=0;
            end else begin
                if (!i_de) vx<=0;
                else if (vx<1919) vx<=vx+1'b1;
                if (line_end) vy<=vy+1'b1;
                if (!in_window) begin sx<=0; phase_x<=0; end
                else begin
                    if (first_window) begin
                        line_good<=usable;
                        if (!usable) underflow<=1;
                    end
                    if (phase_x>=3) begin sx<=sx+1'b1; phase_x<=phase_x-3'd3; end
                    else phase_x<=phase_x+3'd2;
                    if (vx==VIEW_X+639 && vy<VIEW_Y+479) begin
                        if (phase_y>=3) begin sy<=sy+1'b1; phase_y<=phase_y-3'd3; end
                        else phase_y<=phase_y+3'd2;
                    end
                end
            end
        end
    end

    reg de_d, hs_d, vs_d, window_d, good_d, right_d, marker_d;
    reg [23:0] camera_d;
    reg [1:0] lane_d;
    wire [31:0] selected_word=cache_rdata[32*lane_d +: 32];
    // One RAM-read stage and one output stage; sync and left pixels match it.
    always @(posedge pix_clk or negedge pix_rstn) begin
        if (!pix_rstn) begin
            de_d<=0; hs_d<=0; vs_d<=0; window_d<=0; good_d<=0;
            right_d<=0; marker_d<=0; camera_d<=0; lane_d<=0;
            o_de<=0; o_hs<=0; o_vs<=0; o_rgb<=0;
        end else begin
            de_d<=i_de; hs_d<=i_hs; vs_d<=i_vs;
            camera_d<=i_rgb; lane_d<=sx[1:0];
            window_d<=in_window; good_d<=read_good;
            right_d<=vx>=960;
            marker_d<=i_de && vx>=1856 && vx<1888 && vy>=32 && vy<64;
            o_de<=de_d; o_hs<=hs_d; o_vs<=vs_d;
            if (!de_d) o_rgb<=0;
            else if (!right_d) o_rgb<=camera_d;
            else if (marker_d) o_rgb<=err_sync[1] ? 24'hff0000 :
                underflow ? 24'hffff00 : init_sync[1] ? 24'h00ffff : 24'h404040;
            else if (window_d) o_rgb<=good_d ? selected_word[31:8] : 24'hff00ff;
            else o_rgb<=24'h101820;
        end
    end
endmodule
