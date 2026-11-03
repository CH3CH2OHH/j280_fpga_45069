//=============================================================================
// 模块：dig5
// 文件：dig5.v
// 简述：有符号数转 5 位十进制（含符号位）
//-----------------------------------------------------------------------------
// 功能说明
//   与 dig4 结构相同，量程扩到 ±99999，供摆臂位置显示使用。
//
// 接口
//   val    input   待拆位的有符号数
//   sgn    output  1 = 负
//   d4..d0 output  万位到个位
//
// 参数
//   MAXV   饱和上限
//
// 注意事项
//   余数位宽逐级收窄（<10000 / <1000 / <100），否则除法链会成为
//   全设计的关键路径。
//=============================================================================

`timescale 1ns / 1ps

module dig5 #(
    parameter integer MAXV = 99999
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [31:0] val,
    output reg                sgn,     // 1 = 负
    output reg  [3:0]         d4,      // 万位
    output reg  [3:0]         d3,      // 千位
    output reg  [3:0]         d2,      // 百位
    output reg  [3:0]         d1,      // 十位
    output reg  [3:0]         d0       // 个位
);

    localparam signed [31:0] MAX = MAXV;

    wire signed [31:0] c = (val >  MAX) ?  MAX :
                           (val < -MAX) ? -MAX : val;

    // 取绝对值：99999 需要 17 位
    wire [16:0] a = c[31] ? (~c[16:0] + 17'd1) : c[16:0];

    reg [16:0] a1;

    // 各级余数的真实取值范围（这是位宽收窄的依据）
    reg [13:0] r4, r4_d;      // < 10000  → 14 位
    reg [ 9:0] r3, r3_d;      // < 1000   → 10 位
    reg [ 6:0] r2, r2_d;      // < 100    →  7 位
    // 先保留完整商/余数，再显式取已由 MAXV 保证范围内的十进制位。
    wire [16:0] d4_full = a / 17'd10000;
    wire [16:0] r4_full = a1 - (d4 * 17'd10000);
    wire [13:0] d3_full = r4 / 14'd1000;
    wire [13:0] r3_full = r4_d - (d3 * 14'd1000);
    wire [ 9:0] d2_full = r3 / 10'd100;
    wire [ 9:0] r2_full = r3_d - (d2 * 10'd100);
    wire [ 6:0] d1_full = r2 / 7'd10;
    wire [ 6:0] d0_full = r2_d - (d1 * 7'd10);

    always @(posedge clk) begin
        if (!rst_n) begin
            sgn  <= 1'b0;
            a1   <= 17'd0;
            d4   <= 4'd0;
            r4   <= 14'd0;
            r4_d <= 14'd0;
            d3   <= 4'd0;
            r3   <= 10'd0;
            r3_d <= 10'd0;
            d2   <= 4'd0;
            r2   <= 7'd0;
            r2_d <= 7'd0;
            d1   <= 4'd0;
            d0   <= 4'd0;
        end
        else begin
            sgn  <= c[31];                        // E1
            a1   <= a;                            // E1
            d4   <= d4_full[3:0];                 // E1
            r4   <= r4_full[13:0];                // E2
            d3   <= d3_full[3:0];                 // E3
            r4_d <= r4;                           // E3
            r3   <= r3_full[9:0];                 // E4
            d2   <= d2_full[3:0];                 // E5
            r3_d <= r3;                           // E5
            r2   <= r2_full[6:0];                 // E6
            d1   <= d1_full[3:0];                 // E7
            r2_d <= r2;                           // E7
            d0   <= d0_full[3:0];                 // E8
        end
    end

endmodule
