//=============================================================================
// 模块：ang_calc
// 文件：ang_calc.v
// 简述：ADC 码值转角度（单位 0.01°，有符号）
//-----------------------------------------------------------------------------
// 功能说明
//   ang = (raw_q - zero x 2^FRAC) x K_Q8 >>> (8 + FRAC)
//   零点可在运行期改写，斜率为综合期参数；系统时钟流水不改变采样节拍。
//
// 接口
//   raw_q      input   平均后的码值，带 FRAC_LOG2 位小数
//   zero_set   input   运行期零点（整数码值），有效范围 1~1022
//   ang001     output  角度，单位 0.01°
//
// 参数
//   K_Q8       斜率，DEG_PER_COUNT x 100 x 256；默认 8500 对应 0.332°/码
//   FRAC_LOG2  输入小数位数，与 adc_par 一致
//   ANG_LIMIT  输出限幅，单位 0.01°
//
// 注意事项
//   零点必须现场标定：把摆杆扶到真正竖直位置，读取报文中的 RAW，
//   再用串口命令 ZERO <该值> 写入。零点偏差几个度会直接表现为
//   "能站住但摆臂持续单向爬行"。
//=============================================================================

`timescale 1ns / 1ps

module ang_calc #(
    parameter integer K_Q8      = 8500,    // DEG_PER_COUNT × 100 × 256
    parameter integer FRAC_LOG2 = 4,       // 输入小数位数（与 adc_par 一致）
    parameter integer ANG_LIMIT = 18000    // 输出限幅 ±180.00°
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] raw_q,      // 码值 × 2^FRAC_LOG2
    input  wire [15:0] zero_set,   // 运行时零点（整数码值），来自 cfg_regs
    output reg  signed [17:0] ang001   // 0.01° 为单位
);

    // cfg_regs 上电装入 RAW_ZERO；运行期间只接受 ADC 有效范围内的新零点。
    wire [15:0] zsel = zero_set;

    // 零点要放大到和 raw_q 同样的小数位才能相减
    wire signed [20:0] ZERO_Q = $signed({5'd0, zsel}) <<< FRAC_LOG2;

    // raw_q 当有符号处理，才能减出负的偏差
    wire signed [20:0] delta = $signed({5'd0, raw_q}) - ZERO_Q;

    // 将减法与常系数乘法分开，避免 ZERO 选择、乘法、限幅串成关键路径。
    reg signed [20:0] delta_r;
    reg signed [52:0] prod;

    // 除以 256（Q8）再除以 2^FRAC_LOG2，得到 0.01°
    wire signed [52:0] q_shifted = $signed(prod) >>> (8 + FRAC_LOG2);
    wire signed [31:0] q = q_shifted[31:0];

    wire signed [31:0] q_lim = (q >  ANG_LIMIT) ?  ANG_LIMIT :
                               (q < -ANG_LIMIT) ? -ANG_LIMIT : q;

    always @(posedge clk) begin
        if (!rst_n) begin
            delta_r <= 0;
            prod <= 0;
            ang001 <= 18'sd0;
        end else begin
            delta_r <= delta;
            prod <= delta_r * K_Q8;
            ang001 <= q_lim[17:0];
        end
    end

endmodule
