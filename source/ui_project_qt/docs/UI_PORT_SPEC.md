# J280 HTML 上位机实现规范（当前版本）

> 适用范围：`ui_project_qt/` 当前实现。固件基准 **BUILD60 / 遥测 Vy（103B）**，
> 默认配置 `data/config0.json`。本文是当前行为契约，历史重构记录不再逐条保留；
> 如需旧版细节可查项目历史（不在本文件内）。

## 1. 运行时架构

```text
PySide6 main.py
└─ mainWnd(CustomWnd) 无边框窗口
   ├─ QWebEngineView  file:///.../res/main.html
   ├─ QWebChannel
   │  ├─ qt_mainWnd = SerialBridge(bridge.py)  ← 串口/文件/状态
   │  └─ qt_window  = WindowBridge(mainWnd.py) ← 全屏控制/信号
   └─ 关闭时 bridge.shutdown() 尽力发 MODE0 并释放串口
```

- JS 只能通过 QWebChannel 访问串口/文件；所有槽返回 JSON 字符串。
- 全部前端脚本为经典 `<script>` + `window.*` 全局，无构建步骤、无网络请求。
- 浏览器直接打开页面时 `bridge.js` 降级为 `available=false`：无串口，文件用 Blob/File input；
  默认参数无法读取本地 config0。

## 2. 固件协议

### 2.1 参数帧

```text
AA | IDX | VALUE_HI | VALUE_LO
```

- UART 115200 8N1，无校验/无应答；VALUE 为 16 位二补码大端；
- 参数是否生效由遥测版本计数/界面状态确认；
- 本地模式（SRC=1）屏蔽上位机参数帧，但 MODE=0 急停允许；
- ID/范围/版本能力以 `j280_protocol.py` 为准，修改必须与 `project/gui/j280_protocol.py` 同步。

### 2.2 参数表（ID / 范围 / config0 默认）

| ID | 名称 | 范围 | 默认 | ID | 名称 | 范围 | 默认 |
|---:|---|---|---:|---:|---|---|---:|
| 4 | LIM | 0..1023 | 300 | 28 | POSMAX | 0..18000 | 600 |
| 5 | MODE | 0..3 | 0 | 29 | POSTGT | -520..519 | 0 |
| 6 | DZ | 0..1023 | 20 | 30 | ALP | 0..8 | 1 |
| 7 | TRIM | -18000..18000 | 20 | 31 | SLEW | 0..1023 | 0 |
| 10 | FALL | 1..18000 | 1500 | 32 | SWLIM | 0..1023 | 750 |
| 12 | ENTER | 1..18000 | 1000 | 33 | SWCAP | 1..18000 | 800 |
| 16 | ZERO | 1..1022 | 508 | 34 | SWTMO | 100..60000 | 15000 |
| 18 | ILIM | 0..1023 | 0 | 35 | SWDIR | -1..1 | 1 |
| 21 | DLP | 0..8 | 3 | 37 | POS_NEAR | 0..520 | 0 |
| 23 | AKP | -4096..4096 | -150 | 38 | PKDNEAR | -4096..4096 | -300 |
| 24 | AKI | -4096..4096 | 0 | 39 | POSP_LIM | 0..1023 | 427 |
| 25 | AKD | -4096..4096 | -400 | 40 | SWAMP | 0..1023 | 670 |
| 26 | PKP | -4096..4096 | 600 | 41 | SWRAMP | 0..60000 | 200 |
| 27 | PKD | -4096..4096 | -300 | 42 | SWMS | 1..1000 | 3 |
| 43 | PKI | -256..256 | 8 | 44 | PILIM | 0..600 | 45 |
| 45 | RLP | 0..6 | 4 | 46 | DZW | 1..256（2 的幂） | 64 |
| 47 | DZLP | 0..4 | 1 | 48 | TURNS_POSTGT | -32768..32767 | 0 |
| 49 | PIDEAD | 0..8 | 4 | 50 | KDBLEND | 0..6 | 0 |
| 51 | VELMODE | 0..1 | 1 | 52 | ADCAVG | 0..3 | 2 |
| 53 | RATEMODE | 0..2 | 2 | 54 | HOLDPOS | 0..160 | 70 |

- MODE：0 停机 / 1 手动稳定 / 2 自动起摆 / 3 绝对位置；
- MODE3 使用 `TURNS_POSTGT`，`POSTGT` 无效；
- 新参数版本门槛：PIDEAD/KDBLEND 需 t、VELMODE 需 v、ADCAVG 需 w、RATEMODE 需 x、HOLDPOS 需 y。

### 2.3 遥测（100 Hz，103B）

```text
ANG=+012.34 RAW=0508 POS=-00520 SPD=-0080 DUT=+0127 REF=+0000 M1B5 SW=0 Vy6 ABS=0000ABCD SRC=0 HLD=1
```

- `ANG` 度（0.01° 分辨率，带符号小数）；RAW ADC；POS 单圈 -520..519；SPD count/s；DUT duty；
  REF 参考角 0.01°；`M<mode>B<status>` 状态十六进制；
