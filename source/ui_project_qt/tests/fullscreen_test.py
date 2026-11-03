# -*- coding: utf-8 -*-
"""窗口/全屏行为测试。

覆盖：
  1. 普通窗口：(4,4,4,4) 内容边距、标题栏可见、可缩放；
  2. 标题栏“o”最大化：去边框（边距 0）、标题栏保留、最大化时标题栏拖动被屏蔽；还原恢复；
  3. HTML「进入全屏」按钮：真全屏、边距 0、标题栏隐藏、缩放禁用，退出按钮显示；
  4. Esc / 「退出全屏」按钮退出全屏并恢复。
运行：venv python tests/fullscreen_test.py（截图 _dev/shots/fullscreen-*.png）
"""
import json
import os
import sys
import time
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
ROOT = BASE.parent
sys.path.insert(0, str(BASE))
os.chdir(str(BASE))
TEST_DIR = Path(os.environ.get("J280_UI_TEST_DIR", str(ROOT / "_dev" / "qt_test_tmp")))
TEST_DIR.mkdir(parents=True, exist_ok=True)
os.environ["J280_UI_TEST_DIR"] = str(TEST_DIR)
STATE_PATH = TEST_DIR / "fullscreen_state.json"
STATE_PATH.write_text(json.dumps({
    "ui_version": 3, "port": "COM9", "plot_window": "10 秒",
    "display_mode": "趋势", "trend_ms": "40 ms", "cards": {},
}, ensure_ascii=False, indent=2), encoding="utf-8")
os.environ["J280_UI_STATE_PATH"] = str(STATE_PATH)

from PySide6.QtCore import QEvent, QPoint, QPointF, Qt, QTimer    # noqa: E402
from PySide6.QtGui import QMouseEvent                             # noqa: E402
from PySide6.QtWidgets import QApplication                        # noqa: E402

from mainWnd import mainWnd                                       # noqa: E402

SHOT_DIR = ROOT / "_dev" / "shots"
SHOT_DIR.mkdir(parents=True, exist_ok=True)


