# J280 上位机控制系统（ui_project_qt）

`project/gui/j280_debug_gui.py`（Tk）的 HTML 重构版：PySide6 / QWebEngine 无边框桌面外壳 +
科技风 HTML 界面；串口、文件对话框、状态持久化全部由 Python 后端通过 QWebChannel 提供。

当前适配固件：**BUILD60 / 遥测 Vy（103B）**；唯一默认配置：`data/config0.json`（39 项，与 FPGA 上电默认一致）。

![主界面](docs/screenshot-main.png)

## 1. 环境准备与启动

> **源码分发包不携带虚拟环境**：没有 `run.bat`，也不包含 `.venv/`、`.qtcreator/`。
> 拿到源码后请按本节创建环境。首次安装依赖需要网络，PySide6/QtWebEngine 约需 1–2 GB 磁盘。

### 1.1 系统要求

- Windows 10/11 x64；
- Python **3.11 x64**（实测 3.11.9；3.10–3.12 可用）；
- 建议 8 GB 内存；QtWebEngine 需要可用的显卡驱动或软件 OpenGL。

### 1.2 创建虚拟环境

在 `cmd.exe` 中：

```bat
cd ui_project_qt
py -3.11 -m venv .venv
.venv\Scripts\activate
python -m pip install -U pip
python -m pip install -r requirements.txt
```

在 PowerShell 中：

```powershell
cd ui_project_qt
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -U pip
python -m pip install -r requirements.txt
```

如果 PowerShell 提示禁止运行脚本，可仅对当前窗口放开：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

没有 `py` 启动器时可用 `python -m venv .venv`，但必须使用 **Python 3.11 x64**。

### 1.3 启动

```bat
cd ui_project_qt
.venv\Scripts\activate
python main.py
```

不要直接双击 `main.py`，也不要把虚拟环境目录拷进源码包；`python` 必须来自刚创建的 `.venv`。
无串口硬件时界面仍可正常打开。

### 1.4 打包环境（可选）

```bat
.venv\Scripts\activate
python -m pip install -r requirements-build.txt
powershell -ExecutionPolicy Bypass -File build_exe.ps1
```

`build_exe.ps1` 会自动优先使用 `.venv\Scripts\python.exe`；也可显式指定：

```powershell
powershell -ExecutionPolicy Bypass -File build_exe.ps1 -Python "C:\Python311\python.exe"
```

## 2. 当前 UI 要点

### 2.1 左侧书签与参数卡片

- 启动时**所有参数组卡片默认隐藏**；左侧书签栏顺序为：角度 PID、编码器位置外环、
  接管/保护/PWM、标定与滤波、容差保持、自动起摆（6 组）。
- 书签默认是窄标签（序号 + 组简称）；**鼠标悬停时向右弹出**，显示完整组名/参数数，
  带扫光、发光箭头与边框光效；点击后书签保持展开、呼吸发光，对应卡片显示，再点隐藏。
- 书签栏顶部小标题为 **“调整参数”**。
- 书签栏下方有分隔线 `TOOL` 与 **琥珀色“轨迹”特殊书签**，用于显示/隐藏
  「指定运动轨迹」卡片；与青色参数组书签区分。
- 参数卡片仍可拖动、折叠；位置/折叠状态保存在 `data/ui_state.json` 的 `cards` 字段。
- 已移除参数行的鼠标悬停说明框；卡片标题末尾不再显示“N 项”。

### 2.2 参数控件

- 一般参数：普通输入框 + ± 微调 + 发送；
- `POSTGT`：圆形单圈表盘（0 在顶部，可直接拖动/滚轮/方向键调相位），保留输入框与发送；
- `TURNS_POSTGT`：普通输入框（**无 ± 按钮**）+「设置」小按钮；
- 有界参数（PIDEAD/KDBLEND/HOLDPOS、LIM、DZ、SWLIM 等）：滑杆 + 输入框精调；
- DZW / SWDIR / VELMODE / ADCAVG / RATEMODE：下拉选择；
- `TURNS_POSTGT` 另有可拖动「指定运动轨迹」卡片：把绝对目标包装为 **x 圈 + y 相位**
  （1 圈 = 1040 count，y ∈ −520…+519），可拖拽圈数刻度/相位环，应用/应用并发送。
  该卡片隐藏 count/总角度换算式、快捷相位按钮和范围说明，保持简洁。

### 2.3 窗口 / 全屏

- 标题栏“o”：最大化/还原；最大化时内容边距置 0、屏蔽标题栏拖动；
- 顶部「进入全屏/退出全屏」或 F11 切换真全屏；全屏去边框、隐藏标题栏；
- Esc 退出全屏；「■ 停机」不再绑定 Esc。

## 3. 功能对照

