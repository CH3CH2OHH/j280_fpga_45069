//=============================================================================
// 模块：dig4
// 文件：dig4.v
// 简述：有符号数转 4 位十进制（含符号位）
//-----------------------------------------------------------------------------
// 功能说明
//   取绝对值后按 1000/100/10 逐级做除法与乘减，8 级流水每级只做一次
//   除法或一次乘减。超量程时饱和到 ±MAXV。
//
// 接口
//   val   input   待拆位的有符号数
//   sgn   output  1 = 负
//   d3..d0  output 千位到个位
//
// 参数
//   MAXV  饱和上限
//
// 注意事项
//   各级余数位宽必须逐级收窄（<10000 -> <1000 -> <100），
//   统一用 32 位会让除法链过长，成为时序瓶颈。
//=============================================================================

`timescale 1ns / 1ps

module dig4 #(
    parameter integer MAXV = 9999
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [31:0] val,     // 待拆位的值
    output reg                sgn,     // 1 = 负
    output reg  [3:0]         d3,      // 千位
    output reg  [3:0]         d2,      // 百位
    output reg  [3:0]         d1,      // 十位
    output reg  [3:0]         d0       // 个位
);

    // 限幅到 ±MAXV（参数不能直接写进 32'sdXXX 这种带位宽的字面量里）
    localparam signed [31:0] MAX = MAXV;

    wire signed [31:0] c = (val >  MAX) ?  MAX :
                           (val < -MAX) ? -MAX : val;

    // 取绝对值（低 15 位够放 9999）
    wire [14:0] a = c[31] ? (~c[14:0] + 15'd1) : c[14:0];

    reg [14:0] a1;
    // 十进制余数分别小于 1000、100；按真实范围收窄可显著缩短常数除法路径。
    reg [9:0] rem3, rem3_d;
    reg [6:0] rem2, rem2_d;
    // 先保留完整商/余数，再显式取已由 MAXV 保证范围内的十进制位。
    wire [14:0] d3_full = a / 15'd1000;
    wire [14:0] rem3_full = a1 - (d3 * 15'd1000);
    wire [ 9:0] d2_full = rem3 / 10'd100;
    wire [ 9:0] rem2_full = rem3_d - (d2 * 10'd100);
    wire [ 6:0] d1_full = rem2 / 7'd10;
    wire [ 6:0] d0_full = rem2_d - (d1 * 7'd10);

    always @(posedge clk) begin
        if (!rst_n) begin
            sgn   <= 1'b0;
            a1    <= 15'd0;
            d3    <= 4'd0;
            rem3  <= 15'd0;
            rem3_d<= 15'd0;
            d2    <= 4'd0;
            rem2  <= 15'd0;
            rem2_d<= 15'd0;
            d1    <= 4'd0;
            d0    <= 4'd0;
        end
        else begin
            sgn    <= c[31];                      // E1
            a1     <= a;                          // E1
            d3     <= d3_full[3:0];               // E1
            rem3   <= rem3_full[9:0];             // E2
            d2     <= d2_full[3:0];               // E3
            rem3_d <= rem3;                       // E3
            rem2   <= rem2_full[6:0];             // E4
            d1     <= d1_full[3:0];               // E5
            rem2_d <= rem2;                       // E5
            d0     <= d0_full[3:0];               // E6
        end
    end

endmodule
