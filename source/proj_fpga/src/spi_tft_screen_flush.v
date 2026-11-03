  `timescale 1ns / 1ps

  //对spi tft屏幕进行刷新
  module spi_tft_screen_flush(
      input                               sys_clk                    ,
      input                               sys_rst_n                  ,

      //用户接口
      input              [   7: 0]        spi_screen_flush_data_i    ,//屏幕显示数据
      output                              spi_screen_flush_updte_o   ,//像素点数据刷新
      output                              spi_screen_flush_fsync_o   ,//屏幕帧同步

      //驱动模块
      input                               tft_screen_flush_req_i
  ,//刷新请求//初始化完成之后此信号拉高模块进入刷新模式
      output reg         [   7: 0]        tft_screen_flush_data_o
  ,//刷新数据//刷新的图像数据和刷新命令通过spi模块发送
      output reg                          tft_screen_flush_dc_o      ,//刷新dc//区分命令与数据

      //SPI主模块
      output                              spi_send_flush_req_o       ,//spi发送数据请求
      output                              spi_send_flush_end_o       ,//结束spi发送
      input                               spi_send_flush_ack_i        //spi一个数据发送完成
  );

      parameter                           SCREEN_WIDTH              = 16'd128;
      parameter                           SCREEN_HEIGHT             = 16'd160;
      parameter                           Number_Of_Pixels          = 32'd128*32'd160*32'd2; // 像素点字节数

      // 偏移量与初始化模块保持一致(0,0)
      localparam                          COL_OFFSET                = 16'd0;
      localparam                          ROW_OFFSET                = 16'd0;
      localparam                          COL_END                   = COL_OFFSET + SCREEN_WIDTH  - 16'd1;
      localparam                          ROW_END                   = ROW_OFFSET + SCREEN_HEIGHT - 16'd1;

      localparam                          S_IDLE                    = 4'b0001;
      localparam                          S_DATA                    = 4'b0010;  //发送数据
      localparam                          S_DELAY                   = 4'b0100;  //延时
      localparam                          S_FRAME_SYNC              = 4'b1000;  //帧同步

      localparam                          DELAY_5clk                = 'd5;       //命令与数据之间切换等待5个时钟周期

      reg                [  31: 0]        flush_cnt                  ;        //刷新模块写命令/数据计数器
      reg                [  12: 0]        delay_cnt                  ;        //延迟计数
      reg                [   3: 0]        state           ,next_state;        //状态寄存器

      //为写数据状态时，请求拉高
      assign                              spi_send_flush_req_o      = (state == S_DATA) ? 1'b1 : 1'b0;
      //为延迟状态或帧同步状态时结束信号拉高
      assign                              spi_send_flush_end_o      = (state == S_DELAY || state == S_FRAME_SYNC) ? 1'b1
  : 1'b0;

      //当发送完数据时，且写命令/数据计数器计数到10时，像素点数据刷新拉高
      assign                              spi_screen_flush_updte_o  = ( spi_send_flush_ack_i == 1'b1 && flush_cnt >=
  'd10 ) ? 1'b1 : 1'b0;
      //为帧同步状态时，屏幕帧同步拉高，产生帧同步信号
      assign                              spi_screen_flush_fsync_o  = ( state == S_FRAME_SYNC ) ? 1'b1 : 1'b0;

  always@(posedge sys_clk or negedge sys_rst_n) begin
      if( sys_rst_n == 1'b0 )
          state <= S_IDLE;
      else
          state <= next_state;
  end

  always@(*) begin
      case(state)
      S_IDLE:
          if( tft_screen_flush_req_i == 1'b1 )
              next_state = S_DATA;
          else
              next_state = S_IDLE;
      S_DATA:
          if( spi_send_flush_ack_i == 1'b1 && flush_cnt <= 'd10 )
              next_state = S_DELAY;
          else if( spi_send_flush_ack_i == 1'b1 && flush_cnt == (Number_Of_Pixels + 'd10))
              next_state = S_FRAME_SYNC;
          else
              next_state = S_DATA;
      S_DELAY:
          if( delay_cnt == DELAY_5clk)
              next_state = S_DATA;
          else
              next_state = S_DELAY;
      S_FRAME_SYNC:
          next_state = S_IDLE;
      default: next_state = S_IDLE;
      endcase
  end

  //发送数据计数
  always@(posedge sys_clk or negedge sys_rst_n) begin
      if( sys_rst_n == 1'b0 )
          flush_cnt <= 'd0;
      else if( spi_send_flush_ack_i == 1'b1 && flush_cnt == (Number_Of_Pixels + 'd10))
          flush_cnt <= 'd0;
      else if( spi_send_flush_ack_i == 1'b1 )
          flush_cnt <= flush_cnt + 1'b1;
      else
          flush_cnt <= flush_cnt;
  end

  //延时计数
  always@(posedge sys_clk or negedge sys_rst_n) begin
      if( sys_rst_n == 1'b0)
          delay_cnt <= 'd0;
      else if( state == S_DELAY)
          delay_cnt <= delay_cnt + 1'b1;
      else
          delay_cnt <= 'd0;
  end

  //tft_screen_flush_dc_o=0时写命令
  //tft_screen_flush_dc_o=1时写数据
  always @(*) begin
      case (flush_cnt)
          // 前 11 个（发"设置窗口"命令），写区域等参数
          'd0:  begin tft_screen_flush_data_o = 8'h2A;                tft_screen_flush_dc_o = 1'b0; end // CASET
          'd1:  begin tft_screen_flush_data_o = COL_OFFSET[15:8];     tft_screen_flush_dc_o = 1'b1; end // 列起始高8
          'd2:  begin tft_screen_flush_data_o = COL_OFFSET[7:0];      tft_screen_flush_dc_o = 1'b1; end // 列起始低8
          'd3:  begin tft_screen_flush_data_o = COL_END[15:8];        tft_screen_flush_dc_o = 1'b1; end // 列结束高8
          'd4:  begin tft_screen_flush_data_o = COL_END[7:0];         tft_screen_flush_dc_o = 1'b1; end // 列结束低8
          'd5:  begin tft_screen_flush_data_o = 8'h2B;                tft_screen_flush_dc_o = 1'b0; end // RASET
          'd6:  begin tft_screen_flush_data_o = ROW_OFFSET[15:8];     tft_screen_flush_dc_o = 1'b1; end // 行起始高8
          'd7:  begin tft_screen_flush_data_o = ROW_OFFSET[7:0];      tft_screen_flush_dc_o = 1'b1; end // 行起始低8
          'd8:  begin tft_screen_flush_data_o = ROW_END[15:8];        tft_screen_flush_dc_o = 1'b1; end // 行结束高8
          'd9:  begin tft_screen_flush_data_o = ROW_END[7:0];         tft_screen_flush_dc_o = 1'b1; end // 行结束低8
          'd10: begin tft_screen_flush_data_o = 8'h2C;                tft_screen_flush_dc_o = 1'b0; end // RAMWR 写像素

          // 第 11 个以后：发像素字节
          default: begin
              tft_screen_flush_data_o = spi_screen_flush_data_i;
              tft_screen_flush_dc_o   = 1'b1;
          end
      endcase
  end

  endmodule