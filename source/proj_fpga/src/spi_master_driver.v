// ============================================================================
// spi_master_driver.v — 适配 50 MHz 系统时钟的慢速 SPI 字节发送器
// ----------------------------------------------------------------------------
// 原参考工程（project_lcd，GW2A-18）直接每拍翻转 sclk，50 MHz 下 sclk≈25 MHz，
// 对 ST7735 偏高。这里保持与原模块完全相同的端口/握手，仅把 sclk 放慢：
//   每 DIV 个 sys_clk 翻转一次 sclk  ->  sclk = 50 MHz / (2*DIV)
//   DIV=2 -> 12.5 MHz（本项目默认）
// 时序：进入传输时 sclk=0、mosi=MSB；上升沿由屏幕采样，下降沿切换下一位。
// ============================================================================
`timescale 1ns / 1ps

module spi_master_driver #(
    parameter integer DIV = 2          // sclk = sys_clk / (2*DIV)；DIV>=1
)(
    input  wire        sys_clk,
    input  wire        sys_rst_n,

    input  wire        spi_start_i,
    input  wire        spi_end_i,       // 参考工程未使用，保留端口
    input  wire [7:0]  spi_send_data_i,
    output reg         spi_send_ack_o,

    input  wire        lcd_dc_i,
    output reg         lcd_dc,

    output reg         spi_sclk,
    output reg         spi_mosi,
    output wire        spi_cs
);

    localparam [1:0] S_IDLE = 2'd0, S_SEND = 2'd1, S_END = 2'd2;

    reg [1:0]  state;
    reg [7:0]  data_r;
    reg [2:0]  bit_idx;
    reg [7:0]  div_cnt;
    reg        phase;      // 0=下一个边沿为上升沿, 1=下一个边沿为下降沿

    assign spi_cs = (state == S_SEND) ? 1'b0 : 1'b1;

    always @(posedge sys_clk) begin
        if (!sys_rst_n) begin
            state          <= S_IDLE;
            data_r         <= 8'd0;
            bit_idx        <= 3'd0;
            div_cnt        <= 8'd0;
            phase          <= 1'b0;
            spi_sclk       <= 1'b1;
            spi_mosi       <= 1'b1;
            lcd_dc         <= 1'b1;
            spi_send_ack_o <= 1'b0;
        end
        else begin
            spi_send_ack_o <= 1'b0;
            case (state)
            S_IDLE: begin
                spi_sclk <= 1'b1;
                if (spi_start_i) begin
                    data_r   <= spi_send_data_i;
                    lcd_dc   <= lcd_dc_i;
                    bit_idx  <= 3'd0;
                    div_cnt  <= 8'd0;
                    phase    <= 1'b0;
                    spi_sclk <= 1'b0;              // 起始低电平
                    spi_mosi <= spi_send_data_i[7];// 先送 MSB
                    state    <= S_SEND;
                end
            end

            S_SEND: begin
                if (div_cnt == DIV - 1) begin
                    div_cnt <= 8'd0;
                    if (phase == 1'b0) begin
                        spi_sclk <= 1'b1;          // 上升沿：屏幕采样
                        phase    <= 1'b1;
                    end
                    else begin
                        spi_sclk <= 1'b0;          // 下降沿：换下一位
                        phase    <= 1'b0;
                        if (bit_idx == 3'd7) begin
                            spi_send_ack_o <= 1'b1;
                            state          <= S_END;
                        end
                        else begin
                            bit_idx  <= bit_idx + 3'd1;
                            spi_mosi <= data_r[6 - bit_idx];
                        end
                    end
                end
                else begin
                    div_cnt <= div_cnt + 8'd1;
                end
            end

            S_END: begin
                spi_sclk <= 1'b1;
                state    <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
