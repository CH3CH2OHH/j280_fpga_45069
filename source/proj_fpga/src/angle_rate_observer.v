`timescale 1ns/1ps
// 定速二状态观测器：先预测角度，再用测量创新修正角度和角速度。
// 1kHz更新；角度状态单位cdeg×256，速度状态为每毫秒cdeg×256。
// 输出乘10变成deg/s×256。只提供可选D反馈，不改变P测角和判倒阈值。
module angle_rate_observer #(
    parameter integer ALPHA_SHIFT=2,
    parameter integer BETA_SHIFT=5
)(
    input wire clk,rst_n,en,
    input wire signed [25:0] angle_q8,
    output wire signed [27:0] rate_q8
);
    reg initialized;
    reg [1:0] valid;
    // 多保留8位内部小数，并对创新对称舍入，避免负向右移的直流偏置。
    reg signed [39:0] position_fine, velocity_fine;
    wire signed [40:0] prediction=$signed({position_fine[39],position_fine})+
                                $signed({velocity_fine[39],velocity_fine});
    wire signed [40:0] measurement={{7{angle_q8[25]}},angle_q8,8'd0};
    reg signed [40:0] prediction_r,measurement_r;
    reg signed [41:0] innovation_r;
    wire signed [41:0] innovation=$signed({measurement_r[40],measurement_r})-
                                 $signed({prediction_r[40],prediction_r});
    function signed [41:0] rounded_shift;
        input signed [41:0] value;
        input integer shift;
        reg signed [41:0] half;
        begin
            half=42'sd1<<<(shift-1);
            // 负数加half-1等价于绝对值舍入后取负，只需要一次常量加法。
            rounded_shift=(value+(value[41] ? half-42'sd1 : half))>>>shift;
        end
    endfunction
    wire signed [41:0] corrected_position=$signed({prediction_r[40],prediction_r})+
                                          rounded_shift(innovation_r,ALPHA_SHIFT);
    wire signed [41:0] corrected_velocity=$signed({{2{velocity_fine[39]}},velocity_fine})+
                                          rounded_shift(innovation_r,BETA_SHIFT);
    wire signed [43:0] velocity_wide={{4{velocity_fine[39]}},velocity_fine};
    wire signed [43:0] scaled=(velocity_wide<<<3)+(velocity_wide<<<1);
    wire signed [43:0] rounded_rate=(scaled+(scaled[43] ? 44'sd127 : 44'sd128))>>>8;
    assign rate_q8=rounded_rate>44'sd134217727 ? 28'sh7ffffff :
                  rounded_rate< -44'sd134217728 ? 28'sh8000000 : rounded_rate[27:0];
    always @(posedge clk) begin
        if(!rst_n) begin
            initialized<=0;position_fine<=0;velocity_fine<=0;
            valid<=0;prediction_r<=0;measurement_r<=0;innovation_r<=0;
        end else begin
            // 三个系统时钟级完成一次观测，避免串接测角低通和宽位加减路径。
            valid<={valid[0],en && initialized};
            if(en) begin
                prediction_r<=prediction;measurement_r<=measurement;
                if(!initialized) begin
                    initialized<=1;position_fine<=measurement[39:0];velocity_fine<=0;
                end
            end
            if(valid[0])innovation_r<=innovation;
            if(valid[1])begin
                position_fine<=corrected_position[39:0];
                velocity_fine<=corrected_velocity[39:0];
            end
        end
    end
endmodule
