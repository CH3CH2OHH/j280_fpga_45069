//=============================================================================
// 模块：msg_tx
// 文件：msg_tx.v
// 简述：遥测报文组帧与发送
//-----------------------------------------------------------------------------
// 功能说明
//   按固定周期把测量值格式化为一行 ASCII 报文，逐字节送入 uart_tx：
//
//     ANG=+012.34 RAW=0512 POS=+00123 SPD=+0123 DUT=+0123 REF=+00400 M2B5 SW=1 Vj1
//
//   ANG / RAW / POS / SPD / DUT 为测量值，REF 为 0.01° 单位的角度目标，M 为当前模式，
//   B 为十六进制状态字（8 x 保护锁存 + 4 x 已接管 + 2 x 判倒 + 1 x 可接管），
//   V 后第一位为固件版本，第二位为已接受的参数帧数。
//
// 接口
//   trig        input   发送节拍
//   ang001/raw/enc_cnt/spd_cnt/dut_cnt  input  待显示的测量值
//   cfg_cnt     input   已接受的参数帧数
//   mode        input   当前模式
//   bal_on/bal_fall/bal_near/bal_fault  input  状态位
//   tx_data/tx_start/tx_busy  output  接 uart_tx
//
// 注意事项
//   十进制拆位由 dig4 / dig5 完成，本模块只负责按字节位置选择输出。
//   版本号取 BUILD 参数：0~9 显示数字，10~35 显示大写字母，36~61 显示小写字母。
//=============================================================================

