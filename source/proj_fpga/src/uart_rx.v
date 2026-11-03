//=============================================================================
// 模块：uart_rx
// 文件：uart_rx.v
// 简述：UART 接收，8N1
//-----------------------------------------------------------------------------
// 功能说明
//   检测起始位下降沿后在位周期中点采样 8 个数据位，校验停止位，
//   每收到一个字节输出一拍 rx_dv。
//
// 接口
//   rxd         input   串行输入
//   rx_data     output  接收到的字节
//   rx_dv       output  字节有效，单拍
//   frame_err   output  停止位校验失败
//
// 参数
//   CLK_HZ / BAUD   分频系数由二者在综合期算出
//
// 注意事项
//   J280 上 FPGA 的 RX 是 L20，TX 是 K20。
//   用户手册 3.2.7 节的接线说明列把这两者写反了。
//=============================================================================

`timescale 1ns / 1ps

module uart_rx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rxd,
    output reg  [7:0] rx_data,
    output reg        rx_dv,        // 收到一个字节，单拍
    output reg        frame_err     // 停止位不是 1
);

    localparam integer DIV  = (CLK_HZ + BAUD / 2) / BAUD;
    localparam integer HALF = DIV / 2;

    // 输入同步
    reg r0, r1;
    always @(posedge clk) begin
        r0 <= rxd;
        r1 <= r0;
    end

    localparam [2:0] S_IDLE = 3'd0,
                     S_START= 3'd1,
                     S_DATA = 3'd2,
                     S_STOP = 3'd3;

    reg [2:0]  st;
    reg [15:0] cnt;
    reg [2:0]  bit_i;
    reg [7:0]  sh;

    always @(posedge clk) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            cnt       <= 16'd0;
            bit_i     <= 3'd0;
            sh        <= 8'd0;
            rx_data   <= 8'd0;
            rx_dv     <= 1'b0;
            frame_err <= 1'b0;
        end
        else begin
            rx_dv <= 1'b0;

            case (st)
            S_IDLE: begin
                cnt <= 16'd0;
                if (!r1) st <= S_START;      // 下降沿（空闲为高）
            end

            S_START: begin
                if (cnt == HALF - 1) begin
                    cnt <= 16'd0;
                    if (!r1) begin           // 半位后仍为低 → 真起始位
                        st    <= S_DATA;
                        bit_i <= 3'd0;
                    end
                    else
                        st <= S_IDLE;        // 毛刺，丢弃
                end
                else
                    cnt <= cnt + 1'b1;
            end

            S_DATA: begin
                if (cnt == DIV - 1) begin
                    cnt <= 16'd0;
                    sh  <= {r1, sh[7:1]};    // LSB first
                    if (bit_i == 3'd7)
                        st <= S_STOP;
                    else
                        bit_i <= bit_i + 1'b1;
                end
                else
                    cnt <= cnt + 1'b1;
            end

            S_STOP: begin
                if (cnt == DIV - 1) begin
                    cnt       <= 16'd0;
                    st        <= S_IDLE;
                    rx_data   <= sh;
                    rx_dv     <= 1'b1;       // 单拍有效
                    frame_err <= ~r1;        // 停止位应为 1
                end
                else
                    cnt <= cnt + 1'b1;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
