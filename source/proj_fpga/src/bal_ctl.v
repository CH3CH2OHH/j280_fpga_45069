`timescale 1ns / 1ps

//=============================================================================
// 模块：bal_ctl
// 作用：旋转倒立摆的角度内环控制器，以及可选的编码器位置外环。
//
// 设计约定：
//   1. en 是 1 kHz 控制节拍，控制器只在 en=1 时采样一次输入；各计算级
//      在 50 MHz 系统时钟上继续流水，因此不会把乘法器组合路径拉到 1 kHz。
//   2. ang001、trim、fall_th、enter_lim、pos_angle_lim、ref_ang001 的单位
//      都是 0.01 度（例如 1200 表示 12.00°）。
//   3. kp/ki/kd 使用 Q8 定点：参数值除以 256 才是实际增益；PWM 结果的
//      数值单位为 duty，正负号由电机方向约定决定。
//   4. arm_spd_q8 是编码器速度的 Q8 表示（count/s × 256）。位置外环的
//      pos_count 默认使用单圈有符号相位，先做最短环绕差，再改变角度参考值；
//      pos_abs_mode=1（MODE3）时使用完整32位累计计数，不做单圈环绕。
//   5. bal_on=0 或 fall=1 时清空积分并输出 0，避免停机后残留积分再次冲击电机。
//
// 计算流水：
//   位置外环 POS_IDLE→POS_ZONE→POS_MUL→POS_SUM→POS_LIMIT→POS_REF→POS_FILTER，共 7 拍；
//   角速度由乘法和低通两级预处理；角度 PID 再经过 12 级计算流水。
//   补偿幅值单独寄存后计算乘积与限幅，不改变 1 kHz 采样周期。
//   这些状态不是控制周期，而是单次 1 kHz 采样的硬件计算流水。
//=============================================================================

// 角度 PID 直接输出有符号 PWM；编码器位置环只改变角度目标，不直接驱动电机。
module bal_ctl #(
    parameter integer DUTY_MAX = 1023, // PWM 的最大 duty 数值
    parameter integer POS_CPR = 1040,  // 编码器单圈四倍频计数
    parameter integer POS_UPDATE_DIV = 1, // 位置环更新分频，1=每个控制周期
    parameter integer RATE_WIN_LOG2 = 0  // 测角微分窗口；0保持1ms，2为4ms
)(
    input wire clk,                         // 系统时钟
    input wire rst_n,                       // 同步低有效复位
    input wire en,                          // 1 kHz 控制采样使能
    input wire signed [17:0] ang001,        // 实测角度，0.01°/LSB
    input wire signed [31:0] pos_count,     // 单圈有符号编码器相位，count
    input wire signed [15:0] pos_target,    // 用户指定的单圈位置目标，count
    input wire pos_abs_mode,                // 1=MODE3 绝对位置：位置差不再做单圈最短环绕
    input wire signed [31:0] arm_spd_q8,    // 速度，count/s×256
    input wire signed [15:0] kp_ang_q8,     // 角度 P 增益，Q8
    input wire signed [15:0] ki_ang_q8,     // 角度 I 增益，Q8
    input wire signed [15:0] kd_ang_q8,     // 角度 D 增益，Q8
    input wire signed [15:0] kp_pos_q8,     // 位置 P 增益，Q8
    input wire signed [15:0] kd_pos_q8,     // 位置速度 D 增益，Q8
    input wire signed [15:0] ki_pos_q8,     // 慢速位置积分，Q8 0.01°/(count·s)
    input wire signed [15:0] pos_i_lim,     // 位置积分角度上限，0.01°；0=关闭
    input wire [3:0] pos_i_deadband,        // 位置积分软死区，count；默认2，精调候选0/1
    input wire [3:0] kd_blend_shift,        // 远近区阻尼系数渐变，0旁路，4约15ms
    input wire [3:0] ref_lp_shift,          // 位置参考低通，保留 Q8 小数；0=旁路
    input wire signed [15:0] pos_near,      // 近目标区阈值，count
    input wire signed [15:0] kd_pos_near_q8,// 近目标区位置 D 增益，Q8
    input wire signed [15:0] pos_p_lim,     // 位置 P 项角度参考限幅，0.01°；0=关闭
    input wire signed [15:0] pos_angle_lim, // 位置外环角度偏置上限，0.01°
    input wire signed [15:0] trim,          // 角度目标微调，0.01°
    input wire signed [15:0] lim,           // PWM 输出幅值上限，duty
    input wire signed [15:0] dz,            // 静摩擦死区补偿，duty
    input wire [3:0] dz_width_shift,        // 补偿过渡宽度为 2^此值，3=8 duty
    input wire [3:0] dz_lp_shift,           // 只滤摩擦补偿支路，不延迟原始 PD
    input wire signed [15:0] i_lim,         // 积分项幅值上限，duty
    input wire signed [15:0] fall_th,       // 判倒门限，0.01°
    input wire signed [15:0] enter_lim,     // 允许接管门限，0.01°
    input wire [3:0] dlp_shift,             // 角速度低通移位量，0~8
    input wire [3:0] angle_lp_shift,        // 角度测量低通移位量，0~8
    input wire [1:0] rate_observer_mode,    // 0原微分；1快速、2平滑二状态角速度观测
    input wire [15:0] hold_position_tol,    // 0关闭；1..160count，稳定后暂停位置积分追零
    output wire hold_active,
    input wire signed [15:0] slew,          // PWM 每个控制周期最大变化量，0=关闭
    input wire bal_on,                      // 顶层许可的平衡控制状态
    output wire signed [17:0] ref_ang001,   // 角度环参考值，0.01°/LSB
    output reg signed [15:0] duty,          // 有符号 PWM 命令，duty
    output reg fall,                        // 连续超限后置位的判倒状态
    output reg near,                        // 连续进入范围后置位的接管条件
    output wire signed [31:0] angle_rate_q8 // 滤波角速度，°/s×256
);

    // 角度 PID 流水状态。先等待角速度的乘法和低通滤波级完成，再依次
    // 推进 PID 运算；各状态是 50 MHz 系统时钟级，不是控制周期。
    localparam [4:0] ST_IDLE      = 5'd0;
    localparam [4:0] ST_RATE_MUL  = 4'd1;
    localparam [4:0] ST_RATE_FILT = 4'd2;
    localparam [4:0] ST_MUL       = 4'd3;
    localparam [4:0] ST_SCALE     = 4'd4;
    localparam [4:0] ST_AW_SUM    = 4'd5;
    localparam [4:0] ST_AW_LIMIT  = 4'd6;
    localparam [4:0] ST_AW_MUL    = 4'd7;
    localparam [4:0] ST_AW_BLOCK  = 4'd8;
    localparam [4:0] ST_I_ACC     = 4'd9;
    localparam [4:0] ST_I_SUM     = 4'd10;
    localparam [4:0] ST_OUT_BASE  = 4'd11;
    localparam [4:0] ST_OUT_MUL   = 4'd12;
    localparam [4:0] ST_OUT_FINAL = 4'd13;
    localparam [4:0] ST_OUT_APPLY = 4'd14;
    localparam [4:0] ST_OUT_PREP  = 4'd15;
    localparam [4:0] ST_COMP_FILTER = 5'd16;
    localparam [4:0] ST_RATE_OBSERVER = 5'd17;

    // 角速度预处理状态。每个 en 启动一组差分，乘法与低通滤波分拍完成。
    localparam [1:0] RATE_IDLE = 2'd0;
    localparam [1:0] RATE_MUL  = 2'd1;
    localparam [1:0] RATE_FILT = 2'd2;

    // 位置外环流水状态；位置环仅改变 ref_ang001，不直接驱动 PWM。
    localparam [2:0] POS_IDLE  = 3'd0;
    localparam [2:0] POS_MUL   = 3'd1;
    localparam [2:0] POS_SUM   = 3'd2;
    localparam [2:0] POS_LIMIT = 3'd3;
    localparam [2:0] POS_REF   = 3'd4;
    localparam [2:0] POS_ZONE  = 3'd5;
    localparam [2:0] POS_FILTER = 3'd6;
    localparam [2:0] POS_ERROR = 3'd7;
    localparam integer POS_COUNT_W = ($clog2(POS_CPR) > 16) ? $clog2(POS_CPR) : 16;
    localparam integer POS_DELTA_W = POS_COUNT_W + 1;
    localparam signed [POS_DELTA_W-1:0] POS_CPR_EXT = POS_CPR;
    localparam signed [POS_DELTA_W-1:0] POS_HALF_EXT = POS_CPR / 2;

    // Q8 到整数 duty 的对称四舍五入。负数先取绝对值，避免 Verilog
    // 算术右移对负数直接截断造成正负方向不同的量化偏差。
    function signed [47:0] round_q8;
        input signed [47:0] value;
        reg signed [47:0] magnitude;
        begin
            if (value >= 0) begin
                round_q8 = (value + 48'sd128) >>> 8;
            end else begin
                magnitude = -value;
                round_q8 = -((magnitude + 48'sd128) >>> 8);
            end
        end
    endfunction

    // 将宽位宽中间结果限幅到当前 PWM 上限，防止截低位时发生回绕。
    function signed [15:0] clamp_duty;
        input signed [47:0] value;
        input [9:0] limit;
        reg signed [47:0] limit_ext;
        begin
            limit_ext = $signed({38'd0, limit});
            if (value > limit_ext) clamp_duty = $signed({6'd0, limit});
            else if (value < -limit_ext) clamp_duty = -$signed({6'd0, limit});
            else clamp_duty = value[15:0];
        end
    endfunction

    // 对变化率限制结果做显式 16 位返回，避免工具把 17 位加法结果
    // 隐式截断并产生综合警告。
    function signed [15:0] apply_slew;
        input signed [16:0] current;
        input signed [16:0] target;
        input [9:0] step;
        reg signed [16:0] delta;
        reg signed [16:0] result;
        begin
            delta = target - current;
            if (step == 0)
                result = target;
            else if (delta > $signed({1'b0, step}))
                result = current + $signed({1'b0, step});
            else if (delta < -$signed({1'b0, step}))
                result = current - $signed({1'b0, step});
            else
                result = target;
            apply_slew = result[15:0];
        end
    endfunction

    // 位置外环使用用户指定的单圈目标，误差按最短环绕差计算。
    reg signed [17:0] ref_ang001_r;
    reg signed [31:0] ref_filter_q8;
    reg signed [31:0] pos_i_q16;
    // 平均误差内部用Q15，避免128ms低通在Q8下丢掉约0.5count正偏差。
    reg signed [31:0] pos_error_avg_q15;
    reg signed [32:0] pos_i_product_r;
    reg signed [15:0] ki_pos_r, pos_i_lim_r, target_last_r;
    reg [3:0] ref_shift_r;
    reg [9:0] target_settle_ms;
    reg pos_i_allowed_r;
    reg [2:0] pos_state;
    localparam integer POS_DIV = (POS_UPDATE_DIV < 1) ? 1 : POS_UPDATE_DIV;
    localparam integer POS_DIV_W = (POS_DIV <= 1) ? 1 : $clog2(POS_DIV);
    reg [POS_DIV_W-1:0] pos_div_count;
    reg signed [POS_DELTA_W-1:0] pos_delta_r;
    reg signed [32:0] pos_abs_delta_r;
    reg signed [POS_DELTA_W-1:0] pos_short_delta_r;
    reg pos_abs_r, pos_abs_last_r;
    reg signed [23:0] kd_blend_q8;
    reg signed [31:0] arm_spd_pos_r;
    reg signed [15:0] kp_pos_r, kd_pos_r, trim_pos_r;
    reg signed [15:0] kd_pos_near_r, pos_p_lim_r;
    reg pos_near_zone_r;
    reg [15:0] pos_lim_mag_r;
    reg signed [48:0] pos_term_r;
    reg signed [47:0] vel_term_r;
    reg signed [50:0] pos_bias_raw_r;
    reg signed [50:0] pos_bias_limited_r;
    reg signed [17:0] angle_filt_r;
    reg signed [25:0] angle_filt_q8;
    reg angle_initialized,angle_round_pending;
    reg signed [27:0] rate_f_q8;
    reg [1:0] rate_state;
    reg signed [26:0] angle_diff_r;
    localparam integer RATE_WIN = 1 << RATE_WIN_LOG2;
    reg signed [25:0] rate_history [0:RATE_WIN-1];
    integer rate_index;
    reg signed [27:0] rate_input_q8_r;
    reg [3:0] dlp_shift_r;
    reg [1:0] warm_count;
    reg [3:0] fall_count;
    reg [2:0] near_count;
    reg signed [47:0] i_acc_q24;
    reg [4:0] state;

    // 供自动起摆状态机使用的滤波角速度，保持 Q8 定点量纲。
    wire signed [27:0] observed_fast_q8, observed_smooth_q8;
    reg signed [27:0] reported_rate_q8, pid_rate_next_q8;
    reg [1:0] rate_mode_r;
    // 两路观测持续保留各自历史，在线选择不会重置或虚构初始角速度。
    angle_rate_observer #(.ALPHA_SHIFT(1),.BETA_SHIFT(3)) u_rate_fast(
        .clk(clk),.rst_n(rst_n),.en(en),.angle_q8(angle_filter_next_q8[25:0]),
        .rate_q8(observed_fast_q8));
    angle_rate_observer #(.ALPHA_SHIFT(2),.BETA_SHIFT(5)) u_rate_smooth(
        .clk(clk),.rst_n(rst_n),.en(en),.angle_q8(angle_filter_next_q8[25:0]),
        .rate_q8(observed_smooth_q8));
    always @* begin
        // 默认分支逐拍保留旧PID预处理与对外角速度数据的相对时序。
        reported_rate_q8=rate_f_q8;
        pid_rate_next_q8=rate_filtered_next;
        case(rate_observer_mode)
            1: reported_rate_q8=observed_fast_q8;
            2: reported_rate_q8=observed_smooth_q8;
            default: ;
        endcase
        case(rate_mode_r)
            1: pid_rate_next_q8=observed_fast_q8;
            2: pid_rate_next_q8=observed_smooth_q8;
            default: ;
        endcase
    end
    assign angle_rate_q8 = {{4{reported_rate_q8[27]}}, reported_rate_q8};

    // 单圈编码器位置有效位宽由 POS_CPR 决定，至少保留 16 位目标参数；
    // 额外一位用于相减，避免 32 位符号扩展形成过长的位置比较路径。
    wire signed [POS_DELTA_W-1:0] pos_target_ext =
        {{(POS_DELTA_W-16){pos_target[15]}}, pos_target};
    wire signed [POS_DELTA_W-1:0] pos_count_ext =
        {{(POS_DELTA_W-POS_COUNT_W){pos_count[POS_COUNT_W-1]}},
          pos_count[POS_COUNT_W-1:0]};
    wire signed [POS_DELTA_W-1:0] pos_delta_raw = pos_count_ext - pos_target_ext;
    wire signed [POS_DELTA_W-1:0] pos_delta_short =
        (pos_delta_raw > POS_HALF_EXT) ? pos_delta_raw - POS_CPR_EXT :
        (pos_delta_raw < -POS_HALF_EXT) ? pos_delta_raw + POS_CPR_EXT : pos_delta_raw;
    // 绝对模式先以33位相减，下一系统时钟饱和到外环有效范围，绝不截取计数低16位。
    // 超大误差只需要保留方向：P项已独立限幅，积分只在近目标区启用。
    wire signed [32:0] pos_abs_delta = $signed({pos_count[31],pos_count})-
                                                     $signed({{17{pos_target[15]}},pos_target});
    localparam signed [32:0] POS_DELTA_MAX = (33'sd1 << (POS_DELTA_W-1))-33'sd1;
    wire signed [POS_DELTA_W-1:0] pos_abs_limited =
        pos_abs_delta_r>POS_DELTA_MAX ? POS_DELTA_MAX[POS_DELTA_W-1:0] :
        pos_abs_delta_r< -POS_DELTA_MAX ? -POS_DELTA_MAX[POS_DELTA_W-1:0] :
                                             pos_abs_delta_r[POS_DELTA_W-1:0];
    wire signed [POS_DELTA_W-1:0] pos_delta_sample = bal_on ?
        pos_delta_r : {POS_DELTA_W{1'b0}};
    wire [15:0] pos_lim_mag_sample = (pos_angle_lim <= 0) ? 16'd0 :
                                     (pos_angle_lim > 16'sd18000) ? 16'd18000 :
                                     pos_angle_lim[15:0];
    // 乘法在POS_ZONE先寄存，POS_MUL只做限幅；输出提交节拍保持原样。
    // 17位位置差乘16位增益恰好为33位，避免乘法与限幅串在一条时序路径。
    reg signed [32:0] pos_product_r;
    wire signed [32:0] pos_product_next = $signed(pos_delta_r) * $signed(kp_pos_r);
    wire signed [48:0] pos_term_next = {{16{pos_product_r[32]}},pos_product_r};
    wire signed [48:0] pos_p_lim_q8 = $signed({33'd0, pos_p_lim_r}) <<< 8;
    wire signed [48:0] pos_term_limited_next = (pos_p_lim_r <= 0) ? 49'sd0 :
        (pos_term_next > pos_p_lim_q8) ? pos_p_lim_q8 :
        (pos_term_next < -pos_p_lim_q8) ? -pos_p_lim_q8 : pos_term_next;
    wire signed [15:0] kd_pos_target = pos_near_zone_r ?
                                          kd_pos_near_r : kd_pos_r;
    wire signed [23:0] kd_target_q8 = {kd_pos_target,8'd0};
    wire signed [24:0] kd_residual = $signed({kd_target_q8[23],kd_target_q8})-
                                                    $signed({kd_blend_q8[23],kd_blend_q8});
    wire signed [24:0] kd_blended_next = $signed({kd_blend_q8[23],kd_blend_q8})+
                                                            (kd_residual>>>kd_blend_shift);
    wire signed [24:0] kd_rounded = kd_blend_q8>=0 ?
        ($signed({kd_blend_q8[23],kd_blend_q8})+25'sd128)>>>8 :
        -((-$signed({kd_blend_q8[23],kd_blend_q8})+25'sd128)>>>8);
    wire signed [15:0] kd_pos_selected = kd_blend_shift==0 ? kd_pos_target : kd_rounded[15:0];
    wire signed [47:0] vel_term_next =
        $signed(arm_spd_pos_r) * $signed(kd_pos_selected);
    // 先寄存单圈最短位置差，再判定近区；避免编码器归一化、环绕、绝对值与
    // 多个回差比较器串在同一条 50MHz 路径上。
    wire [POS_DELTA_W-1:0] pos_delta_mag = pos_delta_r[POS_DELTA_W-1] ?
        -pos_delta_r : pos_delta_r;
    wire [POS_DELTA_W-1:0] pos_near_mag = (pos_near <= 0) ? {POS_DELTA_W{1'b0}} :
        {{(POS_DELTA_W-16){1'b0}}, pos_near[15:0]};
    wire [POS_DELTA_W-1:0] pos_near_hyst = pos_near_mag + (pos_near_mag >> 3);
    wire pos_near_zone_next = (pos_near_mag == 0) ? 1'b0 :
        pos_near_zone_r ? (pos_delta_mag <= pos_near_hyst) :
                          (pos_delta_mag < pos_near_mag);
    // 速度项按 P-PKD*SPD 合成；符号还取决于电机、编码器及角度内环方向。
    // 本工程已验证方向使用 PKD<0，不能仅根据公式中的减号翻转参数符号。
    wire signed [50:0] pos_bias_sum_next =
        $signed({{2{pos_term_r[48]}}, pos_term_r}) -
        $signed({{3{vel_term_r[47]}}, (vel_term_r >>> 8)}) +
        $signed({{19{pos_i_q16[31]}}, (pos_i_q16 >>> 8)});
    wire signed [50:0] pos_lim_q8 = $signed({{27{1'b0}}, pos_lim_mag_r, 8'd0});
    wire signed [50:0] pos_bias_limited_next =
        (pos_bias_raw_r > pos_lim_q8) ? pos_lim_q8 :
        (pos_bias_raw_r < -pos_lim_q8) ? -pos_lim_q8 : pos_bias_raw_r;
    // 正负参考均做对称舍入，避免负数直接截位额外产生 -1 cdeg 偏置。
    wire signed [50:0] pos_bias_rounded = pos_bias_limited_r>=0 ?
        (pos_bias_limited_r+51'sd128)>>>8 : -((-pos_bias_limited_r+51'sd128)>>>8);
    wire signed [15:0] pos_bias_cdeg_next = pos_bias_rounded[15:0];
    wire signed [32:0] pos_ref_sum_next =
        $signed({{17{trim_pos_r[15]}}, trim_pos_r}) +
        $signed({{17{pos_bias_cdeg_next[15]}}, pos_bias_cdeg_next});
    wire signed [17:0] pos_ref_limited_next =
        (pos_ref_sum_next > 33'sd18000) ? 18'sd18000 :
        (pos_ref_sum_next < -33'sd18000) ? -18'sd18000 :
        pos_ref_sum_next[17:0];
    assign ref_ang001 = ref_ang001_r;

    // 参考滤波独立于角度微分，不延迟角度传感器反馈；Q8 防止小步长被截没。
    wire signed [31:0] ref_target_raw_q8 = $signed({{8{trim_pos_r[15]}},trim_pos_r,8'd0}) +
                                                     $signed(pos_bias_limited_r[31:0]);
    wire signed [31:0] ref_target_q8 = ref_target_raw_q8>32'sd4608000 ? 32'sd4608000 :
        ref_target_raw_q8< -32'sd4608000 ? -32'sd4608000 : ref_target_raw_q8;
    wire signed [32:0] ref_residual_q8 = $signed({ref_target_q8[31],ref_target_q8})-
                                                       $signed({ref_filter_q8[31],ref_filter_q8});
    wire signed [32:0] ref_filtered_ext = $signed({ref_filter_q8[31],ref_filter_q8})+
                                                       (ref_residual_q8>>>ref_shift_r);
    wire signed [31:0] ref_filtered_next = ref_shift_r==0 ? ref_target_q8 : ref_filtered_ext[31:0];
    wire signed [31:0] ref_filtered_rounded = ref_filter_q8>=0 ?
        (ref_filter_q8+32'sd128)>>>8 : -((-ref_filter_q8+32'sd128)>>>8);

    // 每毫秒积分：Q8 增益×count×262/1024 转为 Q16，误差小于 0.06%。
    // 慢速补偿残余平衡偏角；运动、输出饱和、外环限幅时冻结，停机清空。
    wire signed [41:0] pos_i_product_ext = {{9{pos_i_product_r[32]}},pos_i_product_r};
    wire signed [41:0] pos_i_step_scaled = (pos_i_product_ext<<<8)+
                                                (pos_i_product_ext<<<2)+(pos_i_product_ext<<<1);
    wire signed [41:0] pos_i_candidate = $signed({{10{pos_i_q16[31]}},pos_i_q16})+
                                                        ((pos_i_step_scaled>>>10)*POS_DIV);
    wire signed [41:0] pos_i_cap = $signed({10'd0,pos_i_lim_r,16'd0});
    // 积分只学习持续位置偏差，避免把编码器台阶和往返振荡逐点积分。
    // 128ms低通独立于P/D反馈，不增加角度阻尼通路延迟。
    // 17位位置差×2^15恰好容纳于signed32，33位残差覆盖极值之间的差。
    wire signed [31:0] pos_error_input_q15 = $signed(pos_delta_sample) <<< 15;
    wire signed [32:0] pos_error_residual = $signed({pos_error_input_q15[31],pos_error_input_q15})-
                                          $signed({pos_error_avg_q15[31],pos_error_avg_q15});
    wire signed [32:0] pos_error_avg_next = $signed({pos_error_avg_q15[31],pos_error_avg_q15})+
                                           (pos_error_residual>>>7);
    wire signed [32:0] pos_error_fine_ext = {pos_error_avg_q15[31],pos_error_avg_q15};
    wire signed [32:0] pos_error_avg_rounded = pos_error_fine_ext>=0 ?
        (pos_error_fine_ext+33'sd64)>>>7 : -((-pos_error_fine_ext+33'sd64)>>>7);
    wire signed [31:0] pos_error_avg_q8 = pos_error_avg_rounded[31:0];
    // 仅积分学习设置±2count软死区，P/D仍连续工作，不冻结电机。
    // 防止已在编码器分辨率附近时积分持续爬升，再次冲破静摩擦门槛。
    wire signed [31:0] pos_i_dead_q8 = $signed({20'd0,pos_i_deadband,8'd0});
    wire signed [31:0] pos_i_error_q8 = pos_error_avg_q8>pos_i_dead_q8 ? pos_error_avg_q8-pos_i_dead_q8 :
        pos_error_avg_q8< -pos_i_dead_q8 ? pos_error_avg_q8+pos_i_dead_q8 : 32'sd0;
    wire signed [47:0] pos_i_avg_product = $signed(pos_i_error_q8)*$signed(ki_pos_r);
    // 单圈误差与Q8增益的乘积移除8位小数后可容纳于33位，显式取位避免截断警告。
    wire signed [47:0] pos_i_avg_scaled = pos_i_avg_product>>>8;
    wire signed [31:0] pos_i_limited = pos_i_candidate>pos_i_cap ? pos_i_cap[31:0] :
        pos_i_candidate< -pos_i_cap ? -pos_i_cap[31:0] : pos_i_candidate[31:0];
    wire pos_i_output_free = lim>16'sd16 && duty<lim-16'sd16 && duty> -lim+16'sd16;
    wire pos_i_ref_free = pos_bias_raw_r<pos_lim_q8 && pos_bias_raw_r> -pos_lim_q8;
    wire signed [18:0] hold_angle_relative=$signed({angle_filt_r[17],angle_filt_r})-
                                                     $signed({{3{trim[15]}},trim});
    position_hold u_position_hold(
        .clk(clk),.rst_n(rst_n),.en(en),.bal_on(bal_on),.fall(fall),
        .target_changed(pos_target!=target_last_r || pos_abs_mode!=pos_abs_last_r),
        .tolerance(hold_position_tol),.position_error(pos_delta_sample),.position(pos_count),
        .angle_relative(hold_angle_relative),.angle_rate_q8(angle_rate_q8),
        .arm_speed_q8(arm_spd_q8),.active(hold_active));

    // 角度测量先经过一阶低通，再用于接管判定、微分和 PID。遥测仍发送
    // 原始换算角度，便于区分传感器噪声和控制器滤波造成的变化。
    wire signed [26:0] angle_input_q8 = {ang001[17],ang001,8'd0};
    wire signed [26:0] angle_previous_q8 = {angle_filt_q8[25],angle_filt_q8};
    wire signed [26:0] angle_filter_residual = angle_input_q8-angle_previous_q8;
    wire signed [26:0] angle_filter_next_q8 = angle_lp_shift==0 ? angle_input_q8 :
                         angle_previous_q8+(angle_filter_residual>>>angle_lp_shift);
    // 保留小数后低通不会对负数额外偏一侧，微分也不再被整数角度台阶放大。
    wire signed [26:0] angle_filter_rounded = angle_previous_q8>=0 ?
        (angle_previous_q8+27'sd128)>>>8 : -((-angle_previous_q8+27'sd128)>>>8);
    wire signed [17:0] angle_filter_next = angle_filter_rounded[17:0];
    wire signed [18:0] angle_filter_next_ext = {angle_filter_next[17],angle_filter_next};

    // ang001 与 trim 的单位为 0.01°；内环 P/I/D 结果统一为 Q8 PWM。
    // 位置外环用编码器计数和 counts/s 生成角度目标偏置，增益为零时完全旁路。
    // 接管/判倒使用角度的绝对偏差，而不是原始 ADC；因此 trim 改变后
    // 两个判定门限仍然围绕新的目标工作。
    // 角度 P/I 使用当前采样更新后的滤波角度；角速度在独立流水中计算，
    // 不再与滤波器组合逻辑串接。
    wire signed [18:0] angle_ext = {angle_filt_r[17], angle_filt_r};
    wire signed [18:0] trim_ext = {{3{trim[15]}}, trim};
    wire signed [18:0] upright_err = angle_ext - trim_ext;
    wire [18:0] upright_mag = upright_err[18] ? -upright_err : upright_err;
    wire near_condition = (enter_lim > 0) &&
                          (upright_mag <= {3'd0, enter_lim});
    wire fall_condition = (fall_th > 0) &&
                          (upright_mag >= {3'd0, fall_th});

    // 用固定时间窗平均斜率抑制相邻1ms采样噪声，保持真实慢速角速度增益。
    // 历史在en时更新，差分读取更新前最老样本；窗口1与原算法完全等价。
    wire signed [26:0] rate_oldest_q8 = {rate_history[RATE_WIN-1][25],rate_history[RATE_WIN-1]};
    wire signed [26:0] angle_diff_next = angle_filter_next_q8-rate_oldest_q8;
    // 差分已有 Q8 小数，乘 10 后直接是 °/s×256，禁止再左移 8 位。
    wire signed [30:0] angle_diff_ext = {{4{angle_diff_r[26]}}, angle_diff_r};
    wire signed [30:0] rate_window_delta = (angle_diff_ext <<< 3) +
                                             (angle_diff_ext <<< 1);
    wire signed [30:0] rate_delta_next = rate_window_delta >>> RATE_WIN_LOG2;
    wire signed [27:0] rate_input_next = rate_delta_next>31'sd134217727 ? 28'sh7ffffff :
        rate_delta_next< -31'sd134217728 ? 28'sh8000000 : rate_delta_next[27:0];
    wire signed [28:0] rate_residual_next =
        $signed({rate_input_q8_r[27], rate_input_q8_r}) -
        $signed({rate_f_q8[27], rate_f_q8});
    wire signed [28:0] rate_filtered_ext_next =
        $signed({rate_f_q8[27], rate_f_q8}) + (rate_residual_next >>> dlp_shift_r);
    // DLP=0 时旁路速度低通；数值越大，滤波越强，但微分相位滞后越大。
    wire signed [27:0] rate_filtered_next = (dlp_shift_r == 0) ?
        rate_input_q8_r : rate_filtered_ext_next[27:0];

    reg signed [18:0] error_r;
    reg signed [27:0] rate_r_q8;
    reg signed [15:0] kp_r, ki_r, kd_r;
    reg [9:0] lim_r, dz_r, i_lim_r, slew_r;
    reg signed [34:0] p_prod, i_prod;
    reg signed [43:0] d_prod;
    reg signed [34:0] p_q8;
    reg signed [43:0] d_q8;
    reg signed [42:0] i_delta_q24;
    reg signed [47:0] total_q8;
    reg signed [47:0] no_i_sum_q8_r;
    reg signed [15:0] no_i_base_r;
    reg no_i_over_pos_r, no_i_over_neg_r;
    reg [20:0] no_i_comp_product_r;
    reg i_blocked_by_output_r;
    reg signed [47:0] i_accept_q24_r;
    reg signed [15:0] base_duty_r;
    reg signed [15:0] duty_limited_r;
    reg [20:0] comp_product_r;
    reg [3:0] dz_width_r, dz_lp_r;
    reg signed [31:0] comp_filter_q8;
    reg [10:0] comp_mag_r;
    reg comp_positive_r,comp_negative_r;

    // 积分器内部采用 Q24：error(0.01°)×ki(Q8) 先得到 Q8，再乘 168/256
    // 折算为每 1 ms 的积分增量并左移到 Q24，最终输出时右移 16 回到 Q8。
    wire signed [42:0] i_prod_scaled =
        $signed({{8{i_prod[34]}}, i_prod}) * 9'sd168;
    wire signed [47:0] i_delta_ext = {{5{i_delta_q24[42]}}, i_delta_q24};
    wire signed [47:0] i_candidate_q24 = i_acc_q24 + i_delta_ext;
    wire signed [47:0] i_cap_q24 = $signed({14'd0, i_lim_r, 24'd0});
    wire signed [47:0] i_cap_neg_q24 = -i_cap_q24;
    wire signed [47:0] i_candidate_limited =
        (i_candidate_q24 > i_cap_q24) ? i_cap_q24 :
        (i_candidate_q24 < i_cap_neg_q24) ? i_cap_neg_q24 : i_candidate_q24;
    wire signed [31:0] i_old_q8 = $signed(i_acc_q24) >>> 16;
    wire signed [47:0] p_ext = {{13{p_q8[34]}}, p_q8};
    wire signed [47:0] d_ext = {{4{d_q8[43]}}, d_q8};
    wire signed [47:0] i_old_ext = {{16{i_old_q8[31]}}, i_old_q8};
    wire signed [47:0] sum_without_i_q8 = p_ext + d_ext + i_old_ext;
    wire signed [47:0] no_i_rounded_next = round_q8(no_i_sum_q8_r);
    wire signed [15:0] no_i_base_next = clamp_duty(no_i_rounded_next, lim_r);
    wire no_i_over_pos_next = (no_i_rounded_next > lim_ext_q8_rounded);
    wire no_i_over_neg_next = (no_i_rounded_next < -lim_ext_q8_rounded);
    wire signed [16:0] no_i_ext = {no_i_base_r[15], no_i_base_r};
    wire [16:0] no_i_mag_ext = no_i_ext[16] ? -no_i_ext : no_i_ext;
    wire [10:0] no_i_mag = no_i_mag_ext[10:0];
    wire [20:0] no_i_comp_product_next = no_i_mag * dz_r;
    // 可调过渡宽度：宽度过大时小命令仍推不动电机，形成粘滑极限环。
    wire [10:0] dz_width = 11'd1 << dz_width_r;
    wire [20:0] no_i_comp_scaled = no_i_comp_product_r >> dz_width_r;
    wire [9:0] no_i_comp_next = (no_i_mag < dz_width) ? no_i_comp_scaled[9:0] : dz_r;
    wire signed [16:0] no_i_with_dz_next = (no_i_base_r > 0) ?
        ($signed({no_i_base_r[15], no_i_base_r}) + $signed({7'd0, no_i_comp_next})) :
        (no_i_base_r < 0) ?
        ($signed({no_i_base_r[15], no_i_base_r}) - $signed({7'd0, no_i_comp_next})) : 17'sd0;
    wire signed [16:0] lim_ext = $signed({7'd0, lim_r});
    wire signed [47:0] lim_ext_q8_rounded = $signed({31'd0, lim_r});
    // 抗积分饱和：若 P+D+当前 I 已在正/负限幅且本次积分还会把输出
    // 推向同一方向，则冻结积分；反方向积分仍可把积分器拉回有效范围。
    wire i_blocked_by_output_next =
        (no_i_over_pos_r && (i_delta_q24 > 0)) ||
        (no_i_over_neg_r && (i_delta_q24 < 0)) ||
        ((no_i_with_dz_next > lim_ext) && (i_delta_q24 > 0)) ||
        ((no_i_with_dz_next < -lim_ext) && (i_delta_q24 < 0));
    wire signed [47:0] i_accept_q24_next =
        i_blocked_by_output_r ? i_acc_q24 : i_candidate_limited;
    wire signed [31:0] i_accept_q8 = $signed(i_accept_q24_r) >>> 16;
    wire signed [47:0] i_accept_ext = {{16{i_accept_q8[31]}}, i_accept_q8};
    wire signed [47:0] total_next_q8 = p_ext + d_ext + i_accept_ext;
    wire signed [47:0] rounded_q8_next = round_q8(total_q8);
    wire signed [15:0] base_duty_next = clamp_duty(rounded_q8_next, lim_r);
    wire signed [16:0] base_ext = {base_duty_r[15], base_duty_r};
    wire [16:0] base_mag_ext = base_ext[16] ? -base_ext : base_ext;
    wire [10:0] base_mag = base_mag_ext[10:0];
    wire signed [31:0] comp_target_q8 = $signed({{8{base_duty_r[15]}},base_duty_r,8'd0});
    wire signed [32:0] comp_residual = $signed({comp_target_q8[31],comp_target_q8})-
                                                        $signed({comp_filter_q8[31],comp_filter_q8});
    wire signed [32:0] comp_filtered_ext = $signed({comp_filter_q8[31],comp_filter_q8})+
                                                                  (comp_residual>>>dz_lp_r);
    wire signed [31:0] comp_filter_next = dz_lp_r==0 ? comp_target_q8 : comp_filtered_ext[31:0];
    wire signed [31:0] comp_base_rounded = comp_filter_q8>=0 ?
        (comp_filter_q8+32'sd128)>>>8 : -((-comp_filter_q8+32'sd128)>>>8);
    wire [10:0] comp_filtered_mag = comp_base_rounded[31] ? -comp_base_rounded[10:0] : comp_base_rounded[10:0];
    // 补偿只允许助推当前命令；旧方向残留不得抵消反向纠偏。
    // 当前命令接近零时同时收缩补偿幅值，禁止低通残留把小命令放大成突跳。
    wire comp_same_direction = (base_duty_r>0 && comp_base_rounded>0) ||
                               (base_duty_r<0 && comp_base_rounded<0);
    wire [10:0] comp_mag = !comp_same_direction ? 11'd0 :
                         comp_filtered_mag<base_mag ? comp_filtered_mag : base_mag;
    wire [20:0] comp_product_next = comp_mag_r * dz_r;
    wire [20:0] comp_scaled = comp_product_r >> dz_width_r;
    wire [9:0] compensation_next = comp_mag_r<dz_width ? comp_scaled[9:0] : dz_r;
    wire signed [16:0] with_dz_next = comp_positive_r ?
        ($signed({base_duty_r[15], base_duty_r}) + $signed({7'd0, compensation_next})) :
        comp_negative_r ?
        ($signed({base_duty_r[15], base_duty_r}) - $signed({7'd0, compensation_next})) :
        $signed({base_duty_r[15],base_duty_r});
    wire signed [15:0] duty_limited = (with_dz_next > lim_ext) ? $signed({6'd0, lim_r}) :
                                     (with_dz_next < -lim_ext) ? -$signed({6'd0, lim_r}) :
                                     with_dz_next[15:0];
    // 输出变化率限制用于抑制 ADC 噪声和摩擦补偿造成的瞬时换向；设置为 0
    // 时保持原有控制器行为。限幅在最终 PWM 级完成，因此不会改变 PID 内部积分。
    wire signed [15:0] duty_slew_limited = apply_slew(
        $signed({duty[15], duty}), $signed({duty_limited_r[15], duty_limited_r}), slew_r);

    // 角度历史、微分滤波、接管计数和判倒计数。fall 需要连续约 10 ms
    // 超过门限才置位，near 需要连续多个样本才允许接管，均用于抗抖动。
    always @(posedge clk) begin
        if (!rst_n) begin
            angle_filt_r <= 0;
            angle_filt_q8 <= 0;
            angle_initialized <= 1'b0;
            angle_round_pending<=0;
            warm_count <= 0;
            fall_count <= 0;
            near_count <= 0;
            fall <= 0;
            near <= 0;
        end else begin
            angle_round_pending<=en;
            if(angle_round_pending) angle_filt_r<=angle_filter_next;
            if(en) begin
            if (!angle_initialized) begin
                angle_filt_q8 <= {ang001,8'd0};
                angle_initialized <= 1'b1;
            end else begin
                angle_filt_q8 <= angle_filter_next_q8[25:0];
            end
            if (warm_count < 3) warm_count <= warm_count + 1'b1;

            if (fall_condition) begin
                if (fall_count < 10) fall_count <= fall_count + 1'b1;
                if (fall_count >= 9) fall <= 1'b1;
            end else begin
                fall_count <= 0;
                fall <= 1'b0;
            end

            if (near_condition && warm_count >= 2) begin
                if (near_count < 4) near_count <= near_count + 1'b1;
                if (near_count >= 3) near <= 1'b1;
            end else begin
                near_count <= 0;
                near <= 1'b0;
            end
            end
        end
    end

    // 角速度分两拍计算，避免角度滤波、差分缩放和速度低通串成一条长路径。
    // 低通系数在 en 时锁存，确保与对应的角度样本配对。
    always @(posedge clk) begin
        if (!rst_n) begin
            rate_state <= RATE_IDLE;
            for(rate_index=0;rate_index<RATE_WIN;rate_index=rate_index+1)
                rate_history[rate_index]<=0;
            angle_diff_r <= 0;
            rate_input_q8_r <= 0;
            dlp_shift_r <= 0;
            rate_f_q8 <= 0;
        end else begin
            if(en) begin
                if(!angle_initialized) begin
                    for(rate_index=0;rate_index<RATE_WIN;rate_index=rate_index+1)
                        rate_history[rate_index]<=angle_input_q8[25:0];
                end else begin
                    rate_history[0]<=angle_filter_next_q8[25:0];
                    for(rate_index=1;rate_index<RATE_WIN;rate_index=rate_index+1)
                        rate_history[rate_index]<=rate_history[rate_index-1];
                end
            end
            case (rate_state)
                RATE_IDLE: if (en) begin
                    angle_diff_r <= angle_initialized ? angle_diff_next : 27'sd0;
                    dlp_shift_r <= dlp_shift;
                    rate_state <= RATE_MUL;
                end
                RATE_MUL: begin
                    rate_input_q8_r <= rate_input_next;
                    rate_state <= RATE_FILT;
                end
                RATE_FILT: begin
                    rate_f_q8 <= rate_filtered_next;
                    rate_state <= RATE_IDLE;
                end
                default: rate_state <= RATE_IDLE;
            endcase
        end
    end

    // 位置外环每毫秒采样一次，在 50 MHz 时钟下分拍完成定点乘加和限幅。
    // 位置外环：采样位置误差/速度和参数后分拍计算，结果是角度参考偏置。
    always @(posedge clk) begin
        if (!rst_n) begin
            pos_state <= POS_IDLE;
            pos_div_count <= 0;
            pos_delta_r <= 0;
            pos_abs_delta_r<=0;pos_short_delta_r<=0;pos_abs_r<=0;pos_abs_last_r<=0;
            kd_blend_q8<=0;
            arm_spd_pos_r <= 0;
            kp_pos_r <= 0;
            kd_pos_r <= 0;
            kd_pos_near_r <= 0;
            pos_p_lim_r <= 0;
            pos_near_zone_r <= 0;
            trim_pos_r <= 0;
            pos_lim_mag_r <= 0;
            pos_term_r <= 0;
            pos_product_r <= 0;
            vel_term_r <= 0;
            pos_bias_raw_r <= 0;
            pos_bias_limited_r <= 0;
            ref_ang001_r <= 0;
            ref_filter_q8 <= 0; pos_i_q16 <= 0; pos_i_product_r <= 0;
            pos_error_avg_q15 <= 0;
            ki_pos_r <= 0; pos_i_lim_r <= 0; ref_shift_r <= 0;
            target_last_r <= 0; target_settle_ms <= 0; pos_i_allowed_r <= 0;
        end else begin
            if (!bal_on || fall || ki_pos_q8==0 || pos_i_lim<=0 ||
                                                   kp_pos_q8==0 || pos_p_lim<=0)
                pos_i_q16 <= 0;
            if (en) begin
                if(!bal_on || fall || pos_target!=target_last_r || pos_abs_mode!=pos_abs_last_r)
                    pos_error_avg_q15<=0;
                else pos_error_avg_q15<=pos_error_avg_next[31:0];
                target_last_r <= pos_target;
                pos_abs_last_r<=pos_abs_mode;
                if(pos_abs_mode!=pos_abs_last_r) pos_i_q16<=0;
                if (!bal_on || fall || pos_target!=target_last_r || pos_abs_mode!=pos_abs_last_r) target_settle_ms<=0;
                else if (target_settle_ms<10'd500) target_settle_ms<=target_settle_ms+1'b1;
            end
            case (pos_state)
                POS_IDLE: if (en) begin
                    if ((POS_DIV <= 1) || (pos_div_count == POS_DIV - 1)) begin
                        pos_div_count <= 0;
                        pos_abs_delta_r<=pos_abs_delta;
                        pos_short_delta_r<=pos_delta_short;
                        pos_abs_r<=pos_abs_mode;
                        arm_spd_pos_r <= arm_spd_q8;
                        kp_pos_r <= kp_pos_q8;
                        kd_pos_r <= kd_pos_q8;
                        kd_pos_near_r <= kd_pos_near_q8;
                        pos_p_lim_r <= pos_p_lim;
                        trim_pos_r <= trim;
                        pos_lim_mag_r <= pos_lim_mag_sample;
                        ki_pos_r <= ki_pos_q8; pos_i_lim_r <= pos_i_lim;
                        ref_shift_r <= ref_lp_shift;
                        pos_state <= POS_ERROR;
                    end else begin
                        pos_div_count <= pos_div_count + 1'b1;
                    end
                end
                POS_ERROR: begin
                    pos_delta_r<=!bal_on ? {POS_DELTA_W{1'b0}} :
                                      pos_abs_r ? pos_abs_limited : pos_short_delta_r;
                    pos_state<=POS_ZONE;
                end
                POS_ZONE: begin
                    pos_product_r <= pos_product_next;
                    pos_near_zone_r <= pos_near_zone_next;
                    if(!bal_on || kd_blend_shift==0) kd_blend_q8<=kd_target_q8;
                    else kd_blend_q8<=kd_blended_next[23:0];
                    pos_i_allowed_r <= bal_on && !fall && !hold_active && target_settle_ms>=10'd500 &&
                        ki_pos_r!=0 && pos_i_lim_r>0 && kp_pos_r!=0 && pos_p_lim_r>0 &&
                        ki_pos_r[15]==kp_pos_r[15] && pos_delta_mag>=1 && pos_delta_mag<=160 &&
                        arm_spd_pos_r<32'sd30720 && arm_spd_pos_r> -32'sd30720 &&
                        upright_mag<19'd600 && pos_i_output_free;
                    pos_state <= POS_MUL;
                end
                POS_MUL: begin
                    pos_term_r <= pos_term_limited_next;
                    vel_term_r <= vel_term_next;
                    pos_i_product_r <= pos_i_avg_scaled[32:0];
                    pos_state <= POS_SUM;
                end
                POS_SUM: begin
                    pos_bias_raw_r <= pos_bias_sum_next;
                    pos_state <= POS_LIMIT;
                end
                POS_LIMIT: begin
                    pos_bias_limited_r <= pos_bias_limited_next;
                    if (pos_i_allowed_r && pos_i_ref_free && bal_on && !fall && !hold_active &&
                                                          ki_pos_q8!=0 && pos_i_lim>0)
                        pos_i_q16 <= pos_i_limited;
                    pos_state <= POS_REF;
                end
                POS_REF: begin
                    if (!bal_on || fall) begin
                        ref_filter_q8 <= $signed({{8{trim_pos_r[15]}},trim_pos_r,8'd0});
                        ref_ang001_r <= $signed({{2{trim_pos_r[15]}},trim_pos_r});
                    end else if (ref_shift_r==0) begin
                        ref_filter_q8 <= ref_target_q8;
                        ref_ang001_r <= pos_ref_limited_next;
                    end else ref_filter_q8 <= ref_filtered_next;
                    pos_state <= POS_FILTER;
                end
                POS_FILTER: begin
                    if (ref_shift_r!=0 && bal_on && !fall)
                        ref_ang001_r <= ref_filtered_rounded[17:0];
                    pos_state <= POS_IDLE;
                end
                default: pos_state <= POS_IDLE;
            endcase
        end
    end

    // 角度 PID 主流水：采样误差和增益 → 等待速度计算 → P/I/D 乘法 →
    // 抗饱和积分、死区补偿与最终限幅。bal_on 或 fall 失效时清积分和输出。
    always @(posedge clk) begin
        if (!rst_n) begin
            i_acc_q24 <= 0;
            state <= ST_IDLE;
            error_r <= 0;
            rate_r_q8 <= 0;
            rate_mode_r <= 0;
            kp_r <= 0;
            ki_r <= 0;
            kd_r <= 0;
            lim_r <= 0;
            dz_r <= 0;
            i_lim_r <= 0;
            slew_r <= 0;
            p_prod <= 0;
            d_prod <= 0;
            i_prod <= 0;
            p_q8 <= 0;
            d_q8 <= 0;
            i_delta_q24 <= 0;
            total_q8 <= 0;
            no_i_sum_q8_r <= 0;
            no_i_base_r <= 0;
            no_i_over_pos_r <= 0;
            no_i_over_neg_r <= 0;
            no_i_comp_product_r <= 0;
            i_blocked_by_output_r <= 0;
            i_accept_q24_r <= 0;
            base_duty_r <= 0;
            duty_limited_r <= 0;
            comp_product_r <= 0;
            comp_filter_q8<=0; dz_width_r<=6; dz_lp_r<=0;
            comp_mag_r<=0;comp_positive_r<=0;comp_negative_r<=0;
            duty <= 0;
        end else if (!bal_on || fall) begin
            i_acc_q24 <= 0;
            state <= ST_IDLE;
            duty <= 0;
            comp_filter_q8<=0;
        end else begin
            case (state)
                ST_IDLE: if (en) begin
                    // 角度误差与接管/判倒判定统一采用低通角度，避免控制器
                    // 在“已接管”的同时又把 ADC 原始抖动直接放大到 PWM。
                    kp_r <= kp_ang_q8;
                    ki_r <= ki_ang_q8;
                    kd_r <= kd_ang_q8;
                    lim_r <= (lim <= 0) ? 10'd0 :
                             (lim > DUTY_MAX) ? DUTY_MAX[9:0] : lim[9:0];
                    dz_r <= (dz <= 0) ? 10'd0 :
                            (dz > DUTY_MAX) ? DUTY_MAX[9:0] : dz[9:0];
                    dz_width_r<=dz_width_shift>8 ? 4'd8 : dz_width_shift;
                    dz_lp_r<=dz_lp_shift>4 ? 4'd4 : dz_lp_shift;
                    i_lim_r <= (i_lim <= 0) ? 10'd0 :
                               (i_lim > DUTY_MAX) ? DUTY_MAX[9:0] : i_lim[9:0];
                    slew_r <= (slew <= 0) ? 10'd0 :
                              (slew > DUTY_MAX) ? DUTY_MAX[9:0] : slew[9:0];
                    state <= ST_RATE_MUL;
                    // 与本次P/D增益一起锁存，参数帧恰在流水中到达也不混用算法。
                    case(rate_observer_mode)
                        1:rate_mode_r<=1;
                        2:rate_mode_r<=2;
                        default:rate_mode_r<=0;
                    endcase
                end
                ST_RATE_MUL: state <= ST_RATE_FILT;
                ST_RATE_FILT: begin
                    error_r <= $signed({angle_filt_r[17],angle_filt_r})-
                               $signed({ref_ang001[17],ref_ang001});
                    rate_r_q8 <= pid_rate_next_q8;
                    state <= rate_mode_r==0 ? ST_MUL : ST_RATE_OBSERVER;
                end
                ST_RATE_OBSERVER: begin
                    // 仅观测模式多等一个50MHz系统时钟，仍是每1ms一个控制输出。
                    rate_r_q8<=pid_rate_next_q8;
                    state<=ST_MUL;
                end
                ST_MUL: begin
                    p_prod <= $signed(error_r) * $signed(kp_r);
                    d_prod <= $signed(rate_r_q8) * $signed(kd_r);
                    i_prod <= $signed(error_r) * $signed(ki_r);
                    state <= ST_SCALE;
                end
                ST_SCALE: begin
                    p_q8 <= p_prod;
                    d_q8 <= $signed(d_prod) >>> 8;
                    i_delta_q24 <= $signed(i_prod_scaled) >>> 8;
                    state <= ST_AW_SUM;
                end
                // 将抗积分饱和和死区补偿拆成短流水级，避免单拍组合路径过长。
                ST_AW_SUM: begin
                    no_i_sum_q8_r <= sum_without_i_q8;
                    state <= ST_AW_LIMIT;
                end
                ST_AW_LIMIT: begin
                    no_i_base_r <= no_i_base_next;
                    no_i_over_pos_r <= no_i_over_pos_next;
                    no_i_over_neg_r <= no_i_over_neg_next;
                    state <= ST_AW_MUL;
                end
                ST_AW_MUL: begin
                    no_i_comp_product_r <= no_i_comp_product_next;
                    state <= ST_AW_BLOCK;
                end
                ST_AW_BLOCK: begin
                    i_blocked_by_output_r <= i_blocked_by_output_next;
                    state <= ST_I_ACC;
                end
                ST_I_ACC: begin
                    i_accept_q24_r <= i_accept_q24_next;
                    if (!i_blocked_by_output_r) i_acc_q24 <= i_candidate_limited;
                    state <= ST_I_SUM;
                end
                ST_I_SUM: begin
                    total_q8 <= total_next_q8;
                    state <= ST_OUT_BASE;
                end
                ST_OUT_BASE: begin
                    base_duty_r <= base_duty_next;
                    state <= ST_COMP_FILTER;
                end
                ST_COMP_FILTER: begin
                    comp_filter_q8 <= comp_filter_next;
                    state <= ST_OUT_PREP;
                end
                ST_OUT_PREP: begin
                    comp_mag_r<=comp_mag;
                    comp_positive_r<=comp_base_rounded>0;
                    comp_negative_r<=comp_base_rounded<0;
                    state <= ST_OUT_MUL;
                end
                ST_OUT_MUL: begin
                    comp_product_r <= comp_product_next;
                    state <= ST_OUT_FINAL;
                end
                ST_OUT_FINAL: begin
                    // 先把死区补偿后的限幅结果寄存，再在下一拍单独做变化率限制，
                    // 避免把两个比较器串入同一条 50 MHz 时序路径。
                    duty_limited_r <= duty_limited;
                    state <= ST_OUT_APPLY;
                end
                ST_OUT_APPLY: begin
                    duty <= duty_slew_limited;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
