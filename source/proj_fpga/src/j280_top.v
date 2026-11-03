//=============================================================================
// 模块：j280_top
// 作用：J280 旋转倒立摆的工程顶层，连接采集、控制、驱动、显示和串口。
//
// 系统时序：
//   clk_50m 为唯一系统时钟；tick_1k 为角度控制和编码器测速提供 1 kHz 采样节拍，
//   tick_send 以 SEND_HZ（默认 100 Hz）触发一次遥测快照和串口发送。
//   按键、编码器 A/B、串口 RX 在各自模块内完成同步；ADC 并行总线由 adc_par
//   在 ADC 时钟采样窗读取。顶层只使用这些模块的寄存器输出。
//
// 控制流程：
//   ADC 平均值 raw_q → ang_calc 角度 → bal_ctl 角度 PID → pwm_gen/TB6612；
//   编码器同时提供累计计数（测速）和单圈有符号位置（位置外环/遥测）。
//   mode=0 为停机，mode=1 为手动角度稳定，mode=2 为自动起摆后角度稳定，
//   mode=3 为绝对位置（转圈/定位）：位置外环不再做单圈最短环绕，而是把 
//   完整32位累计编码器计数拉向signed16位目标TURNS_POSTGT，差值保留方向并饱和。
//   接管前需 sensor_ok 且角度处于 ENTER 范围；MODE3 与 MODE1 共用接管/保护
//   路径，不允许起摆，只能由 GUI/屏幕的 MODE 参数帧进入。
//
// 拓展板 UI（2026-10-30 融合，2026-10-31 增加 MODE3/参数表）：
//   ui_panel_ctrl负责SPI屏显示、本地调参与参数帧仲裁。
//   u版修正绝对位置与起摆样本时序，增加Q15慢积分、阻尼渐变及ABS/SRC遥测。
//   - 原板 SW1（key[0]）短按翻转 src_local：0 = 上位机模式（默认，UART 写参数），
//     1 = 本地模式（保留UART停机通道，其余参数改用屏幕调节）；
//   - SW2/SW3 仍是 MODE 2 / MODE 0 请求，SW1 不再请求 MODE 1；
//   - 模式切换只改参数通道和屏幕，不复位 mode / bal_on / 电机。
//=============================================================================
`timescale 1ns / 1ps

module j280_top #(
    parameter integer CLK_HZ = 50_000_000, // 系统时钟频率（Hz）
    parameter integer SEND_HZ = 100,       // 遥测发送频率（行/秒）
    parameter integer BAUD = 115_200,      // UART 波特率
    parameter integer ADC_DIV = 10,        // ADC 时钟分频系数
    parameter integer AVG_LOG2 = 9,        // ADC 平均点数为 2^AVG_LOG2
    parameter integer FRAC_LOG2 = 4,       // ADC 平均结果保留的小数位数
    parameter integer BUILD = 60,          // 遥测版本y：稳定容差保持，不关闭角度抗扰闭环
    parameter integer ANGLE_RATE_WIN_LOG2 = 1, // 2ms微分窗口；避免过长窗口引入失稳延迟
    parameter integer RAW_ZERO = 508,      // 上电竖直零点（ADC 码）
    parameter integer K_Q8 = 8500,         // 角度换算斜率（0.01°/count，Q8）
    parameter integer ENC_CPR = 1040       // 编码器每圈四倍频计数
)(
    input wire clk_50m,       // 50 MHz 板载时钟
    input wire key_rst_n,     // 低有效复位按键
    input wire [2:0] key,     // SW1~SW3，按下为低
    input wire [9:0] ad_d,    // 10 位并行 ADC 数据
    input wire ad_otr,        // ADC 超量程标志
    output wire ad_clk,       // ADC 采样时钟
    output wire ad_oe,        // ADC 输出使能，低有效
    input wire enc_a,         // 编码器 A 相
    input wire enc_b,         // 编码器 B 相
    output wire pwma,         // 实际接 TB6612 B 通道 PWMB 的引脚
    output wire ain1,         // 实际接 TB6612 BIN1 的引脚
    output wire ain2,         // 实际接 TB6612 BIN2 的引脚
    input wire rxd,           // 调试串口 RX，115200 8N1
    output wire txd,          // 调试串口 TX，115200 8N1
    output wire [3:0] led,    // 心跳、传感器健康、接管、MODE 指示

    // ---- 拓展板 SPI LCD（H1，3.3 V bank）----------------------------------
    output wire lcd_spi_sclk, // V6
    output wire lcd_spi_mosi, // V7
    output wire lcd_spi_cs,   // Y3
    output wire lcd_dc,       // Y5
    output wire lcd_reset,    // Y4
    output wire lcd_blk,      // AA3

    // ---- 拓展板按键 / 编码器（H1，3.3 V bank，按下为低）-------------------
    input wire sw1_s,         // Y6  编码器 SW1 按下：应用 SPD
    input wire sw1_a,         // AA6
    input wire sw1_b,         // AB1
    input wire sw2_s,         // AB10 编码器 SW2 按下：应用 POS
    input wire sw2_a,         // AB8
    input wire sw2_b,         // AA8
    input wire sw3_s,         // AB6  保留：按下强制重绘一帧
    input wire sw4_s,         // AB2  保留：按下强制重绘一帧
    input wire sw5_s,         // AB5  保留：按下强制重绘一帧
    input wire sw6_s,         // AA7  保留：按下强制重绘一帧
    input wire sw7_s          // AB7  保留：按下强制重绘一帧
);

    // 时钟与复位：clk_rst 负责按键复位的消抖和同步释放，整个工程只使用
    // clk_sys，tick 信号都是时钟使能而不是新时钟。
    wire clk_sys, rst_n;
    clk_rst #(.CLK_HZ(CLK_HZ)) u_clk (
        .clk_50m(clk_50m), .key_rst_n(key_rst_n), .clk_sys(clk_sys), .rst_n(rst_n)
    );

    // tick_send 用于低速遥测；tick_1k 是控制环唯一的采样节拍。
    wire tick_send, tick_1k;
    tick_gen #(.CLK_HZ(CLK_HZ), .RATE_HZ(SEND_HZ)) u_tick_send (
        .clk(clk_sys), .rst_n(rst_n), .tick(tick_send)
    );
    tick_gen #(.CLK_HZ(CLK_HZ), .RATE_HZ(1000)) u_tick_control (
        .clk(clk_sys), .rst_n(rst_n), .tick(tick_1k)
    );

    // key_evt 为按下事件单拍：SW2 请求 MODE 2，SW3 请求 MODE 0。
    // SW1（key[0]）改为“上位机 / 本地”模式切换，不再请求 MODE 1。
    // 三个按键均经过同步和消抖，模式之间可以直接切换。
    wire [2:0] key_lvl, key_evt;
    key_debounce #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(20), .N_KEY(3)) u_key (
        .clk(clk_sys), .rst_n(rst_n), .key_in(key),
        .key_level(key_lvl), .key_press(key_evt)
    );

    // 参数来源模式：0 = 上位机（UART 写参数，默认），1 = 本地（屏幕调参）。
    // 只翻转这一个寄存器：不影响 mode / bal_on / PWM，电机状态保持不变。
    reg src_local;
    always @(posedge clk_sys) begin
        if (!rst_n) src_local <= 1'b0;
        else if (key_evt[0]) src_local <= ~src_local;
    end

    // raw 是整数 ADC 平均码，raw_q 保留 FRAC_LOG2 个小数位供角度计算；
    // raw_upd 每完成一组平均产生一拍，otr_flag 表示该组是否出现超量程。
    wire [15:0] raw, raw_q, raw_control_q;
    wire [1:0] cfg_adcavg;
    wire [1:0] cfg_ratemode;
    wire [15:0] cfg_holdpos;
    wire position_hold_active;
    wire raw_upd, otr_flag;
    adc_par #(
        .CLK_HZ(CLK_HZ), .ADC_DIV(ADC_DIV),
        .AVG_LOG2(AVG_LOG2), .FRAC_LOG2(FRAC_LOG2)
    ) u_adc (
        .clk(clk_sys), .rst_n(rst_n), .ad_d(ad_d), .ad_otr(ad_otr),
        .ad_clk(ad_clk), .ad_oe(ad_oe), .raw(raw), .raw_q(raw_q),
        .control_avg_shift(cfg_adcavg), .raw_control_q(raw_control_q),
        .raw_upd(raw_upd), .otr_flag(otr_flag)
    );

    // ADC 健康判定：连续收到若干个未超量程样本，且近期仍有更新。
    // RAW 端点在底部起摆时可能是角度传感器的有效饱和值，因此保留新鲜度，
    // 但只允许 MODE 2 起摆阶段使用端点数据；角度环仍拒绝饱和码。
    reg [2:0] adc_good;
    reg [2:0] adc_age;
    wire adc_fresh_ok = (adc_good >= 4) && (adc_age < 4);
    wire sensor_ok = adc_fresh_ok && !otr_flag && (raw != 0) && (raw < 1023);
    wire swing_sensor_ok = adc_fresh_ok && !otr_flag;
    always @(posedge clk_sys) begin
        if (!rst_n) begin
            adc_good <= 0;
            adc_age <= 4;
        end else if (raw_upd) begin
            adc_age <= 0;
            if (otr_flag) adc_good <= 0;
            else if (adc_good < 4) adc_good <= adc_good + 1'b1;
        end else if (tick_1k) begin
            if (adc_age < 4) adc_age <= adc_age + 1'b1;
            if (adc_age >= 3) adc_good <= 0;
        end
    end

    // ang001 单位为 0.01°，RAW_ZERO 默认 508；ang_calc 内部保留流水延迟，
    // 控制前平均在ADC组更新时完成，角度环仍按1kHz运行；健康检测独立使用单组。
    wire signed [17:0] ang001;
    wire [15:0] cfg_zero;
    ang_calc #(.K_Q8(K_Q8), .FRAC_LOG2(FRAC_LOG2)) u_ang (
        .clk(clk_sys), .rst_n(rst_n), .raw_q(raw_control_q),
        .zero_set(cfg_zero), .ang001(ang001)
    );

    // 编码器累计计数用于滑窗测速；enc_pos_signed 是 -CPR/2..+CPR/2 的
    // 单圈相位，用于位置外环和遥测，二者不能互换。
    wire signed [31:0] enc_cnt, enc_pos_signed, arm_spd, arm_spd_q8;
    wire cfg_velocity_period;
    encoder_quad #(.W(32), .CPR(ENC_CPR), .INVERT_DIR(1'b0), .USE_INDEX(1'b0)) u_enc (
        .clk(clk_sys), .rst_n(rst_n), .enc_a(enc_a), .enc_b(enc_b), .enc_z(1'b0),
        .count(enc_cnt), .count_mod(), .count_signed(enc_pos_signed), .dir(), .tick()
    );
    // 默认仍为窗口法；ID51可在线对照周期辅助，避免反复下载码流。
    speed_win #(.W(32), .TICK_HZ(1000), .WIN(16), .PERIOD_ASSIST(2)) u_speed (
        .clk(clk_sys), .rst_n(rst_n), .tick(tick_1k), .count(enc_cnt),
        .period_enable(cfg_velocity_period),
        .arm_spd(arm_spd), .arm_spd_q8(arm_spd_q8)
    );

    // UART RX 只输出“字节有效”脉冲，cfg_regs 负责四字节参数帧解析。
    wire [7:0] rx_byte;
    wire rx_dv, rx_fe;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart_rx (
        .clk(clk_sys), .rst_n(rst_n), .rxd(rxd),
        .rx_data(rx_byte), .rx_dv(rx_dv), .frame_err(rx_fe)
    );

    // 参数帧入口 mux（由 ui_panel_ctrl 统一仲裁）：
    //   上位机模式 → UART 参数帧；
    //   本地模式   → 屏幕 SPD/POS 生成的帧，UART 参数帧被整帧丢弃。
    // 两个来源都先组装成完整 4 字节帧再原子送入 cfg_regs，切换瞬间不会把
    // 半帧留给 cfg_regs 的解析器；cfg_regs 本身未做任何修改。
    wire       cfg_rx_dv;
    wire [7:0] cfg_rx_data;

    wire signed [15:0] cfg_lim, cfg_dz, cfg_trim, cfg_fall, cfg_enter;
    wire signed [15:0] cfg_akp, cfg_aki, cfg_akd;
    wire signed [15:0] cfg_pkp, cfg_pkd, cfg_posmax, cfg_pos_target, cfg_ilim;
    // MODE3 绝对位置目标（参数 ID 48），与 POSTGT 完全独立。
    wire signed [15:0] cfg_turns_postgt;
    wire signed [15:0] cfg_pos_near, cfg_pkd_near, cfg_posp_lim;
    wire signed [15:0] cfg_pki, cfg_pilim;
    wire [3:0] cfg_pidead,cfg_kdblend;
    wire [3:0] cfg_rlp, cfg_dzw, cfg_dzlp;
    wire [3:0] cfg_alp;
    wire signed [15:0] cfg_slew;
    wire [15:0] cfg_swl, cfg_swamp, cfg_swramp, cfg_swms, cfg_swc, cfg_swt;
    wire signed [15:0] cfg_swd;
    wire [3:0] cfg_dlp, cfg_cnt;
    wire [2:0] cfg_mode;
    wire cfg_mode_we;
    reg [2:0] mode;

    cfg_regs #(
        .DEF_MODE(0), .DEF_ZERO(RAW_ZERO),
        // 2026-10-30串口实测、用户确认保留的s参数；完整过程见analysis_live_s。
        // TRIM是本机构经验修正，POSTGT是复位坐标；不是绝对机械零位标定。
        .DEF_AKP_Q8(-150), .DEF_AKI_Q8(0), .DEF_AKD_Q8(-400),
        .DEF_PKP_Q8(600), .DEF_PKD_Q8(-300), .DEF_POSMAX(600),
        .DEF_POS_TARGET(0), .DEF_POS_NEAR(0), .DEF_PKD_NEAR_Q8(-300),
        .DEF_PKI_Q8(8), .DEF_PILIM(45), .DEF_RLP(4),
        .DEF_POSP_LIM(427), .DEF_LIM(300), .DEF_DZ(20), .DEF_DZW_SHIFT(6), .DEF_DZLP(1), .DEF_TRIM(20),
        .DEF_FALL(1500), .DEF_ENTER(1000), .DEF_ILIM(0),
        .DEF_DLP(3), .DEF_ALP(1), .DEF_SLEW(0), .DEF_SWLIM(750),
        .DEF_SWAMP(670), .DEF_SWRAMP(200), .DEF_SWMS(3),
        .DEF_SWCAP(800), .DEF_SWTMO(15000), .DEF_SWDIR(1), .DEF_TURNS_POSTGT(0),
        .DEF_PIDEAD(4), .DEF_KDBLEND(0), .DEF_VELMODE(1), .DEF_ADCAVG(2),
        .DEF_RATEMODE(2), .DEF_HOLDPOS(70)
    ) u_cfg (
        .clk(clk_sys), .rst_n(rst_n), .rx_dv(cfg_rx_dv), .rx_data(cfg_rx_data),
        .lim(cfg_lim), .dz(cfg_dz), .dz_width_shift(cfg_dzw), .dz_lp_shift(cfg_dzlp), .trim(cfg_trim),
        .fall_th(cfg_fall), .enter_lim(cfg_enter), .zero_set(cfg_zero),
        .kp_ang_q8(cfg_akp), .ki_ang_q8(cfg_aki), .kd_ang_q8(cfg_akd),
        .kp_pos_q8(cfg_pkp), .kd_pos_q8(cfg_pkd),
        .ki_pos_q8(cfg_pki), .pos_i_lim(cfg_pilim), .ref_lp_shift(cfg_rlp), .pos_angle_lim(cfg_posmax),
        .pos_near(cfg_pos_near), .kd_pos_near_q8(cfg_pkd_near),
        .pos_p_lim(cfg_posp_lim),
        .pos_target(cfg_pos_target),
        .turns_postgt(cfg_turns_postgt),.pos_i_deadband(cfg_pidead),.kd_blend_shift(cfg_kdblend),
        .velocity_period(cfg_velocity_period),
        .adc_avg_shift(cfg_adcavg),
        .rate_observer_mode(cfg_ratemode),
        .hold_position_tol(cfg_holdpos),
        .i_lim(cfg_ilim), .dlp_shift(cfg_dlp),
        .angle_lp_shift(cfg_alp), .slew(cfg_slew),
        .swing_lim(cfg_swl), .swing_amp(cfg_swamp),
        .swing_ramp_ms(cfg_swramp), .swing_capture_ms(cfg_swms),
        .swing_capture(cfg_swc), .swing_timeout(cfg_swt),
        .swing_dir(cfg_swd),
        .mode_cmd(cfg_mode), .mode_we(cfg_mode_we), .upd_cnt(cfg_cnt)
    );

    //------------------------------------------------------------------------
    // 拓展板 UI：SPI 屏 + 本地 SPD/POS/P/MODE 调参 + UART/本地参数帧仲裁
    //   cfg_regs 的 RX 只接收 UI 模块输出的“完整4字节帧”字节流：
    //   - 上位机模式：UI 把 uart_rx 字节原样转发；
    //   - 本地模式：丢弃 UART 参数帧，只转发屏幕应用产生的帧。
    //   控制环 1 kHz 只读 cfg 输出，不受 UI 影响。
    //------------------------------------------------------------------------
    ui_panel_ctrl u_ui (
        .clk            (clk_sys),
        .rst_n          (rst_n),

        .sw1_s          (sw1_s),
        .sw1_a          (sw1_a),
        .sw1_b          (sw1_b),
        .sw2_s          (sw2_s),
        .sw2_a          (sw2_a),
        .sw2_b          (sw2_b),
        .sw3_s          (sw3_s),
        .sw4_s          (sw4_s),
        .sw5_s          (sw5_s),
        .sw6_s          (sw6_s),
        .sw7_s          (sw7_s),

        .cfg_pkd        (cfg_pkd),
        .cfg_pos_target (cfg_pos_target),
        .cfg_turns_postgt (cfg_turns_postgt),
        .cfg_mode       (mode),
        .ang001         (ang001),
        .enc_pos_signed (enc_pos_signed),
        .src_local      (src_local),

        .uart_rx_dv     (rx_dv),
        .uart_rx_data   (rx_byte),

        .cfg_rx_dv      (cfg_rx_dv),
        .cfg_rx_data    (cfg_rx_data),

        .lcd_spi_sclk   (lcd_spi_sclk),
        .lcd_spi_mosi   (lcd_spi_mosi),
        .lcd_spi_cs     (lcd_spi_cs),
        .lcd_dc         (lcd_dc),
        .lcd_reset      (lcd_reset),
        .lcd_blk        (lcd_blk)
    );

    // 模式寄存器优先级：串口完整 MODE 帧 > SW2/SW3 按键事件 > 保持原值。
    // 原板 SW1 已改为上位机/本地模式切换，不再请求 MODE 1；SW2=自动起摆、SW3=停机。
    reg mode_init;
    wire [2:0] mode_from_key = key_evt[1] ? 3'd2 :
                                key_evt[2] ? 3'd0 : mode;
    wire [2:0] mode_next = cfg_mode_we ? cfg_mode : mode_from_key;
    wire mode_event = cfg_mode_we || key_evt[1] || key_evt[2];
    wire mode_retrigger = mode_event && (mode_next == mode);
    wire swing_restart = mode_retrigger && (mode == 3'd2);
    always @(posedge clk_sys) begin
        if (!rst_n) begin
            mode <= 3'd0;
            mode_init <= 1'b0;
        end else if (!mode_init) begin
            mode <= cfg_mode;
            mode_init <= 1'b1;
        end else begin
            mode <= mode_next;
        end
    end

    // bal_ctl 输出角度参考、PWM 命令、接管条件和滤波角速度。
    wire signed [17:0] ref_ang001;
    wire signed [15:0] bal_duty;
    wire bal_fall, bal_near;
    wire signed [31:0] angle_rate_q8;
    reg bal_on;
    reg bal_fault;
    reg swing_captured;
    wire signed [15:0] swing_duty;
    wire swing_capture_req, swing_active, swing_timeout_fault, swing_blind_active;
    wire bal_config_ok = (cfg_lim > 0) && (cfg_fall > cfg_enter) &&
                         (cfg_fall > 0) &&
                         (cfg_fall <= 16'sd18000) && (cfg_enter > 0) &&
                         (cfg_enter <= 16'sd18000);
    wire swing_config_ok = (cfg_swl > 0) && (cfg_swamp > 0) && (cfg_swc > 0) &&
                           (cfg_swt >= 16'd100) &&
                           ((cfg_swd == 16'sd1) || (cfg_swd == -16'sd1));

    bal_ctl #(.POS_CPR(ENC_CPR), .RATE_WIN_LOG2(ANGLE_RATE_WIN_LOG2)) u_bal (
        .hold_position_tol(cfg_holdpos),.hold_active(position_hold_active),
        .clk(clk_sys), .rst_n(rst_n), .en(tick_1k), .ang001(ang001),
        // MODE3：位置环使用完整32位累计计数，不在±32768边界丢失方向。
        // 目标改用 TURNS_POSTGT；其余模式仍使用单圈有符号相位与 POSTGT。
        .pos_count((mode == 3'd3) ? enc_cnt : enc_pos_signed),
        .pos_abs_mode(mode == 3'd3),
        .arm_spd_q8(arm_spd_q8),
        .kp_ang_q8(cfg_akp), .ki_ang_q8(cfg_aki), .kd_ang_q8(cfg_akd),
        .kp_pos_q8(cfg_pkp), .kd_pos_q8(cfg_pkd),
        .ki_pos_q8(cfg_pki), .pos_i_lim(cfg_pilim), .ref_lp_shift(cfg_rlp), .pos_angle_lim(cfg_posmax),
        .pos_i_deadband(cfg_pidead),.kd_blend_shift(cfg_kdblend),
        .pos_near(cfg_pos_near), .kd_pos_near_q8(cfg_pkd_near),
        .pos_p_lim(cfg_posp_lim),
        .trim(cfg_trim), .lim(cfg_lim), .dz(cfg_dz),
        .dz_width_shift(cfg_dzw), .dz_lp_shift(cfg_dzlp), .i_lim(cfg_ilim),
        .fall_th(cfg_fall), .enter_lim(cfg_enter), .dlp_shift(cfg_dlp),
        .pos_target((mode == 3'd3) ? cfg_turns_postgt : cfg_pos_target),
        .angle_lp_shift(cfg_alp), .slew(cfg_slew),
        .bal_on(bal_on), .ref_ang001(ref_ang001), .duty(bal_duty),
        .rate_observer_mode(cfg_ratemode),
        .fall(bal_fall), .near(bal_near), .angle_rate_q8(angle_rate_q8)
    );

    // 起摆、捕获与平衡使用同一 TRIM，避免三个窗口围绕不同的竖直零点。
    wire signed [18:0] swing_angle_relative = $signed({ang001[17],ang001}) -
                                                $signed({{3{cfg_trim[15]}},cfg_trim});
    wire signed [18:0] swing_angle_wrapped =
        swing_angle_relative>19'sd18000 ? swing_angle_relative-19'sd36000 :
        swing_angle_relative< -19'sd18000 ? swing_angle_relative+19'sd36000 :
        swing_angle_relative;
    swingup_ctl u_swing (
        .clk(clk_sys), .rst_n(rst_n), .en(tick_1k), .mode_active(mode == 3'd2),
        .restart(swing_restart),
        .bal_on(bal_on), .angle_valid(sensor_ok),
        .angle_sample_valid(sensor_ok), .ang001(swing_angle_wrapped[17:0]),
        .angle_lp_shift(4'd0),
        .swing_lim(cfg_swl), .swing_amp(cfg_swamp),
        .ramp_ms(cfg_swramp), .capture_ms(cfg_swms),
        .capture_lim((cfg_swc < cfg_enter) ? cfg_swc : cfg_enter),
        .timeout_ms(cfg_swt), .swing_dir(cfg_swd), .duty(swing_duty),
        .capture_req(swing_capture_req), .active(swing_active),
        .timeout_fault(swing_timeout_fault),
        .blind_start_active(swing_blind_active)
    );

    // 接管状态机：MODE 1/3 在竖直窗口内直接进入角度环；MODE 2 先由起摆状态机
    // 输出，捕获后切换角度环。保护后模式保持；条件恢复后自动接管。
    // MODE3 只改变位置环的误差定义（绝对计数差），接管条件与 MODE1 完全相同。
    always @(posedge clk_sys) begin
        if (!rst_n) begin
            bal_on <= 1'b0;
            bal_fault <= 1'b0;
            swing_captured <= 1'b0;
        end else if (mode_next == 3'd0) begin
            bal_on <= 1'b0;
            bal_fault <= 1'b0;
            swing_captured <= 1'b0;
        end else if ((mode_next != mode) || mode_retrigger) begin
            // 切换模式或重发当前模式时清掉旧状态，MODE 2 可从超时状态重启。
            bal_on <= 1'b0;
            bal_fault <= 1'b0;
            swing_captured <= 1'b0;
        end else if (mode_next != 3'd2) begin
            swing_captured <= 1'b0;
            // MODE 1 是持续有效的手动稳定模式。保护触发后保持 MODE 1，
            // 摆杆重新回到接管窗口且 ADC 恢复时自动重新接管，不要求再次按键。
            if (bal_fault && bal_config_ok && sensor_ok && bal_near) begin
                bal_fault <= 1'b0;
                bal_on <= 1'b1;
            end else if (bal_fault) bal_on <= 1'b0;
            else if (!bal_config_ok) begin bal_on <= 1'b0; bal_fault <= 1'b1; end
            else if (bal_on && (!sensor_ok || bal_fall)) begin bal_on <= 1'b0; bal_fault <= 1'b1; end
            else if (!bal_on && sensor_ok && bal_near) bal_on <= 1'b1;
        end else if (bal_fault && bal_config_ok && swing_captured && sensor_ok && bal_near) begin
            // MODE 2 捕获后若触发保护，回到接管窗口时自动恢复。
            bal_fault <= 1'b0;
            bal_on <= 1'b1;
        end else if (bal_fault) begin
            bal_on <= 1'b0;
        end else if (!bal_config_ok || !swing_config_ok || swing_timeout_fault) begin
            bal_on <= 1'b0;
            bal_fault <= 1'b1;
        end else if (swing_capture_req) begin
            swing_captured <= 1'b1;
            bal_on <= 1'b0;
        end else if (bal_on && (!sensor_ok || bal_fall)) begin
            bal_on <= 1'b0;
            bal_fault <= 1'b1;
        end else if (!bal_on && swing_captured && sensor_ok && bal_near) begin
            bal_on <= 1'b1;
        end
    end

    // MODE 2 每次过底部盲区允许最多 1000ms 往复激励；其余阶段要求有效角度。
    // MODE3 与 MODE1 一样直接输出 bal_duty（不分起摆），不允许起摆。
    wire motor_sensor_ok = sensor_ok ||
        ((mode == 3'd2) && !bal_on && !swing_captured && swing_blind_active);
    wire signed [15:0] motor_duty =
        (bal_fault || !motor_sensor_ok) ? 16'sd0 :
        (mode == 3'd1 && bal_on && !bal_fall) ? bal_duty :
        (mode == 3'd3 && bal_on && !bal_fall) ? bal_duty :
        (mode == 3'd2 && bal_on && !bal_fall) ? bal_duty :
        (mode == 3'd2 && !bal_on && swing_active) ? swing_duty : 16'sd0;
    wire pwm_out, dir_out, mot_act;
    pwm_gen #(.CNT_W(10), .PRE_DIV(2), .MIN_DUTY(0)) u_pwm (
        .clk(clk_sys), .rst_n(rst_n), .duty(motor_duty),
        .pwm_out(pwm_out), .dir_out(dir_out), .active(mot_act)
    );
    tb6612_drv #(.BRAKE(1'b1)) u_drv (
        .clk(clk_sys), .rst_n(rst_n), .en(mot_act), .dir(dir_out), .pwm(pwm_out),
        .ain1(ain1), .ain2(ain2), .pwma(pwma), .stby()
    );

    // msg_tx 在 tick_send 到来时锁存一帧快照，再逐字节交给 uart_tx；这样
    // 串口发送期间 ANG/RAW/POS 等字段不会相互错位。
    wire [7:0] tx_byte;
    wire tx_start, tx_busy;
    msg_tx #(.MSG_LEN(103), .EXTENDED(2), .BUILD(BUILD)) u_msg (
        .hold_active(position_hold_active),
        .clk(clk_sys), .rst_n(rst_n), .trig(tick_send),
        .ang001(ang001), .raw(raw), .enc_cnt(enc_pos_signed), .spd_cnt(arm_spd),
        .abs_count(enc_cnt),.src_local(src_local),
        .dut_cnt({{16{motor_duty[15]}}, motor_duty}),
        .ref_cnt({{14{ref_ang001[17]}}, ref_ang001}),
        .cfg_cnt(cfg_cnt), .mode(mode), .bal_on(bal_on),
        .bal_fall(bal_fall), .bal_near(bal_near), .bal_fault(bal_fault),
        .swing_active(swing_active),
        .tx_data(tx_byte), .tx_start(tx_start), .tx_busy(tx_busy)
    );
    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart_tx (
        .clk(clk_sys), .rst_n(rst_n), .data(tx_byte),
        .start(tx_start), .busy(tx_busy), .txd(txd)
    );

    // LED 状态：LED0 心跳，LED1 ADC 新鲜且无超量程，LED2 已接管，LED3 当前有控制模式。
    // LED 只做观察用途，不参与任何控制条件。
    reg [24:0] heartbeat;
    always @(posedge clk_sys) begin
        if (!rst_n) heartbeat <= 0;
        else heartbeat <= heartbeat + 1'b1;
    end
    assign led[0] = heartbeat[24];
    assign led[1] = swing_sensor_ok;
    assign led[2] = bal_on;
    assign led[3] = (mode != 3'd0);

endmodule