class Checker:
    def __init__(self, app, window):
        self.app = app
        self.window = window
        self.report = {"ok": False, "checks": {}}
        self.exit_code = 2
        self.started = time.time()
        self._ready_tries = 0

    # ---- helpers ------------------------------------------------------
    def js(self, code, cb):
        self.window._web_list[0].page().runJavaScript(code, cb)

    def check(self, name, ok, detail=""):
        self.report["checks"][name] = {"ok": bool(ok), "detail": str(detail)}

    def margins(self):
        m = self.window.ui.verticalLayout.contentsMargins()
        return (m.left(), m.top(), m.right(), m.bottom())

    def shot(self, name):
        path = SHOT_DIR / name
        self.window.grab().save(str(path))
        self.check("shot_" + name, path.exists(), str(path))
        return path

    def press_titlebar(self):
        event = QMouseEvent(QEvent.Type.MouseButtonPress, QPointF(12, 12),
                            Qt.MouseButton.LeftButton, Qt.MouseButton.LeftButton,
                            Qt.KeyboardModifier.NoModifier)
        QApplication.sendEvent(self.window.ui.wndBar, event)

    # ---- steps --------------------------------------------------------
    def start(self):
        QTimer.singleShot(1500, self.poll_ready)

    def poll_ready(self):
        self._ready_tries += 1
        self.js("!!(window.J280_APP && window.J280_APP.ready)", self.on_ready)

    def on_ready(self, ready):
        if ready:
            QTimer.singleShot(400, self.step_normal)
            return
        if self._ready_tries > 40:
            return self.finish("等待 J280_APP.ready 超时")
        QTimer.singleShot(500, self.poll_ready)

    def step_normal(self):
        self.check("normal_margins", self.margins() == (4, 4, 4, 4), self.margins())
        self.check("normal_wndbar_visible", self.window.ui.wndBar.isVisible(), "")
        self.check("normal_not_max", not self.window.isMaximized(), "")
        self.check("normal_resize_enable", bool(self.window._resize_enable), "")
        self.window.maxWnd()  # 标题栏“o” = 最大化（不是全屏）
        QTimer.singleShot(900, self.step_maximized)

    def step_maximized(self):
        self.check("max_is_maximized", self.window.isMaximized(), "")
        self.check("max_not_fullscreen", not self.window.isFullScreen(), "")
        self.check("max_margins_zero", self.margins() == (0, 0, 0, 0), self.margins())
        self.check("max_wndbar_visible", self.window.ui.wndBar.isVisible(), "")
        # 最大化时标题栏拖动必须被屏蔽（eventFilter 直接吞掉，不进入 _moving）
        self.window._moving = False
        self.press_titlebar()
        self.check("max_drag_blocked", not self.window._moving, str(self.window._moving))
        self.shot("window-maximized.png")
        self.window.maxWnd()  # 还原
        QTimer.singleShot(900, self.step_unmaximized)

    def step_unmaximized(self):
        self.check("restored_not_max", not self.window.isMaximized(), "")
        self.check("restored_margins", self.margins() == (4, 4, 4, 4), self.margins())
        self.check("restored_wndbar_visible", self.window.ui.wndBar.isVisible(), "")
        # HTML「进入全屏」按钮（经 QWebChannel qt_window）
        self.js("document.getElementById('btnFullscreenOn').click(); 'ok';", lambda _v: None)
        QTimer.singleShot(1400, self.step_fullscreen)

    def step_fullscreen(self):
        self.check("full_is_fullscreen", self.window.isFullScreen(), "")
        self.check("full_margins_zero", self.margins() == (0, 0, 0, 0), self.margins())
        self.check("full_wndbar_hidden", not self.window.ui.wndBar.isVisible(), "")
        self.check("full_resize_disabled", not bool(self.window._resize_enable), "")
        self.shot("fullscreen-on.png")
        self.js(
            "JSON.stringify({on:document.getElementById('btnFullscreenOn').hidden,"
            "off:document.getElementById('btnFullscreenOff').hidden})",
            self.on_full_buttons,
        )

    def on_full_buttons(self, value):
        self.check("full_buttons_state", value == '{"on":true,"off":false}', value)
        # Esc 退出全屏（HTML keydown → bridge → Qt）
        self.js(
            "document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',code:'Escape',bubbles:true})); 'ok';",
            lambda _v: None,
        )
        QTimer.singleShot(1400, self.step_esc_exit)

    def step_esc_exit(self):
        self.check("esc_exits_fullscreen", not self.window.isFullScreen(), "")
        self.check("esc_margins_restored", self.margins() == (4, 4, 4, 4), self.margins())
        self.check("esc_wndbar_visible", self.window.ui.wndBar.isVisible(), "")
        self.js(
            "JSON.stringify({on:document.getElementById('btnFullscreenOn').hidden,"
            "off:document.getElementById('btnFullscreenOff').hidden})",
            self.on_esc_buttons,
        )

    def on_esc_buttons(self, value):
        self.check("esc_buttons_state", value == '{"on":false,"off":true}', value)
        # 再进入全屏，用「退出全屏」按钮退出
        self.js("document.getElementById('btnFullscreenOn').click(); 'ok';", lambda _v: None)
        QTimer.singleShot(1200, self.step_btn_exit)

    def step_btn_exit(self):
        self.check("reenter_fullscreen", self.window.isFullScreen(), "")
        self.js("document.getElementById('btnFullscreenOff').click(); 'ok';", lambda _v: None)
        QTimer.singleShot(1200, self.step_btn_exit_done)

    def step_btn_exit_done(self):
        self.check("button_exits_fullscreen", not self.window.isFullScreen(), "")
        self.check("button_margins_restored", self.margins() == (4, 4, 4, 4), self.margins())
        # 回归：最大化 → 全屏 → 退出全屏 → 应回到带边框的普通窗口
        self.window.maxWnd()
        QTimer.singleShot(700, self.step_max_before_fullscreen)

    def step_max_before_fullscreen(self):
        self.check("seq_max", self.window.isMaximized(), "")
        self.check("seq_max_margins_zero", self.margins() == (0, 0, 0, 0), self.margins())
        self.window.toggle_fullscreen()
        QTimer.singleShot(900, self.step_seq_fullscreen)

    def step_seq_fullscreen(self):
        self.check("seq_fullscreen", self.window.isFullScreen(), "")
        self.window.showNormal()  # 与 Esc/退出全屏按钮相同的退出路径
        QTimer.singleShot(900, self.step_seq_exit)

    def step_seq_exit(self):
        self.check("seq_back_normal", not self.window.isFullScreen() and
                    not self.window.isMaximized(), "")
        self.check("seq_margins_restored", self.margins() == (4, 4, 4, 4), self.margins())
        self.check("seq_normal_margins_kept",
                    tuple(getattr(self.window, "_normal_margins", ())) == (4, 4, 4, 4),
                    str(getattr(self.window, "_normal_margins", None)))
        edge = self.window._get_edges(QPoint(2, 2))
        self.check("seq_resize_edge_present", edge is not None, str(edge))
        self.finish(None)

    # ---- finish -------------------------------------------------------
    def finish(self, error):
        if error:
            self.report["error"] = error
        self.report["ok"] = all(v["ok"] for v in self.report["checks"].values())
        self.report["elapsed_s"] = round(time.time() - self.started, 2)
        print("FULLSCREEN REPORT: " + ("PASS" if self.report["ok"] else "FAIL"))
        if error:
            print("ERROR: " + error)
        for name, item in self.report["checks"].items():
            print(("  PASS " if item["ok"] else "  FAIL ") + name + " " + item["detail"])
        self.exit_code = 0 if self.report["ok"] else 1
        self.app.quit()


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("J280 Fullscreen Test")
    window = mainWnd(minisize=(1280, 800), size=(1600, 1000))
    window.show()
    checker = Checker(app, window)
    checker.start()
    QTimer.singleShot(40000, app.quit)
    app.exec()
    sys.exit(checker.exit_code)


if __name__ == "__main__":
    main()
