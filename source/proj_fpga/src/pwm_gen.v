`timescale 1ns / 1ps

//=============================================================================
// 模块：pwm_gen
// 作用：把有符号 duty 转成 PWM 波形和方向信号。
//
// 载波：CNT_W=10、PRE_DIV=2 时，50 MHz/(2×1024)=24.414 kHz；duty 的绝对值
//   直接对应比较计数，范围 0..(2^CNT_W-1)，不会再乘除其它比例。
// 方向：duty>=0 输出 desired_dir=1，duty<0 输出 desired_dir=0。幅值只在
//   载波周期边界锁存，避免周期中途改变占空比。检测到换向时先关闭 PWM，
//   direction_guard 保留 PRE_DIV 个预分频计数，随后才允许新方向有效，降低
//   半桥上下管直通和电机反接瞬间的风险。
// 复位：rst_n 为低时清零计数、占空比和方向保护；active 只表示当前确实会
//   输出 PWM，供 TB6612 驱动器生成 IN1/IN2/有源 PWM。
//=============================================================================

// 保持原 10 bit 分辨率和占空比单位；默认载波高于可听频段以减轻电机啸叫。
// 幅值只在周期边界更新；换向先关 PWM，再在边界改方向，留一个载波计数死区。
module pwm_gen #(
    parameter integer CNT_W = 10,
    parameter integer PRE_DIV = 2,
    parameter integer MIN_DUTY = 0
)(
    input wire clk, rst_n,
    input wire signed [15:0] duty,
    output reg pwm_out,
    output reg dir_out,
    output wire active
);
    // CNT_MAX 是载波计数的最大值；PD_W 对 PRE_DIV=1/2 等边界值做了
    // 最小位宽保护，避免 $clog2(1) 产生零宽寄存器。
    localparam integer CNT_MAX = (1 << CNT_W)-1;
    localparam integer PD_W = (PRE_DIV <= 2) ? 1 : $clog2(PRE_DIV);
    localparam [PD_W-1:0] PRE_INC = {{(PD_W-1){1'b0}}, 1'b1};
    reg [CNT_W-1:0] cnt, mag;
    reg [PD_W-1:0] pre;
    reg [PD_W:0] direction_guard;
    // pre 每 PRE_DIV 个系统时钟产生一个 cnt_en，cnt 只在 cnt_en 时递增。
    wire cnt_en = (pre == PRE_DIV-1);
    wire boundary = cnt_en && (cnt == CNT_MAX);
    wire signed [16:0] extended = {duty[15],duty};
    wire [16:0] magnitude = (extended < 0) ? -extended : extended;
    wire desired_dir = !duty[15];
    // 先限幅到计数器宽度，再应用 MIN_DUTY；duty=0 单独作为停机条件，
    // 不会被最小起动占空比改成非零输出。
    wire [CNT_W-1:0] desired_mag = (magnitude > CNT_MAX) ? CNT_MAX :
        (magnitude == 0) ? 0 : (magnitude < MIN_DUTY) ? MIN_DUTY : magnitude[CNT_W-1:0];
    wire stop = (duty == 0);
    wire changing_dir = (desired_dir != dir_out);
    assign active = (mag != 0) && !stop && !changing_dir && (direction_guard == 0);

    // 在周期边界同时锁存新幅值和方向；换向期间 pwm_out 强制为 0，
    // direction_guard 结束后 active 才恢复为 1。
    always @(posedge clk) begin
        if (!rst_n) begin
            pre <= 0; cnt <= 0; mag <= 0; dir_out <= 1; pwm_out <= 0; direction_guard <= 0;
        end else begin
            if (boundary && changing_dir) direction_guard <= PRE_DIV;
            else if (direction_guard != 0) direction_guard <= direction_guard - 1'b1;
            pre <= cnt_en ? {PD_W{1'b0}} : pre + PRE_INC;
            if (cnt_en) cnt <= cnt + 1'b1;
            if (stop) begin mag <= 0; pwm_out <= 0; end
            else begin
                if (boundary) begin mag <= desired_mag; dir_out <= desired_dir; end
                if (changing_dir || boundary || direction_guard != 0) pwm_out <= 0;
                else pwm_out <= (cnt < mag);
            end
        end
    end
endmodule