- `ABS` signed32 累计编码器计数（十六进制二补码），`SRC` 0 上位/1 本地，`HLD` 位置保持；
- ABS/SRC/HLD 可选，缺失时解析为 None，旧遥测兼容；
- 版本 token `V<ver><count>`，解析为 `y6` 这类值；界面显示时补 `V`。

## 3. Python 后端

### 3.1 SerialBridge 槽（返回 JSON 字符串）

| 槽 | 说明 |
|---|---|
| `listPorts()` | `{ok, ports}` |
| `openPort(str)` / `closePort()` | 115200 8N1；关闭时尽力 MODE0 |
| `getStatus()` | `{ok, connected, port, ports}` |
| `sendParam(name, valueStr)` | 校验 + 单帧；按固件版本/本地模式拦截 |
| `sendAll(paramsJson)` | 39 项按顺序一次写入；返回 count |
| `setMode(int)` | 0/1/2/3；本地模式仅允许 0 |
| `saveConfig/loadConfig` | QFileDialog；测试钩子重定向目录 |
| `loadDefaults()` | 读取 `data/config0.json` |
| `saveCsv` | UTF-8-SIG + CRLF |
| `saveState/loadState` | `data/ui_state.json` 原子写；`J280_UI_STATE_PATH` 可覆盖 |
| `shutdown()` | MODE0 + 关串口 |

### 3.2 遥测行 schema（Py→JS）

```js
{t, ang, raw, pos, abs, spd, dut, ref, mode, st, sw, src, hld, ver, cc}
```

- `abs` = signed32 累计计数；`src`/`hld` 为 bool/null；`st` 为十六进制状态位整数；
- `app.js` 再补 `tgt/tgtAbs/pos_total/pos_error/sentSnap`。

## 4. JS 模块

### 4.1 `params.js`（`window.J280Params`）

- `PARAMS` 39 项元数据（label/default/unit/desc/rec/up/down/tip）；
- `RANGES` 40 项（含 MODE）；`NUDGE` 步长；`GROUPS` 6 组；`ORDER` 39 项；
- `validate(name,value)` 与 Python 一致（范围、DZW 2 的幂、MODE 0..3）；
- `supportsParameter(name,version)` 与 Python 一致；
- `absDecompose(value)` / `absCompose(turns,phase)` / `absPhaseBounds(turns)`：
  `count=turns*1040+phase`，turns -32..32，phase -520..519，边界截断；
- `createParamRow(name, callbacks)` 控件类型：
  - `dial`：POSTGT 圆形表盘；
  - `range`：有界参数滑杆；
  - `choice`：DZW/SWDIR/VELMODE/ADCAVG/RATEMODE 下拉；
  - 缺省：输入框 + ± + 发送；
  - 特殊：TURNS_POSTGT 普通输入框，无 ±，额外「设置」按钮触发轨迹卡片；
- 已移除参数悬停说明框（`showParamTip` 空实现），`tooltipHtml` 数据仍保留供测试/扩展。

### 4.2 `cards.js`（`window.J280Cards`）

- `createCard({id,title,subtitle,width,bodyEl,footerText,maxBodyHeight,defaultPos,collapsed,onChange})`
  返回 `{el,id,setPos,getPos,setCollapsed,toggleCollapsed,isCollapsed,...}`；
- 卡片 ABS 定位在 `#cardLayer`，头部可拖动，支持折叠/位置回调/拖拽 `z-index`；
- `autoStack(cards,{x,y,gap,bottomMargin})` 只在可见卡片超过高度时折叠尾部；
- 卡片标题末尾不显示“N 项”（subtitle 为空且 CSS 隐藏空节点）。

### 4.3 `charts.js` / `model3d.js`

- `charts.js`：5 路 Canvas（ANG/REF、POS/TGT、SPD、DUT、RAW），趋势/原始/叠加、
  平滑 20/40/80 ms、5/10/30/60 s、暂停、锁 Y、图例、跨图十字光标、目标/±LIM/±DZ 叠加线；
  标题由 HTML `.chart-head` 提供，画布内 `drawTitle:false`。
- `model3d.js`：three.js r149 本地版；旋转倒立摆底座/摆臂/摆杆、DUT 环、状态灯、
  起摆能量环、角度弧和标签；按视口宽高比自适应取景；容器降级提示。

### 4.4 `bridge.js`（`window.J280Bridge`）

- QWebChannel 初始化 → `Backend`；串口/文件/状态方法 Promise 化；
- `loadDefaults()` 读取 config0；
- `getWindowState/setFullscreen/toggleFullscreen` + `onWindowState`（qt_window）；
- `onTelemetry/onStatus/onEvent`；普通浏览器降级无串口。

### 4.5 `app.js`