| 功能 | 原 Tk 版 | HTML 版 |
|---|---|---|
| 串口 | pyserial 115200 8N1，20 ms 轮询 | 同（`bridge.py`，50 ms 批量上报） |
| 遥测 | 100 Hz 103B ASCII | 解析 ANG/RAW/POS/SPD/DUT/REF/M·B/SW/V，可选 ABS/SRC/HLD |
| 指标 | 顶部状态行 | 6 张 HUD 指标卡 + 3D 视口状态 HUD（MODE/接管/位置误差/ABS/SRC/HLD） |
| 3D | 无 | three.js 旋转倒立摆：摆臂（POS/SPD）+ 摆杆（ANG/REF）+ DUT 限幅/状态灯 |
| 曲线 | Tk Canvas | 5 路 Canvas：ANG/REF、POS/TGT、SPD、DUT、RAW；趋势/原始/叠加、暂停、锁Y、十字光标 |
| 分析 | 均值穿越 + 提示 | 同算法移植（`charts.js`） |
| 参数 | Notebook + 输入框 | 39 项、6 组可拖动卡片，默认隐藏，左侧书签切换；POSTGT 表盘、TURNS 轨迹卡片 |
| 默认参数 | 旧参数组 | **`data/config0.json`** 唯一配置 |
| JSON | QFileDialog | 同，逐项范围校验、载入不自动下发 |
| 状态 | Tk 状态文件 | `data/ui_state.json`：端口/曲线设置/卡片布局/轨迹卡片布局 |
| 记录 | Tk CSV | 59 列 CSV（20 遥测 + 39 `sent_*`），UTF-8-SIG |
| 事件 | Tk Text | 右侧事件日志（info/ok/warn/error） |

## 4. 固件协议

- 参数帧：`AA | IDX | VALUE_HI | VALUE_LO`（16 位二补码大端，无校验/无应答）；
- UART：115200 8N1；
- 参数 ID 与范围以 `j280_protocol.py` 为准（ID 4…54，含 MODE/TURNS_POSTGT/PIDEAD/
  KDBLEND/VELMODE/ADCAVG/RATEMODE/HOLDPOS）；
- MODE：0 停机 / 1 手动稳定 / 2 自动起摆 / 3 绝对定位（使用 TURNS_POSTGT，POSTGT 无效）；
- 遥测：`ANG=±dd.dd RAW=dddd POS=±ddddd SPD=±ddddd DUT=±ddddd REF=±ddddd M<mode>B<status>
  [SW=0/1] V<ver><count> [ABS=xxxxxxxx] [SRC=0/1] [HLD=0/1]`；
- 本地模式（SRC=1）下上位机参数帧被屏蔽，但 MODE=0 急停允许通过；
- 新参数按固件版本放行：PIDEAD/KDBLEND 需 t 起、VELMODE 需 v 起、ADCAVG 需 w 起、
  RATEMODE 需 x 起、HOLDPOS 需 y 起；当前 Vy 全部支持。

## 5. 目录

```
ui_project_qt/
├─ main.py                 启动入口
├─ mainWnd.py              QWebEngine 外壳 / QWebChannel / 全屏与最大化
├─ bridge.py               SerialBridge：串口/文件对话框/状态/config0
├─ j280_protocol.py        vendored 自 project/gui（BUILD60 同步）
├─ build_exe.ps1           PyInstaller 便携版打包脚本
├─ requirements.txt        运行依赖（PySide6 / pyserial）
├─ requirements-build.txt  打包依赖（含 PyInstaller）
├─ data/config0.json       唯一默认参数（39 项）
├─ data/ui_state.json      上次端口/曲线/卡片布局/轨迹卡片布局
├─ res/
│  ├─ main.html            DOM 骨架 + 指定运动轨迹卡片模板
│  ├─ css/style.css        科技风 HUD / 书签 / 卡片 / 弹层
│  ├─ vendor/three.min.js  three.js r149 UMD（本地）
│  └─ js/
│     ├─ params.js         参数元数据/校验/控件类型/绝对目标换算
│     ├─ cards.js          可拖动可折叠玻璃卡片
│     ├─ charts.js         5 路 Canvas + 摆动分析
│     ├─ model3d.js        旋转倒立摆模型
│     ├─ bridge.js         QWebChannel 封装 + 浏览器降级
│     └─ app.js            遥测/曲线/3D/卡片/书签/轨迹卡片/CSV/状态
├─ tests/
│  ├─ capture_qt.py        Qt 截图 + 13 项断言
│  ├─ protocol_test.py     Python 协议自测（42 项）
│  ├─ smoke_test.py        Qt 冒烟（默认参数/JSON/CSV/校验）
│  ├─ interaction_test.py  Qt 交互（46 项）
│  ├─ fullscreen_test.py   最大化/全屏（33 项）
│  └─ test_feed.js         100 Hz 测试遥测注入源
└─ docs/
   ├─ UI_PORT_SPEC.md      当前实现规范
   ├─ screenshot-main.png
   ├─ screenshot-bookmarks.png
   ├─ screenshot-abs-target.png
   └─ MANIFEST.sha256
```

## 6. 测试

