`timescale 1ns / 1ps

//=============================================================================
// 模块：cfg_regs
// 作用：解析串口参数帧，并把合法值锁存为控制器配置寄存器。
//
// 帧格式（4 字节，无校验和）：
//   AA | IDX | VALUE_HI | VALUE_LO
//   AA 是帧头；IDX 是参数编号；VALUE 按二补码解释为 signed 16 bit，
//   ZERO、MODE、DLP 等无符号参数仍以同一帧传输。收到完整帧后参数立即更新，
//   upd_cnt 按0..9循环计数完整帧，mode_we 只在本帧接受MODE时拉高一拍。
//
// 参数编号：
//   4 LIM，5 MODE，6 DZ，7 TRIM，10 FALL，12 ENTER，16 ZERO，18 ILIM，
//   21 DLP，23 AKP，24 AKI，25 AKD，26 PKP，27 PKD，28 POSMAX，
//   29 POSTGT，30 ALP，31 SLEW，32 SWLIM，33 SWCAP，34 SWTMO，35 SWDIR。
//   48 TURNS_POSTGT，49 PIDEAD（0..8 count），50 KDBLEND（0..6）。
//   51 VELMODE：0窗口法，1低速周期辅助（反向/高速回退窗口）。
//   52 ADCAVG：0/1/2/3，控制采样前平均1/2/4/8组ADC，默认0保留原行为。
//   36 保留（当前接管只按角度窗口判断）；37 POS_NEAR，38 PKDNEAR，
//   39 POSP_LIM，40 SWAMP，41 SWRAMP，42 SWMS；43 PKI，44 PILIM，45 RLP，46 DZW，47 DZLP，
//   48 TURNS_POSTGT（MODE3 绝对编码器计数目标，signed 16，不额外钳位）。
//   MODE 0=停机、1=手动角度稳定、2=自动起摆后角度稳定、3=绝对位置（转圈/定位）。
//
// 输入 rx_dv 必须是 uart_rx 对每个字节产生的一拍脉冲。解析器是四状态机，
// 只在收到 AA 后进入 IDX/HI/LO；未形成完整四字节帧时不会更新参数，随机字节
// 只有恰好组成合法帧并通过索引/范围检查后才会生效。
//=============================================================================

// 串口参数接收器：接受停机、手动稳定、自动起摆三种模式及控制器参数。
module cfg_regs #(
    parameter integer DEF_MODE = 0,
    parameter integer DEF_ZERO = 508,
    parameter integer DEF_AKP_Q8 = -150,
    parameter integer DEF_AKI_Q8 = 0,
    parameter integer DEF_AKD_Q8 = -400,
    parameter integer DEF_PKP_Q8 = 600,
    parameter integer DEF_PKD_Q8 = -300,
    parameter integer DEF_POSMAX = 600,
    parameter integer DEF_POS_TARGET = 0,
    parameter integer DEF_LIM = 300,
    parameter integer DEF_DZ = 20,
    parameter integer DEF_DZW_SHIFT = 6,
    parameter integer DEF_DZLP = 1,
    parameter integer DEF_PKI_Q8 = 8,
    parameter integer DEF_PILIM = 45,
    parameter integer DEF_RLP = 4,
    parameter integer DEF_TRIM = 20,
    parameter integer DEF_FALL = 1500,
    parameter integer DEF_ENTER = 1000,
    parameter integer DEF_POS_NEAR = 0,
    parameter integer DEF_PKD_NEAR_Q8 = -300,
    parameter integer DEF_POSP_LIM = 427,
    parameter integer DEF_ILIM = 0,
    parameter integer DEF_DLP = 3,
    parameter integer DEF_ALP = 1,
    parameter integer DEF_SLEW = 0,
    parameter integer DEF_SWLIM = 750,
    parameter integer DEF_SWAMP = 670,
    parameter integer DEF_SWRAMP = 200,
    parameter integer DEF_SWMS = 3,
    parameter integer DEF_SWCAP = 800,
    parameter integer DEF_SWTMO = 15000,
    parameter integer DEF_SWDIR = 1,
    parameter integer DEF_TURNS_POSTGT = 0,
    parameter integer DEF_PIDEAD = 4,
    parameter integer DEF_KDBLEND = 0,
    parameter integer DEF_VELMODE = 1,
    parameter integer DEF_ADCAVG = 2,
    parameter integer DEF_RATEMODE = 2,
    parameter integer DEF_HOLDPOS = 70
)(
    input wire clk,
    input wire rst_n,
    input wire rx_dv,
    input wire [7:0] rx_data,
    output reg signed [15:0] lim,
    output reg signed [15:0] dz,
    output reg [3:0] dz_width_shift, dz_lp_shift,
    output reg signed [15:0] trim,
    output reg signed [15:0] fall_th,
    output reg signed [15:0] enter_lim,
    output reg signed [15:0] pos_near,
    output reg signed [15:0] kd_pos_near_q8,
    output reg signed [15:0] pos_p_lim,
    output reg [15:0] zero_set,
    output reg signed [15:0] kp_ang_q8,
    output reg signed [15:0] ki_ang_q8,
    output reg signed [15:0] kd_ang_q8,
    output reg signed [15:0] kp_pos_q8,
    output reg signed [15:0] kd_pos_q8,
    output reg signed [15:0] ki_pos_q8,
    output reg signed [15:0] pos_i_lim,
    output reg [3:0] ref_lp_shift,
    output reg signed [15:0] pos_angle_lim,
    output reg signed [15:0] pos_target,
    // MODE3 绝对位置目标：直接使用 signed 16 位二补码，不做范围钳位。
    output reg signed [15:0] turns_postgt,
    output reg [3:0] pos_i_deadband,
    output reg [3:0] kd_blend_shift,
    output reg velocity_period,
    output reg [1:0] adc_avg_shift,
    output reg [1:0] rate_observer_mode,
    output reg [15:0] hold_position_tol,
    output reg signed [15:0] i_lim,
    output reg [3:0] dlp_shift,
    output reg [3:0] angle_lp_shift,
    output reg [15:0] slew,
    output reg [15:0] swing_lim,
    output reg [15:0] swing_amp,
    output reg [15:0] swing_ramp_ms,
    output reg [15:0] swing_capture_ms,
    output reg [15:0] swing_capture,
    output reg [15:0] swing_timeout,
    output reg signed [15:0] swing_dir,
    output reg [2:0] mode_cmd,
    output reg mode_we,
    output reg [3:0] upd_cnt
);

    // 解析状态严格按字节推进：未看到帧头时保持等待，收到完整四字节后
    // 才执行参数更新，因此半帧或噪声不会写入配置寄存器。
    localparam [1:0] S_HDR = 2'd0;
    localparam [1:0] S_IDX = 2'd1;
    localparam [1:0] S_HI  = 2'd2;
    localparam [1:0] S_LO  = 2'd3;

    reg [1:0] state;
    reg [7:0] index;
    reg [7:0] value_hi;
    // value 在 S_LO 时由已锁存的高字节和当前低字节组成；signed 与 unsigned
    // 两种解释同时保留，避免负增益被当作大正数或 ZERO 被符号扩展。
    wire signed [15:0] value = $signed({value_hi, rx_data});
    wire [15:0] value_u = {value_hi, rx_data};

    // 增益统一限制在 ±4096（Q8，即 ±16.0 实际增益），防止串口误发大值
    // 使乘法中间量溢出；各非增益参数在 S_LO 中按自己的物理范围校验。
    function signed [15:0] clamp_gain;
        input signed [15:0] gain;
        begin
            if (gain > 16'sd4096) clamp_gain = 16'sd4096;
            else if (gain < -16'sd4096) clamp_gain = -16'sd4096;
            else clamp_gain = gain;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_HDR;
            index <= 0;
            value_hi <= 0;
            mode_we <= 0;
            upd_cnt <= 0;
            mode_cmd <= (DEF_MODE == 1) ? 3'd1 :
                        (DEF_MODE == 2) ? 3'd2 :
                        (DEF_MODE == 3) ? 3'd3 : 3'd0;
            lim <= DEF_LIM;
            dz <= DEF_DZ;
            dz_width_shift<=DEF_DZW_SHIFT[3:0]; dz_lp_shift<=DEF_DZLP[3:0];
            trim <= DEF_TRIM;
            fall_th <= DEF_FALL;
            enter_lim <= DEF_ENTER;
            pos_near <= DEF_POS_NEAR;
            kd_pos_near_q8 <= DEF_PKD_NEAR_Q8;
            pos_p_lim <= DEF_POSP_LIM;
            zero_set <= DEF_ZERO;
            kp_ang_q8 <= DEF_AKP_Q8;
            ki_ang_q8 <= DEF_AKI_Q8;
            kd_ang_q8 <= DEF_AKD_Q8;
            kp_pos_q8 <= DEF_PKP_Q8;
            kd_pos_q8 <= DEF_PKD_Q8;
            ki_pos_q8 <= DEF_PKI_Q8;
            pos_i_lim <= DEF_PILIM;
            ref_lp_shift <= DEF_RLP[3:0];
            pos_angle_lim <= DEF_POSMAX;
            pos_target <= DEF_POS_TARGET;
            turns_postgt <= DEF_TURNS_POSTGT;
            pos_i_deadband<=DEF_PIDEAD[3:0];
            kd_blend_shift<=DEF_KDBLEND[3:0];
            velocity_period<=DEF_VELMODE!=0;
            adc_avg_shift<=DEF_ADCAVG[1:0];
            rate_observer_mode<=DEF_RATEMODE[1:0];
            hold_position_tol<=DEF_HOLDPOS[15:0];
            i_lim <= DEF_ILIM;
            dlp_shift <= DEF_DLP[3:0];
            angle_lp_shift <= DEF_ALP[3:0];
            slew <= DEF_SLEW;
            swing_lim <= DEF_SWLIM;
            swing_amp <= DEF_SWAMP;
            swing_ramp_ms <= DEF_SWRAMP;
            swing_capture_ms <= DEF_SWMS;
            swing_capture <= DEF_SWCAP;
            swing_timeout <= DEF_SWTMO;
            swing_dir <= DEF_SWDIR;
        end else begin
            // mode_we 是脉冲而非寄存器电平，顶层据此区分“本拍收到 MODE”
            // 与“保持已有 MODE”。其它参数更新不会触发模式切换。
            mode_we <= 1'b0;
            if (rx_dv) begin
                case (state)
                    S_HDR: if (rx_data == 8'hAA) state <= S_IDX;
                    S_IDX: begin
                        index <= rx_data;
                        state <= S_HI;
                    end
                    S_HI: begin
                        value_hi <= rx_data;
                        state <= S_LO;
                    end
                    S_LO: begin
                        state <= S_HDR;
                        // upd_cnt 只用于遥测确认“收到过多少个完整参数帧”，
                        // 4 bit 到 9 后回到 0，便于上位机观察通信是否仍在工作。
                        upd_cnt <= (upd_cnt == 4'd9) ? 4'd0 : upd_cnt + 1'b1;
                        case (index)
                            8'd4: lim <= (value[15]) ? 16'sd0 :
                                         (value_u > 16'd1023) ? 16'sd1023 : value;
                            8'd5: if ((value_u == 16'd0) || (value_u == 16'd1) ||
                                      (value_u == 16'd2) || (value_u == 16'd3)) begin
                                mode_cmd <= value_u[2:0];
                                mode_we <= 1'b1;
                            end
                            8'd6: dz <= (value[15]) ? 16'sd0 :
                                        (value_u > 16'd1023) ? 16'sd1023 : value;
                            8'd7: if ((value >= -16'sd18000) && (value <= 16'sd18000))
                                      trim <= value;
                            8'd10: if (!value[15] && (value >= 1) && (value <= 16'sd18000))
                                       fall_th <= value;
                            8'd12: if (!value[15] && (value >= 1) && (value <= 16'sd18000))
                                       enter_lim <= value;
                            8'd16: if ((value_u >= 16'd1) && (value_u <= 16'd1022))
                                       zero_set <= value_u;
                            8'd18: i_lim <= (value[15]) ? 16'sd0 :
                                            (value_u > 16'd1023) ? 16'sd1023 : value;
                            8'd21: dlp_shift <= (value_u > 16'd8) ? 4'd8 : value_u[3:0];
                            8'd23: kp_ang_q8 <= clamp_gain(value);
                            8'd24: ki_ang_q8 <= clamp_gain(value);
                            8'd25: kd_ang_q8 <= clamp_gain(value);
                            8'd26: kp_pos_q8 <= clamp_gain(value);
                            8'd27: kd_pos_q8 <= clamp_gain(value);
                            8'd28: if (!value[15] && (value_u <= 16'd18000))
                                       pos_angle_lim <= value;
                            8'd29: if ((value >= -16'sd520) && (value <= 16'sd519))
                                       pos_target <= value;
                            8'd30: if (!value[15])
                                       angle_lp_shift <= (value_u > 16'd8) ? 4'd8 : value_u[3:0];
                            8'd31: if (!value[15] && (value_u <= 16'd1023))
                                       slew <= value_u;
                            8'd32: if (!value[15] && (value_u <= 16'd1023))
                                       swing_lim <= value_u;
                            8'd33: if (!value[15] && (value_u >= 16'd1) &&
                                      (value_u <= 16'd18000))
                                       swing_capture <= value_u;
                            // 超时是无符号毫秒，32768..60000同样有效。
                            8'd34: if ((value_u >= 16'd100) &&
                                      (value_u <= 16'd60000))
                                       swing_timeout <= value_u;
                            8'd35: if ((value == -16'sd1) || (value == 16'sd0) ||
                                      (value == 16'sd1))
                                       swing_dir <= value;
                            8'd37: if (!value[15] && (value_u <= 16'd520))
                                       pos_near <= value;
                            8'd38: kd_pos_near_q8 <= clamp_gain(value);
                            8'd39: if (!value[15] && (value_u <= 16'd1023))
                                       pos_p_lim <= value;
                            8'd40: if (!value[15] && (value_u <= 16'd1023))
                                       swing_amp <= value;
                            8'd41: if (!value[15] && (value_u <= 16'd60000))
                                       swing_ramp_ms <= value;
                            8'd42: if (!value[15] && (value_u >= 16'd1) &&
                                      (value_u <= 16'd1000))
                                       swing_capture_ms <= value;
                            8'd43: if (value>= -16'sd256 && value<=16'sd256)
                                       ki_pos_q8 <= value;
                            8'd44: if (!value[15] && value_u<=16'd600)
                                       pos_i_lim <= value;
                            8'd45: if (value_u<=16'd6) ref_lp_shift<=value_u[3:0];
                            8'd46: case(value_u)
                                1: dz_width_shift<=0; 2: dz_width_shift<=1;
                                4: dz_width_shift<=2; 8: dz_width_shift<=3;
                                16: dz_width_shift<=4; 32: dz_width_shift<=5;
                                64: dz_width_shift<=6; 128: dz_width_shift<=7;
                                256: dz_width_shift<=8; default: ;
                            endcase
                            8'd47: if(value_u<=4) dz_lp_shift<=value_u[3:0];
                            // MODE3 绝对位置目标：signed 16 全范围原样锁存。
                            8'd48: turns_postgt <= value;
                            // 精度与平滑均可在线对照；默认仍用原2count软死区和直接阻尼切换。
                            8'd49: if(value_u<=8) pos_i_deadband<=value_u[3:0];
                            8'd50: if(value_u<=6) kd_blend_shift<=value_u[3:0];
                            8'd51: if(value_u<=1) velocity_period<=value_u[0];
                            8'd52: if(value_u<=3) adc_avg_shift<=value_u[1:0];
                            8'd53: if(value_u<=2) rate_observer_mode<=value_u[1:0];
                            8'd54: if(value_u<=160) hold_position_tol<=value_u;
                            default: ;
                        endcase
                    end
                    default: state <= S_HDR;
                endcase
            end
        end
    end
endmodule
