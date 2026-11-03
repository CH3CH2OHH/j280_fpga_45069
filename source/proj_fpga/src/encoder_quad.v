//=============================================================================
// 模块：encoder_quad
// 文件：encoder_quad.v
// 简述：增量式编码器四倍频正交解码，输出累计计数和单圈相位
//-----------------------------------------------------------------------------
// 功能说明
//   A/B 两相同步后比较第二级与其延迟一级，查表得到计数增减，
//   四倍频后同时输出连续累计计数和按 CPR 回绕的单圈位置。Z 相可选清零。
//
// 接口
//   enc_a    input   A 相（异步）
//   enc_b    input   B 相（异步）
//   enc_z    input   Z 相；不使用时接 0
//   count    output  位置计数，有符号，四倍频
//   count_mod output  无符号单圈相位，范围 0..CPR-1
//   count_signed     单圈有符号相位，范围 -CPR/2..(CPR-1)/2
//   dir      output  方向，1 = 正转
//   tick     output  计数有变化时输出一拍
//
// 参数
//   W           计数位宽
//   CPR         每圈四倍频计数
//   INVERT_DIR  方向取反
//   USE_INDEX   是否启用 Z 相清零
//
// 注意事项
//   count 保持连续累计值供测速；count_mod 和 count_signed 表示同一单圈相位。
//   当前机构测得每圈约 1040 个四倍频计数，顶层可通过 ENC_CPR 调整。
//=============================================================================

`timescale 1ns / 1ps

module encoder_quad #(
    parameter integer W          = 32,
    parameter integer CPR        = 1040,  // 每圈四倍频计数
    parameter         INVERT_DIR = 1'b0,   // 方向反了就改这里
    parameter         USE_INDEX  = 1'b0    // 是否用 Z 相清零
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 enc_a,
    input  wire                 enc_b,
    input  wire                 enc_z,
    output reg  signed [W-1:0]  count,     // 位置计数（四倍频，有符号）
    output reg         [W-1:0]  count_mod, // 单圈位置，范围 0..CPR-1
    output wire signed [W-1:0]  count_signed, // 单圈有符号相位，以复位相位为零
    output reg                  dir,       // 1 = 正转
    output reg                  tick       // 有跳变时输出 1 拍（供测速/调试）
);

    localparam signed [W:0] CPR_EXT = CPR;
    localparam signed [W:0] CPR_HALF_EXT = CPR / 2;
    wire signed [W:0] count_mod_ext = $signed({1'b0, count_mod});
    wire signed [W:0] count_signed_ext = (count_mod_ext >= CPR_HALF_EXT) ?
                                         count_mod_ext - CPR_EXT : count_mod_ext;
    assign count_signed = count_signed_ext[W-1:0];

    //---------------------------------------------------------------
    // 1. 同步打拍
    //---------------------------------------------------------------
    reg a0, a1, a2;
    reg b0, b1, b2;
    reg z0, z1, z2;

    always @(posedge clk) begin
        if (!rst_n) begin
            a0 <= 1'b0; a1 <= 1'b0; a2 <= 1'b0;
            b0 <= 1'b0; b1 <= 1'b0; b2 <= 1'b0;
            z0 <= 1'b0; z1 <= 1'b0; z2 <= 1'b0;
        end
        else begin
            a0 <= enc_a; a1 <= a0; a2 <= a1;
            b0 <= enc_b; b1 <= b0; b2 <= b1;
            z0 <= enc_z; z1 <= z0; z2 <= z1;
        end
    end

    //---------------------------------------------------------------
    // 2. 保留已有方向约定：cur 是较旧值，prv 是较新值。
    // 物理输入 00→10→11→01→00 计数 +4，不擅自翻转已接线系统的方向。
    //---------------------------------------------------------------
    wire [1:0] cur = {a2, b2};
    wire [1:0] prv = {a1, b1};

    wire fwd = (prv == 2'b00 && cur == 2'b01) ||
               (prv == 2'b01 && cur == 2'b11) ||
               (prv == 2'b11 && cur == 2'b10) ||
               (prv == 2'b10 && cur == 2'b00);

    wire rev = (prv == 2'b00 && cur == 2'b10) ||
               (prv == 2'b10 && cur == 2'b11) ||
               (prv == 2'b11 && cur == 2'b01) ||
               (prv == 2'b01 && cur == 2'b00);

    wire fwd_eff = INVERT_DIR ? rev : fwd;
    wire rev_eff = INVERT_DIR ? fwd : rev;

    //---------------------------------------------------------------
    // 3. 位置计数与状态输出
    //---------------------------------------------------------------
    wire z_hit = USE_INDEX & z1 & ~z2;     // 同步后的 Z 相上升沿；顶层未启用 Z

    always @(posedge clk) begin
        if (!rst_n) begin
            count <= {W{1'b0}};
            count_mod <= {W{1'b0}};
            dir   <= 1'b1;
            tick  <= 1'b0;
        end
        else begin
            tick <= fwd_eff | rev_eff;

            if (z_hit) begin
                count <= {W{1'b0}};        // 过零点，位置归零
                count_mod <= {W{1'b0}};
            end
            else if (fwd_eff) begin
                count <= count + 1'b1;
                count_mod <= (count_mod == CPR - 1) ? {W{1'b0}} : count_mod + 1'b1;
                dir   <= 1'b1;
            end
            else if (rev_eff) begin
                count <= count - 1'b1;
                count_mod <= (count_mod == 0) ? CPR - 1 : count_mod - 1'b1;
                dir   <= 1'b0;
            end
        end
    end

endmodule
