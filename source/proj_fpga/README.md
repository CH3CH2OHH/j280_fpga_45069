# J280 旋转倒立摆 FPGA 工程

包含：

- `src/`：Gowin GW2A-55 FPGA 源码（1 kHz 控制、编码器/ADC、TB6612、SPI 屏 UI、遥测）；
- `.fast_gui_tk/`：上位机 GUI（串口参数、遥测曲线、MODE0~3）；
- `project.gprj`：Gowin 工程文件；
- `docs/`：硬件、模式、屏幕、构建和上电说明；参数 ID/范围、串口帧、遥测格式和 GUI 通信约定。


注意：H1 的 1/3/5 脚为 5 V，严禁接 H5/FPGA 信号；首次上电先小 `LIM`，准备实体急停。
