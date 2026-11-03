  `timescale 1ns / 1ps

  //对spi tft屏幕进行初始化，I表示主机发给屏幕，o反之
  module spi_tft_screen_init(
      input                               sys_clk                    ,
      input                               sys_rst_n                  ,

      input                               tft_screen_init_req_i      ,//初始化请求
      output                              tft_screen_init_ack_o      ,//初始化完成
      output reg         [   7: 0]        tft_screen_init_data_o     ,//初始化数据
      output reg                          tft_screen_init_dc_o       ,//初始化dc，这个字节是命令(0)还是数据(1)

      output                              spi_send_init_req_o        ,//spi发送数据请求
      output                              spi_send_init_end_o        ,//结束spi发送
      input                               spi_send_init_ack_i         //spi一个数据发送完成
  );

      parameter                           SCREEN_WIDTH              = 16'd128;
      parameter                           SCREEN_HEIGHT             = 16'd160;

      // 屏幕偏移量：先试(0,0)，若左/顶花屏则试(2,1)/(1,1)等
      localparam                          COL_OFFSET                = 16'd0;
      localparam                          ROW_OFFSET                = 16'd0;
      localparam                          COL_END                   = COL_OFFSET + SCREEN_WIDTH  - 16'd1; // 129
      localparam                          ROW_END                   = ROW_OFFSET + SCREEN_HEIGHT - 16'd1; // 160

      localparam                          INIT_TOTAL                = 'd87;    // 初始化共 87 个字节(0~86)

      // 延时：sys_clk = 50MHz，1 个时钟 = 20ns
      localparam                          DELAY_120ms               = 32'd6_000_000;   // 复位后延时
      localparam                          DELAY_500ms               = 32'd25_000_000;  // 唤醒后延时
      localparam                          DELAY_10ms                = 32'd500_000;     // 正常显示模式延时
      localparam                          DELAY_100ms               = 32'd5_000_000;   // 开显示延时
      localparam                          DELAY_200us               = 32'd10_000;      // 命令之间的短延时

      localparam                          S_IDLE                    = 4'b0001;//初始状态：空闲
      localparam                          S_SEND_DATA               = 4'b0010;//发送数据状态
      localparam                          S_DELAY                   = 4'b0100;//延迟状态，发完一个数据之间等待的状态
      localparam                          S_ACK                     = 4'b1000;//响应状态，全部发完

      reg                [   7: 0]        init_cnt                   ;//初始化命令/数据计数  0~86
      reg                [  31: 0]        delay_cnt                  ;//延时计数
      reg                [   3: 0]        state                      ;//状态寄存器
      reg                [   3: 0]        next_state                 ;//下一状态寄存器

      //为响应状态时，初始化完成信号拉高
      assign                              tft_screen_init_ack_o     = (state == S_ACK) ? 1'b1 : 1'b0;
      //为发送数据状态时，spi发送数据请求信号拉高
      assign                              spi_send_init_req_o       = (state == S_SEND_DATA) ? 1'b1 : 1'b0;
      //为延迟状态时，结束spi发送
      assign                              spi_send_init_end_o       = (state == S_DELAY) ? 1'b1 : 1'b0;

  always@(posedge sys_clk or negedge sys_rst_n) begin
      if( sys_rst_n == 1'b0)
          state <= S_IDLE;
      else
          state <= next_state;
  end

  always@(*) begin
      case(state)
      S_IDLE:
          if( tft_screen_init_req_i == 1'b1)//初始化请求有效时，跳转到发送数据状态
              next_state <= S_SEND_DATA;
          else
              next_state <= S_IDLE;
      S_SEND_DATA:
          if( spi_send_init_ack_i == 1'b1)//spi一个数据发送完成，跳转到延迟状态
              next_state <= S_DELAY;
          else
              next_state <= S_SEND_DATA;
      S_DELAY:
          if( init_cnt == INIT_TOTAL )//发完最后一个字节 DISPON，延时后进响应状态
              if( delay_cnt == DELAY_100ms)
                  next_state <= S_ACK;
              else
                  next_state <= S_DELAY;
          else if( init_cnt == 'd1 )//发完 SWRESET，延时 120ms
              if( delay_cnt == DELAY_120ms)
                  next_state <= S_SEND_DATA;
              else
                  next_state <= S_DELAY;
          else if( init_cnt == 'd2 )//发完 SLPOUT，延时 500ms
              if( delay_cnt == DELAY_500ms)
                  next_state <= S_SEND_DATA;
              else
                  next_state <= S_DELAY;
          else if( init_cnt == 'd86 )//发完 NORON，延时 10ms
              if( delay_cnt == DELAY_10ms)
                  next_state <= S_SEND_DATA;
              else
                  next_state <= S_DELAY;
          else if( delay_cnt == DELAY_200us)//其它命令之间短延时
              next_state <= S_SEND_DATA;
          else
              next_state <= S_DELAY;
      S_ACK:
          next_state <= S_IDLE;
      default: next_state <= S_IDLE;
      endcase
  end

  //初始化数据计数
  always@(posedge sys_clk or negedge sys_rst_n) begin
      if( sys_rst_n == 1'b0)
          init_cnt <= 'd0;
      else if( spi_send_init_ack_i == 1'b1)//spi一个数据发送完成，init_cnt加1
          init_cnt <= init_cnt + 1'b1;
      else
          init_cnt <= init_cnt;
  end

  //延时计数//写命令之间需要间隔的时间
  always@(posedge sys_clk or negedge sys_rst_n) begin
      if( sys_rst_n == 1'b0)
          delay_cnt <= 'd0;
      else if( state == S_DELAY)           //为延迟状态时，delay_cnt加1
          delay_cnt <= delay_cnt + 1'b1;
      else
          delay_cnt <= 'd0;
  end

  //命令数据输出
  //0命令，1数据
  always@(*)begin
      case (init_cnt)
          'd0:  begin tft_screen_init_data_o = 8'h01; tft_screen_init_dc_o = 1'b0; end // SWRESET 软复位
          'd1:  begin tft_screen_init_data_o = 8'h11; tft_screen_init_dc_o = 1'b0; end // SLPOUT  唤醒
          'd2:  begin tft_screen_init_data_o = 8'hB1; tft_screen_init_dc_o = 1'b0; end // FRMCTR1 帧率控制
          'd3:  begin tft_screen_init_data_o = 8'h01; tft_screen_init_dc_o = 1'b1; end
          'd4:  begin tft_screen_init_data_o = 8'h2C; tft_screen_init_dc_o = 1'b1; end
          'd5:  begin tft_screen_init_data_o = 8'h2D; tft_screen_init_dc_o = 1'b1; end
          'd6:  begin tft_screen_init_data_o = 8'hB2; tft_screen_init_dc_o = 1'b0; end // FRMCTR2
          'd7:  begin tft_screen_init_data_o = 8'h01; tft_screen_init_dc_o = 1'b1; end
          'd8:  begin tft_screen_init_data_o = 8'h2C; tft_screen_init_dc_o = 1'b1; end
          'd9:  begin tft_screen_init_data_o = 8'h2D; tft_screen_init_dc_o = 1'b1; end
          'd10: begin tft_screen_init_data_o = 8'hB3; tft_screen_init_dc_o = 1'b0; end // FRMCTR3
          'd11: begin tft_screen_init_data_o = 8'h01; tft_screen_init_dc_o = 1'b1; end
          'd12: begin tft_screen_init_data_o = 8'h2C; tft_screen_init_dc_o = 1'b1; end
          'd13: begin tft_screen_init_data_o = 8'h2D; tft_screen_init_dc_o = 1'b1; end
          'd14: begin tft_screen_init_data_o = 8'h01; tft_screen_init_dc_o = 1'b1; end
          'd15: begin tft_screen_init_data_o = 8'h2C; tft_screen_init_dc_o = 1'b1; end
          'd16: begin tft_screen_init_data_o = 8'h2D; tft_screen_init_dc_o = 1'b1; end
          'd17: begin tft_screen_init_data_o = 8'hB4; tft_screen_init_dc_o = 1'b0; end // INVCTR 反色控制
          'd18: begin tft_screen_init_data_o = 8'h07; tft_screen_init_dc_o = 1'b1; end
          'd19: begin tft_screen_init_data_o = 8'hC0; tft_screen_init_dc_o = 1'b0; end // PWCTR1 电源控制
          'd20: begin tft_screen_init_data_o = 8'hA2; tft_screen_init_dc_o = 1'b1; end
          'd21: begin tft_screen_init_data_o = 8'h02; tft_screen_init_dc_o = 1'b1; end
          'd22: begin tft_screen_init_data_o = 8'h84; tft_screen_init_dc_o = 1'b1; end
          'd23: begin tft_screen_init_data_o = 8'hC1; tft_screen_init_dc_o = 1'b0; end // PWCTR2
          'd24: begin tft_screen_init_data_o = 8'hC5; tft_screen_init_dc_o = 1'b1; end
          'd25: begin tft_screen_init_data_o = 8'hC2; tft_screen_init_dc_o = 1'b0; end // PWCTR3
          'd26: begin tft_screen_init_data_o = 8'h0A; tft_screen_init_dc_o = 1'b1; end
          'd27: begin tft_screen_init_data_o = 8'h00; tft_screen_init_dc_o = 1'b1; end
          'd28: begin tft_screen_init_data_o = 8'hC3; tft_screen_init_dc_o = 1'b0; end // PWCTR4
          'd29: begin tft_screen_init_data_o = 8'h8A; tft_screen_init_dc_o = 1'b1; end
          'd30: begin tft_screen_init_data_o = 8'h2A; tft_screen_init_dc_o = 1'b1; end
          'd31: begin tft_screen_init_data_o = 8'hC4; tft_screen_init_dc_o = 1'b0; end // PWCTR5
          'd32: begin tft_screen_init_data_o = 8'h8A; tft_screen_init_dc_o = 1'b1; end
          'd33: begin tft_screen_init_data_o = 8'hEE; tft_screen_init_dc_o = 1'b1; end
          'd34: begin tft_screen_init_data_o = 8'hC5; tft_screen_init_dc_o = 1'b0; end // VMCTR1 VCOM控制
          'd35: begin tft_screen_init_data_o = 8'h0E; tft_screen_init_dc_o = 1'b1; end
          'd36: begin tft_screen_init_data_o = 8'h20; tft_screen_init_dc_o = 1'b0; end // INVOFF 关闭反色
          'd37: begin tft_screen_init_data_o = 8'h36; tft_screen_init_dc_o = 1'b0; end // MADCTL 扫描方向
          'd38: begin tft_screen_init_data_o = 8'hC8; tft_screen_init_dc_o = 1'b1; end // 竖屏 RGB
          'd39: begin tft_screen_init_data_o = 8'h3A; tft_screen_init_dc_o = 1'b0; end // COLMOD 像素格式
          'd40: begin tft_screen_init_data_o = 8'h05; tft_screen_init_dc_o = 1'b1; end // 16bit RGB565
          'd41: begin tft_screen_init_data_o = 8'h2A; tft_screen_init_dc_o = 1'b0; end // CASET 列地址设置
          'd42: begin tft_screen_init_data_o = COL_OFFSET[15:8]; tft_screen_init_dc_o = 1'b1; end // 列起始高8
          'd43: begin tft_screen_init_data_o = COL_OFFSET[7:0];  tft_screen_init_dc_o = 1'b1; end // 列起始低8 = 2
          'd44: begin tft_screen_init_data_o = COL_END[15:8];    tft_screen_init_dc_o = 1'b1; end // 列结束高8
          'd45: begin tft_screen_init_data_o = COL_END[7:0];     tft_screen_init_dc_o = 1'b1; end // 列结束低8 = 129
          'd46: begin tft_screen_init_data_o = 8'h2B; tft_screen_init_dc_o = 1'b0; end // RASET 行地址设置
          'd47: begin tft_screen_init_data_o = ROW_OFFSET[15:8]; tft_screen_init_dc_o = 1'b1; end // 行起始高8
          'd48: begin tft_screen_init_data_o = ROW_OFFSET[7:0];  tft_screen_init_dc_o = 1'b1; end // 行起始低8 = 1
          'd49: begin tft_screen_init_data_o = ROW_END[15:8];    tft_screen_init_dc_o = 1'b1; end // 行结束高8
          'd50: begin tft_screen_init_data_o = ROW_END[7:0];     tft_screen_init_dc_o = 1'b1; end // 行结束低8 = 160
          'd51: begin tft_screen_init_data_o = 8'hE0; tft_screen_init_dc_o = 1'b0; end // GMCTRP1 正伽马
          'd52: begin tft_screen_init_data_o = 8'h02; tft_screen_init_dc_o = 1'b1; end
          'd53: begin tft_screen_init_data_o = 8'h1C; tft_screen_init_dc_o = 1'b1; end
          'd54: begin tft_screen_init_data_o = 8'h07; tft_screen_init_dc_o = 1'b1; end
          'd55: begin tft_screen_init_data_o = 8'h12; tft_screen_init_dc_o = 1'b1; end
          'd56: begin tft_screen_init_data_o = 8'h37; tft_screen_init_dc_o = 1'b1; end
          'd57: begin tft_screen_init_data_o = 8'h32; tft_screen_init_dc_o = 1'b1; end
          'd58: begin tft_screen_init_data_o = 8'h29; tft_screen_init_dc_o = 1'b1; end
          'd59: begin tft_screen_init_data_o = 8'h2D; tft_screen_init_dc_o = 1'b1; end
          'd60: begin tft_screen_init_data_o = 8'h29; tft_screen_init_dc_o = 1'b1; end
          'd61: begin tft_screen_init_data_o = 8'h25; tft_screen_init_dc_o = 1'b1; end
          'd62: begin tft_screen_init_data_o = 8'h2B; tft_screen_init_dc_o = 1'b1; end
          'd63: begin tft_screen_init_data_o = 8'h39; tft_screen_init_dc_o = 1'b1; end
          'd64: begin tft_screen_init_data_o = 8'h00; tft_screen_init_dc_o = 1'b1; end
          'd65: begin tft_screen_init_data_o = 8'h01; tft_screen_init_dc_o = 1'b1; end
          'd66: begin tft_screen_init_data_o = 8'h03; tft_screen_init_dc_o = 1'b1; end
          'd67: begin tft_screen_init_data_o = 8'h10; tft_screen_init_dc_o = 1'b1; end
          'd68: begin tft_screen_init_data_o = 8'hE1; tft_screen_init_dc_o = 1'b0; end // GMCTRN1 负伽马
          'd69: begin tft_screen_init_data_o = 8'h03; tft_screen_init_dc_o = 1'b1; end
          'd70: begin tft_screen_init_data_o = 8'h1D; tft_screen_init_dc_o = 1'b1; end
          'd71: begin tft_screen_init_data_o = 8'h07; tft_screen_init_dc_o = 1'b1; end
          'd72: begin tft_screen_init_data_o = 8'h06; tft_screen_init_dc_o = 1'b1; end
          'd73: begin tft_screen_init_data_o = 8'h2E; tft_screen_init_dc_o = 1'b1; end
          'd74: begin tft_screen_init_data_o = 8'h2C; tft_screen_init_dc_o = 1'b1; end
          'd75: begin tft_screen_init_data_o = 8'h29; tft_screen_init_dc_o = 1'b1; end
          'd76: begin tft_screen_init_data_o = 8'h2D; tft_screen_init_dc_o = 1'b1; end
          'd77: begin tft_screen_init_data_o = 8'h2E; tft_screen_init_dc_o = 1'b1; end
          'd78: begin tft_screen_init_data_o = 8'h2E; tft_screen_init_dc_o = 1'b1; end
          'd79: begin tft_screen_init_data_o = 8'h37; tft_screen_init_dc_o = 1'b1; end
          'd80: begin tft_screen_init_data_o = 8'h3F; tft_screen_init_dc_o = 1'b1; end
          'd81: begin tft_screen_init_data_o = 8'h00; tft_screen_init_dc_o = 1'b1; end
          'd82: begin tft_screen_init_data_o = 8'h00; tft_screen_init_dc_o = 1'b1; end
          'd83: begin tft_screen_init_data_o = 8'h02; tft_screen_init_dc_o = 1'b1; end
          'd84: begin tft_screen_init_data_o = 8'h10; tft_screen_init_dc_o = 1'b1; end
          'd85: begin tft_screen_init_data_o = 8'h13; tft_screen_init_dc_o = 1'b0; end // NORON 正常显示模式
          'd86: begin tft_screen_init_data_o = 8'h29; tft_screen_init_dc_o = 1'b0; end // DISPON 开显示
          default: begin
              tft_screen_init_data_o  = 8'h01;
              tft_screen_init_dc_o    = 1'b0;
          end
      endcase
  end

  endmodule