//=============================================================================
// 模块：adc_par
// 文件：adc_par.v
// 简述：3PA1030 并行 ADC 采样与多点平均
//-----------------------------------------------------------------------------
// 功能说明
//   产生 ADC 工作时钟（默认 5 MHz），在时钟低电平期间读取 10 位并行数据，
//   累加 2^AVG_LOG2 次后取平均；raw_q保留单组，raw_control_q可平均1/2/4/8组。
//
// 接口
//   ad_d      input   [9:0]  并行数据 D0~D9
//   ad_otr    input   超量程标志（本设计未参与运算）
//   ad_clk    output  ADC 时钟，5 MHz
//   ad_oe     output  输出使能，恒为 0（低有效）
//   raw       output  平均后的整数码值
//   raw_q     output  平均后的码值 x 2^FRAC_LOG2
//   raw_upd   output  新样本有效，单拍
//   otr_flag  output  超量程锁存标志
//
// 参数
//   ADC_DIV     ADC 时钟分频，5 MHz = 50 MHz / 10
//   AVG_LOG2    平均点数取 2 的幂
//   FRAC_LOG2   输出小数位数
//
// 注意事项
//   平均后保留小数位是本设计的关键：10 bit 覆盖 340°，单码 0.33°，
//   直接取整会让角度微分被量化噪声主导。平均后的精度本就高于整数，
//   截断掉等于白算。
//=============================================================================

