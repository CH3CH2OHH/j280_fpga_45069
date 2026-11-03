# -*- coding: utf-8 -*-
"""J280 最新固件协议自测（参数表 / 帧编码 / 103B 遥测）。

运行：.qtcreator\\Python_3_11_9venv\\Scripts\\python.exe tests\\protocol_test.py
覆盖 BUILD60 / Vy 协议：
  - 新参数 ID 48..54、MODE 0..3、TURNS_POSTGT 全 signed16 范围；
  - AA IDX HI LO 帧编码（负数二补码）；
  - 103 字节扩展遥测（ABS signed32 / SRC / HLD）与旧遥测兼容。
"""
import json
import sys
import time
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BASE))

import j280_protocol as proto  # noqa: E402

REPORT = {"ok": False, "checks": {}, "started": time.strftime("%Y-%m-%d %H:%M:%S")}


def check(name, ok, detail=""):
    REPORT["checks"][name] = {"ok": bool(ok), "detail": str(detail)}


def main():
    # 参数表
    expected_new = {
        "TURNS_POSTGT": 48, "PIDEAD": 49, "KDBLEND": 50,
        "VELMODE": 51, "ADCAVG": 52, "RATEMODE": 53, "HOLDPOS": 54,
    }
    check("new_param_ids", all(proto.PARAM.get(k) == v for k, v in expected_new.items()),
          {k: proto.PARAM.get(k) for k in expected_new})
    check("param_count", len(proto.PARAM) == 40, len(proto.PARAM))
    check("range_count", len(proto.PARAM_RANGES) == 40, len(proto.PARAM_RANGES))
    check("table_self_check", proto.table_self_check() is True, "")
    check("mode_range", proto.PARAM_RANGES["MODE"] == (0, 3), proto.PARAM_RANGES["MODE"])
    check("turns_range", proto.PARAM_RANGES["TURNS_POSTGT"] == (-32768, 32767),
          proto.PARAM_RANGES["TURNS_POSTGT"])
    check("hold_range", proto.PARAM_RANGES["HOLDPOS"] == (0, 160),
          proto.PARAM_RANGES["HOLDPOS"])

    # 范围 / 模式校验
    check("mode3_ok", proto.validate_value("MODE", 3) == 3, "")
    try:
        proto.validate_value("MODE", 4)
        mode4 = False
    except ValueError:
        mode4 = True
    check("mode4_reject", mode4, "")
    check("turns_min", proto.validate_value("TURNS_POSTGT", -32768) == -32768, "")
    check("turns_max", proto.validate_value("TURNS_POSTGT", 32767) == 32767, "")
    for name, value in (("TURNS_POSTGT", 32768), ("TURNS_POSTGT", -32769),
                        ("PIDEAD", 9), ("KDBLEND", 7), ("VELMODE", 2),
                        ("ADCAVG", 4), ("RATEMODE", 3), ("HOLDPOS", 161)):
        try:
            proto.validate_value(name, value)
            rejected = False
        except ValueError:
            rejected = True
        check("reject_%s_%s" % (name, value), rejected, "")

    # 帧编码：AA IDX HI LO，负数二补码
    check("frame_mode3", proto.frame(proto.PARAM["MODE"], 3) == b"\xaa\x05\x00\x03", "")
    check("frame_turns_min", proto.frame(48, -32768) == b"\xaa\x30\x80\x00", "")
    check("frame_turns_max", proto.frame(48, 32767) == b"\xaa\x30\x7f\xff", "")
    check("frame_turns_neg1", proto.frame(48, -1) == b"\xaa\x30\xff\xff", "")

    # 103B 扩展遥测
    sample = ("ANG=+012.34 RAW=0508 POS=-00520 SPD=-0080 DUT=+0127 "
              "REF=+0000 M1B5 SW=0 Vy6 ABS=0000ABCD SRC=0 HLD=1")
    row = proto.parse_telemetry(sample)
    check("telemetry_parsed", row is not None, "")
    if row:
        check("telemetry_ang", abs(row["ang"] - 12.34) < 1e-9, row["ang"])
        check("telemetry_raw", row["raw"] == 508, row["raw"])
        check("telemetry_pos", row["pos"] == -520, row["pos"])
        check("telemetry_spd", row["spd"] == -80, row["spd"])
        check("telemetry_dut", row["dut"] == 127, row["dut"])
        check("telemetry_ref", row["ref"] == 0.0, row["ref"])
        check("telemetry_mode", row["mode"] == 1, row["mode"])
        check("telemetry_status", row["bal_status"] == 5, row["bal_status"])
        check("telemetry_sw", row["swing_active"] is False, row["swing_active"])
        check("telemetry_abs", row["pos_absolute"] == 0xABCD, row["pos_absolute"])
        check("telemetry_src", row["src_local"] == 0, row["src_local"])
        check("telemetry_hld", row["position_hold"] is True, row["position_hold"])
        check("telemetry_version", row["version"] == "y6" and row["config_count"] == 6,
              "%s / %s" % (row["version"], row["config_count"]))

    neg = proto.parse_telemetry(sample.replace("ABS=0000ABCD", "ABS=FFFFFFFE"))
    check("telemetry_abs_negative", neg and neg["pos_absolute"] == -2,
          neg["pos_absolute"] if neg else None)

    old = proto.parse_telemetry(
        "ANG=-001.23 RAW=0500 POS=+00123 SPD=+0062 DUT=-0123 REF=+0000 M1B4 Vy6")
    check("old_telemetry_compat", old is not None and old["pos_absolute"] is None and
          old["src_local"] is None and old["position_hold"] is None, old)

    # 版本能力过滤
    check("supports_hold_y", proto.supports_parameter("HOLDPOS", "y6") is True, "")
    check("supports_hold_old", proto.supports_parameter("HOLDPOS", "s1040") is False, "")
    check("supports_ratemode_x", proto.supports_parameter("RATEMODE", "x1") is True, "")

    REPORT["ok"] = all(item["ok"] for item in REPORT["checks"].values())
    REPORT["elapsed_s"] = 0.0
    out = BASE / "tests" / "last_protocol.json"
    out.write_text(json.dumps(REPORT, ensure_ascii=False, indent=2), encoding="utf-8")
    print("=" * 70)
    print("PROTOCOL REPORT: " + ("PASS" if REPORT["ok"] else "FAIL"))
    for name, item in REPORT["checks"].items():
        if not item["ok"]:
            print("  FAIL %s %s" % (name, item["detail"]))
    print("  checks: %d/%d" % (sum(1 for i in REPORT["checks"].values() if i["ok"]),
                                len(REPORT["checks"])))
    print("=" * 70)
    return 0 if REPORT["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
