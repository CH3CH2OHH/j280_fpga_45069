// ============================================================================
// ui_panel_ctrl.v - J280 拓展板 UI 控制与参数通道（融合工程新增）
// ----------------------------------------------------------------------------
// 一个模块内包含：
//   1. 11 路 1 ms 消抖（debounce.v）：SW1/SW2 编码器 A/B/S + SW3_S..SW7_S；
//   2. 两路正交解码：每 4 个有效边沿 = 一格（一个 detent），步进 STEP；
//   3. 模式寄存器同步：src_local 由顶层 SW1 短按给出，切换时把本地编辑值
//      同步为当前 cfg 值；
//   4. 本地参数帧生成：应用时生成与串口完全相同的 4 字节帧 AA|IDX|HI|LO；
//   5. 参数帧通道：UART 字节流和本地帧都先组装/装载成完整 4 字节帧，再原子
//      地（4 个连续字节）送给 cfg_regs。这样两个源切换时 cfg_regs 的解析
//      状态机永远不会停在半帧上；本地模式下 UART 参数帧被整帧丢弃；
//   6. 参数表：
//        左栏 3 行（8 字符/行，x=0..63）  SPD(PKD) / POS(POSTGT) / P(TURNS_POSTGT)
//        右栏 1 行（8 字符/行，x=64..127） MODE(0..3)
//      SW4_S 上移 / SW5_S 下移选择左栏行；SW1 编码器改选中值，SW1_S 应用；
//      SW2 编码器改 MODE（0→1→2→3→0 循环），SW2_S 应用；
//   7. 20 Hz 实时刷新：编码器 → 旋转臂相位；ang001 → 物理摆杆倾角；
//      仅在相位变化时置脏；参数编辑/按键/模式切换立即置脏，但两次重绘至少
//      间隔 REDRAW_MS，避免连续高频重绘；
//   8. 帧缓存 + 绘制 + SPI 扫描（ui_draw / ui_fb / spi_screen_top），
//      RGB565 高低字节交换沿用 exp 工程上板验证过的做法。
//
// 控制环（1 kHz）与本模块只有只读连接：cfg_pkd / cfg_pos_target /
// cfg_turns_postgt / cfg_mode / ang001 都是输入，本模块唯一能影响控制的是
// 通过 cfg_regs 写参数（与串口写完全等价）。
// ============================================================================
`timescale 1ns / 1ps

module ui_panel_ctrl #(
    parameter integer CLK_HZ       = 50_000_000, // 系统时钟
    parameter integer TICK_MS      = 50,         // 实时刷新周期（50 ms = 20 Hz）
    parameter integer REDRAW_MS    = 20,         // 两次整帧重绘最小间隔
    parameter integer FLASH_MS     = 500,        // APPLY 提示时长
    parameter integer STEP         = 5,          // 编码器一格步进（SPD/POS）
    parameter integer ARM_INVERT   = 0,          // 1 = 旋转臂方向取反
    parameter integer ANG_INVERT   = 0           // 1 = 摆杆倾斜方向取反
)(
    input  wire        clk,
    input  wire        rst_n,

    // 拓展板输入（异步，H1 3.3 V bank） --------------------------------------
    input  wire        sw1_s,     // SW1 编码器按下：应用当前选中的左栏行
    input  wire        sw1_a,
    input  wire        sw1_b,
    input  wire        sw2_s,     // SW2 编码器按下：应用 MODE
    input  wire        sw2_a,
    input  wire        sw2_b,
    input  wire        sw3_s,     // SW3_S/SW6_S/SW7_S 保留：按下强制重绘一帧
    input  wire        sw4_s,     // SW4_S：左栏选中行上移（SPD←P）
    input  wire        sw5_s,     // SW5_S：左栏选中行下移（SPD→P）
    input  wire        sw6_s,
    input  wire        sw7_s,

    // 控制侧只读量 -----------------------------------------------------------
    input  wire signed [15:0] cfg_pkd,        // cfg_regs.kd_pos_q8（ID 27）
    input  wire signed [15:0] cfg_pos_target, // cfg_regs.pos_target（ID 29）
    input  wire signed [15:0] cfg_turns_postgt, // cfg_regs.turns_postgt（ID 48）
    input  wire [2:0]  cfg_mode,              // cfg_regs.mode_cmd（ID 5，0..3）
    input  wire signed [17:0] ang001,         // 角度，0.01°，0 = 竖直
    input  wire signed [31:0] enc_pos_signed, // 编码器单圈位置 -CPR/2..+CPR/2
    input  wire        src_local,             // 0 = 上位机模式，1 = 本地模式

    // UART 参数字节流（uart_rx 输出） ----------------------------------------
    input  wire        uart_rx_dv,
    input  wire [7:0]  uart_rx_data,

    // 送 cfg_regs 的参数字节流（永远由完整 4 字节帧组成） --------------------
    output wire        cfg_rx_dv,
    output wire [7:0]  cfg_rx_data,

    // SPI LCD（H1） ----------------------------------------------------------
    output wire        lcd_spi_sclk,
    output wire        lcd_spi_mosi,
    output wire        lcd_spi_cs,
    output wire        lcd_dc,
    output wire        lcd_reset,
    output wire        lcd_blk
);

    //------------------------------------------------------------------------
    // 常量
    //------------------------------------------------------------------------
    localparam integer DEB_CYC   = CLK_HZ / 1000;                // 1 ms
    localparam integer TICK_DIV  = CLK_HZ / 1000 * TICK_MS;      // 2_500_000
    localparam integer GAP_DIV   = CLK_HZ / 1000 * REDRAW_MS;    // 1_000_000
    localparam integer FLASH_DIV = CLK_HZ / 1000 * FLASH_MS;     // 25_000_000

    localparam integer TICK_W  = $clog2(TICK_DIV);
    localparam integer GAP_W   = $clog2(GAP_DIV);
    localparam integer FLASH_W = $clog2(FLASH_DIV);

    // SPD = PKD（kd_pos_q8）：-500..0，步进 5
    localparam signed [15:0] SPD_LO  = -16'sd500;
    localparam signed [15:0] SPD_HI  =  16'sd0;
    localparam signed [15:0] SPD_TOP = -16'sd5;    // > 该值再加就钳到 SPD_HI
    localparam signed [15:0] SPD_BOT = -16'sd495;  // < 该值再减就钳到 SPD_LO

    // POS = POSTGT（pos_target）：-520..519，步进 5
    localparam signed [15:0] POS_LO  = -16'sd520;
    localparam signed [15:0] POS_HI  =  16'sd519;
    localparam signed [15:0] POS_TOP =  16'sd514;
    localparam signed [15:0] POS_BOT = -16'sd515;

    // P = TURNS_POSTGT（MODE3 绝对位置目标）：signed 16 全范围，本地步进 100
    localparam signed [15:0] TURN_LO   = 16'sh8000; // -32768
    localparam signed [15:0] TURN_HI   = 16'sh7FFF; // +32767
    localparam signed [15:0] TURN_STEP = 16'sd100;

    localparam signed [15:0] STEP_V  = STEP;
    localparam signed [15:0] POS_STEP = 16'sd5;  // 本地 POS 一步固定 5

    // 参数编号（与 cfg_regs.v / gui/j280_protocol.py 一致）
    localparam [7:0] IDX_MODE  = 8'd5;  // MODE（0..3）
    localparam [7:0] IDX_PKD   = 8'd27; // PKD -> 屏幕 SPD
    localparam [7:0] IDX_POS   = 8'd29; // POSTGT -> 屏幕 POS
    localparam [7:0] IDX_TURNS = 8'd48; // TURNS_POSTGT -> 屏幕 P

    //------------------------------------------------------------------------
    // 11 路 1 ms 消抖
    //------------------------------------------------------------------------
    wire sw1_s_d, sw1_a_d, sw1_b_d;
    wire sw2_s_d, sw2_a_d, sw2_b_d;
    wire sw3_s_d, sw4_s_d, sw5_s_d, sw6_s_d, sw7_s_d;

    debounce #(.CYCLES(DEB_CYC)) u_db_sw1s (.clk(clk), .rst_n(rst_n), .din(sw1_s), .dout(sw1_s_d));
    debounce #(.CYCLES(DEB_CYC)) u_db_sw1a (.clk(clk), .rst_n(rst_n), .din(sw1_a), .dout(sw1_a_d));
    debounce #(.CYCLES(DEB_CYC)) u_db_sw1b (.clk(clk), .rst_n(rst_n), .din(sw1_b), .dout(sw1_b_d));
    debounce #(.CYCLES(DEB_CYC)) u_db_sw2s (.clk(clk), .rst_n(rst_n), .din(sw2_s), .dout(sw2_s_d));
    debounce #(.CYCLES(DEB_CYC)) u_db_sw2a (.clk(clk), .rst_n(rst_n), .din(sw2_a), .dout(sw2_a_d));
    debounce #(.CYCLES(DEB_CYC)) u_db_sw2b (.clk(clk), .rst_n(rst_n), .din(sw2_b), .dout(sw2_b_d));
    debounce #(.CYCLES(DEB_CYC)) u_db_sw3s (.clk(clk), .rst_n(rst_n), .din(sw3_s), .dout(sw3_s_d));
    debounce #(.CYCLES(DEB_CYC)) u_db_sw4s (.clk(clk), .rst_n(rst_n), .din(sw4_s), .dout(sw4_s_d));
    debounce #(.CYCLES(DEB_CYC)) u_db_sw5s (.clk(clk), .rst_n(rst_n), .din(sw5_s), .dout(sw5_s_d));
    debounce #(.CYCLES(DEB_CYC)) u_db_sw6s (.clk(clk), .rst_n(rst_n), .din(sw6_s), .dout(sw6_s_d));
    debounce #(.CYCLES(DEB_CYC)) u_db_sw7s (.clk(clk), .rst_n(rst_n), .din(sw7_s), .dout(sw7_s_d));

    //------------------------------------------------------------------------
    // 正交解码：4 个有效边沿累计成 1 格（与 exp 工程上板验证一致）
    //------------------------------------------------------------------------
    reg [1:0] e1_prev, e2_prev;
    wire [1:0] e1_ab = {sw1_a_d, sw1_b_d};
    wire [1:0] e2_ab = {sw2_a_d, sw2_b_d};
    wire [3:0] e1_tr = {e1_prev, e1_ab};
    wire [3:0] e2_tr = {e2_prev, e2_ab};

    function signed [1:0] enc_step;
        input [3:0] tr;
        begin
            case (tr)
                4'b0001, 4'b0111, 4'b1110, 4'b1000: enc_step =  2'sd1;
                4'b0010, 4'b1011, 4'b1101, 4'b0100: enc_step = -2'sd1;
                default:                            enc_step =  2'sd0;
            endcase
        end
    endfunction

    wire signed [1:0] e1_step = enc_step(e1_tr);
    wire signed [1:0] e2_step = enc_step(e2_tr);

    reg signed [2:0] e1_acc, e2_acc;
    reg e1_inc, e1_dec, e2_inc, e2_dec;

    always @(posedge clk) begin
        if (!rst_n) begin
            e1_prev <= 2'b00;
            e2_prev <= 2'b00;
            e1_acc  <= 3'sd0;
            e2_acc  <= 3'sd0;
            e1_inc  <= 1'b0;
            e1_dec  <= 1'b0;
            e2_inc  <= 1'b0;
            e2_dec  <= 1'b0;
        end
        else begin
            e1_prev <= e1_ab;
            e2_prev <= e2_ab;
            e1_inc  <= 1'b0;
            e1_dec  <= 1'b0;
            e2_inc  <= 1'b0;
            e2_dec  <= 1'b0;

            if (e1_step > 0) begin
                if (e1_acc == 3'sd3) begin e1_acc <= 3'sd0; e1_inc <= 1'b1; end
                else                       e1_acc <= e1_acc + 3'sd1;
            end
            else if (e1_step < 0) begin
                if (e1_acc == -3'sd3) begin e1_acc <= 3'sd0; e1_dec <= 1'b1; end
                else                        e1_acc <= e1_acc - 3'sd1;
            end

            if (e2_step > 0) begin
                if (e2_acc == 3'sd3) begin e2_acc <= 3'sd0; e2_inc <= 1'b1; end
                else                       e2_acc <= e2_acc + 3'sd1;
            end
            else if (e2_step < 0) begin
                if (e2_acc == -3'sd3) begin e2_acc <= 3'sd0; e2_dec <= 1'b1; end
                else                        e2_acc <= e2_acc - 3'sd1;
            end
        end
    end

    //------------------------------------------------------------------------
    // 按键下降沿（按下）
    //------------------------------------------------------------------------
    reg sw1s_p, sw2s_p, sw3s_p, sw4s_p, sw5s_p, sw6s_p, sw7s_p;

    always @(posedge clk) begin
        if (!rst_n) begin
            sw1s_p <= 1'b1;
            sw2s_p <= 1'b1;
            sw3s_p <= 1'b1;
            sw4s_p <= 1'b1;
            sw5s_p <= 1'b1;
            sw6s_p <= 1'b1;
            sw7s_p <= 1'b1;
        end
        else begin
            sw1s_p <= sw1_s_d;
            sw2s_p <= sw2_s_d;
            sw3s_p <= sw3_s_d;
            sw4s_p <= sw4_s_d;
            sw5s_p <= sw5_s_d;
            sw6s_p <= sw6_s_d;
            sw7s_p <= sw7_s_d;
        end
    end

    wire sw1_fall = sw1s_p & ~sw1_s_d;
    wire sw2_fall = sw2s_p & ~sw2_s_d;
    wire sw3_fall = sw3s_p & ~sw3_s_d;
    wire sw4_fall = sw4s_p & ~sw4_s_d;
    wire sw5_fall = sw5s_p & ~sw5_s_d;
    wire sw6_fall = sw6s_p & ~sw6_s_d;
    wire sw7_fall = sw7s_p & ~sw7_s_d;

    //------------------------------------------------------------------------
    // 本地编辑值 / 应用事件
    //------------------------------------------------------------------------
    reg  signed [15:0] spd_edit;   // PKD 本地编辑值
    reg  signed [15:0] pos_edit;   // POSTGT 本地编辑值
    reg  signed [15:0] turns_edit; // TURNS_POSTGT 本地编辑值（signed 16 全范围）
    reg  [1:0]         mode_edit;  // MODE 本地编辑值（0..3）
    reg  [1:0]         sel_left;   // 左栏选中行：0=SPD，1=POS，2=P
    reg  src_local_d;

    reg  [FLASH_W-1:0] flash_cnt;
    reg                apply_side;   // 0 = L（左栏选中行），1 = R（MODE）
    reg                apply_vis_d;

    // 单拍应用请求 + 帧内容（交给下面的帧投递状态机）
    reg        apply_req;
    reg [7:0]  apply_idx;
    reg signed [15:0] apply_val;


    wire apply_l = sw1_fall & src_local;
    wire apply_r = sw2_fall & src_local;
    wire ev_force = sw3_fall | sw6_fall | sw7_fall;
    // SW4/SW5 只移动左栏选择（上位机模式也可预选，不影响参数写入）。
    wire ev_sel = sw4_fall | sw5_fall;

    // 把任意 16 bit cfg 值钳到本地可编辑范围（进入本地模式时用）
    function signed [15:0] clamp_spd;
        input signed [15:0] v;
        begin
            if (v > SPD_HI)      clamp_spd = SPD_HI;
            else if (v < SPD_LO) clamp_spd = SPD_LO;
            else                 clamp_spd = v;
        end
    endfunction

    function signed [15:0] clamp_pos;
        input signed [15:0] v;
        begin
            if (v > POS_HI)      clamp_pos = POS_HI;
            else if (v < POS_LO) clamp_pos = POS_LO;
            else                 clamp_pos = v;
        end
    endfunction

    // 显示用 11 bit 限幅（4 字符格式化器只支持 -999..999）；TURNS_POSTGT
    // 使用独立的 6 字符格式化器，显示 signed 16 全范围，不做此限幅。
    function signed [10:0] clamp_disp;
        input signed [15:0] v;
        begin
            if (v > 16'sd999)       clamp_disp =  11'sd999;
            else if (v < -16'sd999) clamp_disp = -11'sd999;
            else                    clamp_disp = v[10:0];
        end
    endfunction

    //------------------------------------------------------------------------
    // 20 Hz 实时节拍 + 相位映射
    //   arm_phase = (enc+520)*256/1040；ang001(0.01°) 直接用于摆杆倾斜
    //   ang001 已由 ang_calc 限幅在 ±18000（±180.00°），映射量约为 ±127。
    //   0° 指向上方（192），正角向顺时针（192 -> 224 -> 0 -> 64 ...）。
    //------------------------------------------------------------------------
    reg [TICK_W-1:0] tick_cnt;
    wire tick20 = (tick_cnt == TICK_DIV - 1);

    always @(posedge clk) begin
        if (!rst_n) tick_cnt <= {TICK_W{1'b0}};
        else if (tick20) tick_cnt <= {TICK_W{1'b0}};
        else tick_cnt <= tick_cnt + 1'b1;
    end

    // 编码器 → 旋转臂相位：-CPR/2..+CPR/2 映射到 0..255
    //   (enc + 520) * 63 / 256 ≈ (enc + 520) * 256 / 1040
    wire [31:0] arm_off32 = $signed(enc_pos_signed) + 32'sd520;
    wire [10:0] arm_off   = arm_off32[10:0];
    wire [16:0] arm_scaled = (arm_off << 6) - arm_off;
    wire [7:0]  arm_phase_l = arm_scaled[15:8];
    wire [7:0]  arm_phase   = ARM_INVERT ? (8'd255 - arm_phase_l) : arm_phase_l;

    reg [7:0]  arm_phase_r;
    reg signed [17:0] ang_r;
    wire ev_phase = tick20 && ((arm_phase != arm_phase_r) || (ang001 != ang_r));

    //------------------------------------------------------------------------
    // 编辑 / 应用 / 相位更新
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            spd_edit    <= -16'sd400;   // 与 cfg_regs 的 DEF_PKD_Q8 一致
            pos_edit    <=  16'sd0;
            turns_edit  <=  16'sd0;
            mode_edit   <=  2'd0;
            sel_left    <=  2'd0;
            src_local_d <= 1'b0;
            arm_phase_r <= 8'd0;
            ang_r       <= 18'sd0;
            flash_cnt   <= {FLASH_W{1'b0}};
            apply_side  <= 1'b0;
            apply_vis_d <= 1'b0;
            apply_req   <= 1'b0;
            apply_idx   <= 8'd0;
            apply_val   <= 16'sd0;
        end
        else begin
            src_local_d <= src_local;
            apply_vis_d <= (flash_cnt != {FLASH_W{1'b0}});
            apply_req   <= 1'b0;

            if (flash_cnt != {FLASH_W{1'b0}})
                flash_cnt <= flash_cnt - 1'b1;

            // 左栏选择：SW4 上移 / SW5 下移，3 行循环。
            if (sw4_fall)
                sel_left <= (sel_left == 2'd0) ? 2'd2 : sel_left - 2'd1;
            else if (sw5_fall)
                sel_left <= (sel_left == 2'd2) ? 2'd0 : sel_left + 2'd1;

            // 上位机模式：本地编辑值持续跟随 cfg（进入本地模式时天然同步）
            if (!src_local) begin
                spd_edit   <= clamp_spd(cfg_pkd);
                pos_edit   <= clamp_pos(cfg_pos_target);
                turns_edit <= cfg_turns_postgt;
                mode_edit  <= cfg_mode[1:0];
            end
            else begin
                // SW1 编码器：修改当前选中的左栏行。
                if (e1_inc) begin
                    case (sel_left)
                        2'd0: spd_edit <= (spd_edit > SPD_TOP) ? SPD_HI :
                                                        spd_edit + STEP_V;
                        2'd1: pos_edit <= ((pos_edit + POS_STEP) > POS_HI) ? POS_LO :
                                                        pos_edit + POS_STEP;
                        default: turns_edit <= (turns_edit > TURN_HI - TURN_STEP) ?
                                                        TURN_HI : turns_edit + TURN_STEP;
                    endcase
                end
                else if (e1_dec) begin
                    case (sel_left)
                        2'd0: spd_edit <= (spd_edit < SPD_BOT) ? SPD_LO :
                                                        spd_edit - STEP_V;
                        2'd1: pos_edit <= ((pos_edit - POS_STEP) < POS_LO) ? POS_HI :
                                                        pos_edit - POS_STEP;
                        default: turns_edit <= (turns_edit < TURN_LO + TURN_STEP) ?
                                                        TURN_LO : turns_edit - TURN_STEP;
                    endcase
                end

                // SW2 编码器：MODE 0→1→2→3→0 循环（反向同理）。
                if (e2_inc)      mode_edit <= mode_edit + 2'd1;
                else if (e2_dec) mode_edit <= mode_edit - 2'd1;
            end

            // 应用：生成与串口完全相同的 4 字节帧（AA | IDX | HI | LO）
            // 左栏 SW1_S：应用当前选中行（SPD / POS / P）
            if (apply_l) begin
                apply_req  <= 1'b1;
                apply_side <= 1'b0;
                flash_cnt  <= FLASH_DIV - 1;
                case (sel_left)
                    2'd0: begin apply_idx <= IDX_PKD;   apply_val <= spd_edit;   end
                    2'd1: begin apply_idx <= IDX_POS;   apply_val <= pos_edit;   end
                    default: begin apply_idx <= IDX_TURNS; apply_val <= turns_edit; end
                endcase
            end
            // 右栏 SW2_S：应用 MODE（0..3）
            if (apply_r) begin
                apply_req  <= 1'b1;
                apply_side <= 1'b1;
                apply_idx  <= IDX_MODE;
                apply_val  <= {14'd0, mode_edit};
                flash_cnt  <= FLASH_DIV - 1;
            end

            if (tick20) begin
                arm_phase_r <= arm_phase;
                ang_r       <= ang001;
            end
        end
    end

    wire apply_vis = (flash_cnt != {FLASH_W{1'b0}});

    //------------------------------------------------------------------------
    // 参数帧通道
    //   1) UART 字节流组装成完整 4 字节帧（本地模式整帧丢弃）；
    //   2) 本地应用帧装载；
    //   3) 仲裁后以 4 个连续字节原子投递给 cfg_regs。
    //   由于 cfg_regs 只会看到完整帧，它的解析器每次投递后必然回到帧头状态，
    //   两个来源之间切换不会留下半帧。
    //------------------------------------------------------------------------
    reg [1:0]  ua_st;
    localparam integer UART_GAP_CYC = CLK_HZ / 500; // 字节间隙2ms后丢弃不完整帧
    localparam integer UART_GAP_W = $clog2(UART_GAP_CYC+1);
    reg [UART_GAP_W-1:0] ua_gap;
    reg [7:0]  ua_idx, ua_hi;
    reg        uart_pending;
    reg [31:0] uart_buf;

    reg        local_pending;
    reg [31:0] local_buf;

    reg        tx_busy;
    reg [1:0]  tx_idx;
    reg [31:0] tx_buf;

    reg [7:0]  cfg_rx_data_r;
    reg        cfg_rx_dv_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            ua_st         <= 2'd0;
            ua_gap        <= 0;
            ua_idx        <= 8'd0;
            ua_hi         <= 8'd0;
            uart_pending  <= 1'b0;
            uart_buf      <= 32'd0;
            local_pending <= 1'b0;
            local_buf     <= 32'd0;
            tx_busy       <= 1'b0;
            tx_idx        <= 2'd0;
            tx_buf        <= 32'd0;
            cfg_rx_data_r <= 8'd0;
            cfg_rx_dv_r   <= 1'b0;
        end
        else begin
            cfg_rx_dv_r <= 1'b0;

            // 1) UART 帧组装
            if(src_local!=src_local_d)begin
                ua_st<=0;ua_gap<=0;
            end else if (uart_rx_dv) begin
                ua_gap<=0;
                case (ua_st)
                    2'd0: if (uart_rx_data == 8'hAA) ua_st <= 2'd1;
                    2'd1: begin ua_idx <= uart_rx_data; ua_st <= 2'd2; end
                    2'd2: begin ua_hi  <= uart_rx_data; ua_st <= 2'd3; end
                    default: begin
                        uart_buf     <= {8'hAA, ua_idx, ua_hi, uart_rx_data};
                        // 本地模式仍接受完整MODE0停机帧，其余UART命令被丢弃。
                        uart_pending <= !src_local ||
                            (ua_idx==8'd5 && ua_hi==8'd0 && uart_rx_data==8'd0);
                        ua_st        <= 2'd0;
                    end
                endcase
            end else if(ua_st!=0)begin
                if(ua_gap==UART_GAP_CYC-1)begin ua_st<=0;ua_gap<=0;end
                else ua_gap<=ua_gap+1'b1;
            end else ua_gap<=0;

            // 2) 原子投递：4 个连续字节。
            //    投递不按当前模式二次过滤：一帧一旦开始装载就完整送完，
            //    避免在半帧状态下切换模式；模式门控在“组装/装载”阶段完成。
            if (tx_busy) begin
                cfg_rx_dv_r   <= 1'b1;
                cfg_rx_data_r <= tx_buf[31:24];
                tx_buf        <= {tx_buf[23:0], 8'h00};
                if (tx_idx == 2'd3) begin
                    tx_busy <= 1'b0;
                    tx_idx  <= 2'd0;
                end
                else begin
                    tx_idx <= tx_idx + 2'd1;
                end
            end
            else if (local_pending) begin
                local_pending <= 1'b0;
                tx_buf        <= local_buf;
                tx_busy       <= 1'b1;
                tx_idx        <= 2'd0;
            end
            else if (uart_pending) begin
                uart_pending <= 1'b0;
                tx_buf       <= uart_buf;
                tx_busy      <= 1'b1;
                tx_idx       <= 2'd0;
            end

            // 3) 本地应用帧装载（放在最后，同一拍有冲突时保留下一个待发帧）
            if (apply_req) begin
                local_buf     <= {8'hAA, apply_idx, apply_val[15:8], apply_val[7:0]};
                local_pending <= 1'b1;
            end

            // 4) 切入本地模式的那一拍：丢弃尚未投递的上位机帧，
            //    严格保证本地模式下 UART 参数帧不会生效（已开始的 4 字节
            //    投递仍会完整送完，不会留下半帧）。
            if (src_local && !src_local_d)
                uart_pending <= 1'b0;
        end
    end

    assign cfg_rx_dv   = cfg_rx_dv_r;
    assign cfg_rx_data = cfg_rx_data_r;

    //------------------------------------------------------------------------
    // 显示值 / 待应用标志
    //   上位机模式：只读显示 cfg 值（灰色）；
    //   本地模式：显示本地编辑值（黄色），与 cfg 不同时显示橙色。
    //------------------------------------------------------------------------
    wire signed [10:0] spd_disp = src_local ? clamp_disp(spd_edit) :
                                              clamp_disp(cfg_pkd);
    wire signed [10:0] pos_disp = src_local ? clamp_disp(pos_edit) :
                                              clamp_disp(cfg_pos_target);
    // P 显示 signed 16 全范围（6 字符字段），不做 4 字符限幅。
    wire signed [15:0] turns_disp = src_local ? turns_edit : cfg_turns_postgt;
    wire [1:0]         mode_disp  = src_local ? mode_edit : cfg_mode[1:0];

    wire spd_pending   = src_local && (spd_edit != cfg_pkd);
    wire pos_pending   = src_local && (pos_edit != cfg_pos_target);
    wire turns_pending = src_local && (turns_edit != cfg_turns_postgt);
    wire mode_pending  = src_local && ({1'b0, mode_edit} != cfg_mode);

    // POS 参数预览臂：使用当前显示的 POS（POSTGT）参数，而非真实编码器位置。
    // 与真实臂同一套 0..255 相位映射；独立寄存，避免一帧绘制中途变化。
    wire [31:0] preview_off32 = $signed(pos_disp) + 32'sd520;
    wire [10:0] preview_off   = preview_off32[10:0];
    wire [16:0] preview_scaled = (preview_off << 6) - preview_off;
    wire [7:0]  preview_phase_l = preview_scaled[15:8];
    wire [7:0]  preview_phase = ARM_INVERT ? (8'd255 - preview_phase_l) : preview_phase_l;
    reg  [7:0]  preview_phase_r;
    always @(posedge clk) begin
        if (!rst_n) preview_phase_r <= 8'd0;
        else if (tick20) preview_phase_r <= preview_phase;
    end
    wire ev_preview = tick20 && (preview_phase != preview_phase_r);

    //------------------------------------------------------------------------
    // 十进制 → ASCII 格式化（流水线，每级最多 9 次减常数）
    //   旧实现在绘制状态机里逐拍减常数；改成参数表 4 行后，直接组合格式化
    //   会出现 30 级减法链。这里把每位数字拆成一级流水：每级只做 3/9 次
    //   常数减法，级间有寄存器，长链不会跨级累积。
    //   4 字符字段（SPD/POS，-999..999）：符号/绝对值 → 百位 → 十位/个位；
    //   6 字符字段（P，-32768..32767）：符号/绝对值 → 万位 → 千位 → 百位
    //   → 十位/个位。两种字段都右对齐、空格填充、负号紧贴最高位。
    //------------------------------------------------------------------------
    function [20:0] div10000;   // {digit[3:0], remainder[16:0]}
        input [16:0] a;
        reg [3:0]  d;
        reg [16:0] r;
        integer i;
        begin
            d = 4'd0; r = a;
            for (i = 0; i < 3; i = i + 1)
                if (r >= 17'd10000) begin r = r - 17'd10000; d = d + 1'b1; end
            div10000 = {d, r};
        end
    endfunction

    function [20:0] div1000;
        input [16:0] a;
        reg [3:0]  d;
        reg [16:0] r;
        integer i;
        begin
            d = 4'd0; r = a;
            for (i = 0; i < 9; i = i + 1)
                if (r >= 17'd1000) begin r = r - 17'd1000; d = d + 1'b1; end
            div1000 = {d, r};
        end
    endfunction

    function [20:0] div100;
        input [16:0] a;
        reg [3:0]  d;
        reg [16:0] r;
        integer i;
        begin
            d = 4'd0; r = a;
            for (i = 0; i < 9; i = i + 1)
                if (r >= 17'd100) begin r = r - 17'd100; d = d + 1'b1; end
            div100 = {d, r};
        end
    endfunction

    function [20:0] div10;
        input [16:0] a;
        reg [3:0]  d;
        reg [16:0] r;
        integer i;
        begin
            d = 4'd0; r = a;
            for (i = 0; i < 9; i = i + 1)
                if (r >= 17'd10) begin r = r - 17'd10; d = d + 1'b1; end
            div10 = {d, r};
        end
    endfunction

    wire signed [16:0] spd_ext   = {{6{spd_disp[10]}},  spd_disp};
    wire signed [16:0] pos_ext   = {{6{pos_disp[10]}},  pos_disp};
    wire signed [16:0] turns_ext = {{1{turns_disp[15]}}, turns_disp};

    // ---- SPD：4 字符字段（流水 3 级） --------------------------------------
    reg        s4_neg_s0, s4_neg_s1, s4_neg_s2;
    reg [16:0] s4_mag_s0, s4_rem_s1, s4_rem_s2;
    reg [3:0]  s4_d2_s1, s4_d2_s2, s4_d1_s2;
    reg [31:0] spd_chars;

    always @(posedge clk) begin
        if (!rst_n) begin
            s4_neg_s0 <= 1'b0;  s4_neg_s1 <= 1'b0;  s4_neg_s2 <= 1'b0;
            s4_mag_s0 <= 17'd0; s4_rem_s1 <= 17'd0; s4_rem_s2 <= 17'd0;
            s4_d2_s1  <= 4'd0;  s4_d2_s2  <= 4'd0;  s4_d1_s2  <= 4'd0;
            spd_chars <= {4{8'd32}};
        end
        else begin
            // 第 0 级：符号 + 绝对值
            s4_neg_s0 <= spd_disp[10];
            s4_mag_s0 <= spd_disp[10] ? (17'd0 - spd_ext[16:0]) : spd_ext[16:0];
            // 第 1 级：百位
            {s4_d2_s1, s4_rem_s1} <= div100(s4_mag_s0);
            s4_neg_s1 <= s4_neg_s0;
            // 第 2 级：十位
            {s4_d1_s2, s4_rem_s2} <= div10(s4_rem_s1);
            s4_d2_s2  <= s4_d2_s1;
            s4_neg_s2 <= s4_neg_s1;
            // 第 3 级：个位 + 右对齐 4 字符
            if (s4_d2_s2 != 4'd0)
                spd_chars <= {s4_neg_s2 ? 8'd45 : 8'd32, 8'd48 + s4_d2_s2,
                              8'd48 + s4_d1_s2, 8'd48 + s4_rem_s2[3:0]};
            else if (s4_d1_s2 != 4'd0)
                spd_chars <= {8'd32, s4_neg_s2 ? 8'd45 : 8'd32,
                              8'd48 + s4_d1_s2, 8'd48 + s4_rem_s2[3:0]};
            else
                spd_chars <= {8'd32, 8'd32, s4_neg_s2 ? 8'd45 : 8'd32,
                              8'd48 + s4_rem_s2[3:0]};
        end
    end

    // ---- POS：4 字符字段（流水 3 级） --------------------------------------
    reg        p4_neg_s0, p4_neg_s1, p4_neg_s2;
    reg [16:0] p4_mag_s0, p4_rem_s1, p4_rem_s2;
    reg [3:0]  p4_d2_s1, p4_d2_s2, p4_d1_s2;
    reg [31:0] pos_chars;

    always @(posedge clk) begin
        if (!rst_n) begin
            p4_neg_s0 <= 1'b0;  p4_neg_s1 <= 1'b0;  p4_neg_s2 <= 1'b0;
            p4_mag_s0 <= 17'd0; p4_rem_s1 <= 17'd0; p4_rem_s2 <= 17'd0;
            p4_d2_s1  <= 4'd0;  p4_d2_s2  <= 4'd0;  p4_d1_s2  <= 4'd0;
            pos_chars <= {4{8'd32}};
        end
        else begin
            p4_neg_s0 <= pos_disp[10];
            p4_mag_s0 <= pos_disp[10] ? (17'd0 - pos_ext[16:0]) : pos_ext[16:0];
            {p4_d2_s1, p4_rem_s1} <= div100(p4_mag_s0);
            p4_neg_s1 <= p4_neg_s0;
            {p4_d1_s2, p4_rem_s2} <= div10(p4_rem_s1);
            p4_d2_s2  <= p4_d2_s1;
            p4_neg_s2 <= p4_neg_s1;
            if (p4_d2_s2 != 4'd0)
                pos_chars <= {p4_neg_s2 ? 8'd45 : 8'd32, 8'd48 + p4_d2_s2,
                              8'd48 + p4_d1_s2, 8'd48 + p4_rem_s2[3:0]};
            else if (p4_d1_s2 != 4'd0)
                pos_chars <= {8'd32, p4_neg_s2 ? 8'd45 : 8'd32,
                              8'd48 + p4_d1_s2, 8'd48 + p4_rem_s2[3:0]};
            else
                pos_chars <= {8'd32, 8'd32, p4_neg_s2 ? 8'd45 : 8'd32,
                              8'd48 + p4_rem_s2[3:0]};
        end
    end

    // ---- P：6 字符字段 signed16（流水 6 级） -------------------------------
    reg        t6_neg_s0, t6_neg_s1, t6_neg_s2, t6_neg_s3, t6_neg_s4;
    reg [16:0] t6_mag_s0, t6_rem_s1, t6_rem_s2, t6_rem_s3, t6_rem_s4;
    reg [3:0]  t6_d4_s1, t6_d4_s2, t6_d4_s3, t6_d4_s4;
    reg [3:0]  t6_d3_s2, t6_d3_s3, t6_d3_s4;
    reg [3:0]  t6_d2_s3, t6_d2_s4;
    reg [3:0]  t6_d1_s4;
    reg [47:0] turns_chars;

    always @(posedge clk) begin
        if (!rst_n) begin
            t6_neg_s0 <= 1'b0; t6_neg_s1 <= 1'b0; t6_neg_s2 <= 1'b0;
            t6_neg_s3 <= 1'b0; t6_neg_s4 <= 1'b0;
            t6_mag_s0 <= 17'd0; t6_rem_s1 <= 17'd0; t6_rem_s2 <= 17'd0;
            t6_rem_s3 <= 17'd0; t6_rem_s4 <= 17'd0;
            t6_d4_s1 <= 4'd0; t6_d4_s2 <= 4'd0; t6_d4_s3 <= 4'd0; t6_d4_s4 <= 4'd0;
            t6_d3_s2 <= 4'd0; t6_d3_s3 <= 4'd0; t6_d3_s4 <= 4'd0;
            t6_d2_s3 <= 4'd0; t6_d2_s4 <= 4'd0; t6_d1_s4 <= 4'd0;
            turns_chars <= {6{8'd32}};
        end
        else begin
            // 第 0 级：符号 + 绝对值（-32768 的绝对值 32768 需要 17 位）
            t6_neg_s0 <= turns_disp[15];
            t6_mag_s0 <= turns_disp[15] ? (17'd0 - turns_ext[16:0]) :
                                          turns_ext[16:0];
            // 第 1 级：万位
            {t6_d4_s1, t6_rem_s1} <= div10000(t6_mag_s0);
            t6_neg_s1 <= t6_neg_s0;
            // 第 2 级：千位
            {t6_d3_s2, t6_rem_s2} <= div1000(t6_rem_s1);
            t6_d4_s2  <= t6_d4_s1;
            t6_neg_s2 <= t6_neg_s1;
            // 第 3 级：百位
            {t6_d2_s3, t6_rem_s3} <= div100(t6_rem_s2);
            t6_d4_s3 <= t6_d4_s2; t6_d3_s3 <= t6_d3_s2;
            t6_neg_s3 <= t6_neg_s2;
            // 第 4 级：十位
            {t6_d1_s4, t6_rem_s4} <= div10(t6_rem_s3);
            t6_d4_s4 <= t6_d4_s3; t6_d3_s4 <= t6_d3_s3; t6_d2_s4 <= t6_d2_s3;
            t6_neg_s4 <= t6_neg_s3;
            // 第 5 级：个位 + 右对齐 6 字符
            if (t6_d4_s4 != 4'd0)
                turns_chars <= {t6_neg_s4 ? 8'd45 : 8'd32, 8'd48 + t6_d4_s4,
                                8'd48 + t6_d3_s4, 8'd48 + t6_d2_s4,
                                8'd48 + t6_d1_s4, 8'd48 + t6_rem_s4[3:0]};
            else if (t6_d3_s4 != 4'd0)
                turns_chars <= {8'd32, t6_neg_s4 ? 8'd45 : 8'd32,
                                8'd48 + t6_d3_s4, 8'd48 + t6_d2_s4,
                                8'd48 + t6_d1_s4, 8'd48 + t6_rem_s4[3:0]};
            else if (t6_d2_s4 != 4'd0)
                turns_chars <= {8'd32, 8'd32, t6_neg_s4 ? 8'd45 : 8'd32,
                                8'd48 + t6_d2_s4, 8'd48 + t6_d1_s4,
                                8'd48 + t6_rem_s4[3:0]};
            else if (t6_d1_s4 != 4'd0)
                turns_chars <= {8'd32, 8'd32, 8'd32, t6_neg_s4 ? 8'd45 : 8'd32,
                                8'd48 + t6_d1_s4, 8'd48 + t6_rem_s4[3:0]};
            else
                turns_chars <= {8'd32, 8'd32, 8'd32, 8'd32,
                                t6_neg_s4 ? 8'd45 : 8'd32,
                                8'd48 + t6_rem_s4[3:0]};
        end
    end

    // ---- 4 行 × 8 字符 packed ASCII（[7:0] 为最左字符） --------------------
    wire [7:0]  mode_char = 8'd48 + {6'd0, mode_disp};
    // packed ASCII 以 [7:0] 为最左字符，格式化器大端字节反向拼接
    wire [63:0] row_spd   = {spd_chars[7:0], spd_chars[15:8], spd_chars[23:16], spd_chars[31:24],
                             8'd32, 8'd68, 8'd80, 8'd83}; // SPD + 4 chars
    wire [63:0] row_pos   = {pos_chars[7:0], pos_chars[15:8], pos_chars[23:16], pos_chars[31:24],
                             8'd32, 8'd83, 8'd79, 8'd80}; // POS + 4 chars
    wire [63:0] row_turns = {turns_chars[7:0], turns_chars[15:8], turns_chars[23:16],
                             turns_chars[31:24], turns_chars[39:32], turns_chars[47:40],
                             8'd32, 8'd80}; // P + 6 chars
    wire [63:0] row_mode  = {8'd32, 8'd32, mode_char, 8'd32,
                             8'd69, 8'd68, 8'd79, 8'd77};            // "MODE x"

    //------------------------------------------------------------------------
    // 重绘调度
    //   * 20 Hz 相位变化 / 参数编辑 / 选择变化 / 应用 / 模式切换 / cfg 变化 /
    //     APPLY 结束都置脏；
    //   * 两次重绘至少间隔 REDRAW_MS，避免编码器快速转动造成连续整帧重绘；
    //   * 控制环不受影响：这里只写帧缓存。
    //------------------------------------------------------------------------
    reg signed [15:0] cfg_pkd_d, cfg_pos_d, cfg_turns_d;
    reg [2:0]         cfg_mode_d;

    always @(posedge clk) begin
        if (!rst_n) begin
            cfg_pkd_d   <= 16'sd0;
            cfg_pos_d   <= 16'sd0;
            cfg_turns_d <= 16'sd0;
            cfg_mode_d  <= 3'd0;
        end
        else begin
            cfg_pkd_d   <= cfg_pkd;
            cfg_pos_d   <= cfg_pos_target;
            cfg_turns_d <= cfg_turns_postgt;
            cfg_mode_d  <= cfg_mode;
        end
    end

    wire ev_edit  = src_local && (e1_inc | e1_dec | e2_inc | e2_dec);
    wire ev_cfg   = (cfg_pkd != cfg_pkd_d) || (cfg_pos_target != cfg_pos_d) ||
                    (cfg_turns_postgt != cfg_turns_d) || (cfg_mode != cfg_mode_d);
    wire ev_apply = apply_l | apply_r | (apply_vis_d & ~apply_vis);
    wire ev_any   = ev_edit | ev_sel | ev_cfg | ev_apply | ev_force |
                    (src_local ^ src_local_d);

    reg [GAP_W-1:0] gap_cnt;
    reg             dirty;
    reg             draw_start;
    wire            draw_busy;

    wire gap_ok = (gap_cnt == {GAP_W{1'b0}});

    always @(posedge clk) begin
        if (!rst_n) begin
            gap_cnt    <= {GAP_W{1'b0}};
            dirty      <= 1'b1;      // 复位后先画一帧
            draw_start <= 1'b0;
        end
        else begin
            draw_start <= 1'b0;

            if (gap_cnt != {GAP_W{1'b0}})
                gap_cnt <= gap_cnt - 1'b1;

            if (ev_any || ev_phase || ev_preview)
                dirty <= 1'b1;

            if (dirty && gap_ok && !draw_busy) begin
                draw_start <= 1'b1;
                dirty      <= 1'b0;
                gap_cnt    <= GAP_DIV - 1;
            end
        end
    end

    //------------------------------------------------------------------------
    // 帧缓存 + 绘制 + SPI 扫描
    //------------------------------------------------------------------------
    wire        fb_we;
    wire [14:0] fb_waddr;
    wire [15:0] fb_wdata;
    wire [15:0] fb_rdata;
    wire [15:0] px, py;
    wire [14:0] fb_raddr = {py[7:0], px[6:0]};
    reg  [15:0] flush_data;

    ui_draw #(.ANG_INVERT(ANG_INVERT)) u_draw (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (draw_start),
        .busy        (draw_busy),
        .src_local   (src_local),
        .arm_phase   (arm_phase_r),
        .arm_preview_phase(preview_phase_r),
        .ang001      (ang_r),
        .row_spd     (row_spd),
        .row_pos     (row_pos),
        .row_turns   (row_turns),
        .row_mode    (row_mode),
        .row_pending ({mode_pending, turns_pending, pos_pending, spd_pending}),
        .sel_left    (sel_left),
        .apply_vis   (apply_vis),
        .apply_side  (apply_side),
        .fb_we       (fb_we),
        .fb_waddr    (fb_waddr),
        .fb_wdata    (fb_wdata)
    );

    ui_fb u_fb (
        .clk   (clk),
        .we    (fb_we),
        .waddr (fb_waddr),
        .wdata (fb_wdata),
        .raddr (fb_raddr),
        .rdata (fb_rdata)
    );

    // 面板/扫描实测为低字节先显示，这里交换 RGB565 高低字节（exp 上板验证）
    always @(posedge clk) begin
        flush_data <= {fb_rdata[7:0], fb_rdata[15:8]};
    end

    spi_screen_top u_screen (
        .sys_clk             (clk),
        .sys_rst_n           (rst_n),
        .flush_data_update_o (),
        .flush_data_i        (flush_data),
        .flush_addr_width_o  (px),
        .flush_addr_height_o (py),
        .lcd_spi_sclk        (lcd_spi_sclk),
        .lcd_spi_mosi        (lcd_spi_mosi),
        .lcd_spi_cs          (lcd_spi_cs),
        .lcd_dc              (lcd_dc),
        .lcd_reset           (lcd_reset),
        .lcd_blk             (lcd_blk)
    );

endmodule
