// ============================================================================
// debounce.v — 按键/编码器信号消抖（50 MHz 时钟，默认 1 ms 稳定）
// ============================================================================
`timescale 1ns / 1ps

module debounce #(
    parameter integer CYCLES = 50_000      // 50 MHz 下 1 ms
)(
    input  wire clk,
    input  wire rst_n,
    input  wire din,
    output reg  dout
);
    reg [1:0]  sync;
    reg [15:0] cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            sync <= 2'b11;
            cnt  <= 16'd0;
            dout <= 1'b1;
        end
        else begin
            sync <= {sync[0], din};
            if (sync[1] != dout) begin
                if (cnt == CYCLES - 1) begin
                    dout <= sync[1];
                    cnt  <= 16'd0;
                end
                else begin
                    cnt <= cnt + 16'd1;
                end
            end
            else begin
                cnt <= 16'd0;
            end
        end
    end
endmodule