`timescale 1ns / 1ps

module adc_par #(
    parameter integer CLK_HZ   = 50_000_000,  // 系统时钟
    parameter integer ADC_DIV  = 10,          // ad_clk = CLK_HZ / ADC_DIV
    parameter integer AVG_LOG2 = 8,           // 2^8 = 256 点平均
    parameter integer FRAC_LOG2= 4            // 保留 4 位小数（必须 <= AVG_LOG2）
)(
    input  wire        clk,        // clk_sys
    input  wire        rst_n,      // 同步复位，低有效
    input  wire [9:0]  ad_d,       // AD1_D0~D9（BANK2，3.3V）
    input  wire        ad_otr,     // AD1_OTR 超量程指示
    output wire        ad_clk,     // AD1_CLK
    output wire        ad_oe,      // AD1_OE，恒为 0（正常工作）
    output reg  [15:0] raw,        // 整数平均值，0~1023（显示/标定用）
    output reg  [15:0] raw_q,      // 带 FRAC_LOG2 位小数的平均值（控制用）
    input wire [1:0] control_avg_shift, // 0/1/2/3：控制前平均1/2/4/8组；0保留原行为
    output reg [15:0] raw_control_q,
    output reg         raw_upd,    // 更新脉冲（单拍）
    output reg         otr_flag    // 本块平均内是否出现过超量程
);

    localparam integer AVG  = (1 << AVG_LOG2);
    localparam integer CW   = $clog2(ADC_DIV);
    localparam integer HALF = ADC_DIV / 2;
    localparam integer SHR  = AVG_LOG2 - FRAC_LOG2;

    //-------------------------------------------------------------------------
    // 1. 分频计数与 ADC 时钟
    //-------------------------------------------------------------------------
    reg [CW-1:0] div;

    always @(posedge clk) begin
        if (!rst_n)
            div <= {CW{1'b0}};
        else if (div == ADC_DIV - 1)
            div <= {CW{1'b0}};
        else
            div <= div + 1'b1;
    end

    reg adc_clk_r;

    always @(posedge clk) begin
        if (!rst_n)
            adc_clk_r <= 1'b0;
        else if (div == HALF - 1)
            adc_clk_r <= 1'b1;          // 下一拍（div=HALF）出现上升沿
        else if (div == ADC_DIV - 1)
            adc_clk_r <= 1'b0;
    end

    assign ad_clk = adc_clk_r;
    assign ad_oe  = 1'b0;               // 低有效：常开，别写成 1'b1

    // div = ADC_DIV-2 时采样：上升沿之后 (ADC_DIV-2-HALF) 个时钟
    wire sample = (div == ADC_DIV - 2);

    //-------------------------------------------------------------------------
    // 2. 累加平均
    //    累加器要多留 1 位：AVG_LOG2 = 9（512 点）时最大 512 × 1023 = 523776，
    //    已经超过 2^18；位宽按10+AVG_LOG2推导，9时acc19位、sum20位。
    //    512 点在 5 MHz 下用时 102.4 µs，仍比 1 ms 控制节拍快一个数量级，
    //    白噪声按 √512 衰减；相比 256 点再降 3 dB。
    //-------------------------------------------------------------------------
    localparam integer ACC_W = 10 + AVG_LOG2;
    reg [ACC_W-1:0] acc;
    reg  [AVG_LOG2-1:0] cnt;
    reg                otr_acc;

    wire [ACC_W:0] sum = {1'b0, acc} + {{(ACC_W-9){1'b0}}, ad_d};

    // sum >> SHR = 码值 × 16（AVG_LOG2=9时SHR=5）；整数码值供健康判定。
    wire [ACC_W:0] sum_q = sum >> SHR;
    // 使用完整组和再平均，避免先截去小数后重复平均产生额外偏置。
    // 512点一组时，8组为819.2us，覆盖24.414kHz载波的整20个周期。
    // 历史每组持续更新，在线选择窗口不清历史，也不增加1ms控制节拍。
    reg [ACC_W-1:0] group_history [0:6];
    reg history_ready;
    integer h;
    wire [ACC_W+2:0] group1 = {{3{1'b0}},sum[ACC_W-1:0]};
    wire [ACC_W+2:0] group2 = group1 + {{3{1'b0}},group_history[0]};
    wire [ACC_W+2:0] group4 = group2 + {{3{1'b0}},group_history[1]} +
                                                   {{3{1'b0}},group_history[2]};
    wire [ACC_W+2:0] group8 = group4 + {{3{1'b0}},group_history[3]} +
        {{3{1'b0}},group_history[4]} + {{3{1'b0}},group_history[5]} +
                                                   {{3{1'b0}},group_history[6]};
    wire [ACC_W+2:0] control_sum_q = !history_ready ? group1 >> SHR :
        control_avg_shift==1 ? group2 >> (SHR+1) :
        control_avg_shift==2 ? group4 >> (SHR+2) :
        control_avg_shift==3 ? group8 >> (SHR+3) : group1 >> SHR;

    always @(posedge clk) begin
        if (!rst_n) begin
            acc      <= 0;
            cnt      <= {AVG_LOG2{1'b0}};
            raw      <= 16'd0;
            raw_q    <= 16'd0;
            raw_control_q <= 0;
            history_ready <= 0;
            for(h=0;h<7;h=h+1)group_history[h]<=0;
            raw_upd  <= 1'b0;
            otr_flag <= 1'b0;
            otr_acc  <= 1'b0;
        end
        else begin
            raw_upd <= 1'b0;

            if (sample) begin
                otr_acc <= otr_acc | ad_otr;

                if (cnt == AVG - 1) begin
                    raw      <= sum >> AVG_LOG2;      // 整数码值，给串口显示
                    raw_q    <= sum_q[15:0];          // 码值 × 16，给控制环
                    raw_control_q <= control_sum_q[15:0];
                    history_ready <= 1;
                    if(!history_ready) begin
                        // 首组复制填充，禁止上电时零历史把竖直角度拉向底部。
                        for(h=0;h<7;h=h+1)group_history[h]<=sum[ACC_W-1:0];
                    end else begin
                        for(h=6;h>0;h=h-1)group_history[h]<=group_history[h-1];
                        group_history[0]<=sum[ACC_W-1:0];
                    end
                    acc      <= 0;
                    cnt      <= {AVG_LOG2{1'b0}};
                    raw_upd  <= 1'b1;
                    otr_flag <= otr_acc | ad_otr;
                    otr_acc  <= 1'b0;
                end
                else begin
                    acc <= sum[ACC_W-1:0];
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

endmodule
