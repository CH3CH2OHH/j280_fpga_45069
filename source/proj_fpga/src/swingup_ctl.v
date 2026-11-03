`timescale 1ns / 1ps

// 自动起摆：盲区内往复激励，角度有效后按水平半圈与目标能量包络换相。
// 包络名义 g/l=80/s²，仅作启动候选；实际捕获能力仍需实物记录验证。
module swingup_ctl #(
    parameter integer CTRL_HZ = 1000,
    parameter integer CAP_RATE_DEG_S = 100,
    parameter integer RATE_LP_SHIFT = 2 // 起摆速度独立低通，ALP=0 也不能直接放大 ADC 噪声
)(
    input wire clk, rst_n, en,
    input wire mode_active,
    input wire restart,
    input wire bal_on,
    input wire angle_valid,                 // 非饱和、新鲜、无 OTR
    input wire angle_sample_valid,          // 角度与角速度必须来自有效样本
    input wire signed [17:0] ang001,         // 相对 TRIM 的角度，0.01°
    input wire [3:0] angle_lp_shift,
    input wire [15:0] swing_lim, swing_amp,
    input wire [15:0] ramp_ms, capture_ms, capture_lim, timeout_ms,
    input wire signed [15:0] swing_dir,
    output reg signed [15:0] duty,
    output reg capture_req, active, timeout_fault,
    output wire blind_start_active
);
    localparam [1:0] ST_IDLE=2'd0, ST_RUN=2'd1, ST_DONE=2'd2, ST_FAIL=2'd3;
    localparam [1:0] RATE_IDLE=2'd0, RATE_MUL=2'd1, RATE_FILT=2'd2;
    localparam [15:0] BLIND_LIMIT_MS=16'd1000;
    localparam [7:0] BLIND_HALF_MS=8'd200;
    localparam integer CAP_RATE_Q8=CAP_RATE_DEG_S*256;
    reg [1:0] state, rate_state;
    reg [15:0] elapsed_ms, blind_elapsed, ramp_stage_elapsed;
    reg [7:0] blind_phase_ms;
    reg blind_reverse, pump_negative;
    reg [4:0] ramp_stage;
    reg [9:0] capture_count;
    reg signed [17:0] angle_filt, angle_sample_r;
    reg signed [18:0] angle_diff_r;
    reg signed [31:0] rate_input_q8_r, rate_q8, rate_sample_q8_r;
    reg [3:0] angle_shift_r;
    reg decision_valid, initialized, angle_rate_valid, sample_valid_r;

    wire signed [18:0] residual = $signed({ang001[17],ang001}) -
                                          $signed({angle_filt[17],angle_filt});
    // 穿过底部盲区或 ±180° 回绕时重建历史，禁止把一圈跳变当作角速度。
    wire angle_wrap = (residual > 19'sd18000) || (residual < -19'sd18000);
    wire signed [18:0] filtered_ext = $signed({angle_filt[17],angle_filt}) +
                                                    (residual >>> angle_lp_shift);
    wire signed [17:0] filtered = (angle_lp_shift==0 || angle_wrap) ?
                                                        ang001 : filtered_ext[17:0];
    wire signed [18:0] diff_next = angle_wrap ? 19'sd0 :
                                                  (residual >>> angle_lp_shift);
    wire signed [31:0] diff_ext = {{13{angle_diff_r[18]}},angle_diff_r};
    wire signed [31:0] rate_input_next = (diff_ext <<< 11) + (diff_ext <<< 9);
    wire signed [32:0] rate_residual = $signed({rate_input_q8_r[31],rate_input_q8_r}) -
                                                    $signed({rate_q8[31],rate_q8});
    wire signed [32:0] rate_sum = $signed({rate_q8[31],rate_q8}) +
                                                 (rate_residual >>> angle_shift_r);
    wire signed [31:0] rate_next = (angle_shift_r==0) ? rate_input_q8_r : rate_sum[31:0];
    wire signed [18:0] angle_ext = {angle_sample_r[17],angle_sample_r};
    wire [18:0] angle_mag = angle_ext[18] ? -angle_ext : angle_ext;
    wire [31:0] rate_mag = rate_sample_q8_r[31] ? -rate_sample_q8_r : rate_sample_q8_r;
    wire [15:0] target_amp = swing_amp < swing_lim ? swing_amp : swing_lim;
    wire [16:0] ramp_step_ext = ({1'b0,ramp_ms}+17'd15) >> 4;
    wire [15:0] ramp_step_ms = ramp_step_ext[15:0];
    wire [20:0] ramp_product = target_amp*ramp_stage;
    wire [15:0] ramped_amp = ramp_ms==0 ? target_amp : ramp_product[19:4];
    wire [9:0] capture_required = capture_ms==0 ? 10'd1 :
        capture_ms>16'd1000 ? 10'd1000 : capture_ms[9:0];
    wire capture_confirmed = capture_ms<=16'd1 ||
                                           capture_count>=capture_required-10'd1;
    wire capture_condition = angle_valid && sample_valid_r && angle_rate_valid &&
        capture_lim!=0 && angle_mag<={3'd0,capture_lim} && rate_mag<=CAP_RATE_Q8;

    // 盲区可能在每次过底部时再次出现，按连续盲区时间限制，不能只允许首次启动。
    assign blind_start_active = state==ST_RUN && !angle_valid && !bal_on &&
                                                    blind_elapsed<BLIND_LIMIT_MS;

    // sqrt(2*g/l*(1-cos(theta))) 的 15° 分段包络，单位为 °/s。
    // 融合 v3 的寄存查表以截断组合路径，但不在 en 时读取旧 angle_sample_r：
    // en 先锁存本次角度，下一拍 RATE_MUL 才查表，之后 RATE_FILT 计算本次速度，
    // decision_valid 再执行能量判定。角度、角速度和包络来自同一次采样，
    // 利用原有 50 MHz 流水空隙，不额外增加 1 ms 控制延迟。
    reg [15:0] energy_rate;
    always @(posedge clk) begin
        if (!rst_n || !mode_active || restart) energy_rate <= 16'd1020;
        else if (rate_state==RATE_MUL) begin
            if      (angle_mag<19'd1500)  energy_rate<=16'd67;
            else if (angle_mag<19'd3000)  energy_rate<=16'd200;
            else if (angle_mag<19'd4500)  energy_rate<=16'd330;
            else if (angle_mag<19'd6000)  energy_rate<=16'd452;
            else if (angle_mag<19'd7500)  energy_rate<=16'd568;
            else if (angle_mag<19'd9000)  energy_rate<=16'd675;
            else if (angle_mag<19'd10500) energy_rate<=16'd770;
            else if (angle_mag<19'd12000) energy_rate<=16'd851;
            else if (angle_mag<19'd13500) energy_rate<=16'd917;
            else if (angle_mag<19'd15000) energy_rate<=16'd968;
            else if (angle_mag<19'd16500) energy_rate<=16'd1002;
            else                          energy_rate<=16'd1020;
        end
    end
    // 机构自然频率未标定时，固定包络可能在竖直窗口外形成小幅极限环。
    // 超过 2s/4s 仍未捕获，分级提升目标速度包络，PWM 幅值仍严格受 SWLIM 限制。
    wire [15:0] energy_rate_adapted = elapsed_ms>=16'd4000 ?
        energy_rate+(energy_rate>>1) : elapsed_ms>=16'd2000 ?
        energy_rate+(energy_rate>>2) : energy_rate;
    wire [31:0] energy_q8 = {8'd0,energy_rate_adapted,8'd0};
    wire energy_excess = rate_mag>energy_q8+32'd16384;
    wire energy_near = rate_mag+32'd16384>=energy_q8 &&
                                                    rate_mag<=energy_q8+32'd16384;
    wire [15:0] phase_amp = energy_near ? (ramped_amp>>2) : ramped_amp;
    // 低速时保持方向；速度超过 10°/s 后使用当前样本，避免延迟一个控制周期。
    wire velocity_negative = rate_mag>32'd2560 ? rate_sample_q8_r[31] : pump_negative;
    wire phase_negative = velocity_negative ^ (angle_mag>=19'd9000) ^
                                          energy_excess ^ (swing_dir<0);
    reg signed [16:0] phase_duty, blind_duty;
    always @* begin
        phase_duty = phase_negative ? -$signed({1'b0,phase_amp}) :
                                                      $signed({1'b0,phase_amp});
        blind_duty = (blind_reverse ^ (swing_dir<0)) ? -$signed({1'b0,ramped_amp}) :
                                                       $signed({1'b0,ramped_amp});
        if (phase_duty>17'sd1023) phase_duty=17'sd1023;
        else if (phase_duty< -17'sd1023) phase_duty=-17'sd1023;
        if (blind_duty>17'sd1023) blind_duty=17'sd1023;
        else if (blind_duty< -17'sd1023) blind_duty=-17'sd1023;
    end

    always @(posedge clk) begin
        if (!rst_n || !mode_active || restart) begin
            state<=ST_IDLE; rate_state<=RATE_IDLE; elapsed_ms<=0;
            blind_elapsed<=0; blind_phase_ms<=0; blind_reverse<=0; pump_negative<=0;
            ramp_stage<=0; ramp_stage_elapsed<=0; capture_count<=0;
            angle_filt<=0; angle_sample_r<=0; angle_diff_r<=0;
            rate_input_q8_r<=0; rate_q8<=0; rate_sample_q8_r<=0; angle_shift_r<=0;
            decision_valid<=0; initialized<=0; angle_rate_valid<=0; sample_valid_r<=0;
            duty<=0; capture_req<=0; active<=0; timeout_fault<=0;
        end else begin
            decision_valid<=0;
            if (en && rate_state==RATE_IDLE) begin
                capture_req<=0;
                sample_valid_r<=angle_valid && angle_sample_valid;
                if (angle_valid && angle_sample_valid) begin
                    angle_sample_r<=initialized ? filtered : ang001;
                    angle_filt<=initialized ? filtered : ang001;
                    angle_diff_r<=initialized ? diff_next : 19'sd0;
                    angle_shift_r<=angle_lp_shift>RATE_LP_SHIFT ? angle_lp_shift :
                                                          RATE_LP_SHIFT[3:0];
                    angle_rate_valid<=initialized && !angle_wrap;
                    if (!initialized || angle_wrap) rate_q8<=0;
                    initialized<=1;
                end else begin
                    angle_sample_r<=0; angle_filt<=0; angle_diff_r<=0;
                    rate_q8<=0; initialized<=0; angle_rate_valid<=0;
                end
                rate_state<=RATE_MUL;
            end else begin
                case (rate_state)
                    RATE_MUL: begin rate_input_q8_r<=rate_input_next; rate_state<=RATE_FILT; end
                    RATE_FILT: begin
                        rate_sample_q8_r<=rate_next; rate_q8<=rate_next;
                        rate_state<=RATE_IDLE; decision_valid<=1;
                    end
                    default: rate_state<=RATE_IDLE;
                endcase
            end
            if (decision_valid) begin
                case (state)
                    ST_IDLE: begin
                        elapsed_ms<=0; blind_elapsed<=0; blind_phase_ms<=0;
                        blind_reverse<=0; pump_negative<=0;
                        ramp_stage<=ramp_ms==0 ? 5'd16 : 5'd0;
                        ramp_stage_elapsed<=0; capture_count<=0; timeout_fault<=0;
                        active<=1; duty<=0; state<=ST_RUN;
                    end
                    ST_RUN: begin
                        if (bal_on) begin
                            duty<=0; active<=0; state<=ST_DONE;
                        end else if ((timeout_ms!=0 && elapsed_ms>=timeout_ms-16'd1) ||
                                     (!angle_valid && blind_elapsed>=BLIND_LIMIT_MS)) begin
                            duty<=0; active<=0; timeout_fault<=1; state<=ST_FAIL;
                        end else begin
                            elapsed_ms<=elapsed_ms+16'd1; active<=1;
                            if (angle_valid && sample_valid_r) begin
                                blind_elapsed<=0; blind_phase_ms<=0;
                                if (angle_rate_valid && rate_mag>32'd2560)
                                    pump_negative<=rate_sample_q8_r[31];
                            end else begin
                                blind_elapsed<=blind_elapsed+16'd1;
                                if (blind_phase_ms==BLIND_HALF_MS-8'd1) begin
                                    blind_phase_ms<=0; blind_reverse<=!blind_reverse;
                                end else blind_phase_ms<=blind_phase_ms+8'd1;
                            end
                            if (ramp_ms!=0 && ramp_stage<5'd16) begin
                                if (ramp_step_ms<=16'd1 || ramp_stage_elapsed+16'd1>=ramp_step_ms) begin
                                    ramp_stage_elapsed<=0; ramp_stage<=ramp_stage+5'd1;
                                end else ramp_stage_elapsed<=ramp_stage_elapsed+16'd1;
                            end
                            duty<=(angle_valid && sample_valid_r) ?
                                                        phase_duty[15:0] : blind_duty[15:0];
                            if (capture_condition) begin
                                if (capture_confirmed) begin
                                    duty<=0; active<=0; capture_req<=1;
                                    capture_count<=0; state<=ST_DONE;
                                end else capture_count<=capture_count+10'd1;
                            end else capture_count<=0;
                        end
                    end
                    ST_DONE: begin duty<=0; active<=0; end
                    ST_FAIL: begin duty<=0; active<=0; end
                    default: begin state<=ST_IDLE; duty<=0; active<=0; end
                endcase
            end
        end
    end
endmodule
