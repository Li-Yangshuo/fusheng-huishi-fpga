///////////////////////////////////////////////////////////////////////////
// osd_fps.v
// 左上角叠加 "FPS:xx Pm"
//   xx = 摄像头实际帧率（由 cam_fps.v 在 MIPI 像素时钟域测得）
//   Pm = 当前彩色模式（m = 0..7，见 ti60f225_oob_top.v 的 bayer_mode）
// 设计原则：不用除法，避免综合异常。
// 一级寄存流水线。
///////////////////////////////////////////////////////////////////////////
module osd_fps (
    input        clk,
    input        rstn,
    input        i_de,
    input        i_hs,
    input        i_vs,
    input  [7:0] i_r,
    input  [7:0] i_g,
    input  [7:0] i_b,
    input  [6:0] i_fps,
    input  [3:0] i_mode,
    output reg       o_de,
    output reg       o_hs,
    output reg       o_vs,
    output reg [7:0] o_r,
    output reg [7:0] o_g,
    output reg [7:0] o_b
);

//===========================================================================
// 坐标计数
//===========================================================================
reg [11:0] x, y;
reg        de_d, vs_d;
wire de_rise = i_de & ~de_d;
wire vs_rise = i_vs & ~vs_d;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        de_d <= 1'b0; vs_d <= 1'b0;
        x <= 12'd0; y <= 12'd0;
    end else begin
        de_d <= i_de; vs_d <= i_vs;
        if (vs_rise) y <= 12'd0;
        if (de_rise) begin
            x <= 12'd0;
            if (!vs_rise) y <= y + 12'd1;
        end else if (i_de) begin
            x <= x + 12'd1;
        end
    end
end

