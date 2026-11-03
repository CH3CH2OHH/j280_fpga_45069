//=============================================================================
// 模块：clk_rst
// 文件：clk_rst.v
// 简述：系统时钟与复位管理
//-----------------------------------------------------------------------------
// 功能说明
//   clk_sys 直接取自 50 MHz 有源晶振，不分频、不产生门控时钟。
//   复位采用"异步置位、同步释放"：按键按下立即复位，释放后经 REL_MS 消抖
//   再进 N 级同步器，避免松手抖动和亚稳态。
//
// 接口
//   clk_50m    input   M19，BANK_2 3.3 V，50 MHz 有源晶振
//   key_rst_n  input   AB3，BANK_5 3.3 V，SW5，按下为低
//   clk_sys    output  系统时钟，等于 clk_50m
//   rst_n      output  同步后的系统复位，低有效
//
// 参数
//   CLK_HZ      输入时钟频率
//   REL_MS      复位释放消抖时间（ms）
//   SYNC_STAGE  同步器级数，须 >= 2
//=============================================================================

`timescale 1ns / 1ps

module clk_rst #(
    parameter integer CLK_HZ     = 50_000_000,   // 主时钟频率（M19）
    parameter integer REL_MS     = 20,           // 复位释放消抖时间（ms）
    parameter integer SYNC_STAGE = 3             // 同步器级数，必须 ≥ 2
)(
    input  wire clk_50m,        // M19  BANK_2  3.3V  50 MHz 有源晶振
    input  wire key_rst_n,      // AB3  BANK_5  3.3V  SW5，按下为低（异步）
    output wire clk_sys,        // 系统时钟（= clk_50m）
    output wire rst_n           // 同步后的系统复位，低有效
);

    // 时钟直通
    assign clk_sys = clk_50m;

    // 复位释放消抖
    localparam integer RCNT_MAX = CLK_HZ / 1000 * REL_MS;   // 50 MHz × 20 ms = 1,000,000
    localparam integer RW       = $clog2(RCNT_MAX);         // 20 位

    reg [RW-1:0] rcnt;

    always @(posedge clk_sys or negedge key_rst_n) begin
        if (!key_rst_n)
            rcnt <= {RW{1'b0}};                 // 按下：异步清零
        else if (rcnt != RCNT_MAX - 1)
            rcnt <= rcnt + 1'b1;                // 松开后计时，到满即停
    end

    // 打成寄存器再当作异步复位源：避免用组合比较结果直接驱动复位网络
    reg rst_rel_q;

    always @(posedge clk_sys or negedge key_rst_n) begin
        if (!key_rst_n)
            rst_rel_q <= 1'b0;
        else
            rst_rel_q <= (rcnt == RCNT_MAX - 1);   // 1 = 已稳定松开 20 ms
    end

    //=========================================================================
    // 复位同步器（异步置位、同步释放）
    //    rst_sync[0]            : 第一级，直接承接异步信号，可能亚稳态
    //    rst_sync[SYNC_STAGE-1] : 最后一级，作为输出
    //=========================================================================
    reg [SYNC_STAGE-1:0] rst_sync;

    always @(posedge clk_sys or negedge rst_rel_q) begin
        if (!rst_rel_q)
            // 复位有效：异步清零，不依赖时钟，立即生效
            rst_sync <= {SYNC_STAGE{1'b0}};
        else
            // 复位释放：整体左移一位，最低位补 1，逐拍释放。
            // 经 SYNC_STAGE 个有效沿，1 到达最高位，rst_n 才拉高。
            rst_sync <= {rst_sync[SYNC_STAGE-2:0], 1'b1};
    end

    // 复位输出取最高位：只有 1 完整移过整条同步链，复位才释放。
    assign rst_n = rst_sync[SYNC_STAGE-1];

endmodule
