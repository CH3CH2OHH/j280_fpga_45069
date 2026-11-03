//=============================================================================
// 模块：tb6612_drv
// 文件：tb6612_drv.v
// 简述：TB6612FNG 方向与使能时序
//-----------------------------------------------------------------------------
// 功能说明
//   把"方向 + PWM"翻译成 TB6612 的 AIN1/AIN2/PWMA/STBY 时序。
//   STBY 在板上接高；en 为 0 时使用 IN1=IN2=0、PWM=1 的明确高阻停止组合。
//   en 为 1 但 PWM 为 0 时按 BRAKE 决定
//   是短路制动还是滑行。
//
// 接口
//   en     input   总使能，0 = 待机
//   dir    input   方向，1 = 正转
//   pwm    input   PWM 波形
//   ain1/ain2/pwma/stby   output   TB6612 控制脚
//
// 参数
//   BRAKE  1 = PWM 为 0 时短路制动
//
// 注意事项
//   J280 的 XH1 接的是 B 通道：PWMB = V14，BIN1 = AA17，BIN2 = V15。
//   A 通道（Y18/Y17/Y19）引到 XH2，本设计未使用。
//   STBY 在板上硬接 VCC3V3，这里的 stby 输出仅作指示。
//=============================================================================

`timescale 1ns / 1ps

module tb6612_drv #(
    parameter BRAKE = 1'b1          // 1 = PWM 为 0 时短接制动
)(
    input  wire clk,
    input  wire rst_n,
    input  wire en,                 // 总使能（0 = 待机）
    input  wire dir,                // 1 = 正转
    input  wire pwm,                // PWM 输入
    output reg  ain1,
    output reg  ain2,
    output reg  pwma,
    output reg  stby
);

    always @(posedge clk) begin
        if (!rst_n) begin
            // 板上 STBY 不受 FPGA 控制，必须用数据手册明确定义的停止组合。
            ain1 <= 1'b0;
            ain2 <= 1'b0;
            pwma <= 1'b1;
            stby <= 1'b0;
        end
        else if (!en) begin
            ain1 <= 1'b0;
            ain2 <= 1'b0;
            pwma <= 1'b1;
            stby <= 1'b0;           // 仅内部指示；真实电机通过 IN=00、PWM=1 高阻
        end
        else begin
            stby <= 1'b1;
            pwma <= pwm;

            if (BRAKE) begin
                // 短接制动：方向电平保持，靠 PWM = 0 时绕组短接产生阻尼
                ain1 <=  dir;
                ain2 <= ~dir;
            end
            else begin
                // 惯性滑行：关断区两相拉低，同时保持芯片 PWM 脚为高。
                pwma <= 1'b1;
                ain1 <= dir & pwm;
                ain2 <= (~dir) & pwm;
            end
        end
    end

endmodule
