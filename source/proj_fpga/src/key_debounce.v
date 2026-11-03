//=============================================================================
// 模块：key_debounce
// 文件：key_debounce.v
// 简述：按键消抖，输出电平与按下事件
//-----------------------------------------------------------------------------
// 功能说明
//   每路按键独立计数：输入电平连续保持 DEBOUNCE_MS 才更新输出电平，
//   电平由 0 变 1 时产生一拍 key_press。
//
// 接口
//   clk        input    系统时钟
//   rst_n      input    同步复位，低有效
//   key_in     input    原始按键，按下为低（异步）
//   key_level  output   消抖后的电平，1 = 按下
//   key_press  output   按下事件，单拍脉冲
//
// 参数
//   CLK_HZ       输入时钟频率（Hz）
//   DEBOUNCE_MS  消抖时间（ms）
//   N_KEY        按键数量
//
// 注意事项
//   J280 的 SW1~SW3 位于 T18 / R18 / U20，BANK_3 1.5 V。
//   SW4（T20）被 SSPI 占用，不可用。
//=============================================================================

`timescale 1ns / 1ps
 
module key_debounce #(
    parameter integer CLK_HZ      = 50_000_000,   // 输入时钟频率（Hz），J280 = 50 MHz
    parameter integer DEBOUNCE_MS = 20,           // 消抖时间（ms）
    parameter integer N_KEY       = 3             // 按键数量（J280 默认放开 SW1~SW3）
)(
    input  wire              clk,         // 系统时钟，上升沿有效
    input  wire              rst_n,       // 同步复位，低有效
    input  wire [N_KEY-1:0]  key_in,      // 原始按键输入，按下为低（异步）
    output reg  [N_KEY-1:0]  key_level,   // 消抖后的电平：1 = 按下
    output reg  [N_KEY-1:0]  key_press    // 按下事件，单拍脉冲
);
 
    // 消抖所需的时钟周期数。先除 1000 得到每毫秒周期数，再乘毫秒数。
    localparam integer CNT_MAX = CLK_HZ / 1000 * DEBOUNCE_MS;
 
    // 计数器位宽：计数范围 0 ~ CNT_MAX-1，由 $clog2 自动推算。
    localparam integer CW      = $clog2(CNT_MAX + 1);
 
    // 两级同步器
    reg [N_KEY-1:0] k_meta;     // 同步器第一级
    reg [N_KEY-1:0] k_sync;     // 同步器第二级（输出，可安全使用）
 
    always @(posedge clk) begin
        if (!rst_n) begin
            k_meta <= {N_KEY{1'b1}};
            k_sync <= {N_KEY{1'b1}};
        end
        else begin
            k_meta <= key_in;       // 第一级：采样异步输入
            k_sync <= k_meta;       // 第二级：再采样一次
        end
    end
 
    // 逐位消抖
    reg [N_KEY-1:0] stable;                 // 已确认的稳定电平（1 = 按下）
    reg [N_KEY-1:0] stable_d;               // stable 延迟一拍
    reg [CW-1:0]    cnt [0:N_KEY-1];        // 每个按键一个计数器
    integer         i;                      // 循环变量，综合时展开为并行电路
 
    always @(posedge clk) begin
        //---------------------------------------------------------------------
        // 同步复位：所有状态清零，表示"未按下、无事件"
        // 与同步器复位值（全 1，取反后为 0）保持一致
        //---------------------------------------------------------------------
        if (!rst_n) begin
            stable    <= {N_KEY{1'b0}};
            stable_d  <= {N_KEY{1'b0}};
            key_level <= {N_KEY{1'b0}};
            key_press <= {N_KEY{1'b0}};
            for (i = 0; i < N_KEY; i = i + 1)
                cnt[i] <= {CW{1'b0}};
        end
        // 正常工作
        else begin
            stable_d <= stable;             // 保存上一拍的稳定值，供边沿检测
 
            // 对每个按键执行相同的消抖逻辑
            for (i = 0; i < N_KEY; i = i + 1) begin
                // ~k_sync[i]：取反，使"按下"为 1，与 stable 含义一致
                if (~k_sync[i] != stable[i]) begin
                    // 当前电平与稳定值不同：可能是真实变化，也可能是抖动，开始计时
                    if (cnt[i] == CNT_MAX - 1) begin
                        // 已连续 CNT_MAX 拍不同（= DEBOUNCE_MS），确认电平翻转
                        cnt[i]    <= {CW{1'b0}};
                        stable[i] <= ~k_sync[i];
                    end
                    else
                        cnt[i] <= cnt[i] + 1'b1;    // 继续计数
                end
                else
                    // 与稳定值一致：中途回弹或无变化，计数器清零重来
                    cnt[i] <= {CW{1'b0}};
            end
 
            //-----------------------------------------------------------------
            // 输出寄存
            //    key_level : 稳定值再打一拍输出，保证输出为寄存器（无毛刺）
            //    key_press : 上升沿检测。stable 为 1 且上一拍为 0 -> 按下瞬间。
            //                stable_d 是非阻塞赋值前的旧值，因此只高 1 拍。
            //-----------------------------------------------------------------
            key_level <= stable;
            key_press <= stable & ~stable_d;
        end
    end
 
endmodule
