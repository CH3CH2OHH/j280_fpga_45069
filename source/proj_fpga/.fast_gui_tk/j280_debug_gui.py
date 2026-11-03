#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""J280 运动与平衡调试台 · 1040（兼容s/t/u/v/w/x固件）。

相对旧版的主要变化
  * 波形：深色示波器风格、时间轴按帧序号生成（不再受串口成块到达影响）；
    默认“趋势”模式用 40 ms 低通折线显示，原始模式保留每像素列 min/max 包络；
    Y 轴平滑自动缩放、十字光标跨图联动读数、可暂停/回看、点击图例开关曲线、
    目标线/限幅线/死区线叠加，图例旁显示当前值。
  * 参数：每个参数悬浮提示（含义、单位、范围、推荐值、调大/调小的影响），
    输入校验着色、改动未下发标记、±微调按钮、回车即发送；支持把全部参数
    保存为 JSON 配置，或从 JSON 载入并按协议范围逐项校验。
  * 记录：图表下方“开始记录 / 停止并保存…”把遥测写入独立缓冲区并导出 CSV；
    实时曲线始终照常显示，不受记录状态影响。
  * 诊断：固定高度、可滚动的摆动分析区，自动估计位置/角度摆动幅度与频率、
    输出换向频率，给出调参提示。

