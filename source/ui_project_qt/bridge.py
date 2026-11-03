#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""J280 HTML 调试台 · Python 后端桥（串口 + 文件 + 状态持久化）。

本类在 Qt 外壳中注册为 QWebChannel 对象 ``qt_mainWnd``（见 mainWnd.py），
前端 ``res/js/bridge.js`` 通过它调用串口与文件槽；**所有槽的返回值都是
JSON 字符串**（``{"ok":true,...}`` / ``{"ok":false,"error":"..."}``）。

设计要点：
- 串口由 Python 独占：pyserial 115200 8N1，``timeout=0`` / ``write_timeout=1``；
  打开后 ``dtr=False; rts=False; reset_input_buffer()``（与原 Tk GUI 一致）。
- 读取：QTimer 20 ms ``read(4096)``，按 ``\\n`` 拆行交给 j280_protocol.parse_telemetry；
  时间轴移植原 ``_sample_time``（100 Hz 帧序号，lag > 0.3 s 时保留真实间隔）。
- 上报：每 50 ms 批量 emit ``telemetry``（单批最多 200 行，紧凑 JSON）；
  连接/断开/异常 emit ``status`` 与 ``eventLog``。
- 文件：QFileDialog（parent 取 QApplication.activeWindow()），JSON 用 UTF-8，
  CSV 用 ``utf-8-sig`` + ``newline=''``；state 原子写入 ``data/ui_state.json``。
- 测试钩子：环境变量 ``J280_UI_TEST_DIR``（文件对话框绕过）与
  ``J280_UI_STATE_PATH``（覆盖状态文件路径），见各槽实现。