- 遥测缓冲 `times/rows`（10000 帧上限，超限丢最早 2500）；
- `latest`、pos_total（优先用 ABS 展开）、pos_error（MODE3 用 ABS-TURNS_POSTGT，其余最短单圈差）；
- 5 路曲线、3D 状态、分析条、事件日志、toast；
- 书签：
  - `buildBookmarks()` 创建 6 个参数组书签 + 琥珀色「轨迹」特殊书签；
  - 所有参数组卡片启动隐藏；`setGroupCardVisible()` 显示/隐藏并同步书签 `.active`；
  - 显示卡片时保留上次拖动位置，与已显示卡片重叠则自动下移；
  - `findCardOverlaps/cardRectList` 忽略隐藏卡片；`reflowCards` 只排可见卡片；
  - 书签标题 **调整参数**；默认窄标签，hover 展开 172px，带扫光/发光箭头/呼吸发光；
- 指定运动轨迹卡片：
  - 运行时由 `#absCardTemplate` 构建可拖动卡片（标题「指定运动轨迹」，无副标题）；
  - 点击琥珀色轨迹书签或参数行「设置」切换显示；
  - 圈数刻度 Canvas、相位环 Canvas；无 count/总角度换算式、无 ±10/归零、无范围说明；
  - 应用 / 应用并发送；位置/折叠持久化到 `ui_state.abs_card`；
  - 卡片布局独立于参数组卡片，不参与 `state.cards` 自动堆叠；
- 状态持久化、CSV、键盘（Esc 全屏/收起轨迹、空格暂停）、全屏按钮；
- `J280_APP.test` API：setParam/getParams、injectTelemetry、recordBuffer、
  loadDefaultParams、openAbsEditor/setAbsTarget/getAbsTarget、setGroupCardVisible、
  visibleGroupCards 等，供 Qt 测试脚本调用。

## 5. DOM / CSS

### 5.1 关键 DOM

- `#topbar`：串口、MODE1/2/3、停机、全量下发、文件配置/全屏按钮；
- `#metricStrip`：6 个指标卡；`#statusHud`：MODE/接管/位置误差/ABS/SRC·HLD；
- `#viewport/#model3d`、`#chartsPane`、`#chartStack`、`#eventLog`；
- `#stage`：`#bookmarkRail`（左侧书签）、`#cardLayer`（参数卡）；
- `#absCardTemplate`：轨迹卡片模板（hidden），运行时移入卡片 body；
- `#tooltip`：保留 DOM 但参数悬停不再触发；
- `#bootOverlay`、`#toastLayer`、`#errorBanner`。

### 5.2 样式

- 深空青蓝科技风：玻璃拟态、切角、扫描线、发光描边；
- 书签 `.bookmark-item`：默认 66×34，hover/active 展开 172px，扫光/发光箭头/呼吸；
- 特殊书签 `.bookmark-special`：琥珀色，`TOOL` 分隔，标题“轨迹”；
- 参数卡 `.param-card`：半透明玻璃、拖动 `grab/grabbing`、折叠、错误着色；
- POSTGT 表盘、POSTGT 参数行居中；轨迹卡内容自适应 430px 宽卡片；
- 响应式：1280×800 下不溢出；窗口/全屏状态见 `mainWnd.py`。

## 6. 状态 / CSV / 内存

- `data/ui_state.json`：`{ui_version:3, port, plot_window, display_mode, trend_ms, cards:{}, abs_card?}`；
  每次启动所有参数组卡片隐藏（不恢复可见性），卡片位置恢复；
- CSV 59 列：`time_s,ang,ref,ref_cdeg,raw,pos,pos_absolute,src_local,spd,dut,mode,
  bal_status,swing_active,position_hold,version,config_count,tgt,tgt_abs,pos_total,pos_error`
  + 39 列 `sent_*`；UTF-8-SIG；
- 显示缓冲 10000 帧/丢 2500；记录缓冲 30000 帧，达上限自动停止，保存成功后释放；
- 状态保存有 `state.ready` 保护，启动布局未稳定时不落盘。

## 7. 测试

```bat
python tests\capture_qt.py    :: 截图 + 13 项
python tests\protocol_test.py  :: 42 项
python tests\smoke_test.py
python tests\interaction_test.py :: 46 项
python tests\fullscreen_test.py  :: 33 项
```

最近结果：全部 PASS。测试均使用 `J280_UI_TEST_DIR`/`J280_UI_STATE_PATH` 隔离，
并自行写入干净状态，不污染交付状态。运行前先按 README 创建 `.venv` 并安装依赖。

## 8. 已知限制与注意

- 遥测 100 Hz 只能观察 <50 Hz 现象；趋势不是原始峰值；
- MODE3 下 POSTGT 无效，使用 TURNS_POSTGT；绝对计数来自 ABS；
- 本地模式（SRC=1）屏蔽上位机参数帧，仅 MODE0 可发；
- 新参数需对应固件版本；当前 BUILD60/Vy 全部支持；
- 无实体 FPGA：串口路径只验证协议/错误路径，首次上板从低 LIM、MODE0 开始并准备实体急停；
- `project/gui/**` 为只读参考，不修改；`j280_protocol.py` 修改需同步参考实现。

## 9. 文件清单

交付文件与旧 Tk 参考文件的 sha256 见 `docs/MANIFEST.sha256`。
