// ============================================================================
// ui_fb.v - 128x160x16 frame buffer (simple dual port BSRAM)
// ----------------------------------------------------------------------------
// Write port : drawing engine (ui_draw)
// Read port  : SPI scan-out (spi_screen_top flush address)
// Address    : {y[7:0], x[6:0]}  -> 20480 x 16 bit
//
// The buffer is split into two banks on purpose:
//   mem_lo : rows   0..127 -> 16384 x 16  (14-bit address)
//   mem_hi : rows 128..159 ->  4096 x 16  (12-bit address)
// A single 20480-deep array made Gowin's SDPB inference split the memory
// internally and drop the read-side bank select (py[7]); with explicit banks
// both read and write address every row correctly.  Read latency is 1 clock.
// ============================================================================
`timescale 1ns / 1ps

module ui_fb (
    input  wire        clk,
    input  wire        we,
    input  wire [14:0] waddr,
    input  wire [15:0] wdata,
    input  wire [14:0] raddr,
    output wire [15:0] rdata
);
    reg [15:0] mem_lo [0:16383];
    reg [15:0] mem_hi [0:4095];

    reg [15:0] rlo, rhi;
    reg        sel_r;

    // write port ------------------------------------------------------------
    always @(posedge clk) begin
        if (we && !waddr[14])
            mem_lo[waddr[13:0]] <= wdata;
    end

    always @(posedge clk) begin
        if (we && waddr[14])
            mem_hi[waddr[11:0]] <= wdata;
    end

    // read port -------------------------------------------------------------
    always @(posedge clk) begin
        rlo   <= mem_lo[raddr[13:0]];
        rhi   <= mem_hi[raddr[11:0]];
        sel_r <= raddr[14];
    end

    assign rdata = sel_r ? rhi : rlo;
endmodule
