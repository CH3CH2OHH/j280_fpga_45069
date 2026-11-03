// ============================================================================
// ui_draw.v - J280 融合界面绘制引擎（128x160 ST7735，RGB565）
// ----------------------------------------------------------------------------
// 由 exp_board_test/src/ui_draw.v 改造，保留已验证的帧缓存写入、8x16 字库、
// 中点画圆、整数 DDA 画杆、5x5 端点与 APPLY 机制。参数表为左 3 行 + 右 1 行：
//
//    y   0.. 15 : 标题栏 "J280 UI" + 右上角 PC / LOC + 居中 L/R APPLY
//    y  16.. 93 : 圆环（圆心 64,52，半径 30）+ 实时相位的旋转臂/物理摆杆
//    y  94..109 : 左栏 SPD（PKD）        | 右栏 MODE（0..3）
//    y 110..125 : 左栏 POS（POSTGT）     |
//    y 126..141 : 左栏 P  （TURNS_POSTGT）|
//                 左栏 x=0..63（8 字符），右栏 x=64..127（8 字符）
//    y 142..159 : 留空（深色背景）
//
// 文本项（txt_idx）：
//   0 标题  "J280 UI"（7 字符，x=36 居中）
//   1 模式  "PC"（2 字符，x=112）/ "LOC"（3 字符，x=104），右上角
//   2 APPLY "L APPLY"/"R APPLY"（7 字符，x=36，覆盖标题 0.5 s）
//   3..6 参数表 4 行 × 8 字符，字符内容与颜色由 ui_panel_ctrl 预格式化：
//         每行 64 bit packed ASCII，[7:0] 为最左字符；
//         左栏字符 0..3/0..1 为标签（SPD/POS/P），之后为数值；
//         右栏字符 0..4 为 "MODE" 标签，字符 5 为模式数字。
//
// 数值颜色：上位机模式灰色（只读）；本地模式黄色（可编辑）；
//           本地模式已改未应用橙色。选中行背景高亮。
//
// 每拍写 1 个像素，整帧约 35k 拍（≈0.7 ms @50 MHz），与 exp 工程一致。
// ============================================================================
`timescale 1ns / 1ps

module ui_draw #(
    parameter integer ANG_INVERT = 0   // 1 = 摆杆倾斜方向取反
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,          // 单拍启动
    output wire        busy,

    // UI 状态快照 -------------------------------------------------------------
    input  wire        src_local,      // 0 = 上位机模式，1 = 本地模式
    input  wire [7:0]  arm_phase,      // 真实旋转臂相位（编码器，0..255）
    input  wire [7:0]  arm_preview_phase, // POS 参数预览臂相位（0..255）
    input  wire signed [17:0] ang001,  // 物理摆杆倾角，0.01°，0=竖直向上
    // 参数表 4 行 × 8 字符 packed ASCII（[7:0] = 第 0 个字符）
    input  wire [63:0] row_spd,        // 左栏第 1 行 "SPD " + 4 字符
    input  wire [63:0] row_pos,        // 左栏第 2 行 "POS " + 4 字符
    input  wire [63:0] row_turns,      // 左栏第 3 行 "P "   + 6 字符
    input  wire [63:0] row_mode,       // 右栏第 1 行 "MODE " + 模式数字
    input  wire [3:0]  row_pending,    // {mode, turns, pos, spd} 已改未应用
    input  wire [1:0]  sel_left,       // 左栏选中行 0..2（背景高亮）
    input  wire        apply_vis,      // APPLY 提示有效
    input  wire        apply_side,     // 0 = 左（L），1 = 右（R）

    // 帧缓存写口 --------------------------------------------------------------
    output reg         fb_we,
    output reg  [14:0] fb_waddr,
    output reg  [15:0] fb_wdata
);

    //------------------------------------------------------------------------
    // 颜色（RGB565）
    //------------------------------------------------------------------------
    localparam [15:0] C_BG        = 16'h0841; // 近黑背景
    localparam [15:0] C_TITLE_PC  = 16'h2965; // 上位机模式标题栏（蓝灰）
    localparam [15:0] C_TITLE_LOC = 16'h0C48; // 本地模式标题栏（暗青绿）
    localparam [15:0] C_ROW       = 16'h2104; // 参数行底色
    localparam [15:0] C_ROW_SEL   = 16'h31A6; // 选中行底色（稍亮的蓝灰）
    localparam [15:0] C_TXT_W     = 16'hFFFF; // 白
    localparam [15:0] C_TXT_G     = 16'hC618; // 浅灰：上位机模式只读数值
    localparam [15:0] C_TXT_C     = 16'h07FF; // 青：标签
    localparam [15:0] C_TXT_Y     = 16'hFFE0; // 黄：本地可编辑 / APPLY
    localparam [15:0] C_TXT_OR    = 16'hFD20; // 橙：已改未应用
    localparam [15:0] C_RING      = 16'h6B7D; // 灰蓝圆环
    localparam [15:0] C_ROD       = 16'hFFE0; // 黄色旋转臂（真实编码器）
    localparam [15:0] C_PREVIEW   = 16'h07E0; // 绿色预览臂（POS 参数）
    localparam [15:0] C_PEND      = 16'h07FF; // 青色物理摆杆
    localparam [15:0] C_DOT       = 16'hFFFF; // 白色端点

    //------------------------------------------------------------------------
    // 几何（与 exp 工程一致）
    //------------------------------------------------------------------------
    localparam [7:0] CIRC_X = 8'd64;
    localparam [7:0] CIRC_Y = 8'd52;

    //------------------------------------------------------------------------
    // 文本项编号
    //------------------------------------------------------------------------
    localparam [2:0] T_TITLE   = 3'd0;
    localparam [2:0] T_MODE    = 3'd1;
    localparam [2:0] T_APPLY   = 3'd2;
    localparam [2:0] T_ROW_SPD = 3'd3;
    localparam [2:0] T_ROW_POS = 3'd4;
    localparam [2:0] T_ROW_TRN = 3'd5;
    localparam [2:0] T_ROW_MOD = 3'd6;

    //------------------------------------------------------------------------
    // FSM 状态
    //------------------------------------------------------------------------
    localparam [4:0] D_IDLE      = 5'd0;
    localparam [4:0] D_CLEAR     = 5'd1;
    localparam [4:0] D_TXT_INIT  = 5'd2;
    localparam [4:0] D_TXT_SETUP = 5'd3;
    localparam [4:0] D_G_START   = 5'd8;
    localparam [4:0] D_G_FETCH   = 5'd9;
    localparam [4:0] D_G_PIX     = 5'd10;
    localparam [4:0] D_CIRC_INIT = 5'd11;
    localparam [4:0] D_CIRC_PLOT = 5'd12;
    localparam [4:0] D_CIRC_STEP = 5'd13;
    localparam [4:0] D_LINE_INIT = 5'd14;
    localparam [4:0] D_LINE_PLOT = 5'd15;
    localparam [4:0] D_LINE_NEXT = 5'd16;
    localparam [4:0] D_DOT       = 5'd17;
    localparam [4:0] D_CIRC_OCT  = 5'd18;
    localparam [4:0] D_G_FETCH2  = 5'd19;

    //------------------------------------------------------------------------
    // 寄存器
    //------------------------------------------------------------------------
    reg [4:0]  state;
    reg [14:0] clr_addr;

    reg [2:0]  txt_idx;      // 文本项
    reg [2:0]  ch_idx;       // 当前项内字符序号
    reg [3:0]  nchars;
    reg [7:0]  tx, ty;
    reg [15:0] txt_bg;
    reg [15:0] g_fg;
    reg [6:0]  g_ch;
    reg [7:0]  g_byte;
    reg [3:0]  g_row;
    reg [2:0]  g_col;

    reg signed [7:0]  c_x, c_y;
    reg signed [9:0]  c_err;
    reg [2:0]         c_oct;
    reg [3:0]         c_st;
    reg signed [9:0]  c_bx, c_by;

    reg signed [9:0]  l_x, l_y, l_ex, l_ey;
    reg               l_sx, l_sy;
    reg [3:0]         l_st;

    reg signed [3:0]  dot_x, dot_y;

    //------------------------------------------------------------------------
    // 组合小工具
    //------------------------------------------------------------------------
    assign busy = (state != D_IDLE);

    wire [15:0] title_bg = src_local ? C_TITLE_LOC : C_TITLE_PC;

    wire [7:0] font_data;

    font8x16 u_font (
        .clk  (clk),
        .ch   (g_ch),
        .row  (g_row),
        .data (font_data)
    );

    // 四分之一正弦表：sin_lut(i) = round(30*sin(i*pi/128)), i=0..64
    function [4:0] sin_lut;
        input [6:0] si;
        begin
            case (si)
                7'd0 : sin_lut = 5'd0;
                7'd1 : sin_lut = 5'd1;
                7'd2 : sin_lut = 5'd1;
                7'd3 : sin_lut = 5'd2;
                7'd4 : sin_lut = 5'd3;
                7'd5 : sin_lut = 5'd4;
                7'd6 : sin_lut = 5'd4;
                7'd7 : sin_lut = 5'd5;
                7'd8 : sin_lut = 5'd6;
                7'd9 : sin_lut = 5'd7;
                7'd10: sin_lut = 5'd7;
                7'd11: sin_lut = 5'd8;
                7'd12: sin_lut = 5'd9;
                7'd13: sin_lut = 5'd9;
                7'd14: sin_lut = 5'd10;
                7'd15: sin_lut = 5'd11;
                7'd16: sin_lut = 5'd11;
                7'd17: sin_lut = 5'd12;
                7'd18: sin_lut = 5'd13;
                7'd19: sin_lut = 5'd13;
                7'd20: sin_lut = 5'd14;
                7'd21: sin_lut = 5'd15;
                7'd22: sin_lut = 5'd15;
                7'd23: sin_lut = 5'd16;
                7'd24: sin_lut = 5'd17;
                7'd25: sin_lut = 5'd17;
                7'd26: sin_lut = 5'd18;
                7'd27: sin_lut = 5'd18;
                7'd28: sin_lut = 5'd19;
                7'd29: sin_lut = 5'd20;
                7'd30: sin_lut = 5'd20;
                7'd31: sin_lut = 5'd21;
                7'd32: sin_lut = 5'd21;
                7'd33: sin_lut = 5'd22;
                7'd34: sin_lut = 5'd22;
                7'd35: sin_lut = 5'd23;
                7'd36: sin_lut = 5'd23;
                7'd37: sin_lut = 5'd24;
                7'd38: sin_lut = 5'd24;
                7'd39: sin_lut = 5'd25;
                7'd40: sin_lut = 5'd25;
                7'd41: sin_lut = 5'd25;
                7'd42: sin_lut = 5'd26;
                7'd43: sin_lut = 5'd26;
                7'd44: sin_lut = 5'd26;
                7'd45: sin_lut = 5'd27;
                7'd46: sin_lut = 5'd27;
                7'd47: sin_lut = 5'd27;
                7'd48: sin_lut = 5'd28;
                7'd49: sin_lut = 5'd28;
                7'd50: sin_lut = 5'd28;
                7'd51: sin_lut = 5'd28;
                7'd52: sin_lut = 5'd29;
                7'd53: sin_lut = 5'd29;
                7'd54: sin_lut = 5'd29;
                7'd55: sin_lut = 5'd29;
                7'd56: sin_lut = 5'd29;
                7'd57: sin_lut = 5'd30;
                7'd58: sin_lut = 5'd30;
                7'd59: sin_lut = 5'd30;
                7'd60: sin_lut = 5'd30;
                7'd61: sin_lut = 5'd30;
                7'd62: sin_lut = 5'd30;
                7'd63: sin_lut = 5'd30;
                7'd64: sin_lut = 5'd30;
                default: sin_lut = 5'd0;
            endcase
        end
    endfunction

    // 背景合成：标题栏（随模式变色）+ 左栏 3 行 + 右栏 MODE 行；
    // 选中行用稍亮底色，左栏/右栏之间没有分隔像素（8 字符正好占满 64 px）。
    function [15:0] bg_color;
        input [14:0] addr;
        input        loc;
        input [1:0]  sel;
        reg [6:0] x;
        reg [7:0] y;
        reg [1:0] row;
        begin
            x = addr[6:0];
            y = addr[14:7];
            bg_color = C_BG;
            if (y < 8'd16)
                bg_color = loc ? C_TITLE_LOC : C_TITLE_PC;
            else if ((y >= 8'd94) && (y < 8'd142)) begin
                if (x < 7'd64) begin
                    // 左栏：y=94/110/126 三行
                    row = (y >= 8'd126) ? 2'd2 :
                          (y >= 8'd110) ? 2'd1 : 2'd0;
                    bg_color = (row == sel) ? C_ROW_SEL : C_ROW;
                end
                else if (y < 8'd110)
                    bg_color = C_ROW;      // 右栏只有 MODE 一行
            end
        end
    endfunction

    //------------------------------------------------------------------------
    // 文本字符表
    //------------------------------------------------------------------------
    function [6:0] title_ch;
        input [2:0] i;
        begin
            case (i)
                3'd0: title_ch = 7'd74; // J
                3'd1: title_ch = 7'd50; // 2
                3'd2: title_ch = 7'd56; // 8
                3'd3: title_ch = 7'd48; // 0
                3'd4: title_ch = 7'd32; // space
                3'd5: title_ch = 7'd85; // U
                default: title_ch = 7'd73; // I
            endcase
        end
    endfunction

    function [6:0] mode_ch;
        input [2:0] i;
        begin
            if (src_local) begin
                case (i)
                    3'd0: mode_ch = 7'd76; // L
                    3'd1: mode_ch = 7'd79; // O
                    default: mode_ch = 7'd67; // C
                endcase
            end
            else begin
                case (i)
                    3'd0: mode_ch = 7'd80; // P
                    default: mode_ch = 7'd67; // C
                endcase
            end
        end
    endfunction

    function [6:0] apply_ch;
        input [2:0] i;
        begin
            case (i)
                3'd0: apply_ch = apply_side ? 7'd82 : 7'd76; // R / L
                3'd1: apply_ch = 7'd32; // space
                3'd2: apply_ch = 7'd65; // A
                3'd3: apply_ch = 7'd80; // P
                3'd4: apply_ch = 7'd80; // P
                3'd5: apply_ch = 7'd76; // L
                default: apply_ch = 7'd89; // Y
            endcase
        end
    endfunction

    // 从 packed 8 字符行里取第 i 个 ASCII 字符（[7:0] 为最左字符）。
    function [6:0] row_ch;
        input [63:0] w;
        input [2:0]  i;
        reg   [7:0]  b;
        begin
            case (i)
                3'd0: b = w[7:0];
                3'd1: b = w[15:8];
                3'd2: b = w[23:16];
                3'd3: b = w[31:24];
                3'd4: b = w[39:32];
                3'd5: b = w[47:40];
                3'd6: b = w[55:48];
                default: b = w[63:56];
            endcase
            row_ch = b[6:0];
        end
    endfunction

    // 当前字符是标签还是数值：左栏 SPD/POS 前 4 字符、P 前 2 字符、
    // 右栏 MODE 前 5 字符（含空格）为标签色；其余按数值状态着色。
    function [15:0] row_fg;
        input [1:0] row;
        input [2:0] idx;
        reg         label;
        begin
            case (row)
                2'd0, 2'd1: label = (idx < 3'd4);
                2'd2:       label = (idx < 3'd2);
                default:    label = (idx < 3'd5);
            endcase
            if (label)
                row_fg = C_TXT_C;
            else if (!src_local)
                row_fg = C_TXT_G;
            else
                row_fg = row_pending[row] ? C_TXT_OR : C_TXT_Y;
        end
    endfunction

    // 参数行底色：左栏选中行高亮，MODE 行固定普通底色。
    function [15:0] row_bg;
        input [2:0] item;
        input [1:0] sel;
        begin
            if ((item == T_ROW_MOD) || ((item - 3'd3) != {1'b0, sel}))
                row_bg = C_ROW;
            else
                row_bg = C_ROW_SEL;
        end
    endfunction

    //------------------------------------------------------------------------
    // 旋转臂（编码器相位）在椭圆上的端点 + 物理摆杆（ang001）端点
    //   ellipse: center (64,66), x ~= 1.25*sin_lut, y ~= 0.4375*sin_lut
    //------------------------------------------------------------------------
    wire [6:0] arm_idx   = {1'b0, arm_phase[5:0]};
    wire [4:0] arm_sin_s = sin_lut(arm_idx);
    wire [4:0] arm_cos_s = sin_lut(7'd64 - arm_idx);
    // x uses a~1.25, y uses b~0.4375; quadrants must use the correct axis scale
    wire signed [9:0] arm_cos_x = arm_cos_s + (arm_cos_s >>> 2);
    wire signed [9:0] arm_sin_x = arm_sin_s + (arm_sin_s >>> 2);
    wire signed [9:0] arm_cos_y = (arm_cos_s >>> 1) - (arm_cos_s >>> 4);
    wire signed [9:0] arm_sin_y = (arm_sin_s >>> 1) - (arm_sin_s >>> 4);

    reg signed [9:0] a_ex_r, a_ey_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            a_ex_r <= 10'sd94;
            a_ey_r <= 10'sd66;
        end
        else begin
            case (arm_phase[7:6])
                2'd0: begin a_ex_r <= 10'sd64 + arm_cos_x; a_ey_r <= 10'sd66 - arm_sin_y; end
                2'd1: begin a_ex_r <= 10'sd64 - arm_sin_x; a_ey_r <= 10'sd66 - arm_cos_y; end
                2'd2: begin a_ex_r <= 10'sd64 - arm_cos_x; a_ey_r <= 10'sd66 + arm_sin_y; end
                default: begin a_ex_r <= 10'sd64 + arm_sin_x; a_ey_r <= 10'sd66 + arm_cos_y; end
            endcase
        end
    end

    // POS 参数预览臂端点（绿色细线）；与真实臂相同的椭圆坐标缩放。
    wire [6:0] prev_idx   = {1'b0, arm_preview_phase[5:0]};
    wire [4:0] prev_sin_s = sin_lut(prev_idx);
    wire [4:0] prev_cos_s = sin_lut(7'd64 - prev_idx);
    wire signed [9:0] prev_cos_x = prev_cos_s + (prev_cos_s >>> 2);
    wire signed [9:0] prev_sin_x = prev_sin_s + (prev_sin_s >>> 2);
    wire signed [9:0] prev_cos_y = (prev_cos_s >>> 1) - (prev_cos_s >>> 4);
    wire signed [9:0] prev_sin_y = (prev_sin_s >>> 1) - (prev_sin_s >>> 4);
    reg signed [9:0] pv_ex_r, pv_ey_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            pv_ex_r <= 10'sd94;
            pv_ey_r <= 10'sd66;
        end
        else begin
            case (arm_preview_phase[7:6])
                2'd0: begin pv_ex_r <= 10'sd64 + prev_cos_x; pv_ey_r <= 10'sd66 - prev_sin_y; end
                2'd1: begin pv_ex_r <= 10'sd64 - prev_sin_x; pv_ey_r <= 10'sd66 - prev_cos_y; end
                2'd2: begin pv_ex_r <= 10'sd64 - prev_cos_x; pv_ey_r <= 10'sd66 + prev_sin_y; end
                default: begin pv_ex_r <= 10'sd64 + prev_sin_x; pv_ey_r <= 10'sd66 + prev_cos_y; end
            endcase
        end
    end

    // 物理摆杆：角 0=竖直向上，±90°=水平，±180°=竖直向下
    // 用四分之一正弦表拼出 0..180° 的 sin/cos，再按 ang001 符号补正
    // 第一级：angle 绝对值/符号
    wire signed [17:0] ang_tilt = ANG_INVERT ? -$signed(ang001) : $signed(ang001);
    reg signed [17:0] ang_tilt_r;
    reg [17:0] ang_abs_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            ang_tilt_r <= 18'sd0;
            ang_abs_r  <= 18'sd0;
        end
        else begin
            ang_tilt_r <= ang_tilt;
            ang_abs_r  <= ang_tilt[17] ? -ang_tilt : ang_tilt;
        end
    end

    // 第二级：0..180° 的 sin/cos 分量（7 位索引，128 用 8 位算再截断）
    wire [31:0] ang_prod = ang_abs_r * 32'd29;      // 18000*29/4096 ≈ 127
    wire [6:0]  ang_idx  = ang_prod[18:12];         // 0..127 对应 0..180°
    wire [7:0]  idx_eff8 = (ang_idx <= 7'd64) ? {1'b0, ang_idx} : (8'd128 - {1'b0, ang_idx});
    wire [6:0]  idx_eff  = idx_eff8[6:0];
    wire [4:0]  sin_mag  = sin_lut(idx_eff);
    wire [4:0]  cos_mag  = sin_lut(7'd64 - idx_eff);
    wire        cos_neg  = (ang_idx > 7'd64);
    reg [4:0]   sin_mag_r, cos_mag_r;
    reg         cos_neg_r, ang_neg_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            sin_mag_r <= 5'd0;
            cos_mag_r <= 5'd30;
            cos_neg_r <= 1'b0;
            ang_neg_r <= 1'b0;
        end
        else begin
            sin_mag_r <= sin_mag;
            cos_mag_r <= cos_mag;
            cos_neg_r <= cos_neg;
            ang_neg_r <= ang_tilt_r[17];
        end
    end

    // 第三级：摆杆端点
    wire signed [9:0] sin_p = ang_neg_r ? -$signed({5'b0, sin_mag_r}) : $signed({5'b0, sin_mag_r});
    wire signed [9:0] cos_p = cos_neg_r ? -$signed({5'b0, cos_mag_r}) : $signed({5'b0, cos_mag_r});
    wire signed [9:0] pend_x = a_ex_r + sin_p;     // 摆杆水平分量
    wire signed [9:0] pend_y = a_ey_r - cos_p;     // cos>0 向上，cos<0 向下
    reg signed [9:0] pend_x_r, pend_y_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            pend_x_r <= 10'sd94;
            pend_y_r <= 10'sd36;
        end
        else begin
            pend_x_r <= pend_x;
            pend_y_r <= pend_y;
        end
    end

    //------------------------------------------------------------------------
    // 中点画圆辅助
    //------------------------------------------------------------------------
    reg signed [9:0] o_sx, o_sy;
    always @(*) begin
        case (c_oct)
            3'd0: begin o_sx =  c_x; o_sy =  c_y; end
            3'd1: begin o_sx =  c_y; o_sy =  c_x; end
            3'd2: begin o_sx =  c_y; o_sy = -c_x; end
            3'd3: begin o_sx =  c_x; o_sy = -c_y; end
            3'd4: begin o_sx = -c_x; o_sy = -c_y; end
            3'd5: begin o_sx = -c_y; o_sy = -c_x; end
            3'd6: begin o_sx = -c_y; o_sy =  c_x; end
            default: begin o_sx = -c_x; o_sy = c_y; end
        endcase
    end

    reg signed [9:0] c_dx, c_dy;
    always @(*) begin
        case (c_st)
            4'd0: begin c_dx = -10'sd1; c_dy = -10'sd1; end
            4'd1: begin c_dx =  10'sd0; c_dy = -10'sd1; end
            4'd2: begin c_dx =  10'sd1; c_dy = -10'sd1; end
            4'd3: begin c_dx = -10'sd1; c_dy =  10'sd0; end
            4'd4: begin c_dx =  10'sd0; c_dy =  10'sd0; end
            4'd5: begin c_dx =  10'sd1; c_dy =  10'sd0; end
            4'd6: begin c_dx = -10'sd1; c_dy =  10'sd1; end
            4'd7: begin c_dx =  10'sd0; c_dy =  10'sd1; end
            default: begin c_dx = 10'sd1; c_dy = 10'sd1; end
        endcase
    end

    wire signed [9:0] c_ny10 = c_y + 10'sd1;
    wire signed [9:0] c_nx10 = (c_err < 0) ? c_x : (c_x - 10'sd1);
    wire signed [9:0] c_nerr = (c_err < 0)
                             ? (c_err + (c_ny10 <<< 1) + 10'sd1)
                             : (c_err + ((c_ny10 - c_nx10) <<< 1) + 10'sd1);

    wire signed [9:0] c_px = c_bx + c_dx;
    wire signed [9:0] c_py = c_by + c_dy;

    //------------------------------------------------------------------------
    // 整数 DDA 画杆辅助
    //------------------------------------------------------------------------
    reg signed [9:0] l_dx_off, l_dy_off;
    always @(*) begin
        case (l_st)
            4'd0: begin l_dx_off = -10'sd1; l_dy_off = -10'sd1; end
            4'd1: begin l_dx_off =  10'sd0; l_dy_off = -10'sd1; end
            4'd2: begin l_dx_off =  10'sd1; l_dy_off = -10'sd1; end
            4'd3: begin l_dx_off = -10'sd1; l_dy_off =  10'sd0; end
            4'd4: begin l_dx_off =  10'sd0; l_dy_off =  10'sd0; end
            4'd5: begin l_dx_off =  10'sd1; l_dy_off =  10'sd0; end
            4'd6: begin l_dx_off = -10'sd1; l_dy_off =  10'sd1; end
            4'd7: begin l_dx_off =  10'sd0; l_dy_off =  10'sd1; end
            default: begin l_dx_off = 10'sd1; l_dy_off = 10'sd1; end
        endcase
    end

    reg [1:0]        line_kind;      // 2=POS预览臂，0=真实旋转臂，1=物理摆杆
    reg [15:0]       l_color;
    wire signed [9:0] line_start_x = (line_kind == 2'd0 || line_kind == 2'd2) ? 10'sd64 : a_ex_r;
    wire signed [9:0] line_start_y = (line_kind == 2'd0 || line_kind == 2'd2) ? 10'sd66 : a_ey_r;
    wire signed [9:0] line_end_x   = (line_kind == 2'd2) ? pv_ex_r :
                                     (line_kind == 2'd0) ? a_ex_r : pend_x_r;
    wire signed [9:0] line_end_y   = (line_kind == 2'd2) ? pv_ey_r :
                                     (line_kind == 2'd0) ? a_ey_r : pend_y_r;
    wire signed [9:0] l_dx_init = (line_end_x >= line_start_x) ? (line_end_x - line_start_x) : (line_start_x - line_end_x);
    wire signed [9:0] l_dy_abs  = (line_end_y >= line_start_y) ? (line_end_y - line_start_y) : (line_start_y - line_end_y);
    wire l_sx_init = (line_end_x >= line_start_x);
    wire l_sy_init = (line_end_y >= line_start_y);

    wire signed [9:0] l_px = l_x + l_dx_off;
    wire signed [9:0] l_py = l_y + l_dy_off;

    // 当前字模像素 x
    wire [7:0] g_px = tx + {2'b0, ch_idx, 3'b000} + {5'b0, g_col};

    //------------------------------------------------------------------------
    // 端点白点辅助
    //------------------------------------------------------------------------
    wire signed [3:0] dot_dx = dot_x - 4'sd2;
    wire signed [3:0] dot_dy = dot_y - 4'sd2;
    wire signed [9:0] d_px = l_ex + {{6{dot_dx[3]}}, dot_dx};
    wire signed [9:0] d_py = l_ey + {{6{dot_dy[3]}}, dot_dy};

    // 笔刷越界保护
    wire c_ok = (c_px >= 0) && (c_px < 128) && (c_py >= 0) && (c_py < 160);
    wire l_ok = (l_px >= 0) && (l_px < 128) && (l_py >= 16) && (l_py < 94);
    wire d_ok = (d_px >= 0) && (d_px < 128) && (d_py >= 16) && (d_py < 94);

    reg [9:0] l_rem;
    reg [9:0] l_ax, l_ay, l_den, l_xacc, l_yacc;
    wire [10:0] l_xacc_p = l_xacc + l_ax;
    wire [10:0] l_yacc_p = l_yacc + l_ay;
    wire        l_xstep  = (l_xacc_p >= {1'b0, l_den});
    wire        l_ystep  = (l_yacc_p >= {1'b0, l_den});
    wire [10:0] l_xacc_s = l_xacc_p - {1'b0, l_den};
    wire [10:0] l_yacc_s = l_yacc_p - {1'b0, l_den};
    wire [9:0]  l_xacc_n = l_xstep ? l_xacc_s[9:0] : l_xacc_p[9:0];
    wire [9:0]  l_yacc_n = l_ystep ? l_yacc_s[9:0] : l_yacc_p[9:0];

    //------------------------------------------------------------------------
    // 绘制主状态机
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= D_IDLE;
            fb_we    <= 1'b0;
            clr_addr <= 15'd0;
            txt_idx  <= 3'd0;
        end
        else begin
            fb_we <= 1'b0;
            case (state)

            //----------------------------------------------------------------
            D_IDLE: begin
                if (start) begin
                    clr_addr <= 15'd0;
                    txt_idx  <= 3'd0;
                    state    <= D_CLEAR;
                end
            end

            //----------------------------------------------------------------
            // 背景：标题栏 + 参数表 4 行
            //----------------------------------------------------------------
            D_CLEAR: begin
                fb_we    <= 1'b1;
                fb_waddr <= clr_addr;
                fb_wdata <= bg_color(clr_addr, src_local, sel_left);
                if (clr_addr == 15'd20479)
                    state <= D_TXT_INIT;
                else
                    clr_addr <= clr_addr + 15'd1;
            end

            //----------------------------------------------------------------
            // 文本
            //----------------------------------------------------------------
            D_TXT_INIT: begin
                txt_idx <= 3'd0;
                state   <= D_TXT_SETUP;
            end

            D_TXT_SETUP: begin
                case (txt_idx)
                T_TITLE: begin
                    nchars <= 4'd7;
                    tx     <= 8'd36;   // 7*8=56，(128-56)/2
                    ty     <= 8'd0;
                    txt_bg <= title_bg;
                    ch_idx <= 3'd0;
                    state  <= D_G_START;
                end
                T_MODE: begin
                    nchars <= src_local ? 4'd3 : 4'd2;
                    tx     <= src_local ? 8'd104 : 8'd112; // 右对齐到 x=125
                    ty     <= 8'd0;
                    txt_bg <= title_bg;
                    ch_idx <= 3'd0;
                    state  <= D_G_START;
                end
                T_APPLY: begin
                    if (!apply_vis) begin
                        txt_idx <= T_ROW_SPD;
                        state   <= D_TXT_SETUP;
                    end
                    else begin
                        nchars <= 4'd7;   // "L/R APPLY"
                        tx     <= 8'd36;
                        ty     <= 8'd0;
                        txt_bg <= title_bg;
                        ch_idx <= 3'd0;
                        state  <= D_G_START;
                    end
                end
                T_ROW_SPD, T_ROW_POS, T_ROW_TRN, T_ROW_MOD: begin
                    nchars <= 4'd8;
                    tx     <= (txt_idx == T_ROW_MOD) ? 8'd64 : 8'd0;
                    ty     <= (txt_idx == T_ROW_SPD) ? 8'd94  :
                              (txt_idx == T_ROW_POS) ? 8'd110 :
                              (txt_idx == T_ROW_TRN) ? 8'd126 : 8'd94;
                    txt_bg <= row_bg(txt_idx, sel_left);
                    ch_idx <= 3'd0;
                    state  <= D_G_START;
                end
                default: state <= D_CIRC_INIT;
                endcase
            end

            // 单个字模：16 行 x 8 列 ---------------------------------------
            D_G_START: begin
                g_row <= 4'd0;
                case (txt_idx)
                T_TITLE:   g_ch <= title_ch(ch_idx);
                T_MODE:    g_ch <= mode_ch(ch_idx);
                T_APPLY:   g_ch <= apply_ch(ch_idx);
                T_ROW_SPD: g_ch <= row_ch(row_spd,   ch_idx);
                T_ROW_POS: g_ch <= row_ch(row_pos,   ch_idx);
                T_ROW_TRN: g_ch <= row_ch(row_turns, ch_idx);
                T_ROW_MOD: g_ch <= row_ch(row_mode,  ch_idx);
                default:   g_ch <= 7'd32;
                endcase

                case (txt_idx)
                T_TITLE:   g_fg <= C_TXT_W;
                T_MODE:    g_fg <= src_local ? C_TXT_Y : C_TXT_W;
                T_APPLY:   g_fg <= C_TXT_Y;
                T_ROW_SPD: g_fg <= row_fg(2'd0, ch_idx);
                T_ROW_POS: g_fg <= row_fg(2'd1, ch_idx);
                T_ROW_TRN: g_fg <= row_fg(2'd2, ch_idx);
                T_ROW_MOD: g_fg <= row_fg(2'd3, ch_idx);
                default:   g_fg <= C_TXT_W;
                endcase

                state <= D_G_FETCH;
            end

            D_G_FETCH: begin
                // 字库输出寄存一拍：这里给地址，下一拍在 D_G_FETCH2 取数据
                state <= D_G_FETCH2;
            end

            D_G_FETCH2: begin
                g_byte <= font_data;
                g_col  <= 3'd0;
                state  <= D_G_PIX;
            end

            D_G_PIX: begin
                fb_we    <= 1'b1;
                fb_waddr <= { (ty + {4'b0, g_row}), g_px[6:0] };
                fb_wdata <= g_byte[7 - g_col] ? g_fg : txt_bg;

                if (g_col == 3'd7) begin
                    if (g_row == 4'd15) begin
                        if (({1'b0, ch_idx} + 4'd1) == nchars) begin
                            if (txt_idx == T_ROW_MOD)
                                state <= D_CIRC_INIT;
                            else begin
                                txt_idx <= txt_idx + 3'd1;
                                state   <= D_TXT_SETUP;
                            end
                        end
                        else begin
                            ch_idx <= ch_idx + 3'd1;
                            state  <= D_G_START;
                        end
                    end
                    else begin
                        g_row <= g_row + 4'd1;
                        state <= D_G_FETCH;
                    end
                end
                else begin
                    g_col <= g_col + 3'd1;
                end
            end

            //----------------------------------------------------------------
            // 圆环（中点法，3x3 笔刷）
            //----------------------------------------------------------------
            D_CIRC_INIT: begin
                c_x   <= 8'sd30;
                c_y   <= 8'sd0;
                c_err <= -10'sd29;
                c_oct <= 3'd0;
                c_st  <= 4'd0;
                state <= D_CIRC_OCT;
            end

            D_CIRC_OCT: begin
                // scale unit circle to ellipse: a ~= 1.25*30, b ~= 0.4375*30
                c_bx  <= 10'sd64 + (o_sx + (o_sx >>> 2));
                c_by  <= 10'sd66 + ((o_sy >>> 1) - (o_sy >>> 4));
                c_st  <= 4'd0;
                state <= D_CIRC_PLOT;
            end

            D_CIRC_PLOT: begin
                fb_we    <= c_ok;
                fb_waddr <= { c_py[7:0], c_px[6:0] };
                fb_wdata <= C_RING;
                if (c_st == 4'd8) begin
                    c_st <= 4'd0;
                    if (c_oct == 3'd7)
                        state <= D_CIRC_STEP;
                    else begin
                        c_oct <= c_oct + 3'd1;
                        state <= D_CIRC_OCT;
                    end
                end
                else begin
                    c_st <= c_st + 4'd1;
                end
            end

            D_CIRC_STEP: begin
                if (c_nx10 >= c_ny10) begin
                    c_x   <= c_nx10[7:0];
                    c_y   <= c_ny10[7:0];
                    c_err <= c_nerr;
                    c_oct <= 3'd0;
                    c_st  <= 4'd0;
                    state <= D_CIRC_OCT;
                end
                else begin
                    line_kind <= 2'd2;
                    state     <= D_LINE_INIT;
                end
            end

            //----------------------------------------------------------------
            // 旋转臂 / 物理摆杆（整数 DDA，3x3 笔刷，步数严格等于 max(|dx|,|dy|)）
            //----------------------------------------------------------------
            D_LINE_INIT: begin
                l_x    <= line_start_x;
                l_y    <= line_start_y;
                l_ex   <= line_end_x;
                l_ey   <= line_end_y;
                l_color <= (line_kind == 2'd2) ? C_PREVIEW :
                           (line_kind == 2'd1) ? C_PEND : C_ROD;
                l_ax   <= l_dx_init;
                l_ay   <= l_dy_abs;
                l_den  <= (l_dx_init > l_dy_abs) ? l_dx_init : l_dy_abs;
                l_rem  <= (l_dx_init > l_dy_abs) ? l_dx_init : l_dy_abs;
                l_xacc <= 10'd0;
                l_yacc <= 10'd0;
                l_sx   <= l_sx_init;
                l_sy   <= l_sy_init;
                l_st   <= 4'd0;
                state  <= D_LINE_PLOT;
            end

            D_LINE_PLOT: begin
                // 预览臂只画 1 px 细线；真实臂/摆杆保持 3x3
                fb_we    <= l_ok && ((line_kind != 2'd2) || (l_st == 4'd4));
                fb_waddr <= { l_py[7:0], l_px[6:0] };
                fb_wdata <= l_color;
                if (l_st == 4'd8) begin
                    l_st  <= 4'd0;
                    state <= D_LINE_NEXT;
                end
                else begin
                    l_st <= l_st + 4'd1;
                end
            end

            D_LINE_NEXT: begin
                if (l_rem == 10'd0) begin
                    if (line_kind == 2'd2) begin
                        line_kind <= 2'd0;   // 预览臂 -> 真实臂
                        state     <= D_LINE_INIT;
                    end
                    else if (line_kind == 2'd0) begin
                        line_kind <= 2'd1;   // 真实臂 -> 物理摆杆
                        state     <= D_LINE_INIT;
                    end
                    else begin
                        dot_x <= 4'sd0;
                        dot_y <= 4'sd0;
                        state <= D_DOT;
                    end
                end
                else begin
                    l_x    <= l_xstep ? (l_x + (l_sx ? 10'sd1 : -10'sd1)) : l_x;
                    l_y    <= l_ystep ? (l_y + (l_sy ? 10'sd1 : -10'sd1)) : l_y;
                    l_xacc <= l_xacc_n;
                    l_yacc <= l_yacc_n;
                    l_rem  <= l_rem - 10'd1;
                    state  <= D_LINE_PLOT;
                end
            end

            //----------------------------------------------------------------
            // 端点 5x5 白点
            //----------------------------------------------------------------
            D_DOT: begin
                fb_we    <= d_ok;
                fb_waddr <= { d_py[7:0], d_px[6:0] };
                fb_wdata <= C_DOT;
                if (dot_x == 4'sd4) begin
                    dot_x <= 4'sd0;
                    if (dot_y == 4'sd4)
                        state <= D_IDLE;
                    else
                        dot_y <= dot_y + 4'sd1;
                end
                else begin
                    dot_x <= dot_x + 4'sd1;
                end
            end

            default: state <= D_IDLE;

            endcase
        end
    end

endmodule