以下命令在已激活 `.venv` 的终端执行：

```bat
python tests\capture_qt.py
python tests\protocol_test.py
python tests\smoke_test.py
python tests\interaction_test.py
python tests\fullscreen_test.py
```

测试隔离：`J280_UI_TEST_DIR` 重定向文件对话框；`J280_UI_STATE_PATH` 覆盖状态文件。
每个测试脚本启动时都会写入干净状态，避免污染交付的 `data/ui_state.json`。
当前结果：capture PASS（13）、protocol PASS（42/42）、smoke PASS、
interaction PASS（46/46）、fullscreen PASS（33/33）。

## 7. 上板注意

1. 串口 **115200 8N1**；方向/零点确认前不要请求 MODE 1/2/3；
2. 上电默认 MODE 0；「■ 停机」发 MODE 0，通信异常时必须使用实体急停；
3. 本地模式（SRC=1）需用板上 SW1 切回上位机模式后再调参；
4. 新参数需对应固件版本；当前 BUILD60/Vy 全部支持；
5. 首次上板建议从低 `LIM` 开始，并确认 `ZERO/TRIM/方向`；
6. 同一串口不能被旧 Tk GUI 与本界面同时占用。

## 8. 已知限制

- QWebEngine `file://` 加载，JS 全部经典 `<script>`；浏览器直接打开无法读取 config0；
- 每次启动参数固定取 `data/config0.json`，调参后如需保留请用“保存配置/载入配置”；
- 卡片默认隐藏，位置/折叠状态只持久化布局，不恢复可见性（每次启动保持书签未激活）；
- 遥测 100 Hz 只能观察 <50 Hz 现象；趋势显示不能判断原始峰值；
- 内存：显示缓冲 10000 帧、超限丢最早 2500 帧；记录缓冲 30000 帧，保存成功后释放；
- 无实体 FPGA：真实串口只验证协议/错误路径，首次上板按安全流程从低 `LIM`、MODE 0 开始。

## 9. 交付校验

`docs/MANIFEST.sha256` 记录交付文件与保留的旧 Tk 参考文件 sha256：

```powershell
cd D:\projectD\fpga\proj0
Get-Content ui_project_qt\docs\MANIFEST.sha256
```

## 10. Windows 便携版打包

先按 §1.2 创建 `.venv`，再安装打包依赖：

```bat
.venv\Scripts\activate
python -m pip install -r requirements-build.txt
```

使用 `build_exe.ps1`（PyInstaller 6，one-dir）打包：

```powershell
cd ui_project_qt
powershell -ExecutionPolicy Bypass -File build_exe.ps1
```

脚本自动查找 `.venv\Scripts\python.exe`；也可用 `-Python` 指定其他已安装
`PySide6 + PyInstaller` 的解释器。生成到 `ui_project_qt/output/`：

```text
output/
├─ J280上位机控制系统.exe
├─ runtime/                 Python / PySide6 / QtWebEngine 运行时（勿改名）
├─ res/                     HTML / CSS / JS / three.js（可整体替换）
├─ data/config0.json        默认参数（可编辑，与 FPGA 上电默认一致）
├─ data/ui_state.json       干净初始状态（删除可恢复默认布局）
└─ 启动说明.txt
```

- frozen 模式下 `globals.py` 以 exe 所在目录作为 `APP_DIR`，资源读 `res/`、数据读写 `data/`；
  `bridge.loadDefaults()` 读 exe 旁的 `data/config0.json`，状态写 `data/ui_state.json`；
- 应用图标：`res/icon.ico` 由 PyInstaller 嵌入 exe；`res/icon.png` 用于 Qt 窗口/任务栏图标；
  图案为蓝色光环 + 橙色霓虹竖条；
- 打包后可用无界面自检验证运行时：

```powershell
.\output\J280上位机控制系统.exe --selftest output\selftest.json --selftest-shot output\selftest.png
```

自检检查 `J280_APP.ready`、无 JS 错误、5 曲线、6 卡片、7 书签、默认隐藏卡片、
config0 默认参数；返回码 0/1，并写出 JSON 与截图。

## 11. 源码分发包说明

建议分发的源码压缩包只包含：

```text
ui_project_qt/
├─ *.py
├─ build_exe.ps1
├─ requirements.txt
├─ requirements-build.txt
├─ README_UI.md
├─ CustomWidget/
├─ data/config0.json（及干净的 data/ui_state.json）
├─ res/
├─ tests/
└─ docs/
```

不要包含：

- `.venv/`、`.qtcreator/`：本地虚拟环境，接收方按 §1.2 自行创建；
- `__pycache__/`、`*.pyc`；
- `tests/last_*.json`：本机测试结果；
- `output/`：便携版二进制单独交付，不依赖源码包；
- `.vscode/`：个人 IDE 配置（可选排除）。

接收方只需要一个干净的 Python 3.11 环境和网络，即可按 §1 启动；需要 exe 时再按 §10 打包。

