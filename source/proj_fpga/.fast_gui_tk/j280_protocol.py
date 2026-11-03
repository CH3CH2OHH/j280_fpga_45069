#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""J280 角度环调试协议、参数范围和遥测解析。"""

import re


# 参数名到 FPGA cfg_regs 参数编号的映射；编号必须与 cfg_regs.v 的 case(index)
# 保持一致，改变任一侧都会导致串口帧写入错误寄存器。
PARAM = {
    "LIM": 4,
    "MODE": 5,
    "DZ": 6,
    "TRIM": 7,
    "FALL": 10,
    "ENTER": 12,
    "ZERO": 16,
    "ILIM": 18,
    "DLP": 21,
    "AKP": 23,
    "AKI": 24,
    "AKD": 25,
    "PKP": 26,
    "PKD": 27,
    "POSMAX": 28,
    "POSTGT": 29,
    # MODE3 绝对位置目标（替代 POSTGT，signed 16 全范围）；必须与 cfg_regs.v 的 ID 48 一致。
    "TURNS_POSTGT": 48,
    "ALP": 30,
    "SLEW": 31,
    "SWLIM": 32,
    "SWCAP": 33,
    "SWTMO": 34,
    "SWDIR": 35,
    "POS_NEAR": 37,
    "PKDNEAR": 38,
    "POSP_LIM": 39,
    "SWAMP": 40,
    "SWRAMP": 41,
    "SWMS": 42,
    "PKI": 43,
    "PILIM": 44,
    "RLP": 45,
    "DZW": 46,
    "DZLP": 47,
    "PIDEAD":49,
    "KDBLEND":50,
    "VELMODE":51,
    "ADCAVG":52,
    "RATEMODE":53,
    "HOLDPOS":54,
}

# 上位机先做一次范围检查，板端仍会再次限幅/拒绝，双重校验便于尽早发现输入错误。
PARAM_RANGES = {
    "LIM": (0, 1023),
    "MODE": (0, 3),
    "DZ": (0, 1023),
    "TRIM": (-18000, 18000),
    "FALL": (1, 18000),
    "ENTER": (1, 18000),
    "ZERO": (1, 1022),
    "ILIM": (0, 1023),
    "DLP": (0, 8),
    "AKP": (-4096, 4096),
    "AKI": (-4096, 4096),
    "AKD": (-4096, 4096),
    "PKP": (-4096, 4096),
    "PKD": (-4096, 4096),
    "POSMAX": (0, 18000),
    "POSTGT": (-520, 519),
    "TURNS_POSTGT": (-32768, 32767),
    "ALP": (0, 8),
    "SLEW": (0, 1023),
    "SWLIM": (0, 1023),
    "SWCAP": (1, 18000),
    "SWTMO": (100, 60000),
    "SWDIR": (-1, 1),
    "POS_NEAR": (0, 520),
    "PKDNEAR": (-4096, 4096),
    "POSP_LIM": (0, 1023),
    "SWAMP": (0, 1023),
    "SWRAMP": (0, 60000),
    "SWMS": (1, 1000),
    "PKI": (-256, 256),
    "PILIM": (0, 600),
    "RLP": (0, 6),
    "DZW": (1, 256),
    "DZLP": (0, 4),
    "PIDEAD":(0,8),
    "KDBLEND":(0,6),
    "VELMODE":(0,1),
    "ADCAVG":(0,3),
    "RATEMODE":(0,2),
    "HOLDPOS":(0,160),
}

# msg_tx 每 100 Hz 输出一行 ASCII：角度、RAW、单圈位置、速度、PWM、参考角度、
# MODE/状态位和版本号。兼容旧版使用 PR 字段的遥测，以便分析历史 CSV。
LINE_RE = re.compile(
    r"ANG=(?P<ang>[+-]\d+\.\d+)\s+RAW=(?P<raw>\d+)\s+"
    r"POS=(?P<pos>[+-]\d+)\s+SPD=(?P<spd>[+-]\d+)\s+"
    r"DUT=(?P<dut>[+-]\d+)\s+(?P<aux_name>REF|PR)=(?P<aux>[+-]\d+)\s+"
    r"M(?P<mode>\d)B(?P<status>[0-9A-F])"
    r"(?:\s+SW=(?P<swing_active>[01]))?\s+V(?P<version>\S+)"
)


def frame(idx, value):
    """构造 ``AA | IDX | VALUE_HI | VALUE_LO`` 四字节参数帧。

    value 按 16 位二补码发送；因此负增益直接传入 Python 整数即可。
    """
    value = int(value) & 0xFFFF
    return bytes((0xAA, int(idx) & 0xFF, (value >> 8) & 0xFF, value & 0xFF))


