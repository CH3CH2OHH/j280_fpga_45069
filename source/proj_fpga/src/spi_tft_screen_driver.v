`timescale 1ns / 1ps
module spi_tft_screen_driver(
    input                               sys_clk                    ,
    input                               sys_rst_n                  ,

    //用户接口
    input              [   7: 0]        spi_screen_flush_data_i    ,//屏幕显示数据
    output                              spi_screen_flush_updte_o   ,//像素点数据刷新
    output                              spi_screen_flush_fsync_o   ,//屏幕帧同步

     //spi tft screen   屏幕接口
    output                              lcd_spi_sclk               ,// 屏幕spi时钟接口
    output                              lcd_spi_mosi               ,// 屏幕spi数据接口
    output                              lcd_spi_cs                 ,// 屏幕spi使能接口
    output                              lcd_dc                     ,// 屏幕 数据/命令 接口
    output                              lcd_reset                  ,// 屏幕复位接口
    output                              lcd_blk                     // 屏幕背光接口
);

//屏幕尺寸
    parameter                           SCREEN_WIDTH              = 32'd128;
    parameter                           SCREEN_HEIGHT             = 32'd160;

    localparam                          RESET_DELAY               = 32'd500_000; // 复位脉冲 10ms @ 50MHz

//总模块信号
    reg                                 lcd_init_done              ;//初始化完成标志信号
    wire                                spi_start                  ;//spi开始信号
    wire                                spi_end                    ;//spi结束信号
    wire               [   7: 0]        spi_send_data              ;//spi发送数据（组合）
    reg                [   7: 0]        spi_send_data_r            ;//spi发送数据（打拍，缩短大 mux 路径）
    reg                                 lcd_dc_r                   ;//lcd dc 打拍
    wire                                spi_send_ack               ;//spi数据发送完成响应
    wire                                lcd_dc_i                   ;//lcd数据/命令信号

    reg                [  31: 0]        reset_cnt                  ;//复位计数
    wire                                lcd_reset_done             ;//复位完成

// 初始化模块信号
    wire                                tft_screen_init_req        ;//初始化模块请求
    wire                                tft_screen_init_ack        ;//初始化模块完成
    wire               [   7: 0]        tft_screen_init_data       ;//初始化模块数据
    wire                                tft_screen_init_dc         ;//初始化模块dc
    wire                                spi_send_init_req          ;//spi发送数据请求
    wire                                spi_send_init_end          ;//结束spi发送
    wire                                spi_send_init_ack          ;//spi数据发送完成响应

//刷新模块
    wire                                tft_screen_flush_req       ;//刷新模块请求
    wire               [   7: 0]        tft_screen_flush_data      ;//刷新模块数据
    wire                                tft_screen_flush_dc        ;//刷新模块数据/命令信号
    wire                                spi_send_flush_req         ;//刷新模块发送请求
    wire                                spi_send_flush_end         ;//刷新模块发送结束
    wire                                spi_send_flush_ack         ;//刷新模块数据发送完成响应

// 复位脉冲：上电先拉低 10ms，再拉高（ST7735S 需要硬件复位）
    always@(posedge sys_clk or negedge sys_rst_n) begin
        if( sys_rst_n == 1'b0 )
            reset_cnt <= 'd0;
        else if( reset_cnt < RESET_DELAY )
            reset_cnt <= reset_cnt + 1'b1;
        else
            reset_cnt <= reset_cnt;
    end
    assign lcd_reset_done = (reset_cnt >= RESET_DELAY) ? 1'b1 : 1'b0;
    assign lcd_reset      = lcd_reset_done;
    assign lcd_blk        = 1'b1;

    assign tft_screen_flush_req = ( lcd_init_done == 1'b1) ? 1'b1 : 1'b0;
    assign spi_send_flush_ack   = ( lcd_init_done == 1'b1) ? spi_send_ack : 1'b0;

    // 复位完成后才开始初始化
    assign tft_screen_init_req  = ( lcd_reset_done == 1'b1 ) ? ~lcd_init_done : 1'b0;
    assign spi_send_init_ack    = ( lcd_init_done == 1'b0) ? spi_send_ack : 1'b0;

    //像素初始化完成之后进入显示数据刷新模式
    assign spi_start     = ( lcd_init_done == 1'b0) ? spi_send_init_req : spi_send_flush_req;
    assign spi_end       = ( lcd_init_done == 1'b0) ? spi_send_init_end : spi_send_flush_end;
    assign spi_send_data = ( lcd_init_done == 1'b0) ? tft_screen_init_data : tft_screen_flush_data;
    assign lcd_dc_i      = ( lcd_init_done == 1'b0) ? tft_screen_init_dc : tft_screen_flush_dc;

// 把 init/flush 的大组合 mux 先打一拍再送 SPI 驱动（数据在 start 前早已稳定）
    always @(posedge sys_clk) begin
        if (!sys_rst_n) begin
            spi_send_data_r <= 8'd0;
            lcd_dc_r        <= 1'b1;
        end
        else begin
            spi_send_data_r <= spi_send_data;
            lcd_dc_r        <= lcd_dc_i;
        end
    end

//初始化是否完成
always@(posedge sys_clk or negedge sys_rst_n) begin
    if( sys_rst_n == 1'b0)
        lcd_init_done <= 1'b0;
    else if( tft_screen_init_ack == 1'b1)
        lcd_init_done <= 1'b1;
    else
        lcd_init_done <= lcd_init_done;
end

//刷新模块
spi_tft_screen_flush #(
    .SCREEN_WIDTH                       (SCREEN_WIDTH              ),
    .SCREEN_HEIGHT                      (SCREEN_HEIGHT             ),
    .Number_Of_Pixels                   (SCREEN_WIDTH*SCREEN_HEIGHT*'d2)
)spi_tft_screen_flush_inst(
    .sys_clk                            (sys_clk                   ),
    .sys_rst_n                          (sys_rst_n                 ),

     //用户接口
    .spi_screen_flush_data_i            (spi_screen_flush_data_i   ),
    .spi_screen_flush_updte_o           (spi_screen_flush_updte_o  ),
    .spi_screen_flush_fsync_o           (spi_screen_flush_fsync_o  ),

    .tft_screen_flush_req_i             (tft_screen_flush_req      ),
    .tft_screen_flush_data_o            (tft_screen_flush_data     ),
    .tft_screen_flush_dc_o              (tft_screen_flush_dc       ),

    .spi_send_flush_req_o               (spi_send_flush_req        ),
    .spi_send_flush_end_o               (spi_send_flush_end        ),
    .spi_send_flush_ack_i               (spi_send_flush_ack        )
);

//初始化模块
spi_tft_screen_init #(
    .SCREEN_WIDTH                       (SCREEN_WIDTH              ),
    .SCREEN_HEIGHT                      (SCREEN_HEIGHT             )
) spi_tft_screen_init_inst(
    .sys_clk                            (sys_clk                   ),
    .sys_rst_n                          (sys_rst_n                 ),

    .tft_screen_init_req_i              (tft_screen_init_req       ),
    .tft_screen_init_ack_o              (tft_screen_init_ack       ),
    .tft_screen_init_data_o             (tft_screen_init_data      ),
    .tft_screen_init_dc_o               (tft_screen_init_dc        ),

    .spi_send_init_req_o                (spi_send_init_req         ),
    .spi_send_init_end_o                (spi_send_init_end         ),
    .spi_send_init_ack_i                (spi_send_init_ack         )
);

//spi主机驱动模块
spi_master_driver spi_master_driver_inst(
    .sys_clk                            (sys_clk                   ),
    .sys_rst_n                          (sys_rst_n                 ),

    .spi_start_i                        (spi_start                 ),
    .spi_end_i                          (spi_end                   ),
    .spi_send_data_i                    (spi_send_data_r           ),
    .spi_send_ack_o                     (spi_send_ack              ),

    .lcd_dc_i                           (lcd_dc_r                  ),
    .lcd_dc                             (lcd_dc                    ),

    .spi_sclk                           (lcd_spi_sclk              ),
    .spi_mosi                           (lcd_spi_mosi              ),
    .spi_cs                             (lcd_spi_cs                )
);

endmodule