`timescale 1ns / 1ps

module msg_tx #(
    parameter integer MSG_LEN = 78,
    parameter integer BUILD   = 0,     // 版本号，编译时由顶层传入
    parameter integer EXTENDED = 0     // 1追加32位绝对计数十六进制及控制来源，97字节
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               trig,      // 单拍触发
    input  wire signed [17:0] ang001,    // 角度，0.01°
    input  wire [15:0]        raw,       // ADC 码值 0~1023
    input  wire signed [31:0] enc_cnt,   // 编码器位置计数
    input  wire signed [31:0] abs_count, // 完整累计计数，仅扩展报文使用
    input  wire src_local,
    input  wire hold_active,              // EXTENDED2追加容差保持状态
    input  wire signed [31:0] spd_cnt,   // 角速度，counts/秒
    input  wire signed [31:0] dut_cnt,   // 当前输出占空比
    input  wire signed [31:0] ref_cnt,   // 角度目标，单位 0.01°
    input  wire [3:0]         cfg_cnt,   // 已接受的串口参数帧数（0~9）
    input  wire [2:0]         mode,      // 当前模式
    input  wire               bal_on,    // 平衡是否已接管
    input  wire               bal_fall,  // 判倒标志
    input  wire               bal_near,  // 可投入标志
    input  wire               bal_fault, // 平衡保护锁存
    input  wire               swing_active, // 自动起摆 PWM 正在工作
    output reg  [7:0]         tx_data,
    output reg                tx_start,
    input  wire               tx_busy
);

    // 整帧采用同一时刻的快照，防止 ASCII 逐字节发送时符号、各位、各字段跨时刻。
    reg signed [17:0] snap_ang001;
    reg [15:0] snap_raw;
    reg signed [31:0] snap_enc_cnt, snap_spd_cnt, snap_dut_cnt, snap_ref_cnt;
    reg [3:0] snap_cfg_cnt;
    reg [2:0] snap_mode;
    reg snap_bal_on, snap_bal_fall, snap_bal_near, snap_bal_fault;
    reg snap_swing_active;
    reg signed [31:0] snap_abs_count;
    reg snap_src_local;
    reg snap_hold_active;
    wire [3:0] snap_bal_status = {snap_bal_fault, snap_bal_on, snap_bal_fall, snap_bal_near};
    reg [3:0] settle;

    //=========================================================================
    // 角度：第 0 级 —— 输入打拍（绝对值、符号、原始码值）
    //=========================================================================
    wire [14:0] a_abs = snap_ang001[17] ? (~snap_ang001[14:0] + 15'd1) : snap_ang001[14:0];

    reg [14:0] a_s0;
    reg [9:0]  raw_s0;
    reg        sg_s0;

    always @(posedge clk) begin
        if (!rst_n) begin
            a_s0 <= 15'd0; raw_s0 <= 10'd0; sg_s0 <= 1'b0;
        end
        else begin
            a_s0   <= a_abs;
            raw_s0 <= snap_raw[9:0];
            sg_s0  <= snap_ang001[17];
        end
    end

    //=========================================================================
    // 角度：第 1 级 —— /100 取整数部分；码值千位用比较即可
    //=========================================================================
    reg [7:0]  ip_s1;
    reg        ge1k_s1;
    reg [9:0]  rrem1_s1;
    reg [14:0] a_s1;
    wire [14:0] ip_full_s1 = a_s0 / 15'd100;

    always @(posedge clk) begin
        if (!rst_n) begin
            ip_s1 <= 8'd0; ge1k_s1 <= 1'b0; rrem1_s1 <= 10'd0; a_s1 <= 15'd0;
        end
        else begin
            a_s1     <= a_s0;
            ip_s1    <= ip_full_s1[7:0];
            ge1k_s1  <= (raw_s0 >= 10'd1000);
            rrem1_s1 <= (raw_s0 >= 10'd1000) ? (raw_s0 - 10'd1000) : raw_s0;
        end
    end

    //=========================================================================
    // 角度：第 2 级 —— 小数部分 fp；角度百位；码值百位
    //=========================================================================
    reg [6:0] fp_s2;
    reg       ge100_s2;
    reg [6:0] rem100_s2;
    reg [3:0] q2_s2;
    reg [9:0] rrem1_s2;
    wire [14:0] fp_full_s2 = a_s1 - (ip_s1 * 15'd100);
    wire [7:0] rem100_full_s2 = (ip_s1 >= 8'd100) ?
        (ip_s1 - 8'd100) : {1'b0, ip_s1[6:0]};
    wire [9:0] q2_full_s2 = rrem1_s1 / 10'd100;

    always @(posedge clk) begin
        if (!rst_n) begin
            fp_s2 <= 7'd0; ge100_s2 <= 1'b0; rem100_s2 <= 7'd0;
            q2_s2 <= 4'd0; rrem1_s2 <= 10'd0;
        end
        else begin
            fp_s2     <= fp_full_s2[6:0];
            ge100_s2  <= (ip_s1 >= 8'd100);
            rem100_s2 <= rem100_full_s2[6:0];
            q2_s2     <= q2_full_s2[3:0];
            rrem1_s2  <= rrem1_s1;
        end
    end

    //=========================================================================
    // 角度：第 3 级 —— 三路 /10
    //=========================================================================
    reg [3:0] q10_s3, f10_s3;
    reg [9:0] rrem2_s3;
    reg [6:0] rem100_s3, fp_s3;
    reg       ge100_s3;
    wire [6:0] q10_full_s3 = rem100_s2 / 7'd10;
    wire [6:0] f10_full_s3 = fp_s2 / 7'd10;
    wire [9:0] rrem2_full_s3 = rrem1_s2 - (q2_s2 * 10'd100);
    reg [3:0] q2_s3;
    reg       ge1k_s3;

    always @(posedge clk) begin
        if (!rst_n) begin
            q10_s3 <= 4'd0; f10_s3 <= 4'd0; rrem2_s3 <= 10'd0;
            rem100_s3 <= 7'd0; fp_s3 <= 7'd0; ge100_s3 <= 1'b0;
            q2_s3 <= 4'd0; ge1k_s3 <= 1'b0;
        end
        else begin
            q10_s3    <= q10_full_s3[3:0];
            f10_s3    <= f10_full_s3[3:0];
            rrem2_s3  <= rrem2_full_s3;
            rem100_s3 <= rem100_s2;
            fp_s3     <= fp_s2;
            ge100_s3  <= ge100_s2;
            q2_s3     <= q2_s2;
            ge1k_s3   <= ge1k_s1;
        end
    end

    //=========================================================================
    // 角度：第 4 级 —— 取余数，凑齐所有数字
    //=========================================================================
    reg [3:0] d_h, d_t, d_o;
    reg [3:0] f_t, f_o;
    reg [3:0] d_r3, d_r2, d_r1;
    reg       sg_d;
    reg [9:0] rrem2_d;
    wire [6:0] d_o_full = rem100_s3 - (q10_s3 * 7'd10);
    wire [6:0] f_o_full = fp_s3 - (f10_s3 * 7'd10);
    wire [9:0] d_r1_full = rrem2_s3 / 10'd10;

    always @(posedge clk) begin
        if (!rst_n) begin
            d_h <= 4'd0; d_t <= 4'd0; d_o <= 4'd0;
            f_t <= 4'd0; f_o <= 4'd0;
            d_r3 <= 4'd0; d_r2 <= 4'd0; d_r1 <= 4'd0;
            sg_d <= 1'b0; rrem2_d <= 10'd0;
        end
        else begin
            d_h   <= {3'd0, ge100_s3};
            d_t   <= q10_s3;
            d_o   <= d_o_full[3:0];
            f_t   <= f10_s3;
            f_o   <= f_o_full[3:0];
            d_r3  <= {3'd0, ge1k_s3};
            d_r2  <= q2_s3;
            d_r1  <= d_r1_full[3:0];
            rrem2_d <= rrem2_s3;
            sg_d  <= sg_s0;
        end
    end

    // 码值个位：由已寄存的十位和余数算出，只有一次乘加
    //   注意 rrem2_d 是 0~99，必须先减完再截低 4 位
    wire [6:0] r0_full = rrem2_d[6:0] - (d_r1 * 4'd10);
    wire [3:0] d_r0    = r0_full[3:0];

    //=========================================================================
    // 摆臂位置：dig5（±99999）；角速度 / 占空比：dig4（±9999）
    //=========================================================================
    wire        pos_sg;
    wire [3:0]  pos_d4, pos_d3, pos_d2, pos_d1, pos_d0;

    dig5 u_pos (
        .clk(clk), .rst_n(rst_n), .val(snap_enc_cnt),
        .sgn(pos_sg),
        .d4(pos_d4), .d3(pos_d3), .d2(pos_d2), .d1(pos_d1), .d0(pos_d0)
    );

    wire        spd_sg;
    wire [3:0]  spd_d3, spd_d2, spd_d1, spd_d0;

    dig4 u_spd (
        .clk(clk), .rst_n(rst_n), .val(snap_spd_cnt),
        .sgn(spd_sg), .d3(spd_d3), .d2(spd_d2), .d1(spd_d1), .d0(spd_d0)
    );

    wire        dut_sg;
    wire [3:0]  dut_d3, dut_d2, dut_d1, dut_d0;

    dig4 u_dut (
        .clk(clk), .rst_n(rst_n), .val(snap_dut_cnt),
        .sgn(dut_sg), .d3(dut_d3), .d2(dut_d2), .d1(dut_d1), .d0(dut_d0)
    );

    // 角度目标以 0.01° 的整数形式发送，PC 端除以 100 后显示为角度。
    wire        ref_sg;
    wire [3:0]  ref_d4, ref_d3, ref_d2, ref_d1, ref_d0;

    dig5 u_ref (
        .clk(clk), .rst_n(rst_n), .val(snap_ref_cnt),
        .sgn(ref_sg),
        .d4(ref_d4), .d3(ref_d3), .d2(ref_d2), .d1(ref_d1), .d0(ref_d0)
    );

    //=========================================================================
    // 序号 → 字节
    //=========================================================================
    // 单字节版本字符采用数字、A~Z、a~z，避免 BUILD=36 后输出标点符号。
    localparam [7:0] VNUM = (BUILD < 10) ? (8'h30 + BUILD) :
                            (BUILD < 36) ? (8'h41 + BUILD - 10) :
                            (BUILD < 62) ? (8'h61 + BUILD - 36) : 8'h3F;

    function [7:0] hex_char;
        input [3:0] nibble;
        begin
            hex_char=nibble<10 ? 8'h30+{4'd0,nibble} : 8'h41+{4'd0,nibble}-8'd10;
        end
    endfunction

    function [7:0] byte_of;
        input [6:0] i;
        begin
            case (i)
                7'd0 : byte_of = "A";
                7'd1 : byte_of = "N";
                7'd2 : byte_of = "G";
                7'd3 : byte_of = "=";
                7'd4 : byte_of = sg_d ? "-" : "+";
                7'd5 : byte_of = {4'h3, d_h};
                7'd6 : byte_of = {4'h3, d_t};
                7'd7 : byte_of = {4'h3, d_o};
                7'd8 : byte_of = ".";
                7'd9 : byte_of = {4'h3, f_t};
                7'd10: byte_of = {4'h3, f_o};
                7'd11: byte_of = " ";

                7'd12: byte_of = "R";
                7'd13: byte_of = "A";
                7'd14: byte_of = "W";
                7'd15: byte_of = "=";
                7'd16: byte_of = {4'h3, d_r3};
                7'd17: byte_of = {4'h3, d_r2};
                7'd18: byte_of = {4'h3, d_r1};
                7'd19: byte_of = {4'h3, d_r0};
                7'd20: byte_of = " ";

                7'd21: byte_of = "P";
                7'd22: byte_of = "O";
                7'd23: byte_of = "S";
                7'd24: byte_of = "=";
                7'd25: byte_of = pos_sg ? "-" : "+";
                7'd26: byte_of = {4'h3, pos_d4};
                7'd27: byte_of = {4'h3, pos_d3};
                7'd28: byte_of = {4'h3, pos_d2};
                7'd29: byte_of = {4'h3, pos_d1};
                7'd30: byte_of = {4'h3, pos_d0};
                7'd31: byte_of = " ";

                7'd32: byte_of = "S";
                7'd33: byte_of = "P";
                7'd34: byte_of = "D";
                7'd35: byte_of = "=";
                7'd36: byte_of = spd_sg ? "-" : "+";
                7'd37: byte_of = {4'h3, spd_d3};
                7'd38: byte_of = {4'h3, spd_d2};
                7'd39: byte_of = {4'h3, spd_d1};
                7'd40: byte_of = {4'h3, spd_d0};
                7'd41: byte_of = " ";

                7'd42: byte_of = "D";
                7'd43: byte_of = "U";
                7'd44: byte_of = "T";
                7'd45: byte_of = "=";
                7'd46: byte_of = dut_sg ? "-" : "+";
                7'd47: byte_of = {4'h3, dut_d3};
                7'd48: byte_of = {4'h3, dut_d2};
                7'd49: byte_of = {4'h3, dut_d1};
                7'd50: byte_of = {4'h3, dut_d0};
                7'd51: byte_of = " ";

                7'd52: byte_of = "R";
                7'd53: byte_of = "E";
                7'd54: byte_of = "F";
                7'd55: byte_of = "=";
                7'd56: byte_of = ref_sg ? "-" : "+";
                7'd57: byte_of = {4'h3, ref_d4};
                7'd58: byte_of = {4'h3, ref_d3};
                7'd59: byte_of = {4'h3, ref_d2};
                7'd60: byte_of = {4'h3, ref_d1};
                7'd61: byte_of = {4'h3, ref_d0};
                7'd62: byte_of = " ";

                7'd63: byte_of = "M";
                7'd64: byte_of = {4'h3, 1'b0, snap_mode};      // snap_mode 3 位，补 1 个 0
                7'd65: byte_of = "B";
                // B 是十六进制状态：bit3 保护锁存、bit2 已接管、bit1 判倒、bit0 可投入。
                7'd66: byte_of = (snap_bal_status < 4'd10) ?
                                 (8'h30 + {4'd0, snap_bal_status}) :
                                 (8'h41 + {4'd0, snap_bal_status} - 8'd10);
                7'd67: byte_of = " ";

                7'd68: byte_of = "S";
                7'd69: byte_of = "W";
                7'd70: byte_of = "=";
                7'd71: byte_of = snap_swing_active ? "1" : "0";
                7'd72: byte_of = " ";
                7'd73: byte_of = "V";
                7'd74: byte_of = VNUM;
                7'd75: byte_of = {4'h3, snap_cfg_cnt};
                7'd76: byte_of = EXTENDED ? " " : 8'h0D;
                7'd77: byte_of = EXTENDED ? "A" : 8'h0A;
                7'd78: byte_of = "B";
                7'd79: byte_of = "S";
                7'd80: byte_of = "=";
                7'd81: byte_of = hex_char(snap_abs_count[31:28]);
                7'd82: byte_of = hex_char(snap_abs_count[27:24]);
                7'd83: byte_of = hex_char(snap_abs_count[23:20]);
                7'd84: byte_of = hex_char(snap_abs_count[19:16]);
                7'd85: byte_of = hex_char(snap_abs_count[15:12]);
                7'd86: byte_of = hex_char(snap_abs_count[11:8]);
                7'd87: byte_of = hex_char(snap_abs_count[7:4]);
                7'd88: byte_of = hex_char(snap_abs_count[3:0]);
                7'd89: byte_of = " ";
                7'd90: byte_of = "S";
                7'd91: byte_of = "R";
                7'd92: byte_of = "C";
                7'd93: byte_of = "=";
                7'd94: byte_of = snap_src_local ? "1" : "0";
                7'd95: byte_of = EXTENDED>=2 ? " " : 8'h0D;
                7'd96: byte_of = EXTENDED>=2 ? "H" : 8'h0A;
                7'd97: byte_of = "L";
                7'd98: byte_of = "D";
                7'd99: byte_of = "=";
                7'd100: byte_of = snap_hold_active ? "1" : "0";
                7'd101: byte_of = 8'h0D;
                7'd102: byte_of = 8'h0A;
                default: byte_of = 8'h20;
            endcase
        end
    endfunction

    //=========================================================================
    // 发送状态机
    //=========================================================================
    localparam [2:0] S_IDLE = 0, S_SEND = 1, S_HOLD = 2, S_NEXT = 3, S_SETTLE = 4;

    reg [2:0] st;
    reg [6:0] idx;

    always @(posedge clk) begin
        if (!rst_n) begin
            snap_ang001 <= 0; snap_raw <= 0; snap_enc_cnt <= 0; snap_spd_cnt <= 0;
            snap_dut_cnt <= 0; snap_ref_cnt <= 0; snap_cfg_cnt <= 0; snap_mode <= 0;
            snap_bal_on <= 0; snap_bal_fall <= 0; snap_bal_near <= 0;
            snap_bal_fault <= 0; snap_swing_active <= 0; settle <= 0;
            snap_abs_count<=0;snap_src_local<=0;
            snap_hold_active<=0;
            st       <= S_IDLE;
            idx      <= 7'd0;
            tx_start <= 1'b0;
            tx_data  <= 8'h00;
        end
        else begin
            case (st)
                S_IDLE: begin
                    tx_start <= 1'b0;
                    idx      <= 7'd0;
                    if (trig) begin
                        snap_ang001 <= ang001;
                        snap_raw <= raw;
                        snap_enc_cnt <= enc_cnt;
                        snap_abs_count<=abs_count;snap_src_local<=src_local;
                        snap_hold_active<=hold_active;
                        snap_spd_cnt <= spd_cnt;
                        snap_dut_cnt <= dut_cnt;
                        snap_ref_cnt <= ref_cnt;
                        snap_cfg_cnt <= cfg_cnt;
                        snap_mode <= mode;
                        snap_bal_on <= bal_on;
                        snap_bal_fall <= bal_fall;
                        snap_bal_near <= bal_near;
                        snap_bal_fault <= bal_fault;
                        snap_swing_active <= swing_active;
                        settle <= 0;
                        st <= S_SETTLE;
                    end
                end

                S_SETTLE: begin
                    // 最慢的 dig5 为八级，额外留余量后再发送第一个字符。
                    if (settle == 12) st <= S_SEND;
                    else settle <= settle + 1'b1;
                end

                S_SEND: begin
                    if (!tx_busy) begin
                        tx_data  <= byte_of(idx);
                        tx_start <= 1'b1;
                        st       <= S_HOLD;
                    end
                end

                S_HOLD: begin
                    tx_start <= 1'b0;
                    if (tx_busy)
                        st <= S_NEXT;
                end

                S_NEXT: begin
                    if (!tx_busy) begin
                        if (idx == MSG_LEN - 1)
                            st <= S_IDLE;
                        else begin
                            idx <= idx + 1'b1;
                            st  <= S_SEND;
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
