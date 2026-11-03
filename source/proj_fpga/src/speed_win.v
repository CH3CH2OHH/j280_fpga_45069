`timescale 1ns / 1ps

//=============================================================================
// 模块：speed_win
// 作用：由编码器累计计数计算摆臂速度，并输出整数速度和 Q8 速度。
//
// 算法：每个 tick（默认 1 kHz）把当前 count 压入 WIN 点历史队列，使用
//   count[n]-count[n-WIN] 的净位移，避免逐点差分放大编码器抖动。速度比例为
//   256*TICK_HZ/WIN，因此 arm_spd_q8 的单位是 count/s×256，arm_spd 是四舍五入
//   后的 count/s。初始化阶段先用同一个 count 填满窗口，避免上电瞬间产生假速度。
//
// 时序：tick 只启动入口采样；valid[0]/valid[1] 分别对应测量乘法和低通更新，
//   所以输出相对 tick 有固定的两拍系统时钟延迟。LP_SHIFT=0 为直通，数值越大
//   一阶低通越强，但响应越慢。
//=============================================================================

// 净位移滑窗 + 一阶低通。小数位只减少运算量化，不增加编码器物理分辨率。
// 默认 1 kHz 更新、8 ms 窗口；只输出原始计数速度，不缩放位置。
module speed_win #(
    parameter integer W = 32,
    parameter integer TICK_HZ = 1000,
    parameter integer WIN = 8,
    parameter integer LP_SHIFT = 2,
    parameter integer PERIOD_ASSIST = 0 // 0窗口，1固定周期辅助，2由period_enable在线选择
)(
    input wire clk, rst_n, tick,
    input wire signed [W-1:0] count,
    input wire period_enable,
    output wire signed [31:0] arm_spd,
    output wire signed [31:0] arm_spd_q8
);
    // history[0] 保存最近一次 tick 的位置，history[WIN-1] 是窗口最老样本。
    // count 使用累计计数，跨单圈不会发生位置回绕，适合计算净位移。
    reg signed [W-1:0] history [0:WIN-1];
    reg initialized;
    reg [2:0] valid;
    reg signed [W-1:0] delta;
    reg signed [63:0] measured_q8;
    reg signed [31:0] speed_filt_q8;
    integer i;
    // 把 256·TICK_HZ/WIN 在综合期算成常数，避免写 "/ WIN" 让工具去推除法器。
    // WIN 是 2 的幂，但写成除号后综合器不一定简化；GW2A 的 DSP 只有 88% 余量时
    // 一个 64 位除法器可能直接吃掉剩下的一大半。
    // NSCALE 的结果仍带 8 位小数：delta(count/窗口秒)×256。
    localparam integer NSCALE = (256 * TICK_HZ) / WIN;
    wire signed [32:0] speed_ext = {arm_spd_q8[31], arm_spd_q8};
    wire signed [32:0] speed_rounded = (speed_ext >= 0) ?
        ((speed_ext + 33'sd128) >>> 8) : -((-speed_ext + 33'sd128) >>> 8);
    assign arm_spd = speed_rounded[31:0];
    // measured_q8 是本窗口原始速度；residual/filtered 以更宽位宽计算，
    // 最后再饱和写回 32 位，防止极端编码器跳变时符号回绕。
    wire signed [64:0] residual =
        {measured_q8[63], measured_q8} - {{33{speed_filt_q8[31]}}, speed_filt_q8};
    wire signed [64:0] filtered =
        $signed({{33{speed_filt_q8[31]}}, speed_filt_q8}) + (residual >>> LP_SHIFT);

    generate if(PERIOD_ASSIST!=0) begin: g_period
        wire signed [31:0] period_q8;
        encoder_period_speed #(.W(W),.TICK_HZ(TICK_HZ),.LP_SHIFT(LP_SHIFT)) u_period(
            .clk(clk),.rst_n(rst_n),.tick(tick),.count(count),
            .window_q8(measured_q8),.velocity_q8(period_q8));
        // 两路持续更新，切换时沿用各自历史；遥测与控制器使用同一路速度。
        assign arm_spd_q8=(PERIOD_ASSIST==1 || period_enable) ? period_q8 : speed_filt_q8;
    end else begin: g_window
        assign arm_spd_q8=speed_filt_q8;
    end endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            initialized <= 0; valid <= 0; delta <= 0; measured_q8 <= 0;
            speed_filt_q8 <= 0;
            for (i = 0; i < WIN; i = i + 1) history[i] <= 0;
        end else begin
            // 只有入口等待 tick，后续级在系统时钟上流动；valid 链把同一
            // 个窗口的 delta、乘法结果和滤波结果对齐。
            valid <= {valid[1:0], tick && initialized};
            if (tick) begin
                if (!initialized) begin
                    initialized <= 1;
                    for (i = 0; i < WIN; i = i + 1) history[i] <= count;
                end else begin
                    delta <= count - history[WIN-1];
                    for (i = WIN-1; i > 0; i = i - 1) history[i] <= history[i-1];
                    history[0] <= count;
                end
            end
            if (valid[0]) measured_q8 <= $signed(delta) * NSCALE;
            if (valid[1]) begin
                if (filtered > 65'sd2147483647) speed_filt_q8 <= 32'sh7fffffff;
                else if (filtered < -65'sd2147483648) speed_filt_q8 <= 32'sh80000000;
                else speed_filt_q8 <= filtered[31:0];
            end
        end
    end
endmodule

// 低速周期法辅助：同向单计数事件至少相隔4ms时用边沿周期估速。
// 高频运动、多计数跳变及反向时回退净位移窗；无边沿时按已等待时间收紧速度上界。
// 采用逐拍无符号除法，每次控制节拍内完成，不综合变分母组合除法器。
module encoder_period_speed #(
    parameter integer W=32,
    parameter integer TICK_HZ=1000,
    parameter integer LP_SHIFT=2
)(
    input wire clk,rst_n,tick,
    input wire signed [W-1:0] count,
    input wire signed [63:0] window_q8,
    output reg signed [31:0] velocity_q8
);
    localparam integer NUMERATOR=256*TICK_HZ;
    localparam integer QW=$clog2(NUMERATOR+1);
    reg initialized,edge_seen,last_negative,period_valid;
    reg signed [W-1:0] previous;
    reg [15:0] age,interval_ms,denominator;
    reg choose_period,negative;
    reg [2:0] state;
    reg [QW-1:0] numerator,quotient;
    reg [16:0] remainder;
    reg [5:0] bits_left;
    reg signed [31:0] selected_q8;
    wire signed [W-1:0] recent=count-previous;
    wire single_edge=recent==1 || recent== -1;
    wire [15:0] gap=age==16'hffff ? age : age+1'b1;
    wire [16:0] trial_remainder={remainder[15:0],numerator[QW-1]};
    wire subtract=trial_remainder>={1'b0,denominator};
    wire [QW-1:0] quotient_next={quotient[QW-2:0],subtract};
    wire signed [32:0] residual=$signed({selected_q8[31],selected_q8})-
                                      $signed({velocity_q8[31],velocity_q8});
    wire signed [32:0] filtered=$signed({velocity_q8[31],velocity_q8})+(residual>>>LP_SHIFT);
    always @(posedge clk) begin
        if(!rst_n) begin
            initialized<=0;edge_seen<=0;last_negative<=0;period_valid<=0;previous<=0;
            age<=0;interval_ms<=1;denominator<=1;choose_period<=0;negative<=0;
            state<=0;numerator<=0;quotient<=0;remainder<=0;bits_left<=0;
            selected_q8<=0;velocity_q8<=0;
        end else begin
            case(state)
                0: if(tick) begin
                    if(!initialized) begin
                        initialized<=1;previous<=count;age<=0;
                        choose_period<=0;
                    end else begin
                        previous<=count;
                        if(recent!=0) begin
                            age<=0;edge_seen<=1;last_negative<=recent[W-1];interval_ms<=gap;
                            choose_period<=single_edge && edge_seen && recent[W-1]==last_negative && gap>=4;
                            period_valid<=single_edge && edge_seen && recent[W-1]==last_negative && gap>=4;
                            denominator<=gap;negative<=recent[W-1];
                        end else begin
                            age<=gap;choose_period<=period_valid;
                            denominator<=gap>interval_ms ? gap : interval_ms;
                            negative<=last_negative;
                        end
                    end
                    state<=1;
                end
                1: state<=2;
                2: begin
                    if(choose_period) begin
                        numerator<=NUMERATOR;quotient<=0;remainder<=0;bits_left<=QW;
                        state<=3;
                    end else begin
                        selected_q8<=window_q8>64'sd2147483647 ? 32'sh7fffffff :
                            window_q8< -64'sd2147483648 ? 32'sh80000000 : window_q8[31:0];
                        state<=4;
                    end
                end
                3: begin
                    numerator<=numerator<<1;
                    remainder<=subtract ? trial_remainder-{1'b0,denominator} : trial_remainder;
                    quotient<=quotient_next;bits_left<=bits_left-1'b1;
                    if(bits_left==1) begin
                        selected_q8<=negative ? -$signed({1'b0,quotient_next}) : $signed({1'b0,quotient_next});
                        state<=4;
                    end
                end
                4: begin
                    velocity_q8<=LP_SHIFT==0 ? selected_q8 : filtered[31:0];
                    state<=0;
                end
                default: state<=0;
            endcase
        end
    end
endmodule
