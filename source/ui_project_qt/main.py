# This Python file uses the following encoding: utf-8
"""J280 HTML 调试台启动入口。

窗口尺寸：高度取屏幕可用高度 88%（上限 1000），宽高比 16:9 且不超过可用宽
96%；最小 1280×800，创建后居中（CustomWnd.setCenter）。

打包后的 exe 支持自检参数：
    J280上位机控制系统.exe --selftest <report.json> [--selftest-shot <png>]
自检会加载 HTML、等待 J280_APP.ready，检查卡片/书签/默认参数/JS 错误，
写 JSON 报告并返回 0/1，用于验证冻结后的运行时是否完整。
"""

import ctypes
import json
import os
import sys
import time

from PySide6.QtCore import QTimer
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import QApplication

from globals import globalVar
from mainWnd import mainWnd

TITLE = "J280 上位机控制系统"
MIN_WIDTH = 1280
MIN_HEIGHT = 800


def compute_window_size() -> tuple[int, int]:
    """按规范计算初始窗口尺寸：h=min(screen_h*0.88, 1000)，w=16:9 且 ≤ 0.96 可用宽。"""
    screen = QApplication.primaryScreen()
    available = screen.availableGeometry() if screen is not None else None
    screen_w = available.width() if available is not None else 1600
    screen_h = available.height() if available is not None else 1000

    height = min(int(screen_h * 0.88), 1000)
    height = max(height, MIN_HEIGHT)
    width = int(round(16 / 9 * height))
    width = min(width, int(screen_w * 0.96))
    width = max(width, MIN_WIDTH)
    return width, height


def _arg_value(name: str, default: str = "") -> str:
    try:
        index = sys.argv.index(name)
    except ValueError:
        return default
    if index + 1 < len(sys.argv):
        return sys.argv[index + 1]
    return default


def run_selftest(window: mainWnd, report_path: str, shot_path: str = "") -> int:
    """加载页面并检查打包运行时；不依赖串口硬件。"""
    report = {
        "ok": False,
        "started": time.strftime("%Y-%m-%d %H:%M:%S"),
        "frozen": bool(getattr(sys, "frozen", False)),
        "exe": os.path.abspath(sys.executable),
        "app_dir": os.path.dirname(os.path.abspath(sys.executable)),
        "checks": {},
        "js": None,
        "errors": [],
    }
    started = time.monotonic()
    tries = {"n": 0}
    finished = {"done": False}
    waited_ready = {"value": False}

    def write_report() -> None:
        try:
            directory = os.path.dirname(os.path.abspath(report_path))
            if directory:
                os.makedirs(directory, exist_ok=True)
            with open(report_path, "w", encoding="utf-8") as handle:
                json.dump(report, handle, ensure_ascii=False, indent=2)
        except Exception as error:  # noqa: BLE001
            print(f"写入自检报告失败：{error}", flush=True)

    def finish(code: int) -> None:
        if finished["done"]:
            return
        finished["done"] = True
        report["elapsed_s"] = round(time.monotonic() - started, 2)
        report["ok"] = bool(code == 0)
        write_report()
        print("PACKAGED SELFTEST: " + ("PASS" if code == 0 else "FAIL"), flush=True)
        print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
        app = QApplication.instance()
        if app is not None:
            app.exit(code)

    def on_snapshot(value) -> None:
        try:
            snapshot = json.loads(value) if isinstance(value, str) else value
        except Exception as error:  # noqa: BLE001
            report["errors"].append(f"快照解析失败：{error} / {value}")
            return finish(1)
        if not isinstance(snapshot, dict) or snapshot.get("fatal"):
            report["errors"].append(f"页面异常：{snapshot}")
            return finish(1)
        report["js"] = snapshot
        if not snapshot.get("ready"):
            return
        # ready 后等启动遮罩淡出再取快照/截图，保证自动化截图是完整界面
        if not waited_ready["value"]:
            waited_ready["value"] = True
            QTimer.singleShot(800, poll)
            return
        params = snapshot.get("params") or {}
        checks = {
            "ready": bool(snapshot.get("ready")),
            "no_js_errors": not snapshot.get("errors"),
            "five_plots": snapshot.get("plotCount") == 5,
            "six_cards": snapshot.get("cardCount") == 6,
            "seven_bookmarks": snapshot.get("bookmarks") == 7,
            "cards_hidden": snapshot.get("visibleCards") == 0,
            "defaults_config0": params.get("AKP") == "-150" and params.get("PIDEAD") == "4",
            "window_icon": not window.windowIcon().isNull(),
        }
        report["checks"] = checks
        if shot_path:
            try:
                report["screenshot"] = os.path.abspath(shot_path)
                report["screenshot_ok"] = bool(window.grab().save(shot_path))
            except Exception as error:  # noqa: BLE001
                report["errors"].append(f"截图失败：{error}")
        finish(0 if all(checks.values()) else 1)

    def poll() -> None:
        if finished["done"]:
            return
        tries["n"] += 1
        if tries["n"] > 40:
            report["errors"].append("等待 J280_APP.ready 超时")
            return finish(1)
        page = window._web_list[0].page()
        page.runJavaScript(
            r"""
(function(){
  try{
    var api=window.J280_APP||{};
    return JSON.stringify({
      ready:!!api.ready,
      errors:(window.__J280_ERRORS||[]).slice(0,5),
      title:document.title,
      plotCount:Object.keys(api.plots||{}).length,
      cardCount:Object.keys(api.cards||{}).length,
      bookmarks:document.querySelectorAll('#bookmarkRail .bookmark-item').length,
      visibleCards:document.querySelectorAll('.param-card:not([hidden])').length,
      params:(api.test&&api.test.getParams)?api.test.getParams():null,
      href:location.href
    });
  }catch(e){return JSON.stringify({fatal:String((e&&e.stack)||e)});}
})()
""",
            on_snapshot,
        )
        QTimer.singleShot(500, poll)

    window.show()
    QTimer.singleShot(1200, poll)
    return 0


def load_app_icon() -> QIcon:
    """应用图标：res/icon.png（Windows 任务栏/窗口）；exe 图标由 PyInstaller 嵌入 .ico。"""
    for name in ("icon.png", "icon.ico"):
        path = os.path.join(globalVar.RES_DIR, name)
        if os.path.isfile(path):
            icon = QIcon(path)
            if not icon.isNull():
                return icon
    return QIcon()


def main() -> int:
    if sys.platform == "win32":
        try:
            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(
                "J280.HostControl.HTML")
        except Exception:  # noqa: BLE001 - 仅影响任务栏分组，不能影响启动
            pass

    app = QApplication([])
    app.setApplicationName("J280 上位机控制系统")
    app_icon = load_app_icon()
    if not app_icon.isNull():
        app.setWindowIcon(app_icon)

    window_w, window_h = compute_window_size()
    window_main = mainWnd(minisize=(MIN_WIDTH, MIN_HEIGHT), size=(window_w, window_h))
    window_main.setWindowTitle(TITLE)
    if not app_icon.isNull():
        window_main.setWindowIcon(app_icon)

    if "--selftest" in sys.argv:
        report_path = _arg_value("--selftest",
                                 os.path.join(os.path.dirname(os.path.abspath(sys.executable)),
                                              "selftest.json"))
        shot_path = _arg_value("--selftest-shot", "")
        run_selftest(window_main, report_path, shot_path)
        return app.exec()

    window_main.show()
    # 创建时已 setCenter；show 之后再校正一次，避免 DPI 缩放导致偏移
    window_main.setCenter()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