- 任何槽内部异常都被捕获并转为 ``{"ok":false,"error":...}``，不向 Qt 抛出。
"""

from __future__ import annotations

import json
import os
import tempfile
import time
from typing import Any, Optional

from PySide6.QtCore import QObject, QTimer, Signal, Slot

try:  # 文件对话框在无 GUI 的单元测试里也可能 import，故延迟使用
    from PySide6.QtWidgets import QApplication, QFileDialog
except Exception:  # pragma: no cover
    QApplication = None
    QFileDialog = None

try:
    import serial
    from serial.tools import list_ports
except Exception:  # pragma: no cover - pyserial 缺失时串口功能报错
    serial = None
    list_ports = None

# 同目录 vendored 协议模块（同步自 project/gui/j280_protocol.py）
from j280_protocol import (PARAM, frame, parse_telemetry, supports_parameter,
                           validate_value)
from globals import globalVar

# ---------------------------------------------------------------------------
# 常量（与原 Tk GUI / 规范 9.2 保持一致）
# ---------------------------------------------------------------------------
BAUDRATE = 115200
TELEM_HZ = 100.0            # msg_tx 每秒帧数：时间轴按帧序号生成
READ_INTERVAL_MS = 20       # 串口轮询周期
FLUSH_INTERVAL_MS = 50      # 遥测批量上报周期
TELEMETRY_BATCH_MAX = 200   # 单次 telemetry 信号最大行数
RX_CHUNK = 4096

# 与 project/gui/j280_debug_gui.py 的 PARAMS 顺序一致；sendAll 按此顺序拼帧。
# （PARAM 映射里另有 MODE，但界面参数组不含 MODE，MODE 由 setMode 单独发送。）
PARAM_ORDER = (
    "AKP", "AKI", "AKD", "PKP", "PKD", "PKI", "PILIM", "PIDEAD", "KDBLEND",
    "VELMODE", "RLP", "POS_NEAR", "PKDNEAR", "POSP_LIM", "POSMAX", "POSTGT",
    "TURNS_POSTGT", "ENTER", "FALL", "TRIM", "LIM", "DZ", "DZW", "DZLP",
    "ILIM", "DLP", "RATEMODE", "ALP", "ADCAVG", "SLEW", "HOLDPOS",
    "SWLIM", "SWAMP", "SWRAMP", "SWMS", "SWCAP", "SWTMO", "SWDIR", "ZERO",
)

_ILLEGAL_NAME_CHARS = '<>:"/\\|?*'


def _ok(**extra: Any) -> str:
    """成功返回值：``{"ok":true, ...}`` 的 JSON 字符串。"""
    payload = {"ok": True}
    payload.update(extra)
    return json.dumps(payload, ensure_ascii=False)


def _err(message: Any, **extra: Any) -> str:
    """失败返回值：``{"ok":false,"error":"..."}`` 的 JSON 字符串。"""
    payload = {"ok": False, "error": str(message)}
    payload.update(extra)
    return json.dumps(payload, ensure_ascii=False)


def _parse_int(value: Any) -> int:
    """把前端传来的数字/十进制/0x 文本解析成 int；失败抛 ValueError。"""
    if isinstance(value, bool):
        raise ValueError(f"不是整数：{value}")
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        if value != int(value):
            raise ValueError(f"不是整数：{value}")
        return int(value)
    return int(str(value).strip(), 0)


def _safe_filename(name: Any) -> str:
    """只取文件名部分并清理 Windows 非法字符，避免路径穿越。"""
    base = os.path.basename(str(name or "").strip())
    for char in _ILLEGAL_NAME_CHARS:
        base = base.replace(char, "_")
    return base.strip(". ")


class SerialBridge(QObject):
    """QWebChannel 后端对象（注册名固定 ``qt_mainWnd``）。"""

    # Py -> JS：遥测批（JSON 数组）、连接状态（JSON 对象）、事件（JSON 对象）
    telemetry = Signal(str)
    status = Signal(str)
    eventLog = Signal(str)

    def __init__(self, parent: Optional[QObject] = None) -> None:
        super().__init__(parent)
        self._serial: Optional[Any] = None
        self._port: Optional[str] = None
        self._rx_buffer = bytearray()
        self._frame_index = 0
        self._time_base: Optional[tuple] = None
        self._tx_buffer: list[dict] = []
        self._latest_version = ""
        self._latest_src_local: Optional[int] = None

        # 20 ms 读取串口；只在端口打开时启动
        self._read_timer = QTimer(self)
        self._read_timer.setInterval(READ_INTERVAL_MS)
        self._read_timer.timeout.connect(self._poll_serial)

        # 50 ms 批量上报遥测；构造函数即启动，没有数据时不会 emit
        self._flush_timer = QTimer(self)
        self._flush_timer.setInterval(FLUSH_INTERVAL_MS)
        self._flush_timer.timeout.connect(self._flush_telemetry)
        try:
            self._flush_timer.start()
        except Exception:  # pragma: no cover - 无事件循环时忽略
            pass

    # ------------------------------------------------------------------
    # 路径 / 状态辅助
    # ------------------------------------------------------------------
    @staticmethod
    def _base_dir() -> str:
        """源码运行时为工程目录；打包 exe 后为 exe 所在目录。"""
        return globalVar.APP_DIR

    def _state_path(self) -> str:
        override = os.environ.get("J280_UI_STATE_PATH")
        if override and override.strip():
            return os.path.abspath(override.strip())
        return os.path.join(globalVar.DATA_DIR, "ui_state.json")

    @staticmethod
    def _test_dir() -> Optional[str]:
        value = os.environ.get("J280_UI_TEST_DIR")
        if value and value.strip():
            return os.path.abspath(value.strip())
        return None

    @staticmethod
    def _dialog_parent() -> Optional[Any]:
        try:
            if QApplication is not None:
                return QApplication.activeWindow()
        except Exception:  # pragma: no cover
            pass
        return None

    def _is_open(self) -> bool:
        try:
            return self._serial is not None and bool(self._serial.is_open)
        except Exception:
            return False

    def _port_names(self) -> list[str]:
        if list_ports is None:
            return []
        try:
            return [port.device for port in list_ports.comports()]
        except Exception:
            return []

    # ------------------------------------------------------------------
    # 信号发送辅助
    # ------------------------------------------------------------------
    def _emit_status(self, **info: Any) -> None:
        payload = {
            "connected": self._is_open(),
            "port": self._port,
            "demo": False,
        }
        payload.update(info)
        try:
            self.status.emit(json.dumps(payload, ensure_ascii=False))
        except Exception:  # pragma: no cover
            pass

    def _emit_event(self, level: str, text: str) -> None:
        try:
            self.eventLog.emit(json.dumps({"level": level, "text": str(text)},
                                          ensure_ascii=False))
        except Exception:  # pragma: no cover
            pass

    # ------------------------------------------------------------------
    # 串口生命周期
    # ------------------------------------------------------------------
    def _open_device(self, port: str):
        """按原 GUI 的参数打开串口并做 DTR/RTS/输入缓冲初始化。"""
        if serial is None:
            raise RuntimeError("pyserial 未安装，无法使用串口")
        device = serial.Serial(
            port,
            BAUDRATE,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=0,
            write_timeout=1,
            dsrdtr=False,
            rtscts=False,
        )
        try:
            device.dtr = False
            device.rts = False
        except Exception:
            # 部分虚拟串口不支持控制线设置，不影响收发
            pass
        device.reset_input_buffer()
        return device

    def _close_serial(self, send_stop: bool = True) -> None:
        """关闭串口。``send_stop`` 为真时先尽力发送 MODE 0 停机帧。"""
        device = self._serial
        self._read_timer.stop()
        self._serial = None
        self._port = None
        self._rx_buffer.clear()
        self._tx_buffer.clear()
        if device is None:
            return
        try:
            if device.is_open:
                if send_stop:
                    try:
                        device.write(frame(PARAM["MODE"], 0))
                        device.flush()
                        self._emit_event("info", "断开前已发送 MODE 0")
                    except Exception as error:
                        self._emit_event(
                            "warn",
                            f"断开时 MODE 0 未确认：{error}；请使用实体急停",
                        )
                device.close()
        except Exception as error:
            self._emit_event("warn", f"关闭串口时出错：{error}")

    # ------------------------------------------------------------------
    # 读取与时间轴（移植原 Tk GUI _poll_serial / _sample_time）
    # ------------------------------------------------------------------
    def _sample_time(self, arrival: float) -> float:
        """正常串口成块到达按 100 Hz 重建；超过 300 ms 的缺口保留真实间隔。"""
        if self._time_base is None:
            self._time_base = (arrival, self._frame_index, 0.0)
        base_arrival, base_index, offset = self._time_base
        stamp = offset + (self._frame_index - base_index) / TELEM_HZ
        lag = arrival - base_arrival - (stamp - offset)
        if lag > 0.3:
            stamp += lag
            self._time_base = (arrival, self._frame_index, stamp)
        self._frame_index += 1
        return stamp

    def _make_row(self, parsed: dict, arrival: float) -> dict:
        """把 parse_telemetry 结果转换成规范 9.3 的紧凑遥测行。"""
        stamp = self._sample_time(arrival)
        return {
            "t": round(stamp, 4),
            "ang": parsed["ang"],
            "raw": parsed["raw"],
            "pos": parsed["pos"],
            "spd": parsed["spd"],
            "dut": parsed["dut"],
            "ref": parsed["ref"],
            "mode": parsed["mode"],
            "st": parsed["bal_status"],
            "sw": parsed["swing_active"],
            "ver": parsed["version"],
            "cc": parsed["config_count"],
            # Vy 扩展遥测（旧固件缺省为 None）
            "abs": parsed.get("pos_absolute"),
            "src": parsed.get("src_local"),
            "hld": parsed.get("position_hold"),
        }

    def _poll_serial(self) -> None:
        """QTimer 20 ms：读取 UART、拆行、解析、入批量缓冲。"""
        device = self._serial
        if device is None:
            return
        try:
            chunk = device.read(RX_CHUNK)
            if chunk:
                self._rx_buffer.extend(chunk)
                arrival = time.monotonic()
                while b"\n" in self._rx_buffer:
                    raw_line, _, remainder = self._rx_buffer.partition(b"\n")
                    self._rx_buffer = bytearray(remainder)
                    line = raw_line.decode("ascii", "replace").strip()
                    if not line:
                        continue
                    row = parse_telemetry(line)
                    if row:
                        self._latest_version = row.get("version") or ""
                        self._latest_src_local = row.get("src_local")
                        self._tx_buffer.append(self._make_row(row, arrival))
        except Exception as error:
            self._emit_event(
                "error",
                f"串口读取失败：{error}；MODE 0 未确认，请使用实体急停",
            )
            self._close_serial(send_stop=False)
            self._emit_status(connected=False, port=None, error=str(error))

    def _flush_telemetry(self) -> None:
        """QTimer 50 ms：把缓冲的遥测按 ≤200 行/批 emit 给前端。"""
        if not self._tx_buffer:
            return
        try:
            while self._tx_buffer:
                batch = self._tx_buffer[:TELEMETRY_BATCH_MAX]
                del self._tx_buffer[:TELEMETRY_BATCH_MAX]
                self.telemetry.emit(
                    json.dumps(batch, ensure_ascii=False, separators=(",", ":"))
                )
        except Exception:  # pragma: no cover - 信号发射失败不能影响串口读取
            pass

    # ------------------------------------------------------------------
    # 槽：状态 / 串口
    # ------------------------------------------------------------------
    @Slot(result=str)
    def getStatus(self) -> str:
        try:
            return _ok(
                connected=self._is_open(),
                port=self._port,
                demo=False,
                ports=self._port_names(),
            )
        except Exception as error:
            return _err(error)

    @Slot(result=str)
    def listPorts(self) -> str:
        try:
            return _ok(ports=self._port_names())
        except Exception as error:
            return _err(error)

    @Slot(str, result=str)
    def openPort(self, port: str) -> str:
        port_text = str(port or "").strip()
        try:
            if not port_text:
                return _err("请选择串口")
            if self._is_open():
                if self._port == port_text:
                    return _err(f"串口已连接：{port_text}")
                self._close_serial(send_stop=True)
            device = self._open_device(port_text)
            self._serial = device
            self._port = port_text
            self._rx_buffer.clear()
            self._tx_buffer.clear()
            self._frame_index = 0
            self._time_base = None
            self._read_timer.start()
            self._emit_event(
                "ok",
                f"串口已连接：{port_text}；未自动下发参数或启动电机",
            )
            self._emit_status(connected=True, port=port_text)
            return _ok(connected=True, port=port_text)
        except Exception as error:
            self._serial = None
            self._port = None
            self._read_timer.stop()
            self._emit_event("error", f"串口连接失败：{error}")
            self._emit_status(connected=False, port=port_text or None,
                              error=str(error))
            return _err(f"串口连接失败：{error}")

    @Slot(result=str)
    def closePort(self) -> str:
        try:
            was_open = self._is_open()
            self._close_serial(send_stop=True)
            if was_open:
                self._emit_status(connected=False, port=None)
            return _ok(connected=False)
        except Exception as error:
            return _err(error)

    def _check_writable(self, name: str, value: Any = None) -> None:
        """按固件版本/本地模式拦截参数帧；MODE0 急停始终放行。"""
        if self._latest_version and not supports_parameter(name, self._latest_version):
            raise ValueError(
                "该参数需要更新固件：PIDEAD/KDBLEND 需 t 起、VELMODE 需 v 起、"
                "ADCAVG 需 w 起、RATEMODE 需 x 起、HOLDPOS 需 y 起"
            )
        if self._latest_src_local == 1 and not (name == "MODE" and int(value) == 0):
            raise ValueError("当前为本地调参模式，请用板上 SW1 切回上位机模式")

    @Slot(str, str, result=str)
    def sendParam(self, name: str, value_text: str) -> str:
        try:
            key = str(name or "").strip().upper()
            if not key:
                return _err("参数名不能为空")
            if not self._is_open():
                return _err("串口未连接")
            try:
                value = _parse_int(value_text)
            except (TypeError, ValueError):
                return _err(f"参数值不是整数：{value_text}")
            try:
                checked = validate_value(key, value)
                self._check_writable(key, checked)
            except (KeyError, ValueError) as error:
                return _err(error)
            self._serial.write(frame(PARAM[key], checked))
            self._serial.flush()
            return _ok(name=key, value=checked)
        except Exception as error:
            return _err(error)

    @Slot(str, result=str)
    def sendAll(self, params_json: str) -> str:
        try:
            if not self._is_open():
                return _err("串口未连接")
            try:
                incoming = json.loads(str(params_json or "{}"))
            except (TypeError, ValueError):
                return _err("参数 JSON 解析失败")
            if isinstance(incoming, dict) and isinstance(incoming.get("params"), dict):
                incoming = incoming["params"]
            if not isinstance(incoming, dict) or not incoming:
                return _err("参数对象不能为空")
            normalized: dict[str, Any] = {}
            for raw_key, raw_value in incoming.items():
                key = str(raw_key).strip().upper()
                if key in normalized:
                    return _err(f"参数重复：{key}")
                normalized[key] = raw_value
            # 先按界面 PARAMS 顺序排列，再补上额外键（例如 MODE），保持确定性
            ordered: list[str] = [key for key in PARAM_ORDER if key in normalized]
            ordered += [key for key in normalized if key not in ordered]
            frames = []
            for key in ordered:
                if key not in PARAM:
                    return _err(f"不支持的参数：{key}")
                try:
                    value = _parse_int(normalized[key])
                except (TypeError, ValueError):
                    return _err(f"参数值不是整数：{key}")
                try:
                    checked = validate_value(key, value)
                    self._check_writable(key, checked)
                except (KeyError, ValueError) as error:
                    return _err(error)
                frames.append(frame(PARAM[key], checked))
            self._serial.write(b"".join(frames))
            self._serial.flush()
            return _ok(count=len(ordered))
        except Exception as error:
            return _err(error)

    @Slot(int, result=str)
    def setMode(self, mode: int) -> str:
        try:
            if not self._is_open():
                return _err("串口未连接")
            try:
                checked = validate_value("MODE", int(mode))
                self._check_writable("MODE", checked)
            except (TypeError, ValueError) as error:
                return _err(error)
            self._serial.write(frame(PARAM["MODE"], checked))
            self._serial.flush()
            return _ok(mode=checked)
        except Exception as error:
            return _err(error)

    # ------------------------------------------------------------------
    # 槽：文件 / 状态
    # ------------------------------------------------------------------
    @Slot(str, str, result=str)
    def saveConfig(self, json_text: str, default_name: str) -> str:
        try:
            try:
                data = json.loads(str(json_text or ""))
            except (TypeError, ValueError):
                return _err("配置 JSON 解析失败")
            text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
            test_dir = self._test_dir()
            if test_dir:
                os.makedirs(test_dir, exist_ok=True)
                name = _safe_filename(default_name) or "test_config.json"
                if not name.lower().endswith(".json"):
                    name += ".json"
                path = os.path.join(test_dir, name)
            else:
                if QFileDialog is None:
                    return _err("文件对话框不可用")
                suggested = _safe_filename(default_name) or time.strftime(
                    "j280_config_%Y%m%d_%H%M%S.json"
                )
                path, _ = QFileDialog.getSaveFileName(
                    self._dialog_parent(), "保存参数配置", suggested,
                    "JSON 配置 (*.json);;所有文件 (*)",
                )
                if not path:
                    return _err("已取消保存", canceled=True)
                if not path.lower().endswith(".json"):
                    path += ".json"
            with open(path, "w", encoding="utf-8", newline="") as output:
                output.write(text)
            return _ok(path=path)
        except Exception as error:
            return _err(error)

    @Slot(result=str)
    def loadConfig(self) -> str:
        try:
            test_dir = self._test_dir()
            if test_dir:
                os.makedirs(test_dir, exist_ok=True)
                path = os.path.join(test_dir, "load_target.json")
                if not os.path.isfile(path):
                    candidates = [
                        os.path.join(test_dir, name)
                        for name in os.listdir(test_dir)
                        if name.lower().endswith(".json")
                        and os.path.isfile(os.path.join(test_dir, name))
                    ]
                    if not candidates:
                        return _err(f"测试目录中没有 JSON 文件：{test_dir}")
                    path = max(candidates, key=os.path.getmtime)
            else:
                if QFileDialog is None:
                    return _err("文件对话框不可用")
                path, _ = QFileDialog.getOpenFileName(
                    self._dialog_parent(), "载入参数配置", "",
                    "JSON 配置 (*.json);;所有文件 (*)",
                )
                if not path:
                    return _err("已取消载入", canceled=True)
            with open(path, "r", encoding="utf-8-sig", newline="") as source:
                text = source.read()
            return _ok(path=path, text=text)
        except Exception as error:
            return _err(error)

    @Slot(result=str)
    def loadDefaults(self) -> str:
        """读取 data/config0.json 作为启动默认参数（不弹对话框，Qt 前端调用）。"""
        try:
            path = os.path.join(globalVar.DATA_DIR, "config0.json")
            if not os.path.isfile(path):
                return _err(f"默认参数文件不存在：{path}")
            with open(path, "r", encoding="utf-8-sig", newline="") as source:
                text = source.read()
            return _ok(path=path, text=text)
        except Exception as error:
            return _err(error)

    @Slot(str, str, result=str)
    def saveCsv(self, csv_text: str, default_name: str) -> str:
        try:
            text = str(csv_text or "")
            test_dir = self._test_dir()
            if test_dir:
                os.makedirs(test_dir, exist_ok=True)
                name = _safe_filename(default_name) or "test.csv"
                if not name.lower().endswith(".csv"):
                    name += ".csv"
                path = os.path.join(test_dir, name)
            else:
                if QFileDialog is None:
                    return _err("文件对话框不可用")
                suggested = _safe_filename(default_name) or time.strftime(
                    "j280_%Y%m%d_%H%M%S.csv"
                )
                path, _ = QFileDialog.getSaveFileName(
                    self._dialog_parent(), "保存记录", suggested,
                    "CSV (*.csv);;所有文件 (*)",
                )
                if not path:
                    return _err("已取消保存", canceled=True)
                if not path.lower().endswith(".csv"):
                    path += ".csv"
            with open(path, "w", encoding="utf-8-sig", newline="") as output:
                output.write(text)
            return _ok(path=path)
        except Exception as error:
            return _err(error)

    @Slot(str, result=str)
    def saveState(self, json_text: str) -> str:
        path = self._state_path()
        temp_path = None
        try:
            text = str(json_text or "")
            try:
                json.loads(text)
            except (TypeError, ValueError):
                return _err("状态 JSON 解析失败")
            if not text.endswith("\n"):
                text += "\n"
            directory = os.path.dirname(path) or "."
            os.makedirs(directory, exist_ok=True)
            handle, temp_path = tempfile.mkstemp(
                prefix=".ui_state_", suffix=".tmp", dir=directory
            )
            with os.fdopen(handle, "w", encoding="utf-8", newline="") as output:
                output.write(text)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temp_path, path)
            temp_path = None
            return _ok(path=path)
        except Exception as error:
            return _err(error)
        finally:
            if temp_path:
                try:
                    os.remove(temp_path)
                except OSError:
                    pass

    @Slot(result=str)
    def loadState(self) -> str:
        try:
            path = self._state_path()
            if not os.path.isfile(path):
                return _err("状态文件不存在")
            with open(path, "r", encoding="utf-8-sig", newline="") as source:
                text = source.read()
            return _ok(path=path, text=text)
        except Exception as error:
            return _err(error)

    @Slot(result=str)
    def shutdown(self) -> str:
        try:
            self._flush_timer.stop()
            was_open = self._is_open()
            self._close_serial(send_stop=True)
            if was_open:
                self._emit_status(connected=False, port=None)
            return _ok()
        except Exception as error:
            return _err(error)