纯逻辑函数（nice_ticks / envelope / split_wrap / window_stats /
estimate_oscillation / smooth_range）不依赖 Tk，便于离线测试。
"""

import bisect
import csv
import json
import math
import time
import tkinter as tk
from capture_transition import CaptureTransition, prepare_capture, read_capture
from collections import deque
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

try:
    import serial
    from serial.tools import list_ports
except ImportError as error:
    raise SystemExit("需要 pyserial：python -m pip install pyserial") from error

from j280_protocol import (PARAM, PARAM_RANGES, frame, parse_telemetry,
                           table_self_check, validate_value, supports_parameter)


ENC_CPR = 1040
TELEM_HZ = 100.0              # msg_tx 每秒发送帧数（时间轴按帧序号生成）
BUFFER_MAX = 60000
STATE_PATH = Path(__file__).with_name("j280_debug_gui_state.json")
PRESET_DIR = Path(__file__).with_name("data")

# --------------------------------------------------------------------------
# 参数表：(中文名, 默认值, 单位, 一句话说明)  —— 与旧版保持同构，测试依赖该结构
# --------------------------------------------------------------------------
PARAMS = {
    "HOLDPOS": ("稳定保持容差", 70, "count", "需Vy：0关闭；位置误差在容差内且持续稳定600ms后冻结位置积分，角度闭环及P/D继续纠偏；受扰自动退出。"),
    "AKP": ("比例增益", -150, "Q8 PWM/0.01°", "误差越大，输出越大；正负号决定角度纠正方向。"),
    "AKI": ("积分增益", 0, "Q8 PWM/(°·s)", "消除持续偏差；本结构中建议保持 0（见悬浮提示）。"),
    "AKD": ("微分增益", -400, "Q8 PWM/(°/s)", "按角速度提供阻尼；噪声过大时减小增益或增大 DLP。"),
    "PKP": ("位置比例", 600, "Q8 0.01°/count", "按单圈位置误差修正角度目标；位置 P 项需通过 POSP_LIM 启用。"),
    "PKD": ("位置速度阻尼", -300, "Q8 0.01°/(count/s)", "按编码器速度提供阻尼；符号与角度环增益、编码器方向有关。"),
    "PKI": ("慢速位置积分", 8, "Q8 cdeg/(count·s)", "s版对持续偏差积分，带±2 count软死区；目标静止500ms后学习，运动和饱和时冻结。"),
    "PILIM": ("位置积分限幅", 45, "0.01°", "限制位置积分角度补偿；0 关闭，停机清零。"),
    "PIDEAD": ("积分位置软死区", 4, "count", "仅t/u/v/w/x固件：2保留原行为，1/0提高慢偏差精度，须观察复振。"),
    "KDBLEND": ("阻尼切换渐变", 0, "移位", "仅t/u/v/w/x固件：0直接切换，4约15ms渐变远近阻尼系数。"),
    "VELMODE": ("低速测速方式", 1, "模式", "仅v/w/x固件：0净位移窗口，1低速周期辅助；反向/高速自动回退窗口。"),
    "ADCAVG": ("控制前ADC平均", 2, "移位", "需w/x固件：0/1/2/3平均1/2/4/8组；3约0.819ms，须实机对照。"),
    "RATEMODE": ("角速度算法", 2, "模式", "需x固件：0原窗口微分+DLP，1快速观测，2平滑观测；观测模式的D反馈绕过DLP，ALP继续生效。"),
    "RLP": ("参考平滑", 4, "移位", "只平滑位置角度参考；4约15ms，为当前实测保留值，0旁路。"),
    "POSMAX": ("位置修正上限", 600, "0.01°", "位置环允许改变角度目标的最大幅度。"),
    "POSTGT": ("位置目标", 0, "count", "单圈有符号目标，范围 -520..+519；位置环关闭时不起作用。"),
    "TURNS_POSTGT": ("绝对位置目标/转圈目标", 0, "count",
                     "MODE3 使用的绝对编码器计数目标，替代 POSTGT；signed 16 全范围 -32768..32767。"),
    "POS_NEAR": ("近目标范围", 0, "count", "进入目标附近时切换到 PKDNEAR；0=关闭切换（推荐）。"),
    "PKDNEAR": ("近目标阻尼", -300, "Q8 0.01°/(count/s)", "进入 POS_NEAR 区后使用；POS_NEAR=0 时不起作用。"),
    "POSP_LIM": ("位置 P 限幅", 427, "0.01°；0=关闭", "限制位置 P 项对角度参考的贡献；设 0 可关闭位置 P 回中。"),
    "ENTER": ("接管角度", 1000, "0.01°", "|ANG-TRIM| 不大于此值并连续满足约 4 ms 后接管。"),
    "FALL": ("判倒角度", 1500, "0.01°", "接管后超出此角度约 10 ms，锁止电机输出。"),
    "TRIM": ("目标微调", 20, "0.01°", "角度目标偏置；只在 RAW_ZERO 标定后微调。"),
    "LIM": ("PWM 限幅", 300, "duty / 1023", "限制电机命令幅度；实物调试仍须从低值开始。"),
    "DZ": ("摩擦补偿", 20, "duty", "当前实测保留20；加大补偿或收窄过渡区可能再次激发振荡。"),
    "DZW": ("补偿过渡宽度", 64, "duty", "2 的幂；过宽会推不动小命令，过窄会放大噪声。"),
    "DZLP": ("补偿支路滤波", 1, "移位", "只平滑摩擦补偿，原始 PD 不延迟；0 直通。"),
    "ILIM": ("积分限幅", 0, "duty", "限制积分项最大输出；AKI=0 时不产生作用。"),
    "DLP": ("微分滤波", 3, "移位", "每 1 ms 更新一次；0 为直通，数值越大滤波越强、滞后越大。"),
    "ALP": ("角度低通", 1, "移位", "控制用角度低通；数值越大越平滑，但延迟也越大。"),
    "SLEW": ("PWM 变化率", 0, "duty/毫秒", "限制 PWM 每毫秒变化量；0 表示关闭。"),
    "SWLIM": ("起摆限幅", 750, "duty", "自动起摆专用 PWM 限幅；当前默认提高动力但仍保留余量。"),
    "SWAMP": ("起摆幅度", 670, "duty", "线性软启动后的目标幅度，实际不超过 SWLIM。"),
    "SWRAMP": ("起摆软启动", 200, "ms", "从 0 线性增加到目标幅度的时间。"),
    "SWMS": ("捕获确认", 3, "ms", "角度与角速度条件连续满足该时间后请求接管。"),
    "SWCAP": ("起摆捕获角", 800, "0.01°", "相对 TRIM 的角度进入窗口且角速度不超过 100°/s 时切换角度环。"),
    "SWTMO": ("起摆超时", 15000, "ms", "超过时间仍未捕获则停机并置故障。"),
    "SWDIR": ("起摆方向", 1, "±1", "起摆相位方向；运动趋势相反时改为 -1。"),
    "ZERO": ("ADC 竖直零点", 508, "ADC 码", "摆杆竖直时的 RAW；保留原 508 标定；TRIM 补偿有效平衡偏角。"),
}

# 悬浮提示的详细内容：up=调大的影响，down=调小的影响，rec=v2 推荐值，tip=调参要点
PARAM_HELP = {
    "AKP": dict(rec="-160",
                up="|AKP| 增大：回复力更强、站得更“硬”，但高频更易抖动，并放大位置内环增益。",
                down="|AKP| 减小：更软、更慢；电机死区对应的角度误差变大，可能出现慢摆。",
                tip="经验：死区 ÷ (|AKP|/256×100) ≈ 摆杆需要偏多少度电机才开始动；越小越好。"),
    "AKI": dict(rec="0",
                up="增大：积分与“摆臂速度≈占空比”的对象叠加成二重积分，位置容易出现慢速正弦摆动。",
                down="减小/置 0：位置外环已能消除偏差，且 TRIM 可修正零点偏差。",
                tip="本系统电机相当于速度执行器，角度积分会和位置环打架，建议保持 0。"),
    "AKD": dict(rec="-320",
                up="|AKD| 增大：阻尼更强，但对噪声/滞后更敏感，过大可能增加高频换向和啸叫。",
                down="|AKD| 减小：站立刚度下降，角度收敛慢；太小则无法稳定。",
                tip="本对象中 D 项同时提供“刚度”，其滞后(DLP/ALP)比数值本身更关键。"),
    "PKP": dict(rec="300",
                up="增大：回到目标更快，但位置慢模态阻尼变差，超调与慢摆增多。",
                down="减小：回中更软、更稳，但静态误差与回中速度变差。",
                tip="先固定 PKD，再从 200 往上加；出现 0.2~0.5 Hz 慢摆就回退。"),
    "PKD": dict(rec="-400",
                up="|PKD| 增大：位置慢模态阻尼更好；过大会与角度内环形成过强反馈，增加高频抖动。",
                down="|PKD| 减小：位置摆动不易衰减，超调变大。",
                tip="16ms 窗每计数对应62.5 count/s；RLP 平滑参考台阶，过大仍会增加延迟。"),
    "PKI": dict(rec="48", up="加快消除静差，但过大易形成慢振荡。", down="0 关闭。", tip="符号应与 PKP 一致；与角度积分 AKI 独立。"),
    "PILIM": dict(rec="60", up="允许更大的偏角补偿。", down="0 关闭位置积分。", tip="单位0.01°，当前实测保留最多±0.6°。"),
    "RLP": dict(rec="4", up="降低测速量化引起的参考跳变，同时增加位置反馈延迟。", down="0 直通参考。", tip="当前实测保留4；5/6的现场恢复试验未改善，不宜继续盲目加大。"),
    "POSMAX": dict(rec="600",
                   up="增大：允许位置环把摆杆目标倾得更大，回中更快，但跟踪时摆杆倾斜更大。",
                   down="减小：限制倾角，位置纠偏变慢。",
                   tip="通常 400~700（4~7°）；过小会使位置环“推不动”。"),
    "POSTGT": dict(rec="0",
                   up="目标位置（单圈计数，-520..519），位置环按此目标修正。",
                   down="在输入框直接改目标并发送；目标阶跃过大会让摆杆瞬间倾斜，建议小步修改。",
                   tip="位置环关闭（POSP_LIM=0）时不起作用；改目标后观察位置误差与摆杆倾角。"),
    "TURNS_POSTGT": dict(rec="0",
                         up="MODE3 的绝对编码器计数目标，signed 16 全范围 -32768..32767；与屏幕 P 行同一参数。",
                         down="在 MODE3 平衡时改目标会让位置外环按新目标重新收敛；阶跃过大时先小步改。",
                         tip="只在 MODE3 生效并完全替代 POSTGT；编码器累计计数低 16 位按 signed 解释。"),
    "POS_NEAR": dict(rec="0",
                     up="大于 0：目标附近自动换用 PKDNEAR。该切换会让调试时的 PKD 不再是实际生效值。",
                     down="0：关闭切换，只有 PKD 生效，调参结果可复现。",
                     tip="旧默认 200 + PKDNEAR=-546 在补偿好死区后会诱发高频抖动，建议 0。"),
    "PKDNEAR": dict(rec="-400",
                    up="仅在 POS_NEAR>0 时生效；|值|越大近区阻尼越强，也越易抖。",
                    down="与 PKD 取同值即相当于不切换。",
                    tip="POS_NEAR=0 时本项无作用，建议与 PKD 同值。"),
    "POSP_LIM": dict(rec="427",
                     up="增大：位置 P 对角度参考的最大贡献更大。",
                     down="0：关闭位置 P 回中，仅速度阻尼起作用（首次方向确认时可用）。",
                     tip="PKP×最大位置误差超过此值就会饱和。"),
    "ENTER": dict(rec="1000",
                  up="增大：更远的角度也允许接管，接管瞬间冲击更大。",
                  down="减小：必须扶得更正才接管。",
                  tip="必须小于 FALL。"),
    "FALL": dict(rec="1500",
                 up="增大：更晚判倒，增加保护延迟。",
                 down="减小：更早锁止，扰动稍大就停机。",
                 tip="必须大于 ENTER。"),
    "TRIM": dict(rec="-40",
                 up="正/负偏置会改变“竖直”目标；零点不准会让摆臂持续向一侧漂移。",
                 down="先用 ZERO 标定，再用 TRIM 微调到摆臂不再单向漂移。",
                 tip="单位 0.01°，1 个 ADC 码约 0.33°。"),
    "LIM": dict(rec="300",
                up="增大：更大的纠偏能力，也更危险。",
                down="减小：更安全，但抗扰能力下降；扣除死区后可用范围会变小。",
                tip="扣除摩擦补偿后需保留足够纠偏余量；长时间饱和时先查方向、标定和负载。"),
    "DZ": dict(rec="20",
               up="增大：更好抵消电机死区；超过真实死区会在零附近换向抖动。",
               down="减小：死区未补偿，摆杆需偏更多角度电机才动，出现慢摆与位置不收敛。",
               tip="20为用户确认保留的s实测值，不等同电机物理静摩擦门槛。"),
    "DZW": dict(rec="64", up="过渡更缓，小命令实际推力变小。", down="更接近完整静摩擦补偿，也更易放大噪声。", tip="必须为2的幂；当前保留64，较窄补偿的实测未持续改善。"),
    "DZLP": dict(rec="0", up="抑制摩擦补偿反转，但会延迟过零。", down="0 直通。", tip="只滤补偿，不滤整个 PWM，建议 1~2。"),
    "ILIM": dict(rec="0",
                 up="积分最大输出；AKI=0 时无作用。",
                 down="0：关闭积分。",
                 tip="积分上限接近死区宽度时会把电机“顶开”造成粘滑。"),
    "DLP": dict(rec="2",
                up="增大：微分更平滑，但滞后增加（DLP=4 时约 16 ms），会降低 D 项相位裕度，引起角度振荡。",
                down="减小：滞后小、阻尼更及时；噪声大时会抖。",
                tip="需结合 ALP 对照原始角度与输出；每次只改一项，避免累计过大延迟。"),
    "ALP": dict(rec="1",
                up="增大：角度更平滑但延迟更大。",
                down="0：直通；ADC 已做 512 点平均，通常无需再滤。",
                tip="ALP 与 DLP 滞后叠加，优先压低二者。"),
    "SLEW": dict(rec="0",
                 up="限制 PWM 变化率，可压噪声，但相当于增加滞后。",
                 down="0：关闭。",
                 tip="站立控制不建议开启。"),
    "SWLIM": dict(rec="750", up="起摆最大 PWM。", down="更保守。", tip="保留现场验证的 750 duty 上限。"),
    "SWAMP": dict(rec="670", up="起摆力度更大。", down="起摆更温和。", tip="实际不超过 SWLIM。"),
    "SWRAMP": dict(rec="200", up="软启动更慢。", down="软启动更快。", tip="单位 ms。"),
    "SWMS": dict(rec="3", up="捕获确认更严格。", down="更快请求接管。", tip="单位 ms。"),
    "SWCAP": dict(rec="800", up="捕获窗口更宽，更早切入平衡环。", down="更严格。", tip="单位 0.01°。"),
    "SWTMO": dict(rec="15000", up="允许更长的起摆时间。", down="更快超时停机。", tip="单位 ms。"),
    "SWDIR": dict(rec="1", up="+1/-1 切换起摆相位方向。", down="运动趋势相反时改号。", tip="仅起摆使用。"),
    "ZERO": dict(rec="508",
                 up="ADC 竖直零点；改变会整体平移角度读数。",
                 down="摆杆自然竖直时的 RAW 值。",
                 tip="手扶竖直时读取 RAW 标定。"),
}

NUDGE_STEP = {"AKP": 5, "AKI": 2, "AKD": 10, "PKP": 10, "PKD": 10, "POSMAX": 20,
              "POS_NEAR": 10, "PKDNEAR": 10, "POSP_LIM": 20, "ENTER": 50, "FALL": 100,
              "TRIM": 5, "LIM": 10, "DZ": 5, "ILIM": 5, "DLP": 1, "ALP": 1, "SLEW": 1,
              "SWLIM": 20, "SWAMP": 20, "SWRAMP": 20, "SWMS": 5, "SWCAP": 20,
              "SWTMO": 500, "SWDIR": 2, "ZERO": 1, "POSTGT": 10, "TURNS_POSTGT": 100,
              "PKI": 2, "PILIM": 10, "RLP": 1, "DZW": 1, "DZLP": 1}

PARAM_HELP.update({
    "PIDEAD":dict(rec="2（保留）/1（候选）",up="减少追逐噪声，但允许更大残差。",down="提高位置精度，须排除再次复振。",tip="仅影响慢积分，不屏蔽角度PD和位置P/D；需t/u/v/w固件。"),
    "KDBLEND":dict(rec="0（保留）/4（候选）",up="平缓远近区增益变化，过大则阻尼调整变慢。",down="切换更快，但可能产生角度参考突变。",tip="平滑系数而非测速反馈，不延迟原始角度PD；需t/u/v/w固件。"),
})
NUDGE_STEP.update(PIDEAD=1,KDBLEND=1)
PARAM_HELP['VELMODE']=dict(rec='0（回退）/1（实测对照）',up='使用同向低速编码器周期减少速度台阶。',down='恢复原16ms净位移窗口。',tip='需v/w/x固件；周期法停止后存在速度衰减尾部，应结合位置误差判断静止。')
NUDGE_STEP['VELMODE']=1
PARAM_HELP['ADCAVG']=dict(rec='0（回退）/3（对照）',up='控制采样前使用更多ADC样本，减小混叠与电机载波串扰。',down='减少测量延迟，0保持原单组平均。',tip='0/1/2/3对应1/2/4/8组，默认组长102.4us；不影响RAW健康检测。需w/x固件，待实测。')
NUDGE_STEP['ADCAVG']=1
PARAM_HELP['RATEMODE']=dict(rec='0（回退）/1/2（待实测）',up='用角度与角速度两状态预测校正，减少差分对噪声的放大。',down='0恢复原微分窗口及DLP。',tip='1约3.5ms、2约7.5ms低频等效滞后；选择观测后DLP不作用于该路D反馈。ALP仍生效，需x固件实测。')
NUDGE_STEP['RATEMODE']=1
PARAM_HELP['HOLDPOS']=dict(rec='0关闭 / 70（Vy实测）',up='允许更大的稳定位置偏差，减少积分追零。',down='缩小保持容差，0恢复连续位置积分。',tip='需Vy；稳定600ms后仅冻结位置积分，摆角和速度闭环继续工作，受扰自动退出；人工推扰尚未验收。')
NUDGE_STEP['HOLDPOS']=5

GROUPS = (
    ("角度 PID", ("AKP", "AKI", "AKD")),
    ("编码器位置外环", ("PKP", "PKD", "PKI", "PILIM", "PIDEAD", "KDBLEND", "VELMODE", "RLP", "POS_NEAR", "PKDNEAR", "POSP_LIM", "POSMAX", "POSTGT", "TURNS_POSTGT")),
    ("接管、保护与 PWM", ("ENTER", "FALL", "LIM", "DZ", "DZW", "DZLP", "ILIM")),
    ("标定与滤波", ("ZERO", "TRIM", "DLP", "RATEMODE", "ALP", "ADCAVG", "SLEW")),
    ("容差保持", ("HOLDPOS",)),
    ("自动起摆", ("SWAMP", "SWLIM", "SWRAMP", "SWMS", "SWCAP", "SWTMO", "SWDIR")),
)

PRESETS = {
    "config0": "config0.json",
}

# 曲线样式：名称 -> (颜色, 单位)
SERIES_STYLE = {
    "ANG": ("#ff6b5e", "°"), "REF": ("#ffc247", "°"), "RAW": ("#5ad1a4", "ADC"),
    "POS": ("#5aa9ff", "count"), "TGT": ("#a9c7ff", "count"),
    "SPD": ("#4fd6c2", "count/s"), "DUT": ("#c79bff", "duty"),
}

THEME = dict(bg="#0f1720", grid="#1f2d3b", grid2="#182534", axis="#8aa0b4",
             text="#d6e2ee", dim="#6c8296", zero="#34506b", band="#2a3b4d",
             cross="#e9f1f8", warn="#e8b45a")


# --------------------------------------------------------------------------
# 纯逻辑函数（可离线测试）
# --------------------------------------------------------------------------
def nice_ticks(low, high, count=5):
    """返回 [low, high] 内约 count 个“整齐”刻度。"""
    if not (math.isfinite(low) and math.isfinite(high)):
        return []
    span = high - low
    if span <= 0:
        return [low]
    raw = span / max(1, count)
    magnitude = 10 ** math.floor(math.log10(raw))
    step = 10 * magnitude
    for factor in (1, 2, 2.5, 5, 10):
        step = factor * magnitude
        if raw <= step:
            break
    first = math.ceil(low / step) * step
    ticks, value = [], first
    while value <= high + step * 1e-9 and len(ticks) < 50:
        ticks.append(round(value, 10))
        value += step
    return ticks


def format_tick(value):
    """按量级选择小数位数，避免出现 -0.0。"""
    if abs(value) < 1e-9:
        return "0"
    if abs(value) >= 100:
        return f"{value:.0f}"
    if abs(value) >= 10:
        return f"{value:.1f}".rstrip("0").rstrip(".")
    return f"{value:.2f}".rstrip("0").rstrip(".")


def split_wrap(times, values, threshold):
    """在相邻样本跳变超过 threshold 处切段（用于单圈位置回绕）。"""
    segments, current = [], []
    previous = None
    for stamp, value in zip(times, values):
        if (threshold is not None and previous is not None
                and abs(value - previous) > threshold):
            if current:
                segments.append(current)
            current = []
        current.append((stamp, value))
        previous = value
    if current:
        segments.append(current)
    return segments


def _bucket_points(bucket):
    if len(bucket) <= 2:
        return bucket
    low = min(bucket, key=lambda item: item[1])
    high = max(bucket, key=lambda item: item[1])
    picks = {id(bucket[0]): bucket[0], id(bucket[-1]): bucket[-1],
             id(low): low, id(high): high}
    return sorted(picks.values(), key=lambda item: item[0])


def envelope(points, x_left, x_right, columns):
    """把 (t, v) 序列压缩为每像素列最多 4 个点（首、最小、最大、末），保留尖峰。"""
    if len(points) <= columns * 2 or columns < 2 or x_right <= x_left:
        return list(points)
    width = (x_right - x_left) / columns
    result, bucket, current_col = [], [], None
    for stamp, value in points:
        col = max(0, min(columns - 1, int((stamp - x_left) / width)))
        if current_col is None:
            current_col = col
        if col != current_col:
            result.extend(_bucket_points(bucket))
            bucket = []
            current_col = col
        bucket.append((stamp, value))
    if bucket:
        result.extend(_bucket_points(bucket))
    return result


def window_stats(values):
    """返回 (均值, RMS, 峰峰值)；空序列返回 None。"""
    if not values:
        return None
    count = len(values)
    mean = sum(values) / count
    rms = math.sqrt(sum(v * v for v in values) / count)
    return mean, rms, max(values) - min(values)


def estimate_oscillation(times, values, min_amplitude=0.0):
    """用迟滞均值穿越法估计摆动频率与半幅值。

    返回 (频率 Hz 或 None, 半幅值)；数据不足或幅值低于 min_amplitude 时频率为 None。
    """
    if len(values) < 20 or times[-1] - times[0] < 1.0:
        return None, 0.0
    mean = sum(values) / len(values)
    amplitude = (max(values) - min(values)) / 2.0
    if amplitude <= min_amplitude:
        return None, amplitude
    hyst = max(amplitude * 0.15, 1e-9)
    flips, state = [], 0
    for stamp, value in zip(times, values):
        deviation = value - mean
        if deviation > hyst and state <= 0:
            if state == -1:
                flips.append(stamp)
            state = 1
        elif deviation < -hyst and state >= 0:
            if state == 1:
                flips.append(stamp)
            state = -1
    if len(flips) < 2 or flips[-1] <= flips[0]:
        return None, amplitude
    # 相邻穿越间隔为半个周期；用首末穿越时刻平均，避免窗口端点量化误差
    return (len(flips) - 1) / (2.0 * (flips[-1] - flips[0])), amplitude


def count_reversals(values, deadband=5):
    """统计输出变号次数（忽略 |值|<=deadband 的小量）。"""
    last, count = 0, 0
    for value in values:
        sign = 1 if value > deadband else (-1 if value < -deadband else 0)
        if sign and last and sign != last:
            count += 1
        if sign:
            last = sign
    return count


def smooth_range(current, target, shrink=0.12):
    """Y 轴平滑缩放：扩张立即生效，收缩缓慢逼近，避免画面跳动。"""
    if current is None:
        return target
    low = target[0] if target[0] < current[0] else current[0] + (target[0] - current[0]) * shrink
    high = target[1] if target[1] > current[1] else current[1] + (target[1] - current[1]) * shrink
    return low, high


def diagnose(pos_freq, pos_amp, ang_freq, ang_amp, flips_per_s, duty_rms):
    """根据摆动统计给出调参提示（启发式，仅供参考）。"""
    hints = []
    if flips_per_s >= 8 and duty_rms > 25:
        hints.append("输出频繁换向：对照原始波形；先试 DZLP+1，核对 DZW/DZ；不要只凭平滑趋势加大滤波。")
    if pos_freq is not None and pos_amp > 6 and pos_freq < 1.5:
        hints.append(f"位置在 ±{pos_amp:.0f} count、{pos_freq:.2f} Hz 慢摆：检查 AKI=0、"
                     "DZW 是否使小命令推不动，以及 PKD/RLP 的阻尼与延迟；逐项对比，勿只加积分。")
    if ang_amp > 0.8 and (ang_freq is None or ang_freq > 1.5):
        hints.append(f"角度 ±{ang_amp:.1f}° 振荡：检查 ALP/DLP 滞后是否过大（先对照 ALP=0/1、DLP=1/2）。")
    if not hints:
        if pos_amp <= 3 and ang_amp <= 0.5:
            hints.append("状态良好：位置与角度均在小范围内。")
        else:
            hints.append("暂无明显问题征兆；继续观察 10 s 以上。")
    return " ".join(hints)


def read_preset(name):
    """从 gui/data 读取参数组并逐项执行协议范围校验。"""
    filename = PRESETS[name]
    data = json.loads((PRESET_DIR / filename).read_text(encoding="utf-8"))
    values = data.get("params")
    if not isinstance(values, dict):
        raise ValueError(f"参数组格式错误：{filename}")
    checked = {key: validate_value(key, value) for key, value in values.items()}
    unknown = checked.keys() - PARAMS.keys()
    if unknown:
        raise ValueError(f"参数组包含当前界面不支持的参数：{', '.join(sorted(unknown))}")
    missing = sorted(PARAMS.keys() - checked.keys())
    note = data.get("note", "")
    if missing:
        # 旧参数组可能不含本版新增参数（如 TURNS_POSTGT）：用固件默认值补齐，
        # 保证旧文件仍可载入；界面会提示哪些项是补的默认值。
        for name in missing:
            checked[name] = validate_value(name, PARAMS[name][1])
        suffix = f"缺少 {', '.join(missing)}，已按固件默认值补齐"
        note = f"{note}；{suffix}" if note else suffix
    return checked, note


def shortest_delta(value, origin):
    """最短有符号差；用于累计位置 pos_total 与单圈趋势展开。"""
    delta = float(value) - float(origin)
    wrapped = (delta + ENC_CPR / 2) % ENC_CPR - ENC_CPR / 2
    return ENC_CPR / 2 if wrapped == -ENC_CPR / 2 and delta > 0 else wrapped


def trend_points(points, tau_ms=40, wrap=None):
    """仅用于显示的低通；跨圈先展开，断帧重建历史，CSV 和诊断不使用此结果。"""
    result = []
    last_t = last_raw = filtered = None
    unwrapped = 0.0
    for stamp, value in points:
        if last_t is None or stamp-last_t > 0.12 or stamp<=last_t:
            unwrapped = filtered = float(value)
        else:
            unwrapped += shortest_delta(value,last_raw) if wrap else value-last_raw
            alpha = 1 - math.exp(-(stamp-last_t)/max(tau_ms/1000,0.001))
            filtered += alpha*(unwrapped-filtered)
        result.append((stamp,(filtered+ENC_CPR/2)%ENC_CPR-ENC_CPR/2 if wrap else filtered))
        last_t,last_raw = stamp,value
    return result


def protocol_self_test():
    """启动 GUI 前验证一帧遥测、参数帧协议与参数表一致性。"""
    sample = parse_telemetry(
        "ANG=+012.34 RAW=0508 POS=-00520 SPD=-0080 DUT=+0127 "
        "REF=-00400 M2B5 SW=1 Vj3"
    )
    assert sample and sample["mode"] == 2 and sample["bal_status"] == 5
    assert sample["swing_active"] is True
    assert sample["ref_cdeg"] == -400 and sample["ref"] == -4.0
    assert frame(PARAM["ZERO"], 508) == b"\xaa\x10\x01\xfc"

    # MODE3 / TURNS_POSTGT：ID 48、signed 16 全范围、MODE 0..3，与 cfg_regs.v 一致。
    table_self_check()
    assert PARAM["TURNS_POSTGT"] == 48
    assert PARAM_RANGES["TURNS_POSTGT"] == (-32768, 32767)
    assert PARAM_RANGES["MODE"] == (0, 3)
    assert validate_value("MODE", 3) == 3
    assert validate_value("TURNS_POSTGT", -32768) == -32768
    assert validate_value("TURNS_POSTGT", 32767) == 32767
    assert frame(PARAM["TURNS_POSTGT"], -32768) == b"\xaa\x30\x80\x00"
    assert frame(PARAM["TURNS_POSTGT"], -1) == b"\xaa\x30\xff\xff"
    for name, value in (("MODE", 4), ("TURNS_POSTGT", 32768),
                        ("TURNS_POSTGT", -32769)):
        try:
            validate_value(name, value)
        except ValueError:
            pass
        else:
            raise AssertionError(f"{name}={value} 应被协议范围拒绝")

    # 界面参数表必须覆盖协议表（MODE 由模式按钮管理，不在 PARAMS 里），
    # 分组、微调步长和悬浮提示都必须完整覆盖 PARAMS。
    assert set(PARAM) == set(PARAMS) | {"MODE"}
    assert set(PARAM_RANGES) == set(PARAM)
    grouped = [name for _title, names in GROUPS for name in names]
    assert sorted(grouped) == sorted(PARAMS) and len(grouped) == len(set(grouped))
    for name in PARAMS:
        assert name in PARAM_HELP and name in NUDGE_STEP, f"{name} 缺少提示/步长"


def param_tooltip(name):
    """拼出参数悬浮提示文字。"""
    label, default, unit, description = PARAMS[name]
    low, high = PARAM_RANGES.get(name, (None, None))
    help_ = PARAM_HELP.get(name, {})
    lines = [f"{name} · {label}", f"{description}",
             f"单位：{unit}    范围：{low} ~ {high}",
             f"固件默认：{default}    推荐：{help_.get('rec', '-')}"]
    if help_.get("up"):
        lines.append(f"↑ 调大：{help_['up']}")
    if help_.get("down"):
        lines.append(f"↓ 调小：{help_['down']}")
    if help_.get("tip"):
        lines.append(f"提示：{help_['tip']}")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# 悬浮提示
# --------------------------------------------------------------------------
class ToolTip:
    """鼠标悬停一段时间后显示的提示框；text 可为字符串或返回字符串的函数。"""

    def __init__(self, widget, text, delay=450, wrap=400):
        self.widget = widget
        self.text = text
        self.delay = delay
        self.wrap = wrap
        self.window = None
        self.job = None
        widget.bind("<Enter>", self._schedule, add="+")
        widget.bind("<Leave>", self._hide, add="+")
        widget.bind("<ButtonPress>", self._hide, add="+")

    def _schedule(self, _event=None):
        self._cancel()
        self.job = self.widget.after(self.delay, self._show)

    def _cancel(self):
        if self.job is not None:
            try:
                self.widget.after_cancel(self.job)
            except Exception:
                pass
            self.job = None

    def _show(self):
        self.job = None
        text = self.text() if callable(self.text) else self.text
        if not text or self.window is not None:
            return
        try:
            x = self.widget.winfo_pointerx() + 14
            y = self.widget.winfo_pointery() + 18
            self.window = tk.Toplevel(self.widget)
            self.window.wm_overrideredirect(True)
            self.window.wm_geometry(f"+{x}+{y}")
            tk.Label(self.window, text=text, justify="left", wraplength=self.wrap,
                     background="#fffbe6", foreground="#2b2b2b", relief="solid",
                     borderwidth=1, padx=8, pady=6,
                     font=("Microsoft YaHei UI", 9)).pack()
        except Exception:
            self.window = None

    def _hide(self, _event=None):
        self._cancel()
        if self.window is not None:
            try:
                self.window.destroy()
            except Exception:
                pass
            self.window = None


# --------------------------------------------------------------------------
# 单个波形窗口
# --------------------------------------------------------------------------
class ScopePlot:
    """基于 Canvas 的示波器风格曲线图。"""

    LEFT, RIGHT, TOP, BOTTOM = 62, 14, 40, 20

    def __init__(self, app, canvas, key, title, series, unit, include_zero=False,
                 symmetric=False, wrap_threshold=None):
        self.app = app
        self.canvas = canvas
        self.key = key
        self.title = title
        self.series = series
        self.unit = unit
        self.include_zero = include_zero
        self.symmetric = symmetric
        self.wrap_threshold = wrap_threshold
        self.hidden = set()
        self.yrange = None
        self.view = None          # (t0, t1, y_low, y_high, width, height)
        self.chips = []
        self.lines = {}           # 叠加线：name -> (取值函数, 颜色, 虚线)

    def _geometry(self):
        width = max(self.canvas.winfo_width(), 260)
        height = max(self.canvas.winfo_height(), 90)
        return width, height, width - self.LEFT - self.RIGHT, height - self.TOP - self.BOTTOM

    @staticmethod
    def _thin(points, plot_width):
        """趋势折线按像素等间隔抽点；只影响显示，不改变 40 ms 低通结果。"""
        limit = max(2, int(plot_width))
        if len(points) <= limit:
            return points
        step = max(1, (len(points) + limit - 1) // limit)
        thinned = points[::step]
        if thinned[-1] != points[-1]:
            thinned.append(points[-1])
        return thinned

    @staticmethod
    def _dim(color, factor=0.62):
        """原始包络使用压暗的线色，避免与亮色趋势线抢视觉。"""
        try:
            red, green, blue = (int(color[index:index + 2], 16) for index in (1, 3, 5))
            base = THEME["bg"]
            b_red, b_green, b_blue = (int(base[index:index + 2], 16) for index in (1, 3, 5))
        except (TypeError, ValueError):
            return color
        return "#%02x%02x%02x" % (int(b_red + (red - b_red) * factor),
                                  int(b_green + (green - b_green) * factor),
                                  int(b_blue + (blue - b_blue) * factor))

    def x_of(self, stamp):
        t0, t1, _, _, width, _ = self.view
        return self.LEFT + (stamp - t0) / (t1 - t0) * (width - self.LEFT - self.RIGHT)

    def y_of(self, value):
        _, _, low, high, _, height = self.view
        plot_h = height - self.TOP - self.BOTTOM
        return self.TOP + (high - value) / (high - low) * plot_h

    def time_at(self, x):
        t0, t1, _, _, width, _ = self.view
        plot_w = width - self.LEFT - self.RIGHT
        return t0 + (x - self.LEFT) / plot_w * (t1 - t0)

    def draw(self, times, rows, t0, t1):
        canvas = self.canvas
        canvas.delete("all")
        width, height, plot_w, plot_h = self._geometry()
        canvas.create_rectangle(0, 0, width, height, fill=THEME["bg"], outline="")
        if not rows or t1 <= t0:
            canvas.create_text(width / 2, height / 2, text="等待串口遥测…",
                               fill=THEME["dim"], font=("Microsoft YaHei UI", 10))
            self.view = None
            self.chips = []
            return
        data = {name: [row.get(name.lower()) for row in rows] for name in self.series}
        pool = [v for name, vals in data.items() if name not in self.hidden
                for v in vals if v is not None]
        for getter, _color, _dash in self.lines.values():
            value = getter()
            if value is not None:
                pool.append(value)
        if not pool:
            pool = [v for vals in data.values() for v in vals if v is not None] or [0.0]
        low, high = min(pool), max(pool)
        if self.include_zero:
            low, high = min(low, 0.0), max(high, 0.0)
        if self.symmetric:
            bound = max(abs(low), abs(high), 1e-6)
            low, high = -bound, bound
        pad = max(abs(high) * 0.1, 1.0) if high - low < 1e-9 else (high - low) * 0.10
        target = (low - pad, high + pad)
        if not (self.app.lock_y.get() and self.yrange is not None):
            self.yrange = smooth_range(self.yrange, target)
        y_low, y_high = self.yrange
        self.view = (t0, t1, y_low, y_high, width, height)

        for tick in nice_ticks(y_low, y_high, 4):
            y = self.y_of(tick)
            canvas.create_line(self.LEFT, y, self.LEFT + plot_w, y, fill=THEME["grid"])
            canvas.create_text(self.LEFT - 6, y, text=format_tick(tick), anchor="e",
                               fill=THEME["axis"], font=("Consolas", 9))
        span = t1 - t0
        for tick in nice_ticks(t0, t1, 6):
            x = self.x_of(tick)
            canvas.create_line(x, self.TOP, x, self.TOP + plot_h, fill=THEME["grid2"])
            label = f"{tick - t1:+.0f}s" if span > 6 else f"{tick - t1:+.1f}s"
            canvas.create_text(x, self.TOP + plot_h + 10, text=label,
                               fill=THEME["axis"], font=("Consolas", 9))
        if y_low <= 0 <= y_high:
            canvas.create_line(self.LEFT, self.y_of(0), self.LEFT + plot_w, self.y_of(0),
                               fill=THEME["zero"], dash=(4, 3))
        for name, (getter, color, dash) in self.lines.items():
            value = getter()
            if value is None or not (y_low <= value <= y_high):
                continue
            y = self.y_of(value)
            canvas.create_line(self.LEFT, y, self.LEFT + plot_w, y, fill=color, dash=dash)
            canvas.create_text(self.LEFT + plot_w - 3, y - 7, text=name, anchor="e",
                               fill=color, font=("Consolas", 9))
        columns = max(60, int(plot_w))
        mode = self.app.display_mode.get()
        tau_ms = float(self.app.trend_ms.get().split()[0])
        for name in self.series:
            if name in self.hidden:
                continue
            color = SERIES_STYLE[name][0]
            pairs = [(t, v) for t, v in zip(times, data[name]) if v is not None]
            if not pairs:
                continue
            if name in ("REF", "TGT"):
                # 参考/目标通常是阶跃线，不套 40 ms 低通；原始模式仍用包络保留台阶。
                if mode == "原始":
                    layers = [(pairs, self._dim(color), 1.4, True, False)]
                else:
                    layers = [(pairs, color, 2.0, False, False)]
            elif mode == "原始":
                layers = [(pairs, self._dim(color), 1.4, True, False)]
            elif mode == "趋势":
                layers = [(trend_points(pairs, tau_ms, self.wrap_threshold),
                           color, 2.2, False, True)]
            else:                       # 叠加：暗色原始包络 + 亮色趋势折线
                layers = [(pairs, self._dim(color), 1.4, True, False),
                          (trend_points(pairs, tau_ms, self.wrap_threshold),
                           color, 2.2, False, True)]
            for points, line_color, line_width, use_envelope, smooth_line in layers:
                for segment in split_wrap([p[0] for p in points], [p[1] for p in points],
                                          self.wrap_threshold):
                    # 串口断帧不连线，避免把未知区间画成陡峭折线。
                    runs = [[]]
                    for point in segment:
                        if runs[-1] and point[0] - runs[-1][-1][0] > .12:
                            runs.append([])
                        runs[-1].append(point)
                    for run in runs:
                        if use_envelope:
                            shown = envelope(run, t0, t1, columns)
                        else:
                            shown = self._thin(run, plot_w)
                        coords = [coord for stamp, value in shown
                                  for coord in (self.x_of(stamp),
                                                self.y_of(max(y_low, min(y_high, value))))]
                        if len(coords) >= 4:
                            canvas.create_line(*coords, fill=line_color, width=line_width,
                                               smooth=smooth_line, splinesteps=5)
        canvas.create_rectangle(self.LEFT, self.TOP, self.LEFT + plot_w, self.TOP + plot_h,
                                outline=THEME["band"])
        text = f"{self.title} [{self.unit}]"
        canvas.create_text(self.LEFT, 4, text=text, anchor="nw", fill=THEME["text"],
                           font=("Microsoft YaHei UI", 10, "bold"))
        self.chips = []
        x = width - self.RIGHT
        for name in reversed(self.series):
            color = SERIES_STYLE[name][0]
            latest = next((value for value in reversed(data[name]) if value is not None), None)
            if latest is None:
                value_text = "--"
            elif isinstance(latest, float):
                value_text = f"{latest:+.2f}"
            elif name == "RAW":
                value_text = f"{latest:04d}"
            else:
                value_text = f"{latest:+d}"
            label = f"{name} {value_text}"
            label_w = 14 + 8 * len(label)
            x0, x1, y0, y1 = x - label_w, x, 3, 19
            shown = name not in self.hidden
            canvas.create_rectangle(x0, y0, x1, y1, outline=color,
                                    fill=color if shown else THEME["bg"])
            canvas.create_text((x0 + x1) / 2, (y0 + y1) / 2, text=label,
                               fill=THEME["bg"] if shown else color,
                               font=("Consolas", 8, "bold"))
            self.chips.append((x0, y0, x1, y1, name))
            x = x0 - 6

    def click(self, x, y):
        """命中图例芯片则切换曲线显示。"""
        for x0, y0, x1, y1, name in self.chips:
            if x0 <= x <= x1 and y0 <= y <= y1:
                if name in self.hidden:
                    self.hidden.discard(name)
                else:
                    self.hidden.add(name)
                return True
        return False

    def crosshair(self, stamp, nearest_row):
        """绘制十字光标与该时刻读数（带 'xhair' 标签便于清除）。"""
        canvas = self.canvas
        canvas.delete("xhair")
        if self.view is None or nearest_row is None:
            return
        x = self.x_of(stamp)
        _, _, y_low, y_high, width, height = self.view
        plot_h = height - self.TOP - self.BOTTOM
        canvas.create_line(x, self.TOP, x, self.TOP + plot_h, fill=THEME["cross"],
                           dash=(2, 2), tags="xhair")
        parts = []
        for name in self.series:
            if name in self.hidden:
                continue
            value = nearest_row.get(name.lower())
            if value is None:
                continue
            y = self.y_of(max(y_low, min(y_high, value)))
            color = SERIES_STYLE[name][0]
            canvas.create_oval(x - 3, y - 3, x + 3, y + 3, outline=color,
                               fill=THEME["bg"], tags="xhair")
            parts.append(f"{name} {value:+.2f}" if isinstance(value, float)
                         else f"{name} {value:+d}")
        if parts:
            left_side = x < width * 0.6
            canvas.create_text(x + 8 if left_side else x - 8, self.TOP + 4,
                               text="   ".join(parts), anchor="nw" if left_side else "ne",
                               fill=THEME["cross"], font=("Consolas", 9, "bold"), tags="xhair")


# --------------------------------------------------------------------------
# 主界面
# --------------------------------------------------------------------------
class DebugApp:
    """单窗口调试界面。

    串口轮询只负责接收和保存遥测；参数发送必须经过 ``validate_value``。
    MODE 1/2/3 的接管条件由 FPGA 判断，运行中可直接发送参数。所有曲线与数值读数
    共用同一批遥测样本，时间轴按帧序号（TELEM_HZ）生成；记录缓冲独立保存
    “开始记录”之后的样本，停止时按旧版字段导出 CSV。
    """

    def __init__(self, root):
        protocol_self_test()
        self.root = root
        self.root.title("J280 运动与平衡调试台 · 1040 · s/t/u/v/w/x/y")
        self.root.geometry("1500x960")
        self.root.minsize(1160, 760)
        self.root.protocol("WM_DELETE_WINDOW", self.close)

        self.ser = None
        self.rx_buffer = bytearray()
        self.times = []
        self.rows = []
        self.recorded = []
        self.events = deque(maxlen=500)
        self.latest = None
        self.requested_mode = None
        self.requested_at = None
        self.frame_index = 0
        self.time_base = None
        self.analysis_view = None
        self.analysis_cache = None
        self.capture_profile = {}
        self.capture_switch = None

        self.plot_window = tk.StringVar(value="10 秒")
        self.display_mode = tk.StringVar(value="趋势")
        self.trend_ms = tk.StringVar(value="40 ms")
        self.position_error_text = tk.StringVar(value="位置误差 -- count")
        self.firmware_text = tk.StringVar(value="固件 -- · 1040 count/圈")
        self.position_unwrapped = None
        self.position_previous = None
        self.recording = False
        self.paused = tk.BooleanVar(value=False)
        self.lock_y = tk.BooleanVar(value=False)
        self.freeze_t = None
        self.connection_text = tk.StringVar(value="未连接")
        self.mode_text = tk.StringVar(value="MODE --")
        self.balance_text = tk.StringVar(value="等待遥测")
        self.position_loop_text = tk.StringVar(value="位置 P/I/D 状态待检查")
        self.sample_text = tk.StringVar(value="0 帧")
        self.config_text = tk.StringVar(value="板端参数帧计数：--")
        self.metric_vars = {key: tk.StringVar(value="--")
                            for key in ("ang", "raw", "pos", "spd", "dut", "ref")}
        self.port_text = tk.StringVar(value="")
        self.param_vars = {name: tk.StringVar(value=str(default))
                           for name, (_, default, _, _) in PARAMS.items()}
        self.sent_values = {}
        self.preset_text = tk.StringVar(value=next(iter(PRESETS)))
        self.preset_note = tk.StringVar(
            value="选择参数组后点“载入”才会替换当前值；载入不会自动发送。")
        self._load_state()
        self.param_status = {name: tk.StringVar(value="默认值") for name in PARAMS}
        self.param_dots = {}
        self.param_entries = {}
        self.plots = {}
        self.port_combo = None
        self._build_ui()
        for name in ("PKP", "PKD", "PKDNEAR", "POSP_LIM", "POS_NEAR", "PKI", "PILIM"):
            self.param_vars[name].trace_add("write", self._update_position_loop_text)
        for name in PARAMS:
            self.param_vars[name].trace_add("write", lambda *_a, key=name: self._on_param_edit(key))
            self._on_param_edit(name)
        self._update_position_loop_text()
        # 唯一默认配置：启动时直接加载 gui/data/config0.json
        try:
            values, note = read_preset("config0")
            self._apply_param_values(values)
            self.preset_text.set("config0")
            self.preset_note.set(note or "config0：唯一默认配置")
            self.capture_profile = {}
        except Exception as error:
            self._add_event(f"config0 载入失败：{error}")
        self._refresh_ports()
        self.root.bind("<Escape>", lambda _event: self.request_stop())
        self.root.bind("<space>", self._toggle_pause_key)
        self.root.after(20, self._poll_serial)
        self.root.after(50, self._draw_charts)

    # -- 状态保存 ----------------------------------------------------------
    def _load_state(self):
        """恢复上次关闭 GUI 时的参数、串口和显示设置；文件损坏时回退默认值。"""
        try:
            state = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return
        saved_params = state.get("params", {})
        try:
            self.capture_profile = read_capture(state)
        except (ValueError, TypeError):
            self.capture_profile = {}
        if saved_params:
            self.preset_note.set("已恢复本机上次保存的参数；下拉框参数组尚未载入。")
        if saved_params and "PKI" not in saved_params:
            for name in ("PKI","PILIM","RLP","DZLP"):self.param_vars[name].set("0")
            self.param_vars["DZW"].set("64")
        for name, variable in self.param_vars.items():
            if name in saved_params:
                try:
                    value = validate_value(name, int(saved_params[name]))
                except (TypeError, ValueError):
                    continue
                variable.set(str(value))
        if state.get("port"):
            self.port_text.set(str(state["port"]))
        if state.get("plot_window") in ("5 秒", "10 秒", "30 秒", "60 秒"):
            self.plot_window.set(state["plot_window"])
        # 旧状态文件（ui_version < 2）里的 “叠加” 只是旧版默认值；升级后首次启动
        # 仍使用新的“趋势”默认，之后用户主动选择的模式才会继续保存/恢复。
        if state.get("ui_version", 0) >= 2:
            if state.get("display_mode") in ("原始", "趋势", "叠加"):
                self.display_mode.set(state["display_mode"])
            if state.get("trend_ms") in ("20 ms", "40 ms", "80 ms"):
                self.trend_ms.set(state["trend_ms"])

    def _save_state(self):
        """保存本次参数快照，便于下一次上电调试继续使用同一组参数。"""
        state = {
            "ui_version": 2,
            "params": {name: variable.get() for name, variable in self.param_vars.items()},
            "port": self.port_text.get(),
            "plot_window": self.plot_window.get(),
            "display_mode": self.display_mode.get(), "trend_ms": self.trend_ms.get(),
            "staged_start": bool(self.capture_profile), "capture_params": self.capture_profile,
        }
        try:
            STATE_PATH.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n",
                                  encoding="utf-8")
        except OSError as error:
            self._add_event(f"参数记录保存失败：{error}")

    # -- 界面构建 ----------------------------------------------------------
    def _build_ui(self):
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except Exception:
            pass
        self.root.configure(background="#eef2f7")
        style.configure(".", font=("Microsoft YaHei UI",9), background="#eef2f7",foreground="#243449")
        style.configure("TFrame",background="#eef2f7")
        style.configure("TLabel",background="#eef2f7",foreground="#243449")
        style.configure("TButton",padding=(8,6),background="#ffffff",borderwidth=0)
        style.map("TButton",background=[("active","#dfeafb")])
        style.configure("Compact.TButton",padding=(3,4))
        style.configure("TEntry",padding=5,fieldbackground="#ffffff",bordercolor="#d6dfeb")
        style.configure("TCombobox",padding=5,fieldbackground="#ffffff")
        style.configure("TNotebook",background="#eef2f7",borderwidth=0)
        style.configure("TNotebook.Tab",padding=(12,7),background="#e3eaf3")
        style.map("TNotebook.Tab",background=[("selected","#ffffff")],foreground=[("selected","#2563eb")])
        style.configure("TLabelframe",padding=8,bordercolor="#d6dfeb")
        style.configure("TLabelframe.Label",font=("Microsoft YaHei UI",9,"bold"))
        style.configure("Muted.TLabel",foreground="#697d94",font=("Microsoft YaHei UI",8))
        style.configure("Title.TLabel",foreground="#1d3558",font=("Microsoft YaHei UI",13,"bold"))
        style.configure("Stop.TButton", foreground="#ffffff", background="#c0392b",
                        font=("Microsoft YaHei UI", 10, "bold"))
        style.map("Stop.TButton", background=[("active", "#e74c3c")])
        style.configure("Go.TButton", foreground="#ffffff", background="#1f8a5b",
                        font=("Microsoft YaHei UI", 10, "bold"))
        style.map("Go.TButton", background=[("active", "#27ae7a")])
        style.configure("Card.TLabel", font=("Consolas", 14, "bold"))

        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(2, weight=1)

        toolbar = ttk.Frame(self.root, padding=(14,10))
        toolbar.grid(row=0,column=0,sticky="ew")
        toolbar.columnconfigure(4,weight=1)
        ttk.Label(toolbar,text="J280 / 运动与平衡",style="Title.TLabel").grid(row=0,column=0,padx=(0,18))
        self.port_combo=ttk.Combobox(toolbar,textvariable=self.port_text,width=10,state="readonly")
        self.port_combo.grid(row=0,column=1,padx=3)
        ttk.Button(toolbar,text="刷新",width=5,command=self._refresh_ports).grid(row=0,column=2,padx=3)
        self.connect_button=ttk.Button(toolbar,text="连接",width=7,command=self.toggle_connection)
        self.connect_button.grid(row=0,column=3,padx=3)
        self.manual_button=ttk.Button(toolbar,text="手动平衡  MODE 1",style="Go.TButton",command=lambda:self.request_mode(1))
        self.manual_button.grid(row=0,column=5,padx=4)
        self.swing_button=ttk.Button(toolbar,text="自动起摆  MODE 2",style="Go.TButton",command=lambda:self.request_mode(2))
        self.swing_button.grid(row=0,column=6,padx=4)
        self.mode3_button=ttk.Button(toolbar,text="绝对定位  MODE 3",style="Go.TButton",command=lambda:self.request_mode(3))
        self.mode3_button.grid(row=0,column=7,padx=4)
        self.stop_button=ttk.Button(toolbar,text="■ 停机  Esc",style="Stop.TButton",command=self.request_stop)
        self.stop_button.grid(row=0,column=8,padx=(8,0))
        status=ttk.Frame(toolbar)
        status.grid(row=1,column=0,columnspan=9,sticky="ew",pady=(7,0))
        for var in (self.connection_text,self.firmware_text,self.mode_text,self.balance_text,self.position_error_text):
            ttk.Label(status,textvariable=var,style="Muted.TLabel").pack(side="left",padx=(0,18))

        metrics = ttk.Frame(self.root, padding=(12, 3, 12, 2))
        metrics.grid(row=1, column=0, sticky="ew")
        cards = (("ang", "ANG", "°", "摆杆角度（相对竖直），0.01° 分辨率。"),
                 ("ref", "REF", "°", "角度参考 = TRIM + 位置外环修正量。"),
                 ("raw", "RAW", "ADC", "ADC 原始码值（512 点平均，约 0.33°/码）。"),
                 ("pos", "POS", "count", "编码器单圈位置，-520..+519。"),
                 ("spd", "SPD", "count/s", "摆臂速度估计（16 ms 窗，量化 62.5 count/s）。"),
                 ("dut", "DUT", "duty", "实际输出占空比（含死区补偿与限幅）。"))
        for column,(key,label,unit,tip) in enumerate(cards):
            metrics.columnconfigure(column,weight=1)
            item=ttk.Frame(metrics,padding=(10,6))
            item.grid(row=0,column=column,sticky="ew",padx=3)
            ttk.Label(item,text=f"{label}  {unit}",style="Muted.TLabel").pack(anchor="w")
            value_label=ttk.Label(item,textvariable=self.metric_vars[key],style="Card.TLabel")
            value_label.pack(anchor="w",pady=(2,0))
            ToolTip(value_label,tip)

        main = ttk.Panedwindow(self.root, orient=tk.HORIZONTAL)
        main.grid(row=2, column=0, sticky="nsew", padx=10, pady=(0, 10))
        charts = ttk.Frame(main, padding=(0, 0, 8, 0))
        settings_outer = ttk.Frame(main, width=450)
        main.add(settings_outer, weight=0)
        main.add(charts, weight=5)
        charts.columnconfigure(0, weight=1)
        self.root.after(0,lambda:main.sashpos(0,450))

        # 固定高度的摆动分析区：只更新内部 Text，绝不因文字变长而改变外层高度。
        ana_bar = tk.Frame(charts, height=60, background=THEME["bg"],
                           highlightthickness=1, highlightbackground="#2b3b4c")
        ana_bar.grid(row=0, column=0, sticky="ew", padx=4, pady=(2, 2))
        ana_bar.grid_propagate(False)
        ana_bar.rowconfigure(0, weight=1)
        ana_bar.columnconfigure(0, weight=1)
        self.analysis_view = tk.Text(
            ana_bar, height=3, wrap="word", state="disabled",
            background=THEME["bg"], foreground=THEME["text"],
            insertbackground=THEME["text"], relief="flat", borderwidth=0,
            highlightthickness=0, padx=8, pady=3, spacing1=1, spacing3=1,
            font=("Microsoft YaHei UI", 9, "bold"), cursor="arrow")
        self.analysis_view.grid(row=0, column=0, sticky="nsew")
        ana_scroll = ttk.Scrollbar(ana_bar, orient="vertical",
                                   command=self.analysis_view.yview)
        ana_scroll.grid(row=0, column=1, sticky="ns")
        self.analysis_view.configure(yscrollcommand=ana_scroll.set)
        self.analysis_view.tag_configure("analysis",
                                         font=("Microsoft YaHei UI", 9, "bold"),
                                         foreground=THEME["text"])
        self.analysis_view.tag_configure("hint",
                                         font=("Microsoft YaHei UI", 8),
                                         foreground=THEME["warn"])
        self.analysis_view.configure(state="normal")
        self.analysis_view.insert("1.0", "摆动分析：等待数据", "analysis")
        self.analysis_view.configure(state="disabled")
        ToolTip(self.analysis_view,
                "用当前时间窗数据估计：位置/角度摆动的半幅值与频率（均值穿越法），以及输出每秒换向次数。\n"
                "遥测为 100 Hz，只能观察 <50 Hz 的现象；超过 50 Hz 的信号可能混叠；显示趋势不能用于判断原始峰值。")

        plot_specs = (
            ("angle", "摆杆角度", ("ANG", "REF"), "°", True, True, None),
            ("position", f"编码器位置（单圈 -{ENC_CPR // 2}..+{(ENC_CPR - 1) // 2}）",
             ("POS", "TGT"), "count", False, False, ENC_CPR // 2),
            ("speed", "摆臂速度", ("SPD",), "count/s", True, False, None),
            ("duty", "电机输出", ("DUT",), "duty", True, True, None),
            ("raw", "ADC 原始值", ("RAW",), "ADC", False, False, None),
        )
        for index, (key, title, series, unit, include_zero, symmetric, wrap) in enumerate(plot_specs):
            charts.rowconfigure(index + 1, weight=1)
            box = tk.Frame(charts, background=THEME["bg"], highlightthickness=1,
                           highlightbackground="#2b3b4c")
            box.grid(row=index + 1, column=0, sticky="nsew", padx=4, pady=1)
            box.rowconfigure(0, weight=1)
            box.columnconfigure(0, weight=1)
            canvas = tk.Canvas(box, background=THEME["bg"], highlightthickness=0, height=104,
                               cursor="crosshair")
            canvas.grid(row=0, column=0, sticky="nsew")
            self.plots[key] = ScopePlot(self, canvas, key, title, series, unit,
                                        include_zero, symmetric, wrap)
            canvas.bind("<Motion>", lambda event, k=key: self._on_hover(k, event))
            canvas.bind("<Leave>", lambda _event: self._clear_crosshair())
            canvas.bind("<Button-1>", lambda event, k=key: self._on_plot_click(k, event))
        self.plots["position"].lines["目标"] = (lambda: self.sent_values.get("POSTGT"), "#a9c7ff", (4, 3))
        self.plots["duty"].lines["+LIM"] = (lambda: self._int_param("LIM"), "#8a5a5a", (2, 3))
        self.plots["duty"].lines["-LIM"] = (lambda: self._neg_param("LIM"), "#8a5a5a", (2, 3))
        self.plots["duty"].lines["+DZ"] = (lambda: self._int_param("DZ"), "#5a8a5a", (1, 3))
        self.plots["duty"].lines["-DZ"] = (lambda: self._neg_param("DZ"), "#5a8a5a", (1, 3))
        for plot in self.plots.values():
            ToolTip(plot.canvas, "移动鼠标：十字光标读数（各图联动）。点击右上角图例（含当前值）可开关曲线。空格键暂停/继续。",
                    delay=1200)

        charts_tools = ttk.Frame(charts, padding=(4, 4))
        charts_tools.grid(row=6, column=0, sticky="ew")
        upper_tools=ttk.Frame(charts_tools)
        upper_tools.pack(fill="x")
        ttk.Label(upper_tools,text="波形").pack(side="left")
        ttk.Combobox(upper_tools,textvariable=self.display_mode,values=("原始","趋势","叠加"),
                     state="readonly",width=5).pack(side="left",padx=3)
        ttk.Combobox(upper_tools,textvariable=self.trend_ms,values=("20 ms","40 ms","80 ms"),
                     state="readonly",width=6).pack(side="left",padx=3)
        ttk.Label(upper_tools, text="时间窗").pack(side="left")
        window_box = ttk.Combobox(upper_tools, textvariable=self.plot_window,
                                  values=("5 秒", "10 秒", "30 秒", "60 秒"),
                                  state="readonly", width=7)
        window_box.pack(side="left", padx=5)
        pause = ttk.Checkbutton(upper_tools, text="暂停(空格)", variable=self.paused,
                                command=self._on_pause_changed)
        pause.pack(side="left", padx=8)
        ToolTip(pause, "冻结画面便于读数；数据仍在后台记录。再次点击恢复实时。")
        lock = ttk.Checkbutton(upper_tools, text="锁定Y轴", variable=self.lock_y)
        lock.pack(side="left", padx=4)
        ToolTip(lock, "锁定当前 Y 轴范围，便于比较前后两次调参的幅度。")
        lower_tools=ttk.Frame(charts_tools)
        lower_tools.pack(side="bottom",fill="x",pady=(4,0))
        self.record_button = ttk.Button(lower_tools, text="开始记录",
                                        command=self.start_recording)
        self.record_button.pack(side="left", padx=(0, 4))
        ToolTip(self.record_button, "清空记录缓冲，并把之后收到的每个遥测帧存入独立列表；实时曲线不受影响。")
        self.record_save_button = ttk.Button(lower_tools, text="停止并保存…",
                                             command=self.stop_recording_and_save)
        self.record_save_button.pack(side="left", padx=4)
        ToolTip(self.record_save_button, "停止记录；若缓冲区有数据，选择 CSV 路径保存（时间从首帧归零）。")
        ttk.Button(lower_tools, text="清空显示", command=self.clear_data).pack(side="left", padx=4)
        ttk.Label(lower_tools, textvariable=self.sample_text).pack(side="right")
        self._refresh_record_controls()

        self.event_view = tk.Text(charts, height=3, wrap="word", state="disabled",
                                  background="#f4f7f6", foreground="#26332f",
                                  font=("Consolas", 9))
        self.event_view.grid(row=7, column=0, sticky="nsew", padx=4, pady=(3, 0))
        charts.rowconfigure(7, weight=1)

        self._build_settings(settings_outer)

    def _build_settings(self, settings_outer):
        settings_outer.rowconfigure(0,weight=1)
        settings_outer.columnconfigure(0,weight=1)
        notebook=ttk.Notebook(settings_outer)
        notebook.grid(row=0,column=0,sticky="nsew")
        parameters=ttk.Frame(notebook,padding=10)
        diagnostics=ttk.Frame(notebook,padding=12)
        notebook.add(parameters,text="控制参数")
        notebook.add(diagnostics,text="调试")
        parameters.columnconfigure(0,weight=1)
        parameters.rowconfigure(3,weight=1)
        ttk.Label(parameters,text="唯一配置：gui/data/config0.json（启动自动载入；FPGA 上电默认同此配置）",
                  style="Muted.TLabel",wraplength=390).grid(row=0,column=0,sticky="ew")
        ttk.Label(parameters,textvariable=self.preset_note,wraplength=390,style="Muted.TLabel").grid(row=1,column=0,sticky="ew",pady=8)
        ttk.Label(parameters,text="悬停查看说明，回车或“发送”下发单项；“全量下发”发送全部参数。",style="Muted.TLabel").grid(row=2,column=0,sticky="w",pady=(0,7))
        groups=ttk.Notebook(parameters)
        groups.grid(row=3,column=0,sticky="nsew")
        for (title,names),tab_name in zip(GROUPS,("角度","位置","输出","标定","起摆")):
            tab=ttk.Frame(groups)
            groups.add(tab,text=tab_name)
            tab.rowconfigure(0,weight=1);tab.columnconfigure(0,weight=1)
            canvas=tk.Canvas(tab,highlightthickness=0,width=390,background="#eef2f7")
            scroll=ttk.Scrollbar(tab,orient="vertical",command=canvas.yview)
            canvas.configure(yscrollcommand=scroll.set)
            canvas.grid(row=0,column=0,sticky="nsew");scroll.grid(row=0,column=1,sticky="ns")
            body=ttk.Frame(canvas,padding=(6,8))
            wid=canvas.create_window((0,0),window=body,anchor="nw")
            body.bind("<Configure>",lambda _e,c=canvas:c.configure(scrollregion=c.bbox("all")))
            canvas.bind("<Configure>",lambda e,c=canvas,w=wid:c.itemconfigure(w,width=e.width))
            canvas.bind("<Enter>",lambda _e,c=canvas:c.bind_all("<MouseWheel>",lambda e:c.yview_scroll(int(-e.delta/120),"units")))
            canvas.bind("<Leave>",lambda _e,c=canvas:c.unbind_all("<MouseWheel>"))
            body.columnconfigure(0,weight=1)
            for index,name in enumerate(names):
                label,default,unit,description=PARAMS[name]
                row=ttk.Frame(body,padding=(2,6))
                row.grid(row=index,column=0,sticky="ew")
                row.columnconfigure(1,weight=1)
                dot=ttk.Label(row,text="●",foreground="#9aa5a0")
                dot.grid(row=0,column=0,rowspan=2,padx=(0,5))
                self.param_dots[name]=dot
                caption=ttk.Label(row,text=label,font=("Microsoft YaHei UI",9,"bold"))
                caption.grid(row=0,column=1,sticky="w")
                detail=ttk.Label(row,text=f"{name} · {unit}",style="Muted.TLabel",wraplength=125)
                detail.grid(row=1,column=1,sticky="w")
                entry=ttk.Entry(row,textvariable=self.param_vars[name],width=6,justify="right")
                entry.grid(row=0,column=2,rowspan=2,padx=(5,3))
                entry.bind("<Return>",lambda _e,k=name:self.send_parameter(k))
                self.param_entries[name]=entry
                step=NUDGE_STEP.get(name,1)
                for col,text,delta in ((3,"−",-step),(4,"+",step)):
                    ttk.Button(row,text=text,width=2,style="Compact.TButton",command=lambda k=name,d=delta:self.nudge(k,d)).grid(row=0,column=col,rowspan=2,padx=1)
                ttk.Button(row,text="发送",width=4,style="Compact.TButton",command=lambda k=name:self.send_parameter(k)).grid(row=0,column=5,rowspan=2,padx=(4,0))
                for widget in (caption,detail,entry,dot):
                    ToolTip(widget,lambda k=name:param_tooltip(k)+"\n状态："+self.param_status[k].get())
        ttk.Button(parameters,text="全量下发当前参数",style="Go.TButton",command=self.send_all_parameters).grid(row=5,column=0,sticky="ew",pady=(10,4))
        ttk.Label(parameters,textvariable=self.config_text,wraplength=390,style="Muted.TLabel").grid(row=6,column=0,sticky="w")

        ttk.Label(diagnostics,text="实时调试",style="Title.TLabel").pack(anchor="w")
        for var in (self.position_loop_text,self.position_error_text,self.firmware_text):
            ttk.Label(diagnostics,textvariable=var,wraplength=370).pack(anchor="w",pady=8)
        ttk.Label(diagnostics,text="1  确认s固件后载入实机s确认组并全量下发。\n"
                                   "2  静止时看误差、原始振幅与换向频率。\n"
                                   "3  位置积分学习持续偏差，带±2 count软死区。\n"
                                   "4  原始/趋势/叠加只影响画面，记录 CSV 始终保存原始值。\n"
                                   "5  记录在图表下方工具条：开始记录 / 停止并保存…。",
                  wraplength=370,justify="left").pack(anchor="w",pady=12)
        ttk.Label(diagnostics,text="现场起摆配置保留 670 / 750 / 200ms，可切回原平衡参数对照。",wraplength=370,style="Muted.TLabel").pack(anchor="w",pady=12)

    # -- 参数辅助 ----------------------------------------------------------
    def _int_param(self, name):
        try:
            return int(self.param_vars[name].get().strip(), 0)
        except (ValueError, KeyError):
            return None

    def _neg_param(self, name):
        value = self._int_param(name)
        return None if value is None else -value

    def _on_param_edit(self, name):
        """输入校验着色，并标记“已修改未下发”。"""
        dot = self.param_dots.get(name)
        if dot is None:
            return
        text = self.param_vars[name].get().strip()
        try:
            value = validate_value(name, int(text, 0))
        except (ValueError, TypeError):
            dot.configure(foreground="#d93025")
            self.param_status[name].set("输入无效")
            return
        if name in self.sent_values:
            if self.sent_values[name] == value:
                dot.configure(foreground="#1f9d55")
                self.param_status[name].set("已下发")
            else:
                dot.configure(foreground="#f29900")
                self.param_status[name].set("已修改未下发")
        else:
            dot.configure(foreground="#9aa5a0")
            self.param_status[name].set("未下发")

    def nudge(self, name, delta):
        """按步长微调参数（受协议范围限制）；不自动发送。"""
        value = self._int_param(name)
        if value is None:
            value = PARAMS[name][1]
        low, high = PARAM_RANGES[name]
        if name=="DZW":
            choices=(1,2,4,8,16,32,64,128,256)
            index=min(range(len(choices)),key=lambda i:abs(choices[i]-value))
            value=choices[max(0,min(8,index+(1 if delta>0 else -1)))]
        else:value=max(low,min(high,value+delta))
        self.param_vars[name].set(str(value))

    def _show_preset_note(self):
        try:
            _values, note = read_preset(self.preset_text.get())
            self.preset_note.set(note)
        except (OSError, ValueError, KeyError, json.JSONDecodeError):
            pass

    def _update_position_loop_text(self, *_args):
        """显示当前准备下发的位置 P/I/D，积分门控仍由板端实际状态决定。"""
        try:
            gain = int(self.param_vars["PKP"].get().strip(), 0)
            kd = int(self.param_vars["PKD"].get().strip(), 0)
            kd_near = int(self.param_vars["PKDNEAR"].get().strip(), 0)
            limit = int(self.param_vars["POSP_LIM"].get().strip(), 0)
            near = int(self.param_vars["POS_NEAR"].get().strip(), 0)
            ki = int(self.param_vars["PKI"].get().strip(), 0)
            i_limit = int(self.param_vars["PILIM"].get().strip(), 0)
        except ValueError:
            self.position_loop_text.set("位置参数输入无效")
            return
        p_state = "P 关" if gain == 0 or limit == 0 else "P 开"
        i_state = "I 关" if not gain or not limit or not ki or not i_limit else (
            "I 符号不匹配" if (gain>0)!=(ki>0) else "I 已配置")
        d_state = "D 阻尼关" if kd == 0 and (near == 0 or kd_near == 0) else "D 阻尼开"
        zone = "近区切换开" if near > 0 else "单一 PKD"
        self.position_loop_text.set(f"{p_state} / {i_state} / {d_state} / {zone}")

    def _apply_param_values(self, values):
        """把 {名称: 值} 逐项按协议范围校验后写入输入框；返回 (应用项, 跳过项)。

        参数组载入和 JSON 配置载入共用本方法，确保两者使用同一套范围校验。
        """
        applied, skipped = {}, []
        for name, raw in values.items():
            if name not in PARAMS:
                skipped.append(f"{name}: 未知参数")
                continue
            try:
                if isinstance(raw, bool):
                    raise ValueError("布尔值不是有效参数")
                if isinstance(raw, str):
                    value = validate_value(name, int(raw.strip(), 0))
                elif isinstance(raw, float) and not raw.is_integer():
                    raise ValueError("参数必须是整数")
                else:
                    value = validate_value(name, int(raw))
            except (TypeError, ValueError, OverflowError) as error:
                skipped.append(f"{name}: {error}")
                continue
            applied[name] = value
        for name, value in applied.items():
            self.param_vars[name].set(str(value))
        self._update_position_loop_text()
        return applied, skipped

    def load_selected_preset(self):
        """载入所选的已换算参数组到输入框，待用户检查后统一下发。"""
        try:
            values, note = read_preset(self.preset_text.get())
            metadata = json.loads((PRESET_DIR / PRESETS[self.preset_text.get()]).read_text(encoding="utf-8"))
            capture = read_capture(metadata)
        except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
            self._add_event(f"参数组载入失败：{error}")
            return False
        self._cancel_capture_switch()
        self.capture_profile = capture
        self._apply_param_values(values)
        self.preset_note.set(note)
        self._save_state()
        self._add_event(f"已载入参数组：{self.preset_text.get()}；尚未发送到 FPGA")
        self._refresh_controls()
        return True

    def save_config_dialog(self):
        """把当前全部参数写入 JSON 配置；写入前逐项做协议范围检查。"""
        values, invalid = {}, []
        for name in PARAMS:
            try:
                values[name] = validate_value(name,
                                              int(self.param_vars[name].get().strip(), 0))
            except (TypeError, ValueError, OverflowError):
                invalid.append(name)
        if invalid:
            self._add_event(f"保存配置失败：参数输入无效或越界（{', '.join(invalid)}）")
            return
        path = filedialog.asksaveasfilename(
            parent=self.root, title="保存参数配置",
            initialfile=time.strftime("j280_config_%Y%m%d_%H%M%S.json"),
            defaultextension=".json", filetypes=[("JSON", "*.json")])
        if not path:
            return
        config = {"format": "j280_gui_config",
                  "created": time.strftime("%Y-%m-%d %H:%M:%S"),
                  "params": values}
        if self.capture_profile:
            config.update(staged_start=True, capture_params=self.capture_profile)
        try:
            Path(path).write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n",
                                  encoding="utf-8")
        except OSError as error:
            self._add_event(f"保存配置失败：{error}")
            return
        self._add_event(f"已保存参数配置：{path}")

    def load_config_dialog(self):
        """读取 JSON 配置；兼容 {"params": {...}} 与平铺 dict，只应用已知合法参数。"""
        path = filedialog.askopenfilename(
            parent=self.root, title="载入参数配置",
            defaultextension=".json", filetypes=[("JSON", "*.json")])
        if not path:
            return
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
        except (OSError, ValueError, json.JSONDecodeError) as error:
            self._add_event(f"载入配置失败：{error}")
            return
        if not isinstance(data, dict):
            self._add_event("载入配置失败：顶层必须是 JSON 对象")
            return
        try:
            capture = read_capture(data)
        except (ValueError, TypeError) as error:
            self._add_event(f"载入起摆配置失败：{error}")
            return
        if "params" in data:
            if not isinstance(data["params"], dict):
                self._add_event("载入配置失败：params 必须是对象")
                return
            values = data["params"]
        else:
            values = {key: value for key, value in data.items()
                      if key not in ("format", "created", "note", "version")}
        applied, skipped = self._apply_param_values(values)
        if not applied:
            detail = f"；{'；'.join(skipped[:6])}" if skipped else ""
            self._add_event(f"载入配置失败：没有可应用的参数{detail}")
            return
        self._cancel_capture_switch()
        self.capture_profile = capture
        self._refresh_controls()
        self._save_state()
        message = f"已载入配置：{Path(path).name}（应用 {len(applied)} 项，尚未发送到 FPGA）"
        if skipped:
            message += f"；跳过 {len(skipped)} 项：{'；'.join(skipped[:6])}"
            if len(skipped) > 6:
                message += " …"
        self._add_event(message)

    # -- 串口 --------------------------------------------------------------
    def _refresh_ports(self):
        """重新枚举系统串口，并保持当前选择（若仍然存在）。"""
        ports = [port.device for port in list_ports.comports()]
        self.port_combo.configure(values=ports)
        if ports and self.port_text.get() not in ports:
            self.port_text.set(ports[0])

    def toggle_connection(self):
        """建立或关闭串口连接；连接时不自动下发参数、不自动启动电机。"""
        if self.ser is not None:
            self._disconnect()
            return
        port = self.port_text.get().strip()
        if not port:
            self._add_event("未连接：请选择 FPGA 对应的串口")
            return
        try:
            device = serial.Serial(port, 115200, timeout=0, write_timeout=1,
                                   dsrdtr=False, rtscts=False)
            device.dtr = False
            device.rts = False
            device.reset_input_buffer()
        except Exception as error:
            self.connection_text.set("连接失败")
            self._add_event(f"串口连接失败：{error}")
            return
        self.ser = device
        self.rx_buffer.clear()
        self.latest = None
        self.clear_data()
        self.sent_values.clear()
        for name in PARAMS:
            self._on_param_edit(name)
        self.connection_text.set(f"已连接 {port} · 115200 8N1")
        self.connect_button.configure(text="断开")
        self._add_event(f"串口已连接：{port}；未自动下发参数或启动电机")
        self._refresh_controls()

    def _disconnect(self):
        """发送 MODE 0 后关闭串口；停机帧异常时记录事件并提示实体急停。"""
        self.capture_switch = None
        if self.ser is None:
            return
        try:
            if self.ser.is_open:
                self._write_frame("MODE", 0)
                self._add_event("断开前已发送 MODE 0")
                self.ser.close()
        except Exception as error:
            self._add_event(f"断开时 MODE 0 未确认：{error}；请使用实体急停")
        self.ser = None
        self.requested_mode = None
        self.latest = None
        self.connection_text.set("未连接")
        self.mode_text.set("MODE --")
        self.balance_text.set("等待遥测")
        self.connect_button.configure(text="连接")
        self._refresh_controls()

    def _write_frame(self, name, value):
        """把一个已通过范围检查的参数编码为 FPGA 四字节帧并发送。"""
        if self.ser is None or not self.ser.is_open:
            raise RuntimeError("串口未连接")
        if not supports_parameter(name,(self.latest or {}).get('version','')):
            raise RuntimeError("该参数需要更新固件：PIDEAD/KDBLEND需t起，VELMODE需v起，ADCAVG需w起，RATEMODE需x起，HOLDPOS需y")
        if (self.latest or {}).get("src_local")==1 and (name,value)!=("MODE",0):
            raise RuntimeError("当前为本地调参模式，请用板上SW1切回上位机")
        value = validate_value(name, value)
        if self.capture_switch and name in ("POSTGT", "TURNS_POSTGT"):
            self.capture_switch.steady[name] = value
        self.ser.write(frame(PARAM[name], value))
        self.ser.flush()
        return value

    def _parse_entry(self, name):
        """读取参数输入框，支持十进制和 ``0x`` 等 Python 整数格式。"""
        raw_value = self.param_vars[name].get().strip()
        return validate_value(name, int(raw_value, 0))

    def send_parameter(self, name, from_mode=False):
        """发送单个参数；允许运行中在线改参时立即生效。"""
        if self.ser is None:
            self._add_event(f"参数未发送：串口未连接（{name}）")
            return False
        self._cancel_capture_switch()
        try:
            value = self._parse_entry(name)
            self._write_frame(name, value)
        except (ValueError, RuntimeError, OSError) as error:
            self.param_status[name].set("未发送")
            self._add_event(f"参数未发送：{name}，{error}")
            return False
        self.sent_values[name] = value
        self._on_param_edit(name)
        self._add_event(f"参数已发送：{name}={value}")
        return True

    def send_all_parameters(self, from_mode=False):
        """按 PARAMS 顺序一次发送全部参数，板端用帧计数确认接收活动。"""
        if self.ser is None:
            self._add_event("参数未发送：串口未连接")
            return False
        self._cancel_capture_switch()
        try:
            values = {name: self._parse_entry(name) for name in PARAMS}
            values=self._send_parameter_values(values)
        except (ValueError, RuntimeError, OSError) as error:
            self._add_event(f"全部参数未发送：{error}")
            return False
        self._add_event(f"已发送全部 {len(values)} 项参数；板端帧计数可确认接收活动，不能读回具体值")
        return True

    def _send_parameter_values(self, values):
        """分阶段切换与手动全量下发共用同一套校验及发送路径。"""
        if self.ser is None:
            raise RuntimeError("串口未连接")
        if (self.latest or {}).get("src_local")==1:
            raise RuntimeError("当前为本地模式，请切回上位机模式")
        if values.get('HOLDPOS',0) and not supports_parameter('HOLDPOS',(self.latest or {}).get('version','')):
            raise RuntimeError("容差保持需要先烧录Vy；当前固件未发送任何本组参数")
        values={name:validate_value(name,value) for name,value in values.items()
                if supports_parameter(name,(self.latest or {}).get('version',''))}
        payload=b"".join(frame(PARAM[name],value) for name,value in values.items())
        self.ser.write(payload)
        self.ser.flush()
        self.sent_values.update(values)
        for name in values:
            self._on_param_edit(name)
        return values

    def _cancel_capture_switch(self):
        if self.capture_switch is not None:
            self.capture_switch=None
            self._add_event("已取消待执行的稳态参数切换；当前板端参数未改变")

    def _poll_capture_switch(self):
        if self.capture_switch is None:
            return
        action=self.capture_switch.update(self.latest,time.monotonic())
        if action is None:
            return
        transition=self.capture_switch
        self.capture_switch=None
        if action=='ready':
            try:
                self._send_parameter_values(transition.steady)
                self._add_event("已连续平衡2秒，自动切入所选final稳态参数")
            except (ValueError,RuntimeError,OSError) as error:
                self._add_event(f"稳态参数切换失败：{error}")
                self.request_stop()
        elif action=='cancel':
            self._add_event("板端已退出MODE2，取消稳态参数切换")
        else:
            self._add_event(f"分阶段起摆结束（{action}），发送停机")
            self.request_stop()

    def request_stop(self):
        """请求 MODE 0，并保留遥测等待确认；通信失败必须使用实体急停。"""
        self.capture_switch=None
        if self.ser is None:
            return
        try:
            self._write_frame("MODE", 0)
            self.requested_mode = 0
            self.requested_at = time.monotonic()
            self.mode_text.set("MODE 0 停机请求已发送")
            self._add_event("已发送 MODE 0")
        except Exception as error:
            self._add_event(f"MODE 0 发送失败：{error}；立即使用实体急停")
        self._refresh_controls()

    def request_mode(self, target_mode):
        """直接发送 MODE 0/1/2/3；接管条件和硬件保护由 FPGA 处理。"""
        if target_mode not in (0, 1, 2, 3):
            self._add_event(f"MODE {target_mode} 无效：仅支持 0/1/2/3")
            return
        if self.ser is None:
            self._add_event(f"MODE {target_mode} 未发送：串口未连接")
            return
        if target_mode == 0:
            self.request_stop()
            return
        self._cancel_capture_switch()
        try:
            transition=None
            if target_mode==2 and self.capture_profile:
                if not (self.latest or {}).get('version','').startswith(('x','y')):
                    raise RuntimeError("本轮final分阶段配置需要Vx或Vy固件")
                steady={name:self._parse_entry(name) for name in PARAMS}
                if steady.get('HOLDPOS',0) and not supports_parameter('HOLDPOS',(self.latest or {}).get('version','')):
                    raise RuntimeError("容差保持需要先烧录Vy；尚未启动电机")
                self._send_parameter_values(prepare_capture(steady,self.capture_profile))
                transition=CaptureTransition(steady,time.monotonic())
            elif not self.send_all_parameters(from_mode=True):
                return
            self._write_frame("MODE", target_mode)
            self.capture_switch=transition
        except Exception as error:
            self._add_event(f"MODE {target_mode} 发送失败：{error}")
            if target_mode==2 and self.capture_profile and transition is not None:
                self.request_stop()
            return
        self.requested_mode = target_mode
        self.requested_at = time.monotonic()
        self._add_event(f"已发送 MODE {target_mode}；等待 FPGA 遥测确认")
        if self.capture_switch:
            self._add_event("正在使用起摆参数；连续平衡2秒后自动应用所选稳态参数")
        self._refresh_controls()

    def request_balance(self):
        """兼容旧代码入口，默认请求手动稳定模式。"""
        self.request_mode(1)

    # -- 接收 --------------------------------------------------------------
    def _sample_time(self,arrival):
        """正常串口成块到达按 100Hz 重建；超过 300ms 的缺口保留真实间隔。"""
        if self.time_base is None:self.time_base=(arrival,self.frame_index,0.)
        base_arrival,base_index,offset=self.time_base
        stamp=offset+(self.frame_index-base_index)/TELEM_HZ
        lag=arrival-base_arrival-(stamp-offset)
        if lag>.3:
            stamp+=lag
            self.time_base=(arrival,self.frame_index,stamp)
        self.frame_index+=1
        return stamp

    def _poll_serial(self):
        """定时读取 UART，重组 ASCII 行并更新样本、读数和曲线数据。"""
        if self.ser is not None:
            try:
                chunk = self.ser.read(4096)
                if chunk:
                    self.rx_buffer.extend(chunk)
                    arrival = time.monotonic()
                    while b"\n" in self.rx_buffer:
                        raw_line, _, remainder = self.rx_buffer.partition(b"\n")
                        self.rx_buffer = bytearray(remainder)
                        line = raw_line.decode("ascii", "replace").strip()
                        row = parse_telemetry(line)
                        if row:
                            row["received"] = arrival
                            row["time_s"] = self._sample_time(arrival)
                            row["tgt"] = self.sent_values.get("POSTGT")
                            self._store(row)
                            self.latest = row
                            self._update_readout(row)
            except Exception as error:
                self.connection_text.set("通信中断")
                self._add_event(f"串口读取失败：{error}；MODE 0 未确认，请用实体急停")
                try:
                    self.ser.close()
                except Exception:
                    pass
                self.ser = None
                self.connect_button.configure(text="连接")
                self._refresh_controls()
        self._poll_capture_switch()
        if self.requested_mode is not None and self.requested_at is not None:
            if time.monotonic() - self.requested_at > 1.0:
                reported = self.latest["mode"] if self.latest else "未知"
                self._add_event(f"MODE {self.requested_mode} 未获遥测确认；当前报告 MODE {reported}")
                self.requested_mode = None
                self.requested_at = None
        self.root.after(20, self._poll_serial)

    def _store(self, row):
        # 记录本机最近成功发送值；这些值不是 FPGA 参数读回。
        # 按帧保存，不能在导出时把最终参数误写到整段历史。
        for name in PARAMS:
            row[f"sent_{name}"] = self.sent_values.get(name, "")
        position=float(row["pos"])
        if row.get("pos_absolute") is not None:self.position_unwrapped=float(row["pos_absolute"])
        elif self.position_previous is None:self.position_unwrapped=position
        else:self.position_unwrapped+=shortest_delta(position,self.position_previous)
        self.position_previous=position
        row["pos_total"]=self.position_unwrapped
        target=self.sent_values.get("TURNS_POSTGT") if row["mode"]==3 else self.sent_values.get("POSTGT",row.get("tgt"))
        if row["mode"]==3:
            row["pos_error"]=row["pos_absolute"]-target if row.get("pos_absolute") is not None and target is not None else None
        else:row["pos_error"]=shortest_delta(position,target) if target is not None else None
        self.times.append(row["time_s"])
        self.rows.append(row)
        if len(self.rows) > BUFFER_MAX:
            drop = BUFFER_MAX // 4
            del self.times[:drop]
            del self.rows[:drop]
        # 记录缓冲独立于显示缓冲：只有用户点“开始记录”后才追加。
        if self.recording:
            self.recorded.append(row.copy())

    # -- 记录 --------------------------------------------------------------
    def _update_sample_text(self):
        text = f"{len(self.rows)} 帧"
        if self.recording:
            text += f" · 记录 {len(self.recorded)} 帧"
        self.sample_text.set(text)

    def _refresh_record_controls(self):
        """记录中禁用“开始记录”，仅允许“停止并保存…”。"""
        state = tk.DISABLED if self.recording else tk.NORMAL
        self.record_button.configure(state=state)
        self.record_save_button.configure(state=tk.NORMAL if self.recording else tk.DISABLED)
        self._update_sample_text()

    def start_recording(self):
        """清空记录缓冲并开始逐帧保存遥测；实时显示缓冲不受影响。"""
        if self.recording:
            self._add_event("已在记录中")
            return
        self.recorded.clear()
        self.recording = True
        self._refresh_record_controls()
        self._add_event("开始记录：记录缓冲已清空；实时曲线不受影响")

    def stop_recording_and_save(self):
        """停止记录；有数据时让用户选择 CSV 路径保存。"""
        if not self.recording:
            self._add_event("停止记录：当前没有进行中的记录")
            return
        self.recording = False
        self._refresh_record_controls()
        rows = self.recorded
        if not rows:
            self._add_event("无记录：本次未收到遥测帧")
            return
        path = filedialog.asksaveasfilename(
            parent=self.root, title="保存记录",
            initialfile=time.strftime("j280_%Y%m%d_%H%M%S.csv"),
            defaultextension=".csv", filetypes=[("CSV", "*.csv")])
        if not path:
            self._add_event("已停止记录（未保存）")
            return
        try:
            self._write_csv(path, rows)
        except (OSError, ValueError, csv.Error) as error:
            self._add_event(f"记录保存失败：{error}")
            return
        self._add_event(f"已保存 {len(rows)} 帧记录：{path}")

    def clear_data(self):
        """清空实时显示缓冲；记录缓冲只在“开始记录”时清空。"""
        self.times.clear()
        self.rows.clear()
        self.freeze_t = None
        for plot in self.plots.values():
            plot.yrange = None
        if not self.recording:
            # 记录中保持帧时间轴和累计位置连续，避免 CSV 出现负时间或跳变。
            self.frame_index = 0
            self.time_base = None
            self.position_unwrapped=self.position_previous=None
        self._update_sample_text()

    def _update_readout(self, row):
        """把最新遥测写入顶部指标，并确认待处理的 MODE 请求。"""
        self.mode_text.set(f"MODE {row['mode']}")
        self.firmware_text.set(f"固件 {row['version']} · 1040 count/圈"+
                               (f" · ABS {row['pos_absolute']:+d}" if row.get("pos_absolute") is not None else " · 无绝对计数遥测"))
        error=row.get("pos_error")
        self.position_error_text.set(f"位置误差 {error:+.1f} count" if error is not None else "位置误差 -- count（目标未发送）")
        self.balance_text.set(self._status_text(
            row["bal_status"], row["mode"], row.get("swing_active")))
        if row.get('position_hold') and row['bal_status']&4 and not row['bal_status']&10:
            self.balance_text.set("容差保持中 · 角度闭环持续纠偏")
        self.config_text.set(f"板端参数帧计数：{row['config_count']}（无具体参数读回）")
        self._update_sample_text()
        self.metric_vars["ang"].set(f"{row['ang']:+.2f}")
        self.metric_vars["ref"].set(f"{row['ref']:+.2f}" if row["ref"] is not None else "--")
        self.metric_vars["raw"].set(f"{row['raw']:04d}")
        self.metric_vars["pos"].set(f"{row['pos']:+d}")
        self.metric_vars["spd"].set(f"{row['spd']:+d}")
        self.metric_vars["dut"].set(f"{row['dut']:+d}")
        if self.requested_mode is not None and row["mode"] == self.requested_mode:
            self._add_event(f"板端已确认 MODE {row['mode']}")
            self.requested_mode = None
            self.requested_at = None
        self._refresh_controls()

    @staticmethod
    def _status_text(status, mode, swing_active=None):
        """按 msg_tx 的状态位生成面向调试者的简短说明。"""
        if status & 8:
            return "输出保护暂停；模式保持，可恢复或重发当前模式"
        if status & 4:
            return "角度环已接管"
        if status & 2:
            return "超角度保护；回到接管角度窗口后恢复"
        if mode == 3:
            if status & 1:
                return "MODE 3 绝对位置：角度已到接管窗口，等待接管"
            return "MODE 3 绝对位置：等待摆杆直立窗口后接管"
        if mode == 2 and swing_active:
            return "自动起摆驱动中（SW=1）"
        if mode in (1, 2) and status & 1:
            return "角度在接管范围，等待接管"
        if mode == 1:
            return "手动稳定模式，等待角度接管"
        if mode == 2:
            return "起摆等待捕获；若已在零位附近会直接稳定"
        if mode == 0:
            return "停机"
        return f"旧版模式 {mode}：请先停机"

    def _refresh_controls(self):
        """只根据串口连接状态启用模式按钮；接管条件由 FPGA 实时判断。"""
        state = tk.NORMAL if self.ser is not None else tk.DISABLED
        self.manual_button.configure(state=state)
        self.swing_button.configure(state=state, text="自动起摆 · 分阶段" if self.capture_profile else "自动起摆  MODE 2")
        self.mode3_button.configure(state=state)
        self.stop_button.configure(state=state)

    # -- 绘图 --------------------------------------------------------------
    def _span_seconds(self):
        return int(self.plot_window.get().split()[0])

    def _toggle_pause_key(self, _event=None):
        focus = self.root.focus_get()
        if focus is not None and focus.winfo_class() in ("TEntry", "Entry", "TCombobox", "Text"):
            return
        self.paused.set(not self.paused.get())
        self._on_pause_changed()

    def _on_pause_changed(self):
        self.freeze_t = self.times[-1] if (self.paused.get() and self.times) else None

    @staticmethod
    def _series_value(row, name):
        """把绘图系列名称映射为遥测字典中的数值。"""
        if name == "ANG":
            return row["ang"]
        if name == "REF":
            return row["ref"]
        if name == "RAW":
            return row["raw"]
        if name == "POS":
            return row["pos"]
        if name == "SPD":
            return row["spd"]
        return row["dut"]

    def _visible_slice(self):
        """返回当前时间窗内的 (times, rows, t0, t1)。"""
        if not self.times:
            return [], [], 0.0, 1.0
        span = self._span_seconds()
        t1 = self.freeze_t if (self.paused.get() and self.freeze_t is not None) else self.times[-1]
        t0 = t1 - span
        start = bisect.bisect_left(self.times, t0)
        end = bisect.bisect_right(self.times, t1)
        return self.times[start:end], self.rows[start:end], t0, t1

    def _draw_charts(self):
        """按所选时间窗刷新所有曲线窗口；由 Tk 定时器周期调用。"""
        times, rows, t0, t1 = self._visible_slice()
        for plot in self.plots.values():
            try:
                plot.draw(times, rows, t0, t1)
            except Exception as error:      # 绘图错误不能拖垮串口轮询
                self._add_event(f"绘图错误 {plot.key}：{error}")
        self._update_analysis(times, rows)
        self.root.after(50, self._draw_charts)

    def _update_analysis(self, times, rows):
        if len(rows) < 30:
            self._set_analysis("摆动分析：等待数据（需要 ≥1 s）")
            return
        pos = [float(r["pos"]) for r in rows]
        ang = [float(r["ang"]) for r in rows]
        dut = [float(r["dut"]) for r in rows]
        unwrapped, offset, previous = [], 0.0, pos[0]
        for value in pos:                    # 去掉单圈回绕跳变后再估计
            if value - previous > ENC_CPR / 2:
                offset -= ENC_CPR
            elif previous - value > ENC_CPR / 2:
                offset += ENC_CPR
            unwrapped.append(value + offset)
            previous = value
        pos_f, pos_a = estimate_oscillation(times, unwrapped, 1.0)
        ang_f, ang_a = estimate_oscillation(times, ang, 0.05)
        duration = max(times[-1] - times[0], 1e-6)
        flips = count_reversals(dut) / duration
        stats = window_stats(dut)
        duty_rms = stats[1] if stats else 0.0

        def fmt(freq, amp, unit):
            return f"±{amp:.1f}{unit}" + (f"@{freq:.2f}Hz" if freq else "")
        summary = (
            f"摆动分析（当前窗）：位置 {fmt(pos_f, pos_a, 'count')}  |  "
            f"角度 {fmt(ang_f, ang_a, '°')}  |  "
            f"输出换向 {flips:.1f} 次/s  |  DUT RMS {duty_rms:.0f}")
        balancing = bool(self.latest and (self.latest["bal_status"] & 4))
        hint = (diagnose(pos_f, pos_a, ang_f, ang_a, flips, duty_rms)
                if balancing else "")
        self._set_analysis(summary, hint)

    def _set_analysis(self, summary, hint=""):
        """固定高度分析区的唯一写入口；保留滚动位置，绝不改变外层高度。"""
        view = self.analysis_view
        if view is None:
            return
        content = summary + (("\n" + hint) if hint else "")
        if content == self.analysis_cache:
            return
        self.analysis_cache = content
        try:
            position = view.yview()[0]
        except tk.TclError:
            position = 0.0
        view.configure(state="normal")
        view.delete("1.0", "end")
        view.insert("1.0", summary, "analysis")
        if hint:
            view.insert("end", "\n" + hint, "hint")
        view.configure(state="disabled")
        view.yview_moveto(position)

    def _nearest_row(self, stamp):
        if not self.times:
            return None
        index = min(max(bisect.bisect_left(self.times, stamp), 0), len(self.times) - 1)
        if index > 0 and abs(self.times[index - 1] - stamp) < abs(self.times[index] - stamp):
            index -= 1
        return self.rows[index]

    def _on_hover(self, key, event):
        plot = self.plots[key]
        if plot.view is None:
            return
        stamp = plot.time_at(event.x)
        if not (plot.view[0] <= stamp <= plot.view[1]):
            self._clear_crosshair()
            return
        row = self._nearest_row(stamp)
        for other in self.plots.values():
            if other.view is not None:
                other.crosshair(stamp, row)

    def _clear_crosshair(self):
        for plot in self.plots.values():
            plot.canvas.delete("xhair")

    def _on_plot_click(self, key, event):
        self.plots[key].click(event.x, event.y)

    def _add_event(self, text):
        """向事件窗口追加带本地时间的状态消息。"""
        stamp = time.strftime("%H:%M:%S")
        self.events.append(f"{stamp}  {text}")
        self.event_view.configure(state="normal")
        self.event_view.insert("end", self.events[-1] + "\n")
        self.event_view.see("end")
        self.event_view.configure(state="disabled")

    def _write_csv(self, path, rows):
        """按旧版导出字段与时间归零规则写 CSV。"""
        fields = ("time_s", "ang", "ref", "ref_cdeg", "raw", "pos", "pos_absolute", "src_local", "spd", "dut",
                  "mode", "bal_status", "swing_active", "position_hold", "version", "config_count", "tgt", "pos_total", "pos_error")
        fields += tuple(f"sent_{name}" for name in PARAMS)
        start = rows[0]["time_s"]
        with open(path, "w", encoding="utf-8-sig", newline="") as output:
            writer = csv.DictWriter(output, fieldnames=fields)
            writer.writeheader()
            for row in rows:
                out = {key: row.get(key, "") for key in fields}
                out["time_s"] = row["time_s"] - start
                writer.writerow(out)

    def close(self):
        """关闭前处理未保存记录、保存状态并尽力发送 MODE 0。"""
        if self.recording:
            if messagebox.askyesno("正在记录", "停止并保存记录后退出？", parent=self.root):
                self.stop_recording_and_save()
        self._save_state()
        if self.ser is not None:
            try:
                if self.ser.is_open:
                    self._write_frame("MODE", 0)
                    self.ser.close()
            except Exception:
                pass
        self.root.destroy()


def enable_dpi_awareness():
    """Windows 使用实际屏幕像素布局，避免系统缩放造成窗口截断与字体模糊。"""
    try:
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except (AttributeError,OSError):
        pass


def main():
    enable_dpi_awareness()
    root = tk.Tk()
    DebugApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
