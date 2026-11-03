# -*- coding: utf-8 -*-
"""Qt 集成冒烟测试：演示数据 + 运行时断言 + JSON 往返 + CSV + 参数校验。

不依赖真实串口；使用 J280_UI_TEST_DIR 让后端把文件写到临时目录。
用法：
  .qtcreator\Python_3_11_9venv\Scripts\python.exe tests\smoke_test.py
退出码 0=PASS，1=FAIL，2=异常。
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
CLEAN_STATE = {
    "ui_version": 3, "port": "COM9", "plot_window": "10 秒",
    "display_mode": "趋势", "trend_ms": "40 ms", "cards": {},
}
STATE_PATH = TEST_DIR / "smoke_state.json"
STATE_PATH.write_text(json.dumps(CLEAN_STATE, ensure_ascii=False, indent=2), encoding="utf-8")
os.environ["J280_UI_STATE_PATH"] = str(STATE_PATH)
for stale in ("smoke_config.json", "smoke_record.csv", "load_target.json"):
    try:
        (TEST_DIR / stale).unlink()
    except OSError:
        pass

from PySide6.QtCore import QTimer                              # noqa: E402
from PySide6.QtWidgets import QApplication                     # noqa: E402

from mainWnd import mainWnd                                    # noqa: E402


BASIC_JS = r"""
(function () {
  try {
    var api = window.J280_APP || {};
    return JSON.stringify({
      ready: !!api.ready,
      errors: (window.__J280_ERRORS || []).slice(0, 10),
      plotCount: Object.keys(api.plots || {}).length,
      cardCount: Object.keys(api.cards || {}).length,
      rows: (api.test && api.test.getRuntime ? api.test.getRuntime().rows : 0),
      latest: api.test ? api.test.latestRow() : null,
      status: api.test ? api.test.getRuntime().status : null,
      conn: (document.getElementById('connStatus') || {}).textContent,
      metrics: ['metricAng','metricRef','metricRaw','metricPos','metricSpd','metricDut']
        .map(function (id) { return (document.getElementById(id) || {}).textContent; }),
      params: api.test ? api.test.getParams() : null
    });
  } catch (e) { return JSON.stringify({ fatal: String((e && e.stack) || e) }); }
})()
"""

CONFIG_JS = r"""
window.__SMOKE_CONFIG = null;
(function () {
  var api = window.J280_APP;
  (async function () {
    try {
      var before = api.test.exportConfigObject();
      var save = await api.backend.saveConfig(before, 'smoke_config.json');
      api.test.setParam('AKP', 111);
      var load = await api.backend.loadConfig();
      var parsed = JSON.parse(load.text);
      var applied = api.test.applyConfigObject(parsed.params || parsed);
      var after = api.test.exportConfigObject();
      var diff = [];
      Object.keys(before.params).forEach(function (k) {
        if (after.params[k] !== before.params[k]) diff.push(k);
      });
      window.__SMOKE_CONFIG = {
        ok: !!(save && save.ok && load && load.ok),
        save: save, loadOk: !!(load && load.ok), loadPath: load && load.path,
        applied: Object.keys(applied.applied).length,
        skipped: applied.skipped, diff: diff,
        paramCount: Object.keys(before.params).length,
        roundTripEqual: diff.length === 0
      };
    } catch (e) {
      window.__SMOKE_CONFIG = { ok: false, error: String((e && e.stack) || e) };
    }
  })();
  return 'started';
})()
"""

CSV_JS = r"""
window.__SMOKE_CSV = null;
(function () {
  var api = window.J280_APP;
  (async function () {
    try {
      api.test.startRecord();
      await new Promise(function (r) { setTimeout(r, 1600); });
      var csv = api.test.buildCsv();
      var rows = api.test.recordBuffer().length;
      api.test.stopRecord();
      var save = await api.backend.saveCsv(csv, 'smoke_record.csv');
      var header = csv.split(/\r?\n/)[0].split(',');
      window.__SMOKE_CSV = {
        ok: !!(save && save.ok),
        path: save && save.path, rows: rows,
        lines: csv.split(/\r?\n/).length - 2,
        headerCount: header.length,
        hasFields: ['time_s', 'ang', 'ref', 'ref_cdeg', 'raw', 'pos', 'pos_absolute',
          'src_local', 'spd', 'dut', 'mode', 'bal_status', 'swing_active',
          'position_hold', 'version', 'config_count', 'tgt', 'tgt_abs',
          'pos_total', 'pos_error', 'sent_AKP', 'sent_POSTGT', 'sent_HOLDPOS'].every(function (f) {
            return header.indexOf(f) >= 0;
          })
      };
    } catch (e) {
      window.__SMOKE_CSV = { ok: false, error: String((e && e.stack) || e) };
    }
  })();
  return 'started';
})()
"""

VALIDATE_JS = r"""
(function () {
  try {
    var P = window.J280Params;
    var checks = {
      dzw64_ok: P.validate('DZW', 64).ok,
      dzw48_reject: !P.validate('DZW', 48).ok,
      mode3_ok: P.validate('MODE', 3).ok,
      mode4_reject: !P.validate('MODE', 4).ok,
      mode2_ok: P.validate('MODE', 2).ok,
      akp_bound_ok: P.validate('AKP', -4096).ok,
      akp_over_reject: !P.validate('AKP', 4097).ok,
      trim_ok: P.validate('TRIM', -18000).ok,
      turns_min_ok: P.validate('TURNS_POSTGT', -32768).ok,
      turns_max_ok: P.validate('TURNS_POSTGT', 32767).ok,
      turns_over_reject: !P.validate('TURNS_POSTGT', 32768).ok,
      hold_ok: P.validate('HOLDPOS', 160).ok,
      hold_over_reject: !P.validate('HOLDPOS', 161).ok,
      ratemode_ok: P.validate('RATEMODE', 2).ok,
      ratemode_reject: !P.validate('RATEMODE', 3).ok,
      supports_hold_y: P.supportsParameter('HOLDPOS', 'y6'),
      supports_hold_old: !P.supportsParameter('HOLDPOS', 's1040'),
      abs_decompose_hi: P.absDecompose(32767).turns === 32 &&
                        P.absDecompose(32767).phase === -513,
      abs_decompose_lo: P.absDecompose(-32768).turns === -32 &&
                        P.absDecompose(-32768).phase === 512,
      abs_compose_hi: P.absCompose(32, 123) === 32767,
      abs_compose_lo: P.absCompose(-32, -123) === -32768,
      abs_roundtrip: P.absCompose(P.absDecompose(2203).turns,
                                  P.absDecompose(2203).phase) === 2203,
      hex_parse: P.parseIntEntry('0x10').value === 16,
      empty_reject: !P.parseIntEntry('').ok,
      float_reject: !P.parseIntEntry('1.5').ok,
      nudge_dzw: P.nudge('DZW', 64, 1) === 128,
      nudge_dzw_down: P.nudge('DZW', 64, -1) === 32,
      nudge_clamp: P.nudge('LIM', 1023, 1) === 1023,
      nudge_akp: P.nudge('AKP', 0, 1) === 5,
      tooltip_has_text: P.tooltipHtml('AKP', '未下发').indexOf('比例增益') >= 0,
      pos_loop_text: P.positionLoopText(P.defaultValues()).length > 0,
      param_count: Object.keys(P.PARAMS).length === 39,
      group_count: (P.GROUPS || []).length === 6,
      order_count: (P.ORDER || []).length === 39
    };
    return JSON.stringify({ checks: checks, failed: Object.keys(checks).filter(function (k) { return !checks[k]; }) });
  } catch (e) { return JSON.stringify({ fatal: String((e && e.stack) || e) }); }
})()
"""


class SmokeRunner:
    def __init__(self, app, window):
        self.app = app
        self.window = window
        self.report = {"ok": False, "started": time.strftime("%Y-%m-%d %H:%M:%S")}
        self.exit_code = 2
        self.ready_checks = 0
        self.phase_checks = 0
        self.basic = None
        self.started = time.time()
        window._web_list[0].loadFinished.connect(self._on_load)
        QTimer.singleShot(60000, self._timeout)

    def _page(self):
        return self.window._web_list[0].page()

    def js(self, code, callback):
        self._page().runJavaScript(code, callback)

    def _on_load(self, ok):
        if not ok:
            return self._finish("页面加载失败")
        QTimer.singleShot(1200, self._poll_ready)

    def _poll_ready(self):
        self.ready_checks += 1
        self.js("!!(window.J280_APP && window.J280_APP.ready)", self._on_ready)

    def _on_ready(self, ready):
        if ready:
            self._start_feed()
            return
        if self.ready_checks > 40:
            return self._finish("等待 J280_APP.ready 超时")
        QTimer.singleShot(500, self._poll_ready)

    def _start_feed(self):
        feed_js = (BASE / "tests" / "test_feed.js").read_text(encoding="utf-8")
        self.js(feed_js + "\ntry { window.__J280_TEST_FEED.start(); 'ok'; }"
                " catch (e) { String(e); }", self._on_feed)
        QTimer.singleShot(3000, self._basic)

    def _on_feed(self, result):
        self.report["feed_start"] = result

    # basic --------------------------------------------------------------
    def _basic(self):
        self.js(BASIC_JS, self._on_basic)

    def _on_basic(self, value):
        try:
            self.basic = json.loads(value)
        except Exception as error:  # noqa: BLE001
            return self._finish("基础快照解析失败：%s" % error)
        self.report["basic"] = self.basic
        basic = self.basic
        checks = {
            "ready": bool(basic.get("ready")),
            "no_js_errors": len(basic.get("errors") or []) == 0,
            "five_plots": basic.get("plotCount") == 5,
            "six_cards": basic.get("cardCount") == 6,
            "defaults_from_config0": (basic.get("params") or {}).get("AKP") == "-150" and
                                     (basic.get("params") or {}).get("PIDEAD") == "4" and
                                     (basic.get("params") or {}).get("HOLDPOS") == "70",
            "telemetry_rows": int(basic.get("rows") or 0) > 100,
            "metrics_live": all(m not in (None, "--", "") for m in (basic.get("metrics") or [])),
            "param_count": len(basic.get("params") or {}) == 39
        }
        self.report["basic_checks"] = checks
        if not all(checks.values()):
            return self._finish("基础断言失败：" + json.dumps(
                {k: v for k, v in checks.items() if not v}, ensure_ascii=False))
        self.js(VALIDATE_JS, self._on_validate)

    # validate -----------------------------------------------------------
    def _on_validate(self, value):
        try:
            result = json.loads(value)
        except Exception as error:  # noqa: BLE001
            return self._finish("校验结果解析失败：%s" % error)
        self.report["validate"] = result
        if result.get("fatal") or result.get("failed"):
            return self._finish("参数校验断言失败：" + str(result.get("failed") or result.get("fatal")))
        self.js(CONFIG_JS, self._on_config_start)

    # config roundtrip ---------------------------------------------------
    def _on_config_start(self, _value):
        self._poll("window.__SMOKE_CONFIG", 60, self._on_config)

    def _on_config(self, value):
        if value is None:
            return self._finish("JSON 往返超时")
        self.report["config_roundtrip"] = value
        checks = {
            "config_ok": bool(value.get("ok")),
            "roundtrip_equal": bool(value.get("roundTripEqual")),
            "applied_all": value.get("applied") == value.get("paramCount")
        }
        self.report["config_checks"] = checks
        if not all(checks.values()):
            return self._finish("JSON 往返断言失败：" + json.dumps(checks, ensure_ascii=False))
        self.js(CSV_JS, self._on_csv_start)

    # csv ----------------------------------------------------------------
    def _on_csv_start(self, _value):
        self._poll("window.__SMOKE_CSV", 60, self._on_csv)

    def _on_csv(self, value):
        if value is None:
            return self._finish("CSV 记录超时")
        self.report["csv"] = value
        checks = {
            "csv_ok": bool(value.get("ok")),
            "csv_rows": int(value.get("rows") or 0) > 50,
            "csv_fields": bool(value.get("hasFields")),
            "csv_field_count": int(value.get("headerCount") or 0) == 59
        }
        files = {
            "config_file": (TEST_DIR / "smoke_config.json").exists(),
            "csv_file": (TEST_DIR / "smoke_record.csv").exists()
        }
        checks.update(files)
        self.report["csv_checks"] = checks
        self.report["test_dir"] = str(TEST_DIR)
        if not all(checks.values()):
            return self._finish("CSV/文件断言失败：" + json.dumps(checks, ensure_ascii=False))
        self._final_errors()

    # final --------------------------------------------------------------
    def _final_errors(self):
        self.js("JSON.stringify({errors:(window.__J280_ERRORS||[]).slice(0,10),"
                "events:(window.J280_APP.test.getEvents()||[]).filter(function(e){return e.level==='error';}).slice(0,10)})",
                self._on_final_errors)

    def _on_final_errors(self, value):
        try:
            data = json.loads(value)
        except Exception:  # noqa: BLE001
            data = {"raw": value}
        self.report["final_errors"] = data
        ok = not data.get("errors") and not data.get("events")
        self.report["ok"] = bool(ok)
        self._finish(None if ok else "运行期间存在 JS 错误")

    def _poll(self, expr, attempts, callback, attempt=0):
        if attempt > attempts:
            callback(None)
            return
        self.js("JSON.stringify(%s === undefined ? null : %s)" % (expr, expr),
                lambda value: self._on_poll(expr, attempts, callback, attempt, value))

    def _on_poll(self, expr, attempts, callback, attempt, value):
        try:
            parsed = json.loads(value) if isinstance(value, str) else value
        except Exception:  # noqa: BLE001
            parsed = None
        if parsed is not None:
            callback(parsed)
            return
        QTimer.singleShot(300, lambda: self._poll(expr, attempts, callback, attempt + 1))

    def _finish(self, error):
        if error:
            self.report["error"] = error
        self.report["elapsed_s"] = round(time.time() - self.started, 2)
        out = BASE / "tests" / "last_smoke.json"
        try:
            out.write_text(json.dumps(self.report, ensure_ascii=False, indent=2), encoding="utf-8")
        except OSError:
            pass
        print("=" * 70)
        print("SMOKE REPORT: " + ("PASS" if self.report.get("ok") else "FAIL"))
        if error:
            print("ERROR: " + error)
        print(json.dumps(self.report, ensure_ascii=False, indent=2)[:9000])
        print("=" * 70)
        self.exit_code = 0 if self.report.get("ok") else 1
        self.app.quit()

    def _timeout(self):
        self.report["error"] = "总超时（60s）"
        self.exit_code = 1
        self.app.quit()


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("J280 Smoke")
    window = mainWnd(minisize=(1280, 800), size=(1500, 950))
    window.show()
    runner = SmokeRunner(app, window)
    runner.started = time.time()
    app.exec()
    sys.exit(runner.exit_code)


if __name__ == "__main__":
    main()
