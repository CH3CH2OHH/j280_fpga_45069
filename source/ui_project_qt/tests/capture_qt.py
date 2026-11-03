# -*- coding: utf-8 -*-
"""Qt 真实窗口集成截图/断言脚本（Lead / verifier 使用）。

启动真实 mainWnd（QWebEngine + QWebChannel + SerialBridge），开启演示数据，
等待曲线/3D 刷新后：
  1. 用 window.J280_APP 读取运行时状态并做断言；
  2. 采样 5 个曲线 canvas 像素，确认确实绘制了内容；
  3. 保存窗口截图到 _dev/shots/，并输出 JSON 报告。

用法（在 ui_project_qt 目录或任意目录）：
  set J280_UI_TEST_DIR=D:\projectD\fpga\proj0\_dev\qt_test_tmp
  .qtcreator\Python_3_11_9venv\Scripts\python.exe tests\capture_qt.py
可选参数：--out <png 路径> --width 1600 --height 1000 --wait 4
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent          # ui_project_qt
ROOT = BASE.parent                                     # proj0
sys.path.insert(0, str(BASE))
os.chdir(str(BASE))

os.environ.setdefault("J280_UI_TEST_DIR", str(ROOT / "_dev" / "qt_test_tmp"))
TEST_DIR = Path(os.environ["J280_UI_TEST_DIR"])
TEST_DIR.mkdir(parents=True, exist_ok=True)
# 每次测试使用干净的窗口状态（不读取用户上次保存的布局/参数），保证截图与断言可复现
CLEAN_STATE = {
    "ui_version": 3, "port": "COM9", "plot_window": "10 秒",
    "display_mode": "趋势", "trend_ms": "40 ms", "cards": {},
}
STATE_PATH = TEST_DIR / "capture_state.json"
STATE_PATH.write_text(json.dumps(CLEAN_STATE, ensure_ascii=False, indent=2), encoding="utf-8")
os.environ["J280_UI_STATE_PATH"] = str(STATE_PATH)

from PySide6.QtCore import QTimer, QUrl                        # noqa: E402
from PySide6.QtWidgets import QApplication                     # noqa: E402

from mainWnd import mainWnd                                    # noqa: E402


SNAPSHOT_JS = r"""
(function () {
  try {
    var api = window.J280_APP || {};
    var plots = api.plots || {};
    function sampleCanvas(id) {
      var canvas = document.getElementById(id);
      if (!canvas) return { exists: false, nonBlank: false };
      var w = canvas.width || 0, h = canvas.height || 0;
      if (!w || !h) return { exists: true, w: 0, h: 0, nonBlank: false };
      try {
        var ctx = canvas.getContext('2d');
        if (!ctx) return { exists: true, w: w, h: h, nonBlank: false };
        var data = ctx.getImageData(0, 0, w, h).data;
        var hits = 0;
        for (var i = 0; i < data.length; i += 4 * 137) {
          if (data[i] || data[i + 1] || data[i + 2] || data[i + 3]) hits++;
        }
        return { exists: true, w: w, h: h, nonBlank: hits > 20, hits: hits };
      } catch (e) {
        return { exists: true, w: w, h: h, error: String(e), nonBlank: false };
      }
    }
    var chartIds = ['chartAngle', 'chartPosition', 'chartSpeed', 'chartDuty', 'chartRaw'];
    var model = document.getElementById('model3d');
    var runtime = api.test && api.test.getRuntime ? api.test.getRuntime() : {};
    var cardEls = document.querySelectorAll('.param-card');
    var cardRects = [];
    for (var ci = 0; ci < cardEls.length; ci++) {
      var cr = cardEls[ci].getBoundingClientRect();
      if (cr.width > 0 && cr.height > 0) {
        cardRects.push({ left: cr.left, top: cr.top, right: cr.right, bottom: cr.bottom });
      }
    }
    var overlapPairs = 0;
    for (var oi = 0; oi < cardRects.length; oi++) {
      for (var oj = oi + 1; oj < cardRects.length; oj++) {
        var a = cardRects[oi], b = cardRects[oj];
        if (!(a.right <= b.left + 1 || b.right <= a.left + 1 ||
              a.bottom <= b.top + 1 || b.bottom <= a.top + 1)) overlapPairs++;
      }
    }
    var analysisEl = document.getElementById('analysisSummary');
    var analysisText = analysisEl ? analysisEl.textContent || '' : '';
    var metrics = {};
    ['metricAng', 'metricRef', 'metricRaw', 'metricPos', 'metricSpd', 'metricDut'].forEach(function (id) {
      var el = document.getElementById(id);
      metrics[id] = el ? el.textContent : null;
    });
    return JSON.stringify({
      ready: !!api.ready,
      title: document.title,
      errors: (window.__J280_ERRORS || []).slice(0, 10),
      plotCount: Object.keys(plots).length,
      plotKeys: Object.keys(plots),
      cardCount: Object.keys(api.cards || {}).length,
      bookmarkCount: document.querySelectorAll('#bookmarkRail .bookmark-item:not(.bookmark-special)').length,
      specialBookmark: !!document.querySelector('#bookmarkRail .bookmark-special'),
      bookmarkTotal: document.querySelectorAll('#bookmarkRail .bookmark-item').length,
      visibleCards: (api.test && api.test.visibleGroupCards ? api.test.visibleGroupCards().length : 0),
      cardCountVisible: (api.test && api.test.visibleGroupCards ? api.test.visibleGroupCards().length : 0),
      chartIds: chartIds,
      charts: chartIds.map(function (id) { return sampleCanvas(id); }),
      modelChildren: model ? model.children.length : 0,
      modelHasCanvas: model ? !!model.querySelector('canvas') : false,
      cardsNoOverlap: overlapPairs === 0,
      overlapPairs: overlapPairs,
      analysisText: analysisText,
      analysisWaiting: analysisText.indexOf('等待数据') >= 0,
      metrics: metrics,
      runtime: runtime,
      analysis: (document.getElementById('analysisSummary') || {}).textContent,
      balance: (document.getElementById('balanceText') || {}).textContent,
      connStatus: (document.getElementById('connStatus') || {}).textContent,
      sampleText: (document.getElementById('sampleText') || {}).textContent,
      eventCount: document.getElementById('eventList')
        ? document.getElementById('eventList').children.length : 0,
      cards: api.test && api.test.getStateSnapshot ? api.test.getStateSnapshot().cards : null,
      paramsSample: api.test && api.test.getParams
        ? (function () { var p = api.test.getParams(); return { AKP: p.AKP, DZW: p.DZW, MODE: p.MODE, ZERO: p.ZERO }; })()
        : null
    });
  } catch (e) {
    return JSON.stringify({ fatal: String((e && e.stack) || e) });
  }
})()
"""


class Runner:
    def __init__(self, app, window, args):
        self.app = app
        self.window = window
        self.args = args
        self.started = time.monotonic()
        self.report = {"ok": False, "started": time.strftime("%Y-%m-%d %H:%M:%S")}
        self.exit_code = 2
        self._ready_checks = 0
        self._loaded = False

        web = window._web_list[0]
        web.loadFinished.connect(self._on_load_finished)
        QTimer.singleShot(45000, self._timeout)

    # ---- steps ---------------------------------------------------------
    def _on_load_finished(self, ok):
        self._loaded = bool(ok)
        self.report["load_finished"] = bool(ok)
        if not ok:
            return self._finish("页面加载失败")
        QTimer.singleShot(1200, self._poll_ready)

    def _page(self):
        return self.window._web_list[0].page()

    def _poll_ready(self):
        self._ready_checks += 1
        self._page().runJavaScript(
            "!!(window.J280_APP && window.J280_APP.ready)", self._on_ready_checked
        )

    def _on_ready_checked(self, ready):
        if ready:
            self.report["ready"] = True
            self._start_feed()
            return
        if self._ready_checks > 30:
            return self._finish("等待 J280_APP.ready 超时")
        QTimer.singleShot(500, self._poll_ready)

    def _start_feed(self):
        feed_js = (BASE / "tests" / "test_feed.js").read_text(encoding="utf-8")
        self._page().runJavaScript(
            feed_js + "\ntry { window.__J280_TEST_FEED.start(); 'ok'; }"
            " catch (e) { String(e); }",
            self._on_feed_started,
        )

    def _on_feed_started(self, result):
        self.report["feed_start"] = result
        QTimer.singleShot(int(self.args.wait * 1000), self._snapshot)

    def _snapshot(self):
        self._page().runJavaScript(SNAPSHOT_JS, self._on_snapshot)

    def _on_snapshot(self, value):
        try:
            snapshot = json.loads(value) if isinstance(value, str) else value
        except Exception as error:  # noqa: BLE001
            return self._finish("快照 JSON 解析失败：%s / %s" % (error, value))
        self.report["snapshot"] = snapshot
        errors = snapshot.get("errors") or []
        charts = snapshot.get("charts") or []
        checks = {
            "ready": bool(snapshot.get("ready")),
            "no_js_errors": len(errors) == 0,
            "five_plots": snapshot.get("plotCount") == 5,
            "six_cards": snapshot.get("cardCount") == 6,
            "six_bookmarks": snapshot.get("bookmarkCount") == 6,
            "special_bookmark": bool(snapshot.get("specialBookmark")),
            "cards_default_hidden": snapshot.get("visibleCards") == 0,
            "telemetry_rows": int((snapshot.get("runtime") or {}).get("rows") or 0) > 100,
            "charts_painted": all(bool(c.get("nonBlank")) for c in charts) and len(charts) == 5,
            "3d_present": bool(snapshot.get("modelHasCanvas")),
            "metric_ang_live": (snapshot.get("metrics") or {}).get("metricAng") not in (None, "--", ""),
            "cards_no_overlap": bool(snapshot.get("cardsNoOverlap")),
            "analysis_live": (not snapshot.get("analysisWaiting")) and
                             len(snapshot.get("analysisText") or "") > 10,
        }
        self.report["checks"] = checks
        self.report["ok"] = all(checks.values())

        out = Path(self.args.out).resolve()
        out.parent.mkdir(parents=True, exist_ok=True)
        pixmap = self.window.grab()
        saved = pixmap.save(str(out))
        self.report["screenshot"] = str(out)
        self.report["screenshot_ok"] = bool(saved)
        self.report["screenshot_size"] = [pixmap.width(), pixmap.height()]
        self.report["elapsed_s"] = round(time.monotonic() - self.started, 2)
        self._finish(None if self.report["ok"] else "断言未通过：" + json.dumps(
            {k: v for k, v in checks.items() if not v}, ensure_ascii=False))

    # ---- finish --------------------------------------------------------
    def _finish(self, error):
        if error:
            self.report["error"] = error
        self.report.setdefault("elapsed_s", round(time.monotonic() - self.started, 2))
        report_path = BASE / "tests" / "last_capture.json"
        try:
            report_path.write_text(json.dumps(self.report, ensure_ascii=False, indent=2),
                                   encoding="utf-8")
        except OSError:
            pass
        print("=" * 70)
        print("CAPTURE REPORT: " + ("PASS" if self.report.get("ok") else "FAIL"))
        if error:
            print("ERROR: " + error)
        print(json.dumps(self.report, ensure_ascii=False, indent=2)[:8000])
        print("=" * 70)
        self.exit_code = 0 if self.report.get("ok") else 1
        self.app.quit()

    def _timeout(self):
        self.report.setdefault("error", "总超时（45s）")
        self.exit_code = 1
        self.app.quit()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=str(ROOT / "_dev" / "shots" / "qt-app.png"))
    parser.add_argument("--width", type=int, default=1600)
    parser.add_argument("--height", type=int, default=1000)
    parser.add_argument("--wait", type=float, default=4.0)
    args = parser.parse_args()

    app = QApplication(sys.argv)
    app.setApplicationName("J280 Capture")
    width = min(args.width, 1700)
    height = min(args.height, 1000)
    window = mainWnd(minisize=(1280, 800), size=(width, height))
    window.resize(width, height)
    window.show()
    runner = Runner(app, window, args)
    app.exec()
    sys.exit(runner.exit_code)


if __name__ == "__main__":
    main()
