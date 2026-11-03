`timescale 1ns/1ps
// 容差保持仅冻结位置积分；角度PID、位置P/速度D和全部保护始终工作。
module position_hold #(
    parameter integer QUIET_MS=600
)(
    input wire clk,rst_n,en,
    input wire bal_on,fall,target_changed,
    input wire [15:0] tolerance,
    input wire signed [16:0] position_error,
    input wire signed [31:0] position,
    input wire signed [18:0] angle_relative,
    input wire signed [31:0] angle_rate_q8,
    input wire signed [31:0] arm_speed_q8,
    output reg active
);
    localparam integer TIMER_W=$clog2(QUIET_MS+1)>0 ? $clog2(QUIET_MS+1) : 1;
    reg [TIMER_W-1:0] quiet_count;
    reg signed [31:0] previous_position,entry_position;
    reg [15:0] previous_tolerance;
    wire [16:0] error_mag=position_error[16] ? -position_error : position_error;
    wire [18:0] angle_mag=angle_relative[18] ? -angle_relative : angle_relative;
    wire [31:0] rate_mag=angle_rate_q8[31] ? -angle_rate_q8 : angle_rate_q8;
    wire [31:0] speed_mag=arm_speed_q8[31] ? -arm_speed_q8 : arm_speed_q8;
    wire signed [32:0] displacement=$signed({position[31],position})-
                                             $signed({entry_position[31],entry_position});
    wire [32:0] movement_mag=displacement[32] ? -displacement : displacement;
    wire enabled=tolerance!=0 && tolerance<=160;
    wire enter_quiet=error_mag<={1'b0,tolerance} && position==previous_position &&
        angle_mag<=19'd80 && rate_mag<=32'd2048 && speed_mag<=32'd5120;
    wire [16:0] exit_error={1'b0,tolerance}+17'd8;
    wire disturbed=error_mag>exit_error || movement_mag>=33'd8 ||
        angle_mag>19'd160 || rate_mag>32'd6400 || speed_mag>32'd20480;
    always @(posedge clk) begin
        if(!rst_n) begin
            active<=0;quiet_count<=0;previous_position<=0;entry_position<=0;previous_tolerance<=0;
        end else if(en) begin
            previous_position<=position;
            previous_tolerance<=tolerance;
            if(!enabled || !bal_on || fall || target_changed || tolerance!=previous_tolerance) begin
                active<=0;quiet_count<=0;
            end else if(active) begin
                if(disturbed) begin active<=0;quiet_count<=0;end
            end else if(enter_quiet) begin
                if(quiet_count>=QUIET_MS-1) begin
                    active<=1;quiet_count<=0;entry_position<=position;
                end else quiet_count<=quiet_count+1'b1;
            end else quiet_count<=0;
        end
    end
endmodule
