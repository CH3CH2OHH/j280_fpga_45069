//=============================================================================
// 模块：tick_gen
// 文件：tick_gen.v
// 简述：单调计数式节拍产生器
//-----------------------------------------------------------------------------
// 功能说明
//   自由运行计数器计到 DIV-1 归零，并输出一拍 tick。不使用门控时钟，
//   所有下游逻辑都在同一个 clk 上，节拍只作为使能使用。
//
// 接口
//   clk     input   系统时钟
//   rst_n   input   同步复位，低有效
//   tick    output  单拍使能，频率 = CLK_HZ / RATE_HZ
//
// 参数
//   CLK_HZ   输入时钟频率（Hz）
//   RATE_HZ  目标节拍频率（Hz），须 <= CLK_HZ/2
//
// 注意事项
//   分频系数在综合期由 CLK_HZ/RATE_HZ 算出，运行期无除法。
//=============================================================================

`timescale 1ns / 1ps

module tick_gen #(
    parameter integer CLK_HZ  = 50_000_000,   // 输入时钟频率（Hz），J280 主时钟 = 50 MHz
    parameter integer RATE_HZ = 1_000         // 期望节拍频率（Hz），须 ≤ CLK_HZ/2
)(
    input  wire clk,                          // 系统时钟，上升沿有效
    input  wire rst_n,                        // 同步复位，低有效
    output reg  tick                          // 节拍脉冲，单拍
);

    //=========================================================================
    // 分频系数：(a + b/2) / b 是整数除法的四舍五入写法，避免截断误差累积。
    // 计数范围 0 ~ DIV-1，共 DIV 拍。
    //=========================================================================
    localparam integer DIV = (CLK_HZ + RATE_HZ / 2) / RATE_HZ;

    // 计数器位宽
    localparam integer CW = $clog2(DIV);

    reg [CW-1:0] cnt;

    // 节拍生成
    always @(posedge clk) begin
        if (!rst_n) begin
            // 复位：计数器与 tick 清零
            cnt  <= {CW{1'b0}};
            tick <= 1'b0;
        end
        else if (cnt == DIV - 1) begin
            // 计数到头：计数器回 0，tick 置 1（寄存器输出，下一拍可见，仅 1 拍）
            cnt  <= {CW{1'b0}};
            tick <= 1'b1;
        end
        else begin
            // 正常计数：tick 在此分支回 0
            cnt  <= cnt + 1'b1;
            tick <= 1'b0;
        end
    end

endmodule