def supports_parameter(name, version):
    """按固件功能版本过滤新增寄存器，防止旧固件忽略后仍显示已发送。"""
    prefix=str(version)[:1]
    if name=='HOLDPOS': return prefix=='y'
    if name=='RATEMODE': return prefix in ('x','y')
    if name=='ADCAVG': return prefix in ('w','x','y')
    if name=='VELMODE': return prefix in ('v','w','x','y')
    if name in ('PIDEAD','KDBLEND'): return prefix in ('t','u','v','w','x','y')
    return True


def table_self_check():
    """参数表一致性自测：PARAM / PARAM_RANGES 必须一一对应、编号唯一。

    cfg_regs.v 只接受 8 bit 参数编号，重复编号会让两个参数写到同一寄存器，
    因此这里在 GUI 启动时直接断言，避免协议表和固件悄悄分叉。
    """
    if set(PARAM) != set(PARAM_RANGES):
        only_param = sorted(set(PARAM) - set(PARAM_RANGES))
        only_range = sorted(set(PARAM_RANGES) - set(PARAM))
        raise AssertionError(
            f"PARAM/PARAM_RANGES 不一致：缺范围 {only_param}，缺编号 {only_range}")
    indices = list(PARAM.values())
    if len(indices) != len(set(indices)):
        raise AssertionError("PARAM 中存在重复的参数编号")
    for name, idx in PARAM.items():
        if not isinstance(idx, int) or not 1 <= idx <= 255:
            raise AssertionError(f"参数 {name} 的编号 {idx} 超出 1..255")
        low, high = PARAM_RANGES[name]
        # 帧里是 16 bit：有符号参数用二补码，无符号参数（如 SWTMO）可用到 65535。
        if not -32768 <= low <= high <= 65535:
            raise AssertionError(f"参数 {name} 的范围 {low}~{high} 超出 16 bit 帧范围")
    if PARAM["TURNS_POSTGT"] != 48:
        raise AssertionError("TURNS_POSTGT 必须使用 cfg_regs.v 的 ID 48")
    return True


def validate_value(name_or_idx, value):
    """校验参数范围；未知编号不允许发送。"""
    name = str(name_or_idx).upper()
    if name not in PARAM:
        idx = int(name_or_idx)
        name = next((key for key, value_idx in PARAM.items() if value_idx == idx), "")
    if not name:
        raise ValueError(f"不支持的参数：{name_or_idx}")
    value = int(value)
    low, high = PARAM_RANGES[name]
    if not low <= value <= high:
        raise ValueError(f"参数 {name} 必须在 {low}~{high}，收到 {value}")
    if name=="DZW" and value & (value-1):
        raise ValueError("DZW 必须为 1/2/4/8/16/32/64/128/256")
    if name == "MODE" and value not in (0, 1, 2, 3):
        raise ValueError("MODE 只支持 0=停机、1=手动稳定、2=自动起摆、3=绝对位置（转圈/定位）")
    return value


def parse_telemetry(line):
    """解析新旧遥测并统一字段。

    ``REF`` 是当前角度参考值（0.01 度），旧版 ``PR`` 只是相对位置字段，
    不能误当成参考角度；格式不完整时返回 ``None``。
    """
    match = LINE_RE.search(line)
    if not match:
        return None
    version = match.group("version")
    count = int(version[-1]) if version and version[-1].isdigit() else None
    aux = int(match.group("aux"))
    ref_cdeg = aux if match.group("aux_name") == "REF" else None
    extended=re.search(r"\sABS=([0-9A-Fa-f]{8})\s+SRC=([01])(?:\s|$)",line)
    held=re.search(r"\sHLD=([01])(?:\s|$)",line)
    absolute=int(extended.group(1),16) if extended else None
    if absolute is not None and absolute>=0x80000000:
        absolute-=0x100000000
    return {
        "ang": float(match.group("ang")),
        "raw": int(match.group("raw")),
        "pos": int(match.group("pos")),
        "pos_absolute":absolute,
        "src_local":int(extended.group(2)) if extended else None,
        "position_hold":bool(int(held.group(1))) if held else None,
        "spd": int(match.group("spd")),
        "dut": int(match.group("dut")),
        "ref_cdeg": ref_cdeg,
        "ref": ref_cdeg / 100.0 if ref_cdeg is not None else None,
        "legacy_pr": aux if match.group("aux_name") == "PR" else None,
        "mode": int(match.group("mode")),
        "bal_status": int(match.group("status"), 16),
        "swing_active": (None if match.group("swing_active") is None
                          else match.group("swing_active") == "1"),
        "version": version,
        "config_count": count,
        "line": line.strip(),
    }
