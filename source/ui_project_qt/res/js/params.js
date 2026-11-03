/* =====================================================================
 * J280 参数元数据 / 校验 / 参数行（window.J280Params）
 *
 * 本文件由 _dev/params-dev/gen_params.py 自动生成，不要手改；
 * 需要改 API 请改 _dev/params-dev/params_api.template.js 后重跑脚本。
 *
 * 数据来源（只读，禁止修改 project/gui/**）：
 *   project/gui/j280_debug_gui.py       PARAMS / PARAM_HELP / NUDGE_STEP / GROUPS
 *   project/gui/j280_protocol.py        PARAM_RANGES / validate_value
 *   project/gui/j280_debug_gui_state.json  params（实机 s 参数组）
 *
 * 生成结果：PARAMS 39 项 · RANGES 40 项 · NUDGE 39 项 · GROUPS 6 组（无内置参数组）
 * ===================================================================== */
/* eslint-disable no-var */
(function (global) {
  'use strict';

  /* ==================================================================
   * 数据段：由 _dev/params-dev/gen_params.py 用 ast 从 Python 源提取，
   * 请勿手改；上游参数表变化时重跑脚本即可。
   *   PARAMS 39 项（j280_debug_gui.PARAMS + PARAM_HELP）
   *   RANGES 33 项（j280_protocol.PARAM_RANGES，含 MODE）
   *   GROUPS 6 组 / NUDGE 39 项（唯一默认配置为 data/config0.json）
   * ================================================================== */

  var PARAMS = {
    "AKP": {
      "label": "比例增益",
      "default": -160,
      "unit": "Q8 PWM/0.01°",
      "desc": "误差越大，输出越大；正负号决定角度纠正方向。",
      "rec": "-160",
      "up": "数值增大（|AKP| 减小）：回复更软、更慢，死区对应的角度误差变大，可能出现慢摆。",
      "down": "数值减小（|AKP| 增大）：回复力更强、站得更“硬”，但高频更易抖动，并放大位置内环增益。",
      "tip": "经验：死区 ÷ (|AKP|/256×100) ≈ 摆杆需要偏多少度电机才开始动；越小越好。"
    },
    "AKI": {
      "label": "积分增益",
      "default": 0,
      "unit": "Q8 PWM/(°·s)",
      "desc": "消除持续偏差；本结构中建议保持 0（见悬浮提示）。",
      "rec": "0",
      "up": "增大：积分与“摆臂速度≈占空比”的对象叠加成二重积分，位置容易出现慢速正弦摆动。",
      "down": "减小/置 0：位置外环已能消除偏差，且 TRIM 可修正零点偏差。",
      "tip": "本系统电机相当于速度执行器，角度积分会和位置环打架，建议保持 0。"
    },
    "AKD": {
      "label": "微分增益",
      "default": -400,
      "unit": "Q8 PWM/(°/s)",
      "desc": "按角速度提供阻尼；噪声过大时减小增益或增大 DLP。",
      "rec": "-400",
      "up": "数值增大（|AKD| 减小）：阻尼减弱，角度收敛变慢，站立刚度下降。",
      "down": "数值减小（|AKD| 增大）：阻尼更强，但更怕噪声/滞后，过大可能增加高频换向和啸叫。",
      "tip": "本对象中 D 项同时提供“刚度”，其滞后(DLP/ALP)比数值本身更关键。"
    },
    "PKP": {
      "label": "位置比例",
      "default": 600,
      "unit": "Q8 0.01°/count",
      "desc": "按单圈位置误差修正角度目标；位置 P 项需通过 POSP_LIM 启用。",
      "rec": "300",
      "up": "增大：回到目标更快，但位置慢模态阻尼变差，超调与慢摆增多。",
      "down": "减小：回中更软、更稳，但静态误差与回中速度变差。",
      "tip": "先固定 PKD，再从 200 往上加；出现 0.2~0.5 Hz 慢摆就回退。"
    },
    "PKD": {
      "label": "位置速度阻尼",
      "default": -300,
      "unit": "Q8 0.01°/(count/s)",
      "desc": "按编码器速度提供阻尼；符号与角度环增益、编码器方向有关。",
      "rec": "-300",
      "up": "数值增大（|PKD| 减小）：位置慢模态阻尼变差，摆动不易衰减、超调变大。",
      "down": "数值减小（|PKD| 增大）：阻尼增强；过大会与角度内环形成过强反馈，增加高频抖动。",
      "tip": "16ms 窗每计数对应62.5 count/s；RLP 平滑参考台阶，过大仍会增加延迟。"
    },
    "PKI": {
      "label": "慢速位置积分",
      "default": 8,
      "unit": "Q8 cdeg/(count·s)",
      "desc": "s版对持续偏差积分，带±2 count软死区；目标静止500ms后学习，运动和饱和时冻结。",
      "rec": "8",
      "up": "加快消除静差，但过大易形成慢振荡。",
      "down": "0 关闭。",
      "tip": "符号应与 PKP 一致；与角度积分 AKI 独立。"
    },
    "PILIM": {
      "label": "位置积分限幅",
      "default": 45,
      "unit": "0.01°",
      "desc": "限制位置积分角度补偿；0 关闭，停机清零。",
      "rec": "45",
      "up": "允许更大的偏角补偿。",
      "down": "0 关闭位置积分。",
      "tip": "单位0.01°，当前实测保留最多±0.6°。"
    },
    "RLP": {
      "label": "参考平滑",
      "default": 4,
      "unit": "移位",
      "desc": "只平滑位置角度参考；4约15ms，为当前实测保留值，0旁路。",
      "rec": "4",
      "up": "降低测速量化引起的参考跳变，同时增加位置反馈延迟。",
      "down": "0 直通参考。",
      "tip": "当前实测保留4；5/6的现场恢复试验未改善，不宜继续盲目加大。"
    },
    "POSMAX": {
      "label": "位置修正上限",
      "default": 600,
      "unit": "0.01°",
      "desc": "位置环允许改变角度目标的最大幅度。",
      "rec": "600",
      "up": "增大：允许位置环把摆杆目标倾得更大，回中更快，但跟踪时摆杆倾斜更大。",
      "down": "减小：限制倾角，位置纠偏变慢。",
      "tip": "通常 400~700（4~7°）；过小会使位置环“推不动”。"
    },
    "POSTGT": {
      "label": "位置目标",
      "default": 0,
      "unit": "count",
      "desc": "单圈有符号目标，范围 -520..+519；位置环关闭时不起作用。",
      "rec": "0",
      "up": "目标数值向 + 方向增大（单圈 -520..+519，底部轮回）；位置环按新目标修正。",
      "down": "目标数值向 − 方向减小；阶跃过大时摆杆会瞬间倾斜，建议小步修改。",
      "tip": "位置环关闭（POSP_LIM=0）时不起作用；改目标后观察位置误差与摆杆倾角。"
    },
    "POS_NEAR": {
      "label": "近目标范围",
      "default": 0,
      "unit": "count",
      "desc": "进入目标附近时切换到 PKDNEAR；0=关闭切换（推荐）。",
      "rec": "0",
      "up": "大于 0：目标附近自动换用 PKDNEAR。该切换会让调试时的 PKD 不再是实际生效值。",
      "down": "0：关闭切换，只有 PKD 生效，调参结果可复现。",
      "tip": "旧默认 200 + PKDNEAR=-546 在补偿好死区后会诱发高频抖动，建议 0。"
    },
    "PKDNEAR": {
      "label": "近目标阻尼",
      "default": -300,
      "unit": "Q8 0.01°/(count/s)",
      "desc": "进入 POS_NEAR 区后使用；POS_NEAR=0 时不起作用。",
      "rec": "-300",
      "up": "数值增大（|值| 减小）：近区阻尼减弱（POS_NEAR>0 时生效）。",
      "down": "数值减小（|值| 增大）：近区阻尼增强，过强更易抖；与 PKD 取同值相当于不切换。",
      "tip": "POS_NEAR=0 时本项无作用，建议与 PKD 同值。"
    },
    "POSP_LIM": {
      "label": "位置 P 限幅",
      "default": 427,
      "unit": "0.01°；0=关闭",
      "desc": "限制位置 P 项对角度参考的贡献；设 0 可关闭位置 P 回中。",
      "rec": "427",
      "up": "增大：位置 P 对角度参考的最大贡献更大。",
      "down": "0：关闭位置 P 回中，仅速度阻尼起作用（首次方向确认时可用）。",
      "tip": "PKP×最大位置误差超过此值就会饱和。"
    },
    "ENTER": {
      "label": "接管角度",
      "default": 1000,
      "unit": "0.01°",
      "desc": "|ANG-TRIM| 不大于此值并连续满足约 4 ms 后接管。",
      "rec": "1000",
      "up": "增大：更远的角度也允许接管，接管瞬间冲击更大。",
      "down": "减小：必须扶得更正才接管。",
      "tip": "必须小于 FALL。"
    },
    "FALL": {
      "label": "判倒角度",
      "default": 1500,
      "unit": "0.01°",
      "desc": "接管后超出此角度约 10 ms，锁止电机输出。",
      "rec": "1500",
      "up": "增大：更晚判倒，增加保护延迟。",
      "down": "减小：更早锁止，扰动稍大就停机。",
      "tip": "必须大于 ENTER。"
    },
    "TRIM": {
      "label": "目标微调",
      "default": 20,
      "unit": "0.01°",
      "desc": "角度目标偏置；只在 RAW_ZERO 标定后微调。",
      "rec": "20",
      "up": "数值增大：角度目标向正方向平移；需配合 ZERO 标定观察摆臂漂移方向。",
      "down": "数值减小：角度目标向负方向平移；先 ZERO 标定，再微调到摆臂不再单向漂移。",
      "tip": "单位 0.01°，1 个 ADC 码约 0.33°。"
    },
    "LIM": {
      "label": "PWM 限幅",
      "default": 300,
      "unit": "duty / 1023",
      "desc": "限制电机命令幅度；实物调试仍须从低值开始。",
      "rec": "300",
      "up": "增大：更大的纠偏能力，也更危险。",
      "down": "减小：更安全，但抗扰能力下降；扣除死区后可用范围会变小。",
      "tip": "扣除摩擦补偿后需保留足够纠偏余量；长时间饱和时先查方向、标定和负载。"
    },
    "DZ": {
      "label": "摩擦补偿",
      "default": 20,
      "unit": "duty",
      "desc": "当前实测保留20；加大补偿或收窄过渡区可能再次激发振荡。",
      "rec": "20",
      "up": "增大：更好抵消电机死区；超过真实死区会在零附近换向抖动。",
      "down": "减小：死区未补偿，摆杆需偏更多角度电机才动，出现慢摆与位置不收敛。",
      "tip": "20为用户确认保留的s实测值，不等同电机物理静摩擦门槛。"
    },
    "DZW": {
      "label": "补偿过渡宽度",
      "default": 64,
      "unit": "duty",
      "desc": "2 的幂；过宽会推不动小命令，过窄会放大噪声。",
      "rec": "64",
      "up": "数值增大：过渡区更宽，小命令实际推力更小。",
      "down": "数值减小：更接近完整静摩擦补偿，也更易放大噪声。",
      "tip": "必须为2的幂；当前保留64，较窄补偿的实测未持续改善。"
    },
    "DZLP": {
      "label": "补偿支路滤波",
      "default": 1,
      "unit": "移位",
      "desc": "只平滑摩擦补偿，原始 PD 不延迟；0 直通。",
      "rec": "1",
      "up": "抑制摩擦补偿反转，但会延迟过零。",
      "down": "0 直通。",
      "tip": "只滤补偿，不滤整个 PWM，建议 1~2。"
    },
    "ILIM": {
      "label": "积分限幅",
      "default": 0,
      "unit": "duty",
      "desc": "限制积分项最大输出；AKI=0 时不产生作用。",
      "rec": "0",
      "up": "数值增大：允许更大的积分输出；AKI=0 时仍无作用。",
      "down": "数值减小到 0：关闭积分输出。",
      "tip": "积分上限接近死区宽度时会把电机“顶开”造成粘滑。"
    },
    "DLP": {
      "label": "微分滤波",
      "default": 3,
      "unit": "移位",
      "desc": "每 1 ms 更新一次；0 为直通，数值越大滤波越强、滞后越大。",
      "rec": "3",
      "up": "增大：微分更平滑，但滞后增加（DLP=4 时约 16 ms），会降低 D 项相位裕度，引起角度振荡。",
      "down": "减小：滞后小、阻尼更及时；噪声大时会抖。",
      "tip": "需结合 ALP 对照原始角度与输出；每次只改一项，避免累计过大延迟。"
    },
    "ALP": {
      "label": "角度低通",
      "default": 1,
      "unit": "移位",
      "desc": "控制用角度低通；数值越大越平滑，但延迟也越大。",
      "rec": "1",
      "up": "增大：角度更平滑但延迟更大。",
      "down": "0：直通；ADC 已做 512 点平均，通常无需再滤。",
      "tip": "ALP 与 DLP 滞后叠加，优先压低二者。"
    },
    "SLEW": {
      "label": "PWM 变化率",
      "default": 0,
      "unit": "duty/毫秒",
      "desc": "限制 PWM 每毫秒变化量；0 表示关闭。",
      "rec": "0",
      "up": "数值增大：允许更快的 PWM 变化（限速更松），平滑/抗噪作用减弱。",
      "down": "数值减小：PWM 变化率限制更强、更平滑，但滞后增加；0=关闭限制。",
      "tip": "站立控制不建议开启。"
    },
    "SWLIM": {
      "label": "起摆限幅",
      "default": 750,
      "unit": "duty",
      "desc": "自动起摆专用 PWM 限幅；当前默认提高动力但仍保留余量。",
      "rec": "750",
      "up": "数值增大：起摆最大 PWM 更大，起摆更有力。",
      "down": "数值减小：起摆更保守。",
      "tip": "保留现场验证的 750 duty 上限。"
    },
    "SWAMP": {
      "label": "起摆幅度",
      "default": 670,
      "unit": "duty",
      "desc": "线性软启动后的目标幅度，实际不超过 SWLIM。",
      "rec": "670",
      "up": "起摆力度更大。",
      "down": "起摆更温和。",
      "tip": "实际不超过 SWLIM。"
    },
    "SWRAMP": {
      "label": "起摆软启动",
      "default": 200,
      "unit": "ms",
      "desc": "从 0 线性增加到目标幅度的时间。",
      "rec": "200",
      "up": "数值增大：软启动更慢。",
      "down": "数值减小：软启动更快。",
      "tip": "单位 ms。"
    },
    "SWMS": {
      "label": "捕获确认",
      "default": 3,
      "unit": "ms",
      "desc": "角度与角速度条件连续满足该时间后请求接管。",
      "rec": "3",
      "up": "数值增大：连续满足时间更长，捕获确认更严格。",
      "down": "数值减小：更快请求接管。",
      "tip": "单位 ms。"
    },
    "SWCAP": {
      "label": "起摆捕获角",
      "default": 800,
      "unit": "0.01°",
      "desc": "相对 TRIM 的角度进入窗口且角速度不超过 100°/s 时切换角度环。",
      "rec": "800",
      "up": "数值增大：捕获窗口更宽，更早切入平衡环。",
      "down": "数值减小：捕获窗口更严格，需要更接近竖直。",
      "tip": "单位 0.01°。"
    },
    "SWTMO": {
      "label": "起摆超时",
      "default": 15000,
      "unit": "ms",
      "desc": "超过时间仍未捕获则停机并置故障。",
      "rec": "15000",
      "up": "允许更长的起摆时间。",
      "down": "更快超时停机。",
      "tip": "单位 ms。"
    },
    "SWDIR": {
      "label": "起摆方向",
      "default": 1,
      "unit": "±1",
      "desc": "起摆相位方向；运动趋势相反时改为 -1。",
      "rec": "1",
      "up": "-",
      "down": "-",
      "tip": "仅起摆使用。"
    },
    "ZERO": {
      "label": "ADC 竖直零点",
      "default": 508,
      "unit": "ADC 码",
      "desc": "摆杆竖直时的 RAW；保留原 508 标定；TRIM 补偿有效平衡偏角。",
      "rec": "508",
      "up": "数值增大：同一 RAW 计算出的角度向负方向整体平移。",
      "down": "数值减小：同一 RAW 计算出的角度向正方向整体平移。",
      "tip": "手扶竖直时读取 RAW 标定。"
    },
    "TURNS_POSTGT": {
      "label": "绝对位置目标",
      "default": 0,
      "unit": "count",
      "desc": "MODE3 使用的绝对编码器计数目标，替代 POSTGT；signed 16 全范围 -32768..32767。",
      "rec": "0",
      "up": "数值增大：MODE3 绝对位置目标向 + 方向移动；平衡中阶跃过大会让摆杆瞬间倾斜。",
      "down": "数值减小：MODE3 绝对位置目标向 − 方向移动；建议小步修改并观察位置误差。",
      "tip": "只在 MODE3 生效并替代 POSTGT；编码器累计计数按低 16 位 signed 解释。"
    },
    "PIDEAD": {
      "label": "积分位置软死区",
      "default": 4,
      "unit": "count",
      "desc": "位置积分软死区；需 t 及以上固件。2 保留原行为，1/0 提高慢偏差精度，须观察复振。",
      "rec": "4",
      "up": "数值增大：软死区更大，减少位置积分追逐噪声，但允许更大残差。",
      "down": "数值减小：软死区更小，提高慢偏差精度，须排除再次复振。",
      "tip": "仅影响慢位置积分，不屏蔽角度 PD 和位置 P/D。"
    },
    "KDBLEND": {
      "label": "阻尼切换渐变",
      "default": 0,
      "unit": "移位",
      "desc": "远近目标阻尼切换的渐变时间；0=直接切换，4 约 15 ms。",
      "rec": "0",
      "up": "数值增大：远近区增益切换更平缓，但阻尼调整变慢。",
      "down": "数值减小：切换更快（0=直接切换），可能产生角度参考突变。",
      "tip": "平滑的是增益切换，不延迟原始角度 PD；需 t 及以上固件。"
    },
    "VELMODE": {
      "label": "低速测速方式",
      "default": 1,
      "unit": "模式",
      "desc": "0=净位移窗口，1=低速周期辅助；反向/高速自动回退窗口。需 v 及以上固件。",
      "rec": "1",
      "up": "-",
      "down": "-",
      "tip": "周期法停止后存在速度衰减尾部，应结合位置误差判断静止。"
    },
    "ADCAVG": {
      "label": "控制前 ADC 平均",
      "default": 2,
      "unit": "组数",
      "desc": "控制前 ADC 平均组数：0/1/2/3 对应 1/2/4/8 组；需 w 及以上固件。",
      "rec": "2",
      "up": "数值增大：使用更多 ADC 样本，减小混叠与电机载波串扰，但测量延迟增加。",
      "down": "数值减小：减少测量延迟；0 保持原单组平均。",
      "tip": "默认组长约 102.4 us；不影响 RAW 健康检测。"
    },
    "RATEMODE": {
      "label": "角速度算法",
      "default": 2,
      "unit": "模式",
      "desc": "0=原窗口微分+DLP，1=快速观测，2=平滑观测；观测模式的 D 反馈绕过 DLP。需 x 及以上固件。",
      "rec": "2",
      "up": "-",
      "down": "-",
      "tip": "1 约 3.5 ms、2 约 7.5 ms 低频等效滞后；ALP 仍生效，需实机实测。"
    },
    "HOLDPOS": {
      "label": "稳定保持容差",
      "default": 70,
      "unit": "count",
      "desc": "位置误差在容差内并稳定 600 ms 后冻结位置积分；0=关闭。需 Vy 固件。",
      "rec": "70",
      "up": "数值增大：允许更大的稳定位置偏差，减少积分追零。",
      "down": "数值缩小：保持容差更严格；0 恢复连续位置积分。",
      "tip": "仅冻结位置积分，角度闭环及 P/D 继续纠偏，受扰自动退出。"
    }
  };

  var RANGES = {
    "LIM": [0, 1023],
    "MODE": [0, 3],
    "DZ": [0, 1023],
    "TRIM": [-18000, 18000],
    "FALL": [1, 18000],
    "ENTER": [1, 18000],
    "ZERO": [1, 1022],
    "ILIM": [0, 1023],
    "DLP": [0, 8],
    "AKP": [-4096, 4096],
    "AKI": [-4096, 4096],
    "AKD": [-4096, 4096],
    "PKP": [-4096, 4096],
    "PKD": [-4096, 4096],
    "POSMAX": [0, 18000],
    "POSTGT": [-520, 519],
    "ALP": [0, 8],
    "SLEW": [0, 1023],
    "SWLIM": [0, 1023],
    "SWCAP": [1, 18000],
    "SWTMO": [100, 60000],
    "SWDIR": [-1, 1],
    "POS_NEAR": [0, 520],
    "PKDNEAR": [-4096, 4096],
    "POSP_LIM": [0, 1023],
    "SWAMP": [0, 1023],
    "SWRAMP": [0, 60000],
    "SWMS": [1, 1000],
    "PKI": [-256, 256],
    "PILIM": [0, 600],
    "RLP": [0, 6],
    "DZW": [1, 256],
    "DZLP": [0, 4],
    "TURNS_POSTGT": [-32768, 32767],
    "PIDEAD": [0, 8],
    "KDBLEND": [0, 6],
    "VELMODE": [0, 1],
    "ADCAVG": [0, 3],
    "RATEMODE": [0, 2],
    "HOLDPOS": [0, 160]
  };

  var NUDGE = {
    "AKP": 5,
    "AKI": 2,
    "AKD": 10,
    "PKP": 10,
    "PKD": 10,
    "POSMAX": 20,
    "POS_NEAR": 10,
    "PKDNEAR": 10,
    "POSP_LIM": 20,
    "ENTER": 50,
    "FALL": 100,
    "TRIM": 5,
    "LIM": 10,
    "DZ": 5,
    "ILIM": 5,
    "DLP": 1,
    "ALP": 1,
    "SLEW": 1,
    "SWLIM": 20,
    "SWAMP": 20,
    "SWRAMP": 20,
    "SWMS": 5,
    "SWCAP": 20,
    "SWTMO": 500,
    "SWDIR": 2,
    "ZERO": 1,
    "POSTGT": 10,
    "PKI": 2,
    "PILIM": 10,
    "RLP": 1,
    "DZW": 1,
    "DZLP": 1,
    "TURNS_POSTGT": 100,
    "PIDEAD": 1,
    "KDBLEND": 1,
    "VELMODE": 1,
    "ADCAVG": 1,
    "RATEMODE": 1,
    "HOLDPOS": 5
  };

  /**
   * 交互控件类型（不是所有参数都适合“输入框 + ±”）：
   *  - dial   : 圆形表盘，POSTGT 单圈 -520..519 在底部轮回；
   *  - range  : 有界参数用滑杆粗调 + 输入框精调；
   *  - choice : 离散取值（DZW 2 的幂 / SWDIR ±1）用下拉；
   *  - 缺省   : 数值输入 + ±（宽范围增益/偏置）。
   */
  var CONTROLS = {
    "POSTGT": {type: 'dial', step: 10},
    "DZW": {type: 'choice', options: [1, 2, 4, 8, 16, 32, 64, 128, 256]},
    "SWDIR": {type: 'choice', options: [-1, 1], labels: {'-1': '−1（反向）', '1': '+1（正向）'}},
    "DZ": {type: 'range', step: 1},
    "DZLP": {type: 'range', step: 1},
    "ILIM": {type: 'range', step: 1},
    "DLP": {type: 'range', step: 1},
    "ALP": {type: 'range', step: 1},
    "SLEW": {type: 'range', step: 1},
    "LIM": {type: 'range', step: 1},
    "SWLIM": {type: 'range', step: 1},
    "SWAMP": {type: 'range', step: 1},
    "SWRAMP": {type: 'range', step: 10},
    "SWMS": {type: 'range', step: 1},
    "SWTMO": {type: 'range', step: 100},
    "SWCAP": {type: 'range', step: 10},
    "ZERO": {type: 'range', step: 1},
    "POS_NEAR": {type: 'range', step: 1},
    "PILIM": {type: 'range', step: 1},
    "RLP": {type: 'range', step: 1},
    "POSP_LIM": {type: 'range', step: 1},
    "ENTER": {type: 'range', step: 10},
    "FALL": {type: 'range', step: 10},
    "POSMAX": {type: 'range', step: 10},
    "PIDEAD": {type: 'range', step: 1},
    "KDBLEND": {type: 'range', step: 1},
    "HOLDPOS": {type: 'range', step: 1},
    "VELMODE": {type: 'choice', options: [0, 1],
                labels: {'0': '0 净位移窗口', '1': '1 低速周期辅助'}},
    "ADCAVG": {type: 'choice', options: [0, 1, 2, 3],
               labels: {'0': '0（1 组）', '1': '1（2 组）', '2': '2（4 组）', '3': '3（8 组）'}},
    "RATEMODE": {type: 'choice', options: [0, 1, 2],
                 labels: {'0': '0 原微分', '1': '1 快速观测', '2': '2 平滑观测'}}
  };

  var GROUPS = [
    {
      "title": "角度 PID",
      "short": "角度",
      "names": [
        "AKP",
        "AKI",
        "AKD"
      ]
    },
    {
      "title": "编码器位置外环",
      "short": "位置",
      "names": [
        "PKP",
        "PKD",
        "PKI",
        "PILIM",
        "PIDEAD",
        "KDBLEND",
        "VELMODE",
        "RLP",
        "POS_NEAR",
        "PKDNEAR",
        "POSP_LIM",
        "POSMAX",
        "POSTGT",
        "TURNS_POSTGT"
      ]
    },
    {
      "title": "接管、保护与 PWM",
      "short": "输出",
      "names": [
        "ENTER",
        "FALL",
        "LIM",
        "DZ",
        "DZW",
        "DZLP",
        "ILIM"
      ]
    },
    {
      "title": "标定与滤波",
      "short": "标定",
      "names": [
        "ZERO",
        "TRIM",
        "DLP",
        "RATEMODE",
        "ALP",
        "ADCAVG",
        "SLEW"
      ]
    },
    {
      "title": "容差保持",
      "short": "保持",
      "names": [
        "HOLDPOS"
      ]
    },
    {
      "title": "自动起摆",
      "short": "起摆",
      "names": [
        "SWAMP",
        "SWLIM",
        "SWRAMP",
        "SWMS",
        "SWCAP",
        "SWTMO",
        "SWDIR"
      ]
    }
  ];

  var ORDER = [
    "AKP",
    "AKI",
    "AKD",
    "PKP",
    "PKD",
    "PKI",
    "PILIM",
    "PIDEAD",
    "KDBLEND",
    "VELMODE",
    "RLP",
    "POS_NEAR",
    "PKDNEAR",
    "POSP_LIM",
    "POSMAX",
    "POSTGT",
    "TURNS_POSTGT",
    "ENTER",
    "FALL",
    "LIM",
    "DZ",
    "DZW",
    "DZLP",
    "ILIM",
    "ZERO",
    "TRIM",
    "DLP",
    "RATEMODE",
    "ALP",
    "ADCAVG",
    "SLEW",
    "HOLDPOS",
    "SWAMP",
    "SWLIM",
    "SWRAMP",
    "SWMS",
    "SWCAP",
    "SWTMO",
    "SWDIR"
  ];

  var hasOwn = Object.prototype.hasOwnProperty;
  var DZW_CHOICES = [1, 2, 4, 8, 16, 32, 64, 128, 256];
  var DEC_RE = /^[+-]?(?:0|[1-9][0-9]*)$/;
  var HEX_RE = /^[+-]?0[xX][0-9a-fA-F]+$/;

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  /** 严格整数解析：number 或 "10" / "0x1f" / "-0x10"（等价 Python int(text, 0) 的常用子集）。 */
  function toInt(value) {
    if (typeof value === 'number') {
      return (isFinite(value) && Math.floor(value) === value) ? value : null;
    }
    if (typeof value === 'string') {
      var text = value.trim();
      if (!text) {
        return null;
      }
      var negative = text.charAt(0) === '-';
      var body = (negative || text.charAt(0) === '+') ? text.slice(1) : text;
      var number;
      if (HEX_RE.test(text)) {
        number = parseInt(body.slice(2), 16);
      } else if (DEC_RE.test(text)) {
        number = parseInt(body, 10);
      } else {
        return null;
      }
      if (!isFinite(number)) {
        return null;
      }
      return negative ? -number : number;
    }
    return null;
  }

  /* ---------------------------------------------------------------- 输入解析 */

  function parseIntEntry(text) {
    if (typeof text === 'number') {
      if (isFinite(text) && Math.floor(text) === text) {
        return {ok: true, value: text, error: null};
      }
      return {ok: false, value: null, error: '请输入整数'};
    }
    var raw = (text == null) ? '' : String(text).trim();
    if (!raw) {
      return {ok: false, value: null, error: '请输入数值（不能为空）'};
    }
    var value = toInt(raw);
    if (value === null) {
      return {ok: false, value: null, error: '非法输入：只支持十进制或 0x 十六进制整数'};
    }
    return {ok: true, value: value, error: null};
  }

  /* ---------------------------------------------------------------- 绝对定位 x 圈 + y 相位 */
  // 编码器 1040 count = 1 圈；TURNS_POSTGT 用 signed16 绝对计数表示：
  //   count = turns × 1040 + phase，phase 取单圈有符号相位 [-520, +519]。
  // 这样既保留“整圈数”直觉，又能沿用 POSTGT 的相位/轮回概念。
  var ABS_COUNTS = 1040;
  var ABS_HALF = 520;
  var ABS_MIN = -32768;
  var ABS_MAX = 32767;
  var ABS_TURNS_MIN = -32;
  var ABS_TURNS_MAX = 32;

  function absPhaseBounds(turns) {
    var x = Math.max(ABS_TURNS_MIN, Math.min(ABS_TURNS_MAX, Math.round(Number(turns) || 0)));
    var low = Math.max(-ABS_HALF, ABS_MIN - x * ABS_COUNTS);
    var high = Math.min(ABS_HALF - 1, ABS_MAX - x * ABS_COUNTS);
    if (low > high) return [-ABS_HALF, ABS_HALF - 1];
    return [low, high];
  }

  function absCompose(turns, phase) {
    var x = Math.max(ABS_TURNS_MIN, Math.min(ABS_TURNS_MAX, Math.round(Number(turns) || 0)));
    var bounds = absPhaseBounds(x);
    var y = Math.round(Number(phase) || 0);
    y = Math.max(bounds[0], Math.min(bounds[1], y));
    var count = x * ABS_COUNTS + y;
    count = Math.max(ABS_MIN, Math.min(ABS_MAX, count));
    return count;
  }

  function absDecompose(value) {
    var count = toInt(value);
    if (count === null) count = 0;
    count = Math.max(ABS_MIN, Math.min(ABS_MAX, count));
    var turns = Math.floor((count + ABS_HALF) / ABS_COUNTS);
    var phase = count - turns * ABS_COUNTS;
    return {turns: turns, phase: phase, count: count};
  }

  /* ---------------------------------------------------------------- 协议校验 */

  /** 与 j280_protocol.validate_value 一致：范围、DZW 2 的幂、MODE 0/1/2/3、必须整数。 */
  function validate(name, value) {
    var key = String(name == null ? '' : name).toUpperCase();
    var range = hasOwn.call(RANGES, key) ? RANGES[key] : null;
    if (!range) {
      return {ok: false, value: null, error: '不支持的参数：' + String(name)};
    }
    if (typeof value === 'boolean') {
      return {ok: false, value: null, error: '布尔值不是有效参数'};
    }
    var parsed = toInt(value);
    if (parsed === null) {
      return {ok: false, value: null, error: '参数必须是整数'};
    }
    var low = range[0];
    var high = range[1];
    if (parsed < low || parsed > high) {
      return {
        ok: false,
        value: null,
        error: '参数 ' + key + ' 必须在 ' + low + '~' + high + '，收到 ' + parsed
      };
    }
    if (key === 'DZW' && (parsed & (parsed - 1))) {
      return {ok: false, value: null, error: 'DZW 必须为 1/2/4/8/16/32/64/128/256'};
    }
    if (key === 'MODE' && parsed !== 0 && parsed !== 1 && parsed !== 2 && parsed !== 3) {
      return {ok: false, value: null,
        error: 'MODE 只支持 0=停机、1=手动稳定、2=自动起摆、3=绝对位置'};
    }
    return {ok: true, value: parsed, error: null};
  }

  /** 与 j280_protocol.supports_parameter 一致：按固件版本判断新增参数是否可用。 */
  function supportsParameter(name, version) {
    var key = String(name == null ? '' : name).toUpperCase();
    var prefix = String(version == null ? '' : version).charAt(0);
    if (key === 'HOLDPOS') return prefix === 'y';
    if (key === 'RATEMODE') return prefix === 'x' || prefix === 'y';
    if (key === 'ADCAVG') return prefix === 'w' || prefix === 'x' || prefix === 'y';
    if (key === 'VELMODE') return ['v', 'w', 'x', 'y'].indexOf(prefix) >= 0;
    if (key === 'PIDEAD' || key === 'KDBLEND') {
      return ['t', 'u', 'v', 'w', 'x', 'y'].indexOf(prefix) >= 0;
    }
    return true;
  }

  /* ---------------------------------------------------------------- ± 微调 */

  function nudge(name, current, dir) {
    var key = String(name == null ? '' : name).toUpperCase();
    var step = hasOwn.call(NUDGE, key) ? NUDGE[key] : 1;
    var value = toInt(current);
    if (value === null) {
      value = hasOwn.call(PARAMS, key) ? PARAMS[key].default : 0;
    }
    var direction = (Number(dir) < 0) ? -1 : 1;
    if (key === 'DZW') {
      // 原 GUI：先吸附到最近的 2 的幂档位，再跳一档，两端夹紧。
      var index = 0;
      var best = Infinity;
      for (var i = 0; i < DZW_CHOICES.length; i += 1) {
        var distance = Math.abs(DZW_CHOICES[i] - value);
        if (distance < best) {
          best = distance;
          index = i;
        }
      }
      index = Math.max(0, Math.min(DZW_CHOICES.length - 1, index + direction));
      return DZW_CHOICES[index];
    }
    var range = hasOwn.call(RANGES, key) ? RANGES[key] : null;
    var next = value + direction * step;
    if (range) {
      next = Math.max(range[0], Math.min(range[1], next));
    }
    return next;
  }

  /* ---------------------------------------------------------------- 悬浮提示 */

  function tooltipHtml(name, statusText) {
    var key = String(name == null ? '' : name).toUpperCase();
    if (!hasOwn.call(PARAMS, key)) {
      return '<div class="param-tip"><div class="tip-title">' +
        escapeHtml(key) + ' · 未知参数</div></div>';
    }
    var meta = PARAMS[key];
    var range = hasOwn.call(RANGES, key) ? RANGES[key] : [null, null];
    // 悬浮信息审计约定：每个标头都必须有对应内容；缺失/不适用统一显示 “-”
    var dash = function (value) {
      if (value === null || value === undefined) return '-';
      var text = String(value);
      return text.trim() === '' ? '-' : text;
    };
    var rangeLow = dash(range[0]);
    var rangeHigh = dash(range[1]);
    var parts = [];
    parts.push('<div class="param-tip">');
    // 标题：使用 .tip-title（style.css 已覆盖），便于 shell CSS 直接着色。
    parts.push('<div class="tip-title">' + escapeHtml(key) + ' · ' +
      escapeHtml(dash(meta.label)) + '</div>');
    parts.push('<div class="tip-meta">单位：<b>' + escapeHtml(dash(meta.unit)) +
      '</b>　范围：<b>' + escapeHtml(rangeLow) + ' ~ ' + escapeHtml(rangeHigh) + '</b></div>');
    parts.push('<div class="tip-meta">固件默认：<b>' + escapeHtml(dash(meta.default)) +
      '</b>　推荐：<b>' + escapeHtml(dash(meta.rec)) + '</b></div>');
    parts.push('<div class="tip-desc">' + escapeHtml(dash(meta.desc)) + '</div>');
    parts.push('<div class="tip-row tip-up"><span class="tip-key">↑ 调大</span>' +
      escapeHtml(dash(meta.up)) + '</div>');
    parts.push('<div class="tip-row tip-down"><span class="tip-key">↓ 调小</span>' +
      escapeHtml(dash(meta.down)) + '</div>');
    parts.push('<div class="tip-row tip-note"><span class="tip-key">提示</span>' +
      escapeHtml(dash(meta.tip)) + '</div>');
    parts.push('<div class="tip-status">状态：<b>' + escapeHtml(dash(statusText)) + '</b></div>');
    parts.push('</div>');
    return parts.join('');
  }

  /* ---------------------------------------------------------------- 默认值 / 位置环文案 */

  function defaultValues() {
    var values = {};
    for (var i = 0; i < ORDER.length; i += 1) {
      values[ORDER[i]] = PARAMS[ORDER[i]].default;
    }
    return values;
  }

  /** 移植 j280_debug_gui._update_position_loop_text（P/I/D 与近区切换状态）。 */
  function positionLoopText(values) {
    var source = values || {};
    var keys = ['PKP', 'PKD', 'PKDNEAR', 'POSP_LIM', 'POS_NEAR', 'PKI', 'PILIM'];
    var parsed = {};
    for (var i = 0; i < keys.length; i += 1) {
      var number = toInt(source[keys[i]]);
      if (number === null) {
        return '位置参数输入无效';
      }
      parsed[keys[i]] = number;
    }
    var gain = parsed.PKP;
    var limit = parsed.POSP_LIM;
    var kd = parsed.PKD;
    var kdNear = parsed.PKDNEAR;
    var near = parsed.POS_NEAR;
    var ki = parsed.PKI;
    var iLimit = parsed.PILIM;
    var pState = (gain === 0 || limit === 0) ? 'P 关' : 'P 开';
    var iState;
    if (!gain || !limit || !ki || !iLimit) {
      iState = 'I 关';
    } else if ((gain > 0) !== (ki > 0)) {
      iState = 'I 符号不匹配';
    } else {
      iState = 'I 已配置';
    }
    var dState = (kd === 0 && (near === 0 || kdNear === 0)) ? 'D 阻尼关' : 'D 阻尼开';
    var zone = (near > 0) ? '近区切换开' : '单一 PKD';
    return pState + ' / ' + iState + ' / ' + dState + ' / ' + zone;
  }

  /* ---------------------------------------------------------------- 参数行 DOM */

  /**
   * 生成一行参数控件。
   * callbacks = {onInput(name,parsed), onEnter(name), onNudge(name,dir), onSend(name),
   *              onTipEnter(name,rowEl), onTipLeave()}
   *
   * 控件类型由 CONTROLS[name] 决定：dial（POSTGT 圆形表盘）/ range（滑杆+输入框）
   * / choice（离散下拉）/ 缺省（输入框 + ±）。
   */
  function createParamRow(name, callbacks) {
    var key = String(name == null ? '' : name).toUpperCase();
    var meta = hasOwn.call(PARAMS, key) ? PARAMS[key] : null;
    var cb = callbacks || {};
    var range = hasOwn.call(RANGES, key) ? RANGES[key] : [0, 0];
    var control = hasOwn.call(CONTROLS, key) ? CONTROLS[key] : {type: 'default'};
    var controlType = control.type || 'default';
    var call = function (fn, a, b) {
      if (typeof fn === 'function') {
        fn(a, b);
      }
    };

    var row = document.createElement('div');
    row.className = 'param-row' + (controlType === 'default' ? '' : ' has-' + controlType);
    row.setAttribute('data-name', key);
    row.setAttribute('data-state', 'default');

    var dot = document.createElement('span');
    dot.className = 'param-dot';
    dot.setAttribute('data-state', 'default');
    dot.title = '';

    var metaDiv = document.createElement('div');
    metaDiv.className = 'param-meta';
    var labelEl = document.createElement('b');
    labelEl.className = 'param-label';
    labelEl.textContent = meta ? meta.label : key;
    var subEl = document.createElement('small');
    subEl.className = 'param-sub';
    subEl.textContent = key;
    metaDiv.appendChild(labelEl);
    metaDiv.appendChild(subEl);

    var input;
    if (controlType === 'choice') {
      input = document.createElement('select');
      input.className = 'param-select';
      (control.options || range).forEach(function (optionValue) {
        var option = document.createElement('option');
        option.value = String(optionValue);
        option.textContent = (control.labels && control.labels[String(optionValue)])
          ? control.labels[String(optionValue)] : String(optionValue);
        input.appendChild(option);
      });
    } else {
      input = document.createElement('input');
      input.className = 'param-input';
      input.type = 'text';
      input.setAttribute('inputmode', 'numeric');
      input.spellcheck = false;
      input.autocomplete = 'off';
    }

    var actions = document.createElement('div');
    actions.className = 'param-actions';
    var nudgeDown = null;
    var nudgeUp = null;
    if (controlType === 'default' && key !== 'TURNS_POSTGT') {
      nudgeDown = document.createElement('button');
      nudgeDown.type = 'button';
      nudgeDown.className = 'mini-btn nudge';
      nudgeDown.setAttribute('data-dir', '-1');
      nudgeDown.title = '按步长调小（不自动发送）';
      nudgeDown.textContent = '−';
      nudgeUp = document.createElement('button');
      nudgeUp.type = 'button';
      nudgeUp.className = 'mini-btn nudge';
      nudgeUp.setAttribute('data-dir', '1');
      nudgeUp.title = '按步长调大（不自动发送）';
      nudgeUp.textContent = '+';
      actions.appendChild(nudgeDown);
      actions.appendChild(nudgeUp);
    }
    var send = document.createElement('button');
    send.type = 'button';
    send.className = 'mini-btn send';
    send.title = '发送本项参数';
    send.textContent = '发送';
    var absToggle = null;
    if (key === 'TURNS_POSTGT') {
      absToggle = document.createElement('button');
      absToggle.type = 'button';
      absToggle.className = 'mini-btn abs-edit';
      absToggle.title = '显示 / 收起指定运动轨迹卡片';
      absToggle.textContent = '设置';
      absToggle.addEventListener('click', function (event) {
        event.preventDefault();
        call(cb.onAbsEdit, key);
      });
      actions.appendChild(absToggle);
    }
    actions.appendChild(send);

    row.appendChild(dot);
    row.appendChild(metaDiv);
    row.appendChild(input);
    row.appendChild(actions);

    /* ---------------------------------------------------------- 滑杆 */
    var slider = null;
    if (controlType === 'range') {
      var sliderLine = document.createElement('div');
      sliderLine.className = 'param-slider-line';
      var minLabel = document.createElement('span');
      minLabel.className = 'param-slider-min';
      minLabel.textContent = String(range[0]);
      var maxLabel = document.createElement('span');
      maxLabel.className = 'param-slider-max';
      maxLabel.textContent = String(range[1]);
      slider = document.createElement('input');
      slider.type = 'range';
      slider.className = 'param-slider';
      slider.min = String(range[0]);
      slider.max = String(range[1]);
      slider.step = String(control.step || 1);
      slider.setAttribute('aria-label', key + ' 滑杆');
      sliderLine.appendChild(minLabel);
      sliderLine.appendChild(slider);
      sliderLine.appendChild(maxLabel);
      row.appendChild(sliderLine);
      slider.addEventListener('input', function () {
        input.value = slider.value;
        call(cb.onInput, key, parseIntEntry(slider.value));
      });
    }

    /* ---------------------------------------------------------- 圆形表盘（POSTGT） */
    var dialCanvas = null;
    var drawDial = null;
    var dialValue = 0;
    if (controlType === 'dial') {
      var DIAL_LOW = -520;
      var DIAL_SPAN = 1040;
      var DIAL_SIZE = 160;
      var dialWrap = document.createElement('div');
      dialWrap.className = 'param-dial-wrap';
      dialCanvas = document.createElement('canvas');
      dialCanvas.className = 'param-dial';
      dialCanvas.width = DIAL_SIZE * 2;
      dialCanvas.height = DIAL_SIZE * 2;
      dialCanvas.style.width = DIAL_SIZE + 'px';
      dialCanvas.style.height = DIAL_SIZE + 'px';
      dialCanvas.tabIndex = 0;
      dialCanvas.setAttribute('role', 'slider');
      dialCanvas.setAttribute('aria-label', '位置目标 POSTGT（-520 到 519 单圈）');
      dialCanvas.setAttribute('aria-valuemin', String(DIAL_LOW));
      dialCanvas.setAttribute('aria-valuemax', String(DIAL_LOW + DIAL_SPAN - 1));
      dialWrap.appendChild(dialCanvas);
      row.appendChild(dialWrap);

      function normalizeDial(value) {
        var number = Math.round(Number(value));
        if (!isFinite(number)) return 0;
        return ((number - DIAL_LOW) % DIAL_SPAN + DIAL_SPAN) % DIAL_SPAN + DIAL_LOW;
      }

      drawDial = function () {
        var ctx = dialCanvas.getContext('2d');
        if (!ctx) return;
        var size = DIAL_SIZE;
        var dpr = 2;
        if (dialCanvas.width !== size * dpr) {
          dialCanvas.width = size * dpr;
          dialCanvas.height = size * dpr;
        }
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.clearRect(0, 0, size, size);
        var cx = size / 2;
        var cy = size / 2;
        var radius = size / 2 - 26;
        var start = -Math.PI / 2;

        // 底环
        ctx.lineWidth = 9;
        ctx.strokeStyle = 'rgba(63, 227, 255, 0.15)';
        ctx.beginPath();
        ctx.arc(cx, cy, radius, 0, Math.PI * 2);
        ctx.stroke();

        // 刻度：52 格（每 20 count），每 13 格为主刻度
        for (var i = 0; i < 52; i++) {
          var angle = i / 52 * Math.PI * 2;
          var major = (i % 13 === 0);
          var r1 = radius + (major ? 7 : 3);
          var r2 = radius + 10;
          ctx.beginPath();
          ctx.strokeStyle = major ? 'rgba(63, 227, 255, 0.55)' : 'rgba(63, 227, 255, 0.20)';
          ctx.lineWidth = major ? 1.5 : 1;
          ctx.moveTo(cx + Math.sin(angle) * r1, cy - Math.cos(angle) * r1);
          ctx.lineTo(cx + Math.sin(angle) * r2, cy - Math.cos(angle) * r2);
          ctx.stroke();
        }

        // 数值弧（0 在顶部，正数顺时针）
        var value = normalizeDial(dialValue);
        var valueAngle = value / DIAL_SPAN * Math.PI * 2;
        if (Math.abs(valueAngle) > 0.001) {
          ctx.beginPath();
          ctx.lineWidth = 4;
          ctx.strokeStyle = '#3fe3ff';
          ctx.shadowColor = 'rgba(63, 227, 255, 0.75)';
          ctx.shadowBlur = 8;
          ctx.arc(cx, cy, radius, start, start + valueAngle, valueAngle < 0);
          ctx.stroke();
          ctx.shadowBlur = 0;
        }

        // 指针
        var px = cx + Math.sin(valueAngle) * radius;
        var py = cy - Math.cos(valueAngle) * radius;
        ctx.beginPath();
        ctx.strokeStyle = '#ffc247';
        ctx.lineWidth = 2;
        ctx.moveTo(cx, cy);
        ctx.lineTo(px, py);
        ctx.stroke();
        ctx.beginPath();
        ctx.fillStyle = '#ffc247';
        ctx.arc(px, py, 4, 0, Math.PI * 2);
        ctx.fill();

        // 中心数值
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillStyle = '#eaf9ff';
        ctx.font = '600 22px Consolas, "Cascadia Mono", monospace';
        ctx.fillText((value > 0 ? '+' : '') + value, cx, cy - 6);
        ctx.fillStyle = '#6f93a9';
        ctx.font = '9px Consolas, "Cascadia Mono", monospace';
        ctx.fillText('count', cx, cy + 13);

        // 关键刻度文字
        ctx.font = '9px Consolas, "Cascadia Mono", monospace';
        ctx.fillStyle = '#7fa3b8';
        ctx.fillText('0', cx, cy - radius - 13);
        ctx.fillText('+260', cx + radius + 13, cy);
        ctx.fillText('-260', cx - radius - 13, cy);
      };

      function setDialValue(value, notify) {
        dialValue = normalizeDial(value);
        input.value = String(dialValue);
        dialCanvas.setAttribute('aria-valuenow', String(dialValue));
        drawDial();
        if (notify) {
          call(cb.onInput, key, {ok: true, value: dialValue, error: null});
        }
      }

      function valueFromPointer(event) {
        var rect = dialCanvas.getBoundingClientRect();
        var dx = event.clientX - (rect.left + rect.width / 2);
        var dy = event.clientY - (rect.top + rect.height / 2);
        if (Math.abs(dx) < 0.01 && Math.abs(dy) < 0.01) return dialValue;
        var angle = Math.atan2(dx, -dy);
        return normalizeDial(Math.round(angle / (Math.PI * 2) * DIAL_SPAN));
      }

      var dialDragging = false;
      dialCanvas.addEventListener('pointerdown', function (event) {
        dialDragging = true;
        try { dialCanvas.setPointerCapture(event.pointerId); } catch (err) { /* ignore */ }
        setDialValue(valueFromPointer(event), true);
        dialCanvas.focus();
        event.preventDefault();
      });
      dialCanvas.addEventListener('pointermove', function (event) {
        if (!dialDragging) return;
        setDialValue(valueFromPointer(event), true);
      });
      function stopDialDrag(event) {
        if (!dialDragging) return;
        dialDragging = false;
        try { dialCanvas.releasePointerCapture(event.pointerId); } catch (err) { /* ignore */ }
      }
      dialCanvas.addEventListener('pointerup', stopDialDrag);
      dialCanvas.addEventListener('pointercancel', stopDialDrag);
      dialCanvas.addEventListener('wheel', function (event) {
        event.preventDefault();
        var step = control.step || 10;
        setDialValue(dialValue + (event.deltaY < 0 ? step : -step), true);
      }, {passive: false});
      dialCanvas.addEventListener('keydown', function (event) {
        var step = control.step || 10;
        if (event.key === 'ArrowUp' || event.key === 'ArrowRight') {
          event.preventDefault();
          setDialValue(dialValue + step, true);
        } else if (event.key === 'ArrowDown' || event.key === 'ArrowLeft') {
          event.preventDefault();
          setDialValue(dialValue - step, true);
        } else if (event.key === 'Home') {
          event.preventDefault();
          setDialValue(0, true);
        }
      });
      row._drawDial = drawDial;
      row._setDialValue = setDialValue;
      dialValue = 0;
      drawDial();
    }

    /* ---------------------------------------------------------- 事件绑定 */
    if (controlType === 'choice') {
      input.addEventListener('change', function () {
        call(cb.onInput, key, parseIntEntry(input.value));
      });
    } else {
      input.addEventListener('input', function () {
        var parsed = parseIntEntry(input.value);
        if (slider && parsed.ok) {
          slider.value = String(Math.min(Math.max(parsed.value, Number(slider.min)),
            Number(slider.max)));
        }
        if (dialCanvas && parsed.ok) {
          if (parsed.value >= -520 && parsed.value <= 519) {
            dialValue = ((parsed.value - (-520)) % 1040 + 1040) % 1040 + (-520);
            drawDial();
          }
        }
        call(cb.onInput, key, parsed);
      });
      input.addEventListener('keydown', function (event) {
        var isEnter = event.key === 'Enter' || event.keyCode === 13;
        if (isEnter) {
          event.preventDefault();
          call(cb.onEnter, key);
        }
      });
    }

    if (nudgeDown && nudgeUp) {
      var onNudgeClick = function (event) {
        event.preventDefault();
        var dir = Number(this.getAttribute('data-dir'));
        call(cb.onNudge, key, dir < 0 ? -1 : 1);
      };
      nudgeDown.addEventListener('click', onNudgeClick);
      nudgeUp.addEventListener('click', onNudgeClick);
    }
    send.addEventListener('click', function (event) {
      event.preventDefault();
      call(cb.onSend, key);
    });
    row.addEventListener('mouseenter', function () {
      call(cb.onTipEnter, key, row);
    });
    row.addEventListener('mouseleave', function () {
      call(cb.onTipLeave);
    });
    row.addEventListener('focusin', function () {
      call(cb.onTipEnter, key, row);
    });
    row.addEventListener('focusout', function () {
      call(cb.onTipLeave);
    });

    function setValue(value) {
      var text = (value === null || value === undefined) ? '' : String(value);
      input.value = text;
      var parsed = parseIntEntry(text);
      if (slider && parsed.ok) {
        slider.value = String(Math.min(Math.max(parsed.value, Number(slider.min)),
          Number(slider.max)));
      }
      if (dialCanvas) {
        if (parsed.ok && parsed.value >= -520 && parsed.value <= 519) {
          dialValue = ((parsed.value - (-520)) % 1040 + 1040) % 1040 + (-520);
        } else {
          dialValue = 0;
        }
        drawDial();
      }
    }

    function getText() {
      return input.value.trim();
    }

    function setStatus(state, tooltipText) {
      var next = state || 'default';
      if (['default', 'sent', 'dirty', 'invalid'].indexOf(next) < 0) {
        next = 'default';
      }
      dot.setAttribute('data-state', next);
      row.setAttribute('data-state', next);   // style.css 会据此给整行/输入框着色
      dot.title = (tooltipText == null) ? '' : String(tooltipText);
      if (next === 'invalid') {
        input.setAttribute('aria-invalid', 'true');
        input.classList.add('invalid');
      } else {
        input.removeAttribute('aria-invalid');
        input.classList.remove('invalid');
      }
    }

    return {
      el: row,
      input: input,
      dot: dot,
      slider: slider,
      dial: dialCanvas,
      setValue: setValue,
      getText: getText,
      setStatus: setStatus
    };
  }

  global.J280Params = {
    PARAMS: PARAMS,
    RANGES: RANGES,
    NUDGE: NUDGE,
    CONTROLS: CONTROLS,
    GROUPS: GROUPS,
    ORDER: ORDER,
    parseIntEntry: parseIntEntry,
    validate: validate,
    supportsParameter: supportsParameter,
    ABS_COUNTS: ABS_COUNTS,
    absDecompose: absDecompose,
    absCompose: absCompose,
    absPhaseBounds: absPhaseBounds,
    nudge: nudge,
    tooltipHtml: tooltipHtml,
    defaultValues: defaultValues,
    positionLoopText: positionLoopText,
    createParamRow: createParamRow
  };
})(typeof window !== 'undefined' ? window : this);