//===========================================================================
// 十进制位（用比较链，不用除法）
//===========================================================================
wire [3:0] tens = (i_fps >= 7'd90) ? 4'd9 :
                  (i_fps >= 7'd80) ? 4'd8 :
                  (i_fps >= 7'd70) ? 4'd7 :
                  (i_fps >= 7'd60) ? 4'd6 :
                  (i_fps >= 7'd50) ? 4'd5 :
                  (i_fps >= 7'd40) ? 4'd4 :
                  (i_fps >= 7'd30) ? 4'd3 :
                  (i_fps >= 7'd20) ? 4'd2 :
                  (i_fps >= 7'd10) ? 4'd1 : 4'd0;
wire [3:0] ones = (i_fps > 7'd99) ? 4'd9 : (i_fps - tens * 7'd10);

//===========================================================================
// 叠加区域   10 个字符：F P S : 十 个 ' ' P 模式 ' '
//===========================================================================
wire in_box  = i_de & (x >= 12'd8)   & (x < 12'd184) &
                      (y >= 12'd8)   & (y < 12'd40);
wire in_text = i_de & (x >= 12'd16)  & (x < 12'd176) &
                      (y >= 12'd16)  & (y < 12'd32);

wire [3:0] cidx = (x - 12'd16) >> 4;
wire [2:0] fcol = ((x - 12'd16) >> 1) & 3'h7;
wire [2:0] frow = ((y - 12'd16) >> 1) & 3'h7;

// 当前字符序号 cidx: 0=F,1=P,2=S,3=:,4=十位,5=个位,6=空格,7=P,8=模式,9=空格
reg [3:0] cur_digit;
always @(*) begin
    case (cidx)
        4'd4: cur_digit = tens;
        4'd5: cur_digit = ones;
        4'd8: cur_digit = i_mode;
        default: cur_digit = 4'd0;
    endcase
end

// 字模行数据（纯组合 case，不用 function）
reg [7:0] grow;
always @(*) begin
    case (cidx)
        4'd0: begin // F
            case (frow)
                3'd0: grow=8'h7E; 3'd1: grow=8'h60; 3'd2: grow=8'h60; 3'd3: grow=8'h7C;
                3'd4: grow=8'h60; 3'd5: grow=8'h60; 3'd6: grow=8'h60; default: grow=8'h00;
            endcase
        end
        4'd1, 4'd7: begin // P
            case (frow)
                3'd0: grow=8'h7C; 3'd1: grow=8'h66; 3'd2: grow=8'h66; 3'd3: grow=8'h7C;
                3'd4: grow=8'h60; 3'd5: grow=8'h60; 3'd6: grow=8'h60; default: grow=8'h00;
            endcase
        end
        4'd2: begin // S
            case (frow)
                3'd0: grow=8'h3C; 3'd1: grow=8'h66; 3'd2: grow=8'h60; 3'd3: grow=8'h3C;
                3'd4: grow=8'h06; 3'd5: grow=8'h66; 3'd6: grow=8'h3C; default: grow=8'h00;
            endcase
        end
        4'd3: begin // :
            case (frow)
                3'd1: grow=8'h18; 3'd2: grow=8'h18;
                3'd4: grow=8'h18; 3'd5: grow=8'h18;
                default: grow=8'h00;
            endcase
        end
        4'd4, 4'd5, 4'd8: begin // 数字
            case (cur_digit)
                4'd0: case(frow)
                    3'd0: grow=8'h3C;3'd1: grow=8'h66;3'd2: grow=8'h66;3'd3: grow=8'h66;
                    3'd4: grow=8'h66;3'd5: grow=8'h66;3'd6: grow=8'h3C;default:grow=8'h00;
                endcase
                4'd1: case(frow)
                    3'd0: grow=8'h18;3'd1: grow=8'h38;3'd2: grow=8'h18;3'd3: grow=8'h18;
                    3'd4: grow=8'h18;3'd5: grow=8'h18;3'd6: grow=8'h7E;default:grow=8'h00;
                endcase
                4'd2: case(frow)
                    3'd0: grow=8'h3C;3'd1: grow=8'h66;3'd2: grow=8'h06;3'd3: grow=8'h0C;
                    3'd4: grow=8'h30;3'd5: grow=8'h60;3'd6: grow=8'h7E;default:grow=8'h00;
                endcase
                4'd3: case(frow)
                    3'd0: grow=8'h3C;3'd1: grow=8'h66;3'd2: grow=8'h06;3'd3: grow=8'h1C;
                    3'd4: grow=8'h06;3'd5: grow=8'h66;3'd6: grow=8'h3C;default:grow=8'h00;
                endcase
                4'd4: case(frow)
                    3'd0: grow=8'h06;3'd1: grow=8'h0E;3'd2: grow=8'h1E;3'd3: grow=8'h66;
                    3'd4: grow=8'h7E;3'd5: grow=8'h06;3'd6: grow=8'h06;default:grow=8'h00;
                endcase
                4'd5: case(frow)
                    3'd0: grow=8'h7E;3'd1: grow=8'h60;3'd2: grow=8'h7C;3'd3: grow=8'h06;
                    3'd4: grow=8'h06;3'd5: grow=8'h66;3'd6: grow=8'h3C;default:grow=8'h00;
                endcase
                4'd6: case(frow)
                    3'd0: grow=8'h3C;3'd1: grow=8'h66;3'd2: grow=8'h60;3'd3: grow=8'h7C;
                    3'd4: grow=8'h66;3'd5: grow=8'h66;3'd6: grow=8'h3C;default:grow=8'h00;
                endcase
                4'd7: case(frow)
                    3'd0: grow=8'h7E;3'd1: grow=8'h66;3'd2: grow=8'h0C;3'd3: grow=8'h18;
                    3'd4: grow=8'h18;3'd5: grow=8'h18;3'd6: grow=8'h18;default:grow=8'h00;
                endcase
                4'd8: case(frow)
                    3'd0: grow=8'h3C;3'd1: grow=8'h66;3'd2: grow=8'h66;3'd3: grow=8'h3C;
                    3'd4: grow=8'h66;3'd5: grow=8'h66;3'd6: grow=8'h3C;default:grow=8'h00;
                endcase
                4'd9: case(frow)
                    3'd0: grow=8'h3C;3'd1: grow=8'h66;3'd2: grow=8'h66;3'd3: grow=8'h3E;
                    3'd4: grow=8'h06;3'd5: grow=8'h66;3'd6: grow=8'h3C;default:grow=8'h00;
                endcase
                default: grow=8'h00;
            endcase
        end
        default: grow = 8'h00; // 空格
    endcase
end

wire pix = grow[7 - fcol];

//===========================================================================
// 输出寄存
//===========================================================================
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        o_de <= 1'b0; o_hs <= 1'b0; o_vs <= 1'b0;
        o_r <= 8'd0; o_g <= 8'd0; o_b <= 8'd0;
    end else begin
        o_de <= i_de;
        o_hs <= i_hs;
        o_vs <= i_vs;
        if (in_text && pix) begin
            o_r <= 8'd255; o_g <= 8'd255; o_b <= 8'd255;
        end else if (in_box) begin
            o_r <= 8'd0; o_g <= 8'd0; o_b <= 8'd0;
        end else begin
            o_r <= i_r; o_g <= i_g; o_b <= i_b;
        end
    end
end

endmodule
