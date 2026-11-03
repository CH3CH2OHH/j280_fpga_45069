//=============================================================================
// 模块：uart_tx
// 文件：uart_tx.v
// 简述：UART 发送，8N1
//-----------------------------------------------------------------------------
// 功能说明
//   start 有效时锁存数据，按 起始位 -> 8 数据位 -> 停止位 的顺序串行输出，
//   发送期间 busy 保持高电平。
//
// 接口
//   data    input   待发字节
//   start   input   单拍启动
//   busy    output  发送中
//   txd     output  串行输出，空闲为高
//
// 参数
//   CLK_HZ / BAUD   分频系数由二者在综合期算出
//=============================================================================

`timescale 1ns / 1ps

module uart_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,      // 待发字节（start 那一拍有效）
    input  wire       start,     // 单拍启动脉冲
    output reg        busy,
    output reg        txd        // 空闲为高
);

    localparam integer DIV = (CLK_HZ + BAUD / 2) / BAUD;
    localparam integer CW  = $clog2(DIV);

    reg [CW-1:0] cnt;      // 位内计时
    reg [3:0]    bi;       // 位序号：0=起始，1~8=数据，9=停止
    reg [7:0]    sr;       // 移位寄存器，右移，先发 LSB

    always @(posedge clk) begin
        if (!rst_n) begin
            cnt  <= {CW{1'b0}};
            bi   <= 4'd0;
            sr   <= 8'd0;
            busy <= 1'b0;
            txd  <= 1'b1;            // 空闲电平为高
        end
        else if (!busy) begin
            txd <= 1'b1;
            if (start) begin
                busy <= 1'b1;
                cnt  <= {CW{1'b0}};
                bi   <= 4'd0;
                sr   <= data;
                txd  <= 1'b0;        // 起始位
            end
        end
        else begin
            if (cnt == DIV - 1) begin
                cnt <= {CW{1'b0}};
                if (bi == 4'd9) begin
                    busy <= 1'b0;    // 停止位发完
                    txd  <= 1'b1;
                end
                else if (bi == 4'd8) begin
                    txd <= 1'b1;     // 进入停止位
                    bi  <= 4'd9;
                end
                else begin
                    txd <= sr[0];    // 数据位 LSB 先出
                    sr  <= {1'b0, sr[7:1]};
                    bi  <= bi + 1'b1;
                end
            end
            else
                cnt <= cnt + 1'b1;
        end
    end

endmodule
