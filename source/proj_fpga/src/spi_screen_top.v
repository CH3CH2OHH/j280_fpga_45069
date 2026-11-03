  `timescale 1ns / 1ps

  //整个spi屏幕控制顶层，用户只需要提供显示数据就可以使用这个顶层进行spi屏幕显示
  module spi_screen_top(
      input                               sys_clk                    ,
      input                               sys_rst_n                  ,

      //用户信号
      output                              flush_data_update_o        ,//更新当前坐标点显示数据使能
      input              [  15: 0]        flush_data_i               ,//当前坐标点显示的数据
      output             [  15: 0]        flush_addr_width_o         ,//当前刷新的x坐标
      output             [  15: 0]        flush_addr_height_o        ,//当前刷新的y坐标

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

  //屏幕用户接口
      wire               [   7: 0]        spi_screen_flush_data      ;
      wire                                spi_screen_flush_updte     ;
      wire                                spi_screen_flush_fsync     ;

  //长宽计数器
      reg                [  15: 0]        width_cnt                  ;
      reg                [  15: 0]        height_cnt                 ;

  //数据更新
      reg                                 data_update_cnt            ;

  //更新数据寄存器
      reg                [  15: 0]        flush_data_reg             ;
  //更新数据使能寄存器
      reg                                 flush_updte_en;

      assign  spi_screen_flush_data     = flush_data_reg[15:8];//高位发送

      //当发送完16bit的图像数据时，坐标点显示数据使能拉高
      assign  flush_data_update_o = (spi_screen_flush_updte == 1'b1 && data_update_cnt == 1'b0 && flush_updte_en ==
  1'b1) ? 1'b1 : 1'b0;

      //将长宽计数器连接到输出
      assign  flush_addr_width_o        = width_cnt;
      assign  flush_addr_height_o       = height_cnt;

  //1.flush_updte_en,发完8位就拉高，发完一帧清0
  always@(posedge sys_clk or negedge sys_rst_n) begin
      if( sys_rst_n == 1'b0)
          flush_updte_en <= 'd0;
      else if( spi_screen_flush_fsync == 1'b1 )
          flush_updte_en <= 'd0;
      else if( spi_screen_flush_updte == 1'b1)
          flush_updte_en <= 'd1;
      else
          flush_updte_en <= flush_updte_en;
  end

  //2.data_update_cnt，发送高八位时data_update_cnt=1，发送低八位时data_update_cnt=0
  always@(posedge sys_clk or negedge sys_rst_n) begin
      if( sys_rst_n == 1'b0)
          data_update_cnt <= 'd0;
      else if( spi_screen_flush_fsync == 1'b1 )
          data_update_cnt <= 'd0;
      else if( spi_screen_flush_updte == 1'b1)
          data_update_cnt <= data_update_cnt + 1'b1;
      else
          data_update_cnt <= data_update_cnt;
  end

  //3.flush_data_reg，
  always@(posedge sys_clk or negedge sys_rst_n) begin
      if( sys_rst_n == 1'b0)
          flush_data_reg <= 'd0;
      else if( spi_screen_flush_updte == 1'b1)
          if( data_update_cnt == 1'b0 )
              flush_data_reg <= flush_data_i;
          else
              flush_data_reg <= flush_data_reg << 8;
      else
          flush_data_reg <= flush_data_reg;
  end

  //一帧图像刷洗完之后，开始横着加一写像素点
  always@(posedge sys_clk or negedge sys_rst_n) begin
      if( sys_rst_n == 1'b0 )
          width_cnt <= 'd0;
      else if( spi_screen_flush_fsync == 1'b1 )
          width_cnt <= 'd0;
      else if( flush_data_update_o)
          if( width_cnt == (SCREEN_WIDTH-1))
              width_cnt <= 'd0;
          else
              width_cnt <= width_cnt + 1'b1;
      else
          width_cnt <= width_cnt;
  end

  //一行写满后然后换一行写
  always@(posedge sys_clk or negedge sys_rst_n) begin
      if( sys_rst_n == 1'b0 )
          height_cnt <= 'd0;
      else if( spi_screen_flush_fsync == 1'b1)
          height_cnt <= 'd0;
      else if( width_cnt == (SCREEN_WIDTH-1) && flush_data_update_o)
          if( height_cnt == (SCREEN_HEIGHT-1))
              height_cnt <= 'd0;
          else
              height_cnt <= height_cnt + 1'b1;
      else
          height_cnt <= height_cnt;
  end

  spi_tft_screen_driver spi_tft_screen_driver_inst(
      .sys_clk                            (sys_clk                   ),
      .sys_rst_n                          (sys_rst_n                 ),

      //用户接口
      .spi_screen_flush_data_i            (spi_screen_flush_data     ),
      .spi_screen_flush_updte_o           (spi_screen_flush_updte    ),
      .spi_screen_flush_fsync_o           (spi_screen_flush_fsync    ),

       //spi tft screen   屏幕接口
      .lcd_spi_sclk                       (lcd_spi_sclk              ),
      .lcd_spi_mosi                       (lcd_spi_mosi              ),
      .lcd_spi_cs                         (lcd_spi_cs                ),
      .lcd_dc                             (lcd_dc                    ),
      .lcd_reset                          (lcd_reset                 ),
      .lcd_blk                            (lcd_blk                   )
  );
  endmodule