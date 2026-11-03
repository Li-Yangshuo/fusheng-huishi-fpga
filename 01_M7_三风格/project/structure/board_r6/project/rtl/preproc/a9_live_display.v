`timescale 1ns/1ps
// A-only live loopback. Capture one complete frame, publish, and wait for the
// display's frame-boundary acknowledgement before reusing its old buffer.
module a9_live_display #(
    parameter [31:0] BASE_ADDR=32'h02800000,
    parameter [31:0] FRAME_STRIDE=32'h00030000,
    parameter integer VIEW_X=1120, VIEW_Y=300,
    parameter integer DDR_PROBE=0,
    parameter integer CAPTURE_PROBE=0
)(
    input wire cap_clk, cap_rstn, cap_de, cap_sof,
    input wire [23:0] cap_rgb,
    input wire axi_clk, axi_rstn, cal_done,
    output wire [3:0] awid, arid,
    output reg [31:0] awaddr, araddr,
    output wire [7:0] awlen, arlen,
    output wire awvalid, wlast, wvalid, bready, arvalid, rready,
    input wire awready, wready, bvalid, arready, rlast, rvalid,
    output wire [127:0] wdata,
    input wire [127:0] rdata,
    input wire [1:0] bresp, rresp,
    output reg init_done, axi_error,
    output reg capture_error,
    output reg [31:0] written_frames,
    input wire pix_clk, pix_rstn, i_de, i_hs, i_vs,
    input wire [23:0] i_rgb,
    output reg o_de, o_hs, o_vs,
    output reg [23:0] o_rgb,
    output reg underflow
);
    reg grant_toggle, grant_seen;
    (* async_reg="true" *) reg [2:0] grant_sync;
    reg cap_active, row_pending;
    reg cap_frame_fault,cap_row_fault;
    reg [9:0] cx;
    reg [8:0] cy;
    reg [2:0] xp, yp;
    reg [7:0] ox, oy;
    reg [95:0] pack_lo;
    reg row_req;
    reg [7:0] row_y;
    reg row_ack;
    (* async_reg="true" *) reg [2:0] row_ack_sync;
    wire start_capture=cap_sof && grant_sync[2]!=grant_seen && !capture_error;
    wire take_frame=start_capture || (cap_active && !cap_sof);
    wire [9:0] cur_x=cap_sof ? 10'd0 : cx;
    wire [8:0] cur_y=cap_sof ? 9'd0 : cy;
    wire [2:0] cur_xp=cap_sof ? 3'd0 : xp;
    wire [2:0] cur_yp=cap_sof ? 3'd0 : yp;
    wire [7:0] cur_ox=cap_sof ? 8'd0 : ox;
    wire [7:0] cur_oy=cap_sof ? 8'd0 : oy;
    wire row_available=!row_pending || row_ack_sync[2]==row_req;
    wire selected=cap_de && take_frame && !capture_error && row_available &&
                  (cur_xp==0 || cur_xp==2) && (cur_yp==0 || cur_yp==2);
    wire cap_write=selected && cur_ox[1:0]==3;
    // This pattern enters BEFORE packing and the dual-clock capture RAM.
    function [23:0] capture_probe_pixel;
        input [7:0] x,y;
        begin
            if(y[3:0]==0) capture_probe_pixel=24'h000000;
            else case(x[7:6])
                0: capture_probe_pixel=24'h00ffff;
                1: capture_probe_pixel=24'hff8000;
                2: capture_probe_pixel=24'h2060ff;
                default: capture_probe_pixel=24'hffffff;
            endcase
        end
    endfunction
    wire [23:0] capture_pixel=(CAPTURE_PROBE!=0 && cur_oy>=96 && cur_oy<144) ?
        capture_probe_pixel(cur_ox,cur_oy) : cap_rgb;
    wire [127:0] cap_word={capture_pixel,8'h00,pack_lo};
    wire [127:0] write_cache_data;
    reg [5:0] write_index;
    wire write_cache_read;
    simple_dual_port_ram #(.DATA_WIDTH(128),.ADDR_WIDTH(6),
        .OUTPUT_REG("FALSE"),.RAM_INIT_FILE("")) u_capture_row (
        .wclk(cap_clk),.we(cap_write),.waddr(cur_ox[7:2]),.wdata(cap_word),
        .rclk(axi_clk),.re(write_cache_read),.raddr(write_index),.rdata(write_cache_data));

    always @(posedge cap_clk or negedge cap_rstn) begin
        if(!cap_rstn) begin
            grant_sync<=0;row_ack_sync<=0;
        end else begin
            grant_sync<={grant_sync[1:0],grant_toggle};
            row_ack_sync<={row_ack_sync[1:0],row_ack};
        end
    end
    always @(posedge cap_clk or negedge cap_rstn) begin
        if(!cap_rstn) begin
            grant_seen<=0;cap_active<=0;row_pending<=0;capture_error<=0;
            cap_frame_fault<=0;cap_row_fault<=0;
            cx<=0;cy<=0;xp<=0;yp<=0;ox<=0;oy<=0;pack_lo<=0;row_req<=0;row_y<=0;
        end else begin
            if(row_pending && row_ack_sync[2]==row_req) row_pending<=0;
            if(cap_sof) begin
                if(cap_active || row_pending && row_ack_sync[2]!=row_req) begin
                    capture_error<=1;cap_active<=0;
                    if(cap_active) cap_frame_fault<=1;
                    if(row_pending && row_ack_sync[2]!=row_req) cap_row_fault<=1;
                end else begin
                    cap_active<=start_capture;
                    if(start_capture) grant_seen<=grant_sync[2];
                end
                cx<=0;cy<=0;xp<=0;yp<=0;ox<=0;oy<=0;
            end
            if(cap_de && take_frame && !capture_error) begin
                if(cur_x==0 && (cur_yp==0 || cur_yp==2) && !row_available) begin
                    capture_error<=1;cap_active<=0;
                    cap_row_fault<=1;
                end
                if(cur_x==639) begin
                    cx<=0;xp<=0;ox<=0;cy<=cur_y+1'b1;
                    yp<=cur_yp==4 ? 3'd0 : cur_yp+1'b1;
                    if(cur_y==479) cap_active<=0;
                end else begin
                    cx<=cur_x+1'b1;xp<=cur_xp==4 ? 3'd0 : cur_xp+1'b1;
                end
                if(selected) begin
                    case(cur_ox[1:0])
                        0: pack_lo[31:0]<={capture_pixel,8'h00};
                        1: pack_lo[63:32]<={capture_pixel,8'h00};
                        2: pack_lo[95:64]<={capture_pixel,8'h00};
                        default: begin end
                    endcase
                    ox<=cur_ox+1'b1;
                    if(cur_ox==255) begin
                        row_y<=cur_oy;oy<=cur_oy+1'b1;
                        row_req<=~row_req;row_pending<=1;
                    end
                end
            end
        end
    end

    // Row memory remains immutable until the last successful BRESP of that row.
    (* async_reg="true" *) reg [2:0] row_req_sync;
    (* async_reg="true" *) reg [7:0] row_y_sync0,row_y_sync1;
    (* async_reg="true" *) reg [1:0] cap_err_sync;
    reg published_bank, publish_toggle, commit_ack;
    (* async_reg="true" *) reg [2:0] commit_sync;
    reg write_bank;
    reg [7:0] expected_row;
    reg [1:0] write_burst;
    reg [3:0] write_beat;
    reg [127:0] write_hold;
    localparam W_CAL=0,W_ROW=1,W_AW=2,W_FETCH=3,W_LOAD=4,W_SEND=5,
               W_B=6,W_PUBLISH=7,W_STOP=8;
    reg [3:0] ws;
    assign awid=4'd2; assign awlen=8'd15;
    assign awvalid=ws==W_AW; assign wvalid=ws==W_SEND;
    assign wlast=write_beat==15; assign wdata=write_hold; assign bready=ws==W_B;
    assign write_cache_read=ws==W_FETCH;
    always @(posedge axi_clk or negedge axi_rstn) begin
        if(!axi_rstn) begin
            row_req_sync<=0;row_y_sync0<=0;row_y_sync1<=0;cap_err_sync<=0;commit_sync<=0;
        end else begin
            row_req_sync<={row_req_sync[1:0],row_req};
            row_y_sync0<=row_y;row_y_sync1<=row_y_sync0;
            cap_err_sync<={cap_err_sync[0],capture_error};
            commit_sync<={commit_sync[1:0],commit_ack};
        end
    end
    reg write_error;
    // Probe pixels bypass capture RAM but use exactly the same AXI transactions.
    function [23:0] probe_pixel;
        input [7:0] x,y;
        begin
            if(y<32) case(x[7:5])
                0: probe_pixel=24'hff0000;
                1: probe_pixel=24'h00ff00;
                2: probe_pixel=24'h0000ff;
                3: probe_pixel=24'hffff00;
                4: probe_pixel=24'h00ffff;
                5: probe_pixel=24'hff00ff;
                6: probe_pixel=24'hffffff;
                default: probe_pixel=24'h000000;
            endcase
            else if(y<64) probe_pixel={x,{y[4:0],3'b000},8'h80};
            else probe_pixel=(x[4]^y[3]) ? 24'h00ffff : 24'hff00ff;
        end
    endfunction
    wire [7:0] probe_x={write_index,2'b00};
    wire [127:0] probe_word={
        probe_pixel(probe_x+8'd3,expected_row),8'h00,
        probe_pixel(probe_x+8'd2,expected_row),8'h00,
        probe_pixel(probe_x+8'd1,expected_row),8'h00,
        probe_pixel(probe_x,expected_row),8'h00};
    always @(posedge axi_clk or negedge axi_rstn) begin
        if(!axi_rstn) begin
            ws<=W_CAL;grant_toggle<=0;row_ack<=0;write_bank<=0;expected_row<=0;
            write_burst<=0;write_beat<=0;write_index<=0;write_hold<=0;awaddr<=0;
            published_bank<=0;publish_toggle<=0;init_done<=0;write_error<=0;written_frames<=0;
        end else case(ws)
            W_CAL: if(cal_done) begin grant_toggle<=1;ws<=W_ROW;end
            W_ROW: if(cap_err_sync[1]) ws<=W_STOP;
                else if(row_req_sync[2]!=row_ack) begin
                    if(row_y_sync1!=expected_row) begin write_error<=1;ws<=W_STOP;end
                    else begin
                        awaddr<=BASE_ADDR+(write_bank ? FRAME_STRIDE : 32'd0)+{14'd0,expected_row,10'd0};
                        write_burst<=0;write_index<=0;ws<=W_AW;
                    end
                end
            W_AW: if(awready) begin write_beat<=0;ws<=W_FETCH;end
            W_FETCH: ws<=W_LOAD;
            W_LOAD: begin
                write_hold<=(DDR_PROBE!=0 && expected_row<96) ? probe_word : write_cache_data;
                ws<=W_SEND;
            end
            W_SEND: if(wready) begin
                write_index<=write_index+1'b1;write_beat<=write_beat+1'b1;
                ws<=wlast ? W_B : W_FETCH;
            end
            W_B: if(bvalid) begin
                if(bresp!=0) begin write_error<=1;ws<=W_STOP;end
                else if(write_burst!=3) begin
                    write_burst<=write_burst+1'b1;awaddr<=awaddr+32'd256;ws<=W_AW;
                end else begin
                    row_ack<=row_req_sync[2];
                    if(expected_row==191) begin
                        if(cap_err_sync[1]) ws<=W_STOP;
                        else begin
                            published_bank<=write_bank;publish_toggle<=~publish_toggle;
                            init_done<=1;written_frames<=written_frames+1'b1;ws<=W_PUBLISH;
                        end
                    end else begin expected_row<=expected_row+1'b1;ws<=W_ROW;end
                end
            end
            W_PUBLISH: if(cap_err_sync[1]) ws<=W_STOP;
                else if(commit_sync[2]==publish_toggle) begin
                    write_bank<=~write_bank;expected_row<=0;
                    grant_toggle<=~grant_toggle;ws<=W_ROW;
                end
            default: ws<=W_STOP;
        endcase
    end

    reg req_toggle,req_bank,ack_toggle,row_good;
    reg [7:0] req_y;
    (* async_reg="true" *) reg [2:0] req_sync;
    (* async_reg="true" *) reg [7:0] req_y_sync0,req_y_sync1;
    (* async_reg="true" *) reg [1:0] req_bank_sync;
    reg [5:0] row_beat;
    reg [5:0] beat_count;
    reg row_bad,read_error;
    localparam R_IDLE=0,R_AR=1,R_DATA=2,R_STOP=3;
    reg [1:0] rs;
    assign arid=4'd2;assign arlen=8'd63;
    assign arvalid=rs==R_AR;assign rready=rs==R_DATA;
    always @(posedge axi_clk or negedge axi_rstn) begin
        if(!axi_rstn) begin req_sync<=0;req_y_sync0<=0;req_y_sync1<=0;req_bank_sync<=0;end
        else begin
            req_sync<={req_sync[1:0],req_toggle};
            req_y_sync0<=req_y;req_y_sync1<=req_y_sync0;
            req_bank_sync<={req_bank_sync[0],req_bank};
        end
    end
    always @(posedge axi_clk or negedge axi_rstn) begin
        if(!axi_rstn) begin
            rs<=R_IDLE;row_beat<=0;beat_count<=0;row_bad<=0;araddr<=0;
            ack_toggle<=0;row_good<=0;read_error<=0;axi_error<=0;
        end else begin
            axi_error<=write_error || read_error;
            case(rs)
                R_IDLE: if(req_sync[2]!=ack_toggle) begin
                    araddr<=BASE_ADDR+(req_bank_sync[1] ? FRAME_STRIDE : 32'd0)+{14'd0,req_y_sync1,10'd0};
                    row_beat<=0;beat_count<=0;row_bad<=0;rs<=R_AR;
                end
                R_AR: if(arready) begin beat_count<=0;rs<=R_DATA;end
                R_DATA: if(rvalid) begin
                    if(rresp!=0) begin read_error<=1;row_bad<=1;end
                    if(rlast!=(beat_count==63)) begin read_error<=1;row_good<=0;rs<=R_STOP;end
                    else begin
                        row_beat<=row_beat+1'b1;beat_count<=beat_count+1'b1;
                        if(rlast) begin
                            row_good<=!row_bad && rresp==0;ack_toggle<=req_sync[2];rs<=R_IDLE;
                        end
                    end
                end
                default: rs<=R_STOP;
            endcase
        end
    end

    reg [7:0] sx,sy,cached_y;
    reg [2:0] phase_x,phase_y;
    reg [10:0] vx,vy;
    reg display_bank,has_frame,cache_valid,pending,line_good;
    wire in_window=i_de && vx>=VIEW_X && vx<VIEW_X+640 && vy>=VIEW_Y && vy<VIEW_Y+480;
    wire first_window=in_window && vx==VIEW_X;
    wire usable=cache_valid && cached_y==sy && !pending;
    wire read_good=first_window ? usable : line_good;
    wire [127:0] cache_rdata;
    simple_dual_port_ram #(.DATA_WIDTH(128),.ADDR_WIDTH(6),
        .OUTPUT_REG("FALSE"),.RAM_INIT_FILE("")) u_row_cache (
        .wdata(rdata),.waddr(row_beat),.we(rs==R_DATA && rvalid && rready),.wclk(axi_clk),
        .raddr(sx[7:2]),.re(in_window && read_good),.rclk(pix_clk),.rdata(cache_rdata));
    (* async_reg="true" *) reg [2:0] ack_sync,publish_sync;
    (* async_reg="true" *) reg [1:0] err_sync,good_sync,bank_sync,cap_error_sync;
    (* async_reg="true" *) reg [1:0] fault_sync0,fault_sync1;
    reg de_prev,vs_prev;
    wire frame_start=vs_prev && !i_vs;
    wire line_end=de_prev && !i_de;
    wire switch_frame=frame_start && !pending && publish_sync[2]!=commit_ack;
    always @(posedge pix_clk or negedge pix_rstn) begin
        if(!pix_rstn) begin
            ack_sync<=0;publish_sync<=0;err_sync<=0;good_sync<=0;bank_sync<=0;cap_error_sync<=0;
            fault_sync0<=0;fault_sync1<=0;
        end else begin
            ack_sync<={ack_sync[1:0],ack_toggle};publish_sync<={publish_sync[1:0],publish_toggle};
            err_sync<={err_sync[0],axi_error};good_sync<={good_sync[0],row_good};
            bank_sync<={bank_sync[0],published_bank};cap_error_sync<={cap_error_sync[0],capture_error};
            fault_sync0<={cap_row_fault,cap_frame_fault};fault_sync1<=fault_sync0;
        end
    end
    always @(posedge pix_clk or negedge pix_rstn) begin
        if(!pix_rstn) begin
            req_toggle<=0;req_y<=0;req_bank<=0;pending<=0;cached_y<=0;cache_valid<=0;
            display_bank<=0;has_frame<=0;commit_ack<=0;
            vx<=0;vy<=0;sx<=0;sy<=0;phase_x<=0;phase_y<=0;
            de_prev<=0;vs_prev<=0;line_good<=0;underflow<=0;
        end else begin
            de_prev<=i_de;vs_prev<=i_vs;
            if(switch_frame) begin
                display_bank<=bank_sync[1];has_frame<=1;commit_ack<=publish_sync[2];cache_valid<=0;
            end else if(pending && ack_sync[2]==req_toggle) begin
                pending<=0;cached_y<=req_y;cache_valid<=good_sync[1];
            end else if(!pending && has_frame && !err_sync[1] &&
                        (!cache_valid || cached_y!=sy) && !in_window && !frame_start) begin
                req_y<=sy;req_bank<=display_bank;req_toggle<=~req_toggle;pending<=1;cache_valid<=0;
            end
            if(frame_start) begin
                vx<=0;vy<=0;sx<=0;sy<=0;phase_x<=0;phase_y<=0;line_good<=0;
            end else begin
                if(!i_de) vx<=0;else if(vx<1919) vx<=vx+1'b1;
                if(line_end) vy<=vy+1'b1;
                if(!in_window) begin sx<=0;phase_x<=0;end
                else begin
                    if(first_window) begin
                        line_good<=usable;if(has_frame && !usable) underflow<=1;
                    end
                    if(phase_x>=3) begin sx<=sx+1'b1;phase_x<=phase_x-3'd3;end
                    else phase_x<=phase_x+3'd2;
                    if(vx==VIEW_X+639 && vy<VIEW_Y+479) begin
                        if(phase_y>=3) begin sy<=sy+1'b1;phase_y<=phase_y-3'd3;end
                        else phase_y<=phase_y+3'd2;
                    end
                end
            end
        end
    end
    reg de_d,hs_d,vs_d,window_d,good_d,right_d,marker_d,probe_marker_d,fault_marker_d;
    reg [23:0] camera_d;
    reg [1:0] lane_d;
    wire [31:0] selected_word=cache_rdata[32*lane_d +: 32];
    always @(posedge pix_clk or negedge pix_rstn) begin
        if(!pix_rstn) begin
            de_d<=0;hs_d<=0;vs_d<=0;window_d<=0;good_d<=0;right_d<=0;marker_d<=0;probe_marker_d<=0;
            fault_marker_d<=0;
            camera_d<=0;lane_d<=0;o_de<=0;o_hs<=0;o_vs<=0;o_rgb<=0;
        end else begin
            de_d<=i_de;hs_d<=i_hs;vs_d<=i_vs;camera_d<=i_rgb;lane_d<=sx[1:0];
            window_d<=in_window;good_d<=read_good;right_d<=vx>=960;
            marker_d<=i_de && vx>=1856 && vx<1888 && vy>=32 && vy<64;
            probe_marker_d<=DDR_PROBE!=0 && i_de && vx>=1808 && vx<1840 && vy>=32 && vy<64;
            fault_marker_d<=CAPTURE_PROBE!=0 && i_de && vx>=1760 && vx<1792 && vy>=32 && vy<64;
            o_de<=de_d;o_hs<=hs_d;o_vs<=vs_d;
            if(!de_d) o_rgb<=0;
            else if(!right_d) o_rgb<=camera_d;
            else if(fault_marker_d) case(fault_sync1)
                1: o_rgb<=24'hffffff;
                2: o_rgb<=24'hffff00;
                3: o_rgb<=24'hff8000;
                default: o_rgb<=24'h404040;
            endcase
            else if(probe_marker_d) o_rgb<=CAPTURE_PROBE==2 ? 24'hffff00 :
                                         CAPTURE_PROBE!=0 ? 24'hff8000 : 24'h2080ff;
            else if(marker_d) o_rgb<=err_sync[1] ? 24'hff0000 : cap_error_sync[1] ? 24'hff00ff :
                underflow ? 24'hffff00 : has_frame ? 24'h00ff80 : 24'h404040;
            else if(window_d) o_rgb<=!has_frame ? 24'h101820 : good_d ? selected_word[31:8] : 24'hff00ff;
            else o_rgb<=24'h101820;
        end
    end
endmodule
