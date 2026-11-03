# -*- coding: utf-8 -*-
r"""Qt 端交互测试：用真实 DOM 点击驱动关键流程。

覆盖：参数微调/回车发送/越界着色、参数组载入、JSON 保存→修改→载入往返、
记录 CSV 按钮、暂停、MODE 2/停机、悬浮提示、卡片折叠、清空显示、Esc/空格快捷键。

用法（建议隔离状态）：
  set J280_UI_TEST_DIR=D:\...\_dev\qt_test_tmp
  set J280_UI_STATE_PATH=D:\...\_dev\qt_state\ui_state_seeded.json
  .qtcreator\Python_3_11_9venv\Scripts\python.exe tests\interaction_test.py
退出码 0=PASS。
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
STATE_COPY = TEST_DIR / "interaction_state.json"
# 每次测试使用干净状态，避免受用户上次保存的布局/参数影响
CLEAN_STATE = {
    "ui_version": 3, "port": "COM9", "plot_window": "10 秒",
    "display_mode": "趋势", "trend_ms": "40 ms", "cards": {},
}
STATE_COPY.write_text(json.dumps(CLEAN_STATE, ensure_ascii=False, indent=2), encoding="utf-8")
os.environ["J280_UI_STATE_PATH"] = str(STATE_COPY)

from PySide6.QtCore import QTimer                              # noqa: E402
from PySide6.QtWidgets import QApplication                     # noqa: E402

from mainWnd import mainWnd                                    # noqa: E402

CFG_PATTERN = "j280_config_*.json"
CSV_PATTERN = "j280_*.csv"
for pattern in (CFG_PATTERN, CSV_PATTERN, "load_target.json"):
    for stale in TEST_DIR.glob(pattern):
        try:
            stale.unlink()
        except OSError:
            pass


def any_file(pattern):
    return sorted(TEST_DIR.glob(pattern))


JS = {
    "ready": "!!(window.J280_APP && J280_APP.ready)",
    "snapshot": r"""
(function(){try{
  var api=window.J280_APP, rt=api.test.getRuntime();
  function val(name){
    var row=document.querySelector('.param-row[data-name="'+name+'"]');
    return row?{value:row.querySelector('.param-input').value,
                dot:row.querySelector('.param-dot').getAttribute('data-state'),
                invalid:row.querySelector('.param-input').getAttribute('aria-invalid')}:null;
  }
  var firstCard=document.querySelector('.param-card');
  var cardRect=firstCard?firstCard.getBoundingClientRect():null;
  var evts=(api.test.getEvents?api.test.getEvents():[]).slice(-8).map(function(e){return e.text;});
  return JSON.stringify({
    akp:val('AKP'),
    postgt:val('POSTGT'),
    turns:val('TURNS_POSTGT'),
    absCardHidden:(function(){var c=document.querySelector('[data-card-id="abs-target-card"]');return c?c.hidden:null;})(),
    absCardTitle:(function(){var c=document.querySelector('[data-card-id="abs-target-card"] .card-title');return c?c.textContent:null;})(),
    absEquation:!!document.querySelector('.abs-equation'),
    absPhaseButtons:document.querySelectorAll('.abs-phase-input-row .mini-btn').length,
    absRange:!!document.querySelector('.abs-range'),
    turnsSetting:(function(){var b=document.querySelector('.param-row[data-name="TURNS_POSTGT"] .abs-edit');return b?b.textContent:null;})(),
    turnsNudges:document.querySelectorAll('.param-row[data-name="TURNS_POSTGT"] .nudge').length,
    postgtHint:document.querySelectorAll('.param-dial-hint').length,
    postgtZero:document.querySelectorAll('.dial-zero').length,
    paramSub:(document.querySelector('.param-row[data-name="AKP"] .param-sub')||{}).textContent,
    tooltipAllFields:(function(){
      var h=window.J280Params.tooltipHtml('AKP','');
      return ['↑ 调大','↓ 调小','提示','状态'].every(function(k){return h.indexOf(k)>=0;});
    })(),
    tooltipSwdirDash:(function(){
      var h=window.J280Params.tooltipHtml('SWDIR','');
      return h.indexOf('↑ 调大</span>-')>=0 && h.indexOf('↓ 调小</span>-')>=0;
    })(),
    cards:document.querySelectorAll('.param-card').length,
    bookmarks:document.querySelectorAll('#bookmarkRail .bookmark-item:not(.bookmark-special)').length,
    bookmarkTotal:document.querySelectorAll('#bookmarkRail .bookmark-item').length,
    specialBookmark:(function(){var n=document.querySelector('#bookmarkRail .bookmark-special .bookmark-name');return n?n.textContent:null;})(),
    specialActive:!!document.querySelector('#bookmarkRail .bookmark-special.active'),
    visibleCards:(api.test.visibleGroupCards?api.test.visibleGroupCards().length:0),
    activeBookmarks:document.querySelectorAll('#bookmarkRail .bookmark-item:not(.bookmark-special).active').length,
    cardFoots:document.querySelectorAll('.card-foot').length,
    cardCollapsedFirst: firstCard?firstCard.classList.contains('collapsed'):null,
    cardLeft: cardRect?Math.round(cardRect.left):null,
    cardTop: cardRect?Math.round(cardRect.top):null,
    crosshairActive: !!(window.J280_APP.state && window.J280_APP.state.crosshair),
    hiddenSeries: (window.J280_APP.test.getChartHidden?window.J280_APP.test.getChartHidden():null),
    pause:(document.getElementById('pauseToggle')||{}).checked,
    pausedDisplay:rt.display.paused,
    sent:rt.sentValues, mode:(rt.latest||{}).mode, rows:rt.rows,
    connected:rt.status.connected,
    mode1Disabled:(document.getElementById('btnMode1')||{}).disabled,
    mode3Disabled:(document.getElementById('btnMode3')||{}).disabled,
    modeText:(document.getElementById('modeText')||{}).textContent,
    balanceText:(document.getElementById('balanceText')||{}).textContent,
    absText:(document.getElementById('absText')||{}).textContent,
    srcHldText:(document.getElementById('srcHldText')||{}).textContent,
    version:(rt.latest||{}).ver,
    latestAbs:(rt.latest||{}).abs,
    sampleText:(document.getElementById('sampleText')||{}).textContent,
    eventTexts:evts,
    tooltipHidden:(document.getElementById('tooltip')||{}).hidden,
    tooltipLen:((document.getElementById('tooltip')||{}).textContent||'').length,
    errors:(window.__J280_ERRORS||[]).length,
    recording:rt.recording,
    recordRows:(api.test.recordBuffer()||[]).length,
    lastRecordCount:(api.test.lastRecordCount?api.test.lastRecordCount():0),
    eventCount:document.getElementById('eventList').children.length
  });
}catch(e){return JSON.stringify({fatal:String((e&&e.stack)||e)})}})()
""",
    "nudge": r"""
(function(){
  var btn=document.querySelector('.param-row[data-name="AKP"] .nudge[data-dir="1"]');
  if(!btn) return JSON.stringify({ok:false});
  btn.click();
  return JSON.stringify({ok:true, value:document.querySelector('.param-row[data-name="AKP"] .param-input').value});
})()
""",
    "enter_send": r"""
(function(){
  var input=document.querySelector('.param-row[data-name="AKP"] .param-input');
  input.focus();
  var ev=new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,bubbles:true});
  input.dispatchEvent(ev);
  return 'sent';
})()
""",
    "set_invalid": r"""
(function(){
  var input=document.querySelector('.param-row[data-name="AKP"] .param-input');
  input.value='99999';
  input.dispatchEvent(new Event('input',{bubbles:true}));
  return 'ok';
})()
""",
    "load_preset": "document.getElementById('btnLoadPreset') ? (document.getElementById('btnLoadPreset').click(), 'ok') : 'absent'",
    "save_config": "document.getElementById('btnSaveConfig').click(); 'ok'",
    "set_akp": r"""
(function(){
  var input=document.querySelector('.param-row[data-name="AKP"] .param-input');
  input.value='-123';
  input.dispatchEvent(new Event('input',{bubbles:true}));
  return 'ok';
})()
""",
    "load_config": "document.getElementById('btnLoadConfig').click(); 'ok'",
    "record_start": "document.getElementById('btnRecordStart').click(); 'ok'",
    "record_stop": "document.getElementById('btnRecordSave').click(); 'ok'",
    "pause_click": "document.getElementById('pauseToggle').click(); 'ok'",
    "mode2": "document.getElementById('btnMode2').click(); 'ok'",
    "stop": "document.getElementById('btnStop').click(); 'ok'",
    "hover_akp": r"""
(function(){
  var row=document.querySelector('.param-row[data-name="AKP"]');
  row.dispatchEvent(new MouseEvent('mouseenter',{bubbles:true}));
  return 'ok';
})()
""",
    "drag_card": r"""
(function(){
  var card=document.querySelector('.param-card');
  var head=card.querySelector('.card-head');
  var r=head.getBoundingClientRect();
  function send(type,x,y){
    head.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerId:7,
      clientX:x,clientY:y,button:0,buttons:(type==='pointerup'?0:1),
      pointerType:'mouse',isPrimary:true}));
  }
  send('pointerdown', r.left+30, r.top+12);
  send('pointermove', r.left+80, r.top+72);
  send('pointerup', r.left+80, r.top+72);
  return 'ok';
})()
""",
    "hover_chart": r"""
(function(){
  var c=document.getElementById('chartAngle');
  var r=c.getBoundingClientRect();
  c.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,
    clientX:r.left+r.width*0.62, clientY:r.top+r.height*0.5}));
  return 'ok';
})()
""",
    "leave_chart": r"""
(function(){
  document.getElementById('chartAngle').dispatchEvent(new MouseEvent('mouseleave',{bubbles:true}));
  return 'ok';
})()
""",
    "dial_left": r"""
(function(){
  var c=document.querySelector('.param-row[data-name="POSTGT"] .param-dial');
  if(!c) return 'no-dial';
  var r=c.getBoundingClientRect();
  function send(type,x,y){ c.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,
    pointerId:11,clientX:x,clientY:y,button:0,buttons:(type==='pointerup'?0:1),
    pointerType:'mouse',isPrimary:true})); }
  send('pointerdown', r.left+r.width*0.35, r.top+r.height*0.93);
  send('pointerup', r.left+r.width*0.35, r.top+r.height*0.93);
  return 'ok';
})()
""",
    "dial_right": r"""
(function(){
  var c=document.querySelector('.param-row[data-name="POSTGT"] .param-dial');
  if(!c) return 'no-dial';
  var r=c.getBoundingClientRect();
  function send(type,x,y){ c.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,
    pointerId:12,clientX:x,clientY:y,button:0,buttons:(type==='pointerup'?0:1),
    pointerType:'mouse',isPrimary:true})); }
  send('pointerdown', r.left+r.width*0.65, r.top+r.height*0.93);
  send('pointerup', r.left+r.width*0.65, r.top+r.height*0.93);
  return 'ok';
})()
""",
    "inject_many": r"""(function(){
  var api=window.J280_APP;
  var latest=api.test.latestRow();
  var base=latest?latest.t:0;
  var rows=[];
  for(var i=1;i<=12000;i++){
    rows.push({t:base+i*0.01,ang:1.2*Math.sin(i/37),raw:508,pos:(i%1040)-520,
      abs:i*13-5000,spd:0,dut:0,ref:-0.4,mode:1,st:5,sw:false,src:false,hld:false,
      ver:'y6',cc:6});
  }
  api.test.injectTelemetry(rows);
  return 'ok';
})()
""",
    "leave_akp": r"""
(function(){
  var row=document.querySelector('.param-row[data-name="AKP"]');
  row.dispatchEvent(new MouseEvent('mouseleave',{bubbles:true}));
  return 'ok';
})()
""",
    "collapse": r"""
(function(){
  var btn=document.querySelector('.param-card .card-collapse');
  btn.click();
  return 'ok';
})()
""",
    "clear": "document.getElementById('btnClear').click(); 'ok'",
    "space_key": r"""
(function(){
  document.body.dispatchEvent(new KeyboardEvent('keydown',{key:' ',code:'Space',bubbles:true}));
  return 'ok';
})()
""",
    "escape_key": r"""
(function(){
  document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',code:'Escape',bubbles:true}));
  return 'ok';
})()
""",
    "open_default_cards": r"""
(function(){
  var items=document.querySelectorAll('#bookmarkRail .bookmark-item');
  var byTitle={};
  for(var i=0;i<items.length;i++){ byTitle[items[i].getAttribute('data-group')]=items[i]; }
  if(byTitle['角度 PID']) byTitle['角度 PID'].click();
  if(byTitle['编码器位置外环']) byTitle['编码器位置外环'].click();
  return 'ok';
})()
""",
    "show_extra_bookmark": r"""
(function(){
  var items=document.querySelectorAll('#bookmarkRail .bookmark-item');
  for(var i=0;i<items.length;i++){
    if(items[i].getAttribute('data-group')==='容差保持'){ items[i].click(); return 'ok'; }
  }
  return 'missing';
})()
""",
    "hide_extra_bookmark": r"""
(function(){
  var items=document.querySelectorAll('#bookmarkRail .bookmark-item');
  for(var i=0;i<items.length;i++){
    if(items[i].getAttribute('data-group')==='容差保持'){ items[i].click(); return 'ok'; }
  }
  return 'missing';
})()
""",
    "stop_feed": "try { window.__J280_TEST_FEED.stop(); 'ok'; } catch (e) { String(e); }",
    "open_abs_editor": "document.querySelector('#bookmarkRail .bookmark-special').click(); 'ok'",
    "apply_abs_target": r"""
(function(){
  var api=window.J280_APP;
  api.test.setAbsTarget(2, 123);
  document.getElementById('absApply').click();
  document.getElementById('absHideCard').click();
  return 'ok';
})()
""",
    "inject_mode3": r"""
(function(){
  var api=window.J280_APP;
  var latest=api.test.latestRow();
  var t=latest?latest.t+0.01:1;
  api.test.injectTelemetry([{t:t,ang:0.2,raw:508,pos:100,abs:12345,spd:0,dut:0,
    ref:0.0,mode:3,st:4,sw:false,src:false,hld:true,ver:'y6',cc:6}]);
  return 'ok';
})()
""",
    "file_state": r"""
(function(){
  var api=window.J280_APP;
  return JSON.stringify({
    recording:api.test.getRuntime().recording,
    rows:api.test.getRuntime().rows,
    recordRows:api.test.recordBuffer().length,
    mode:(api.test.latestRow()||{}).mode,
    errors:(window.__J280_ERRORS||[]).length
  });
})()
""",
}


class Runner:
    def __init__(self, app, window):
        self.app = app
        self.window = window
        self.report = {"ok": False, "checks": {}, "notes": []}
        self.exit_code = 2
        self.started = time.time()
        self._ready_tries = 0
        self._steps = [
            ("wait", 2600),
            ("snap_bookmarks_initial", 0),
            ("open_default_cards", 350),
            ("snap_initial", 0),
            ("show_extra_bookmark", 250),
            ("snap_bookmark_show", 0),
            ("hide_extra_bookmark", 250),
            ("snap_bookmark_hide", 0),
            ("drag_card", 250),
            ("snap_drag", 0),
            ("nudge", 150),
            ("snap_after_nudge", 0),
            ("enter_send", 400),
            ("snap_after_send", 0),
            ("save_config", 1000),
            ("prepare_load", 0),
            ("set_akp", 150),
            ("load_config", 900),
            ("snap_config", 0),
            ("set_invalid", 150),
            ("snap_invalid", 0),
            ("hover_chart", 300),
            ("snap_crosshair", 0),
            ("leave_chart", 120),
            ("dial_left", 250),
            ("snap_dial_left", 0),
            ("dial_right", 250),
            ("snap_dial_right", 0),
            ("open_abs_editor", 300),
            ("snap_abs_open", 0),
            ("apply_abs_target", 300),
            ("snap_abs_apply", 0),
            ("record_start", 1700),
            ("record_stop", 1500),
            ("snap_record", 0),
            ("pause_click", 150),
            ("snap_pause_on", 0),
            ("pause_click", 150),
            ("snap_pause_off", 0),
            ("hover_akp", 200),
            ("snap_tooltip", 0),
            ("leave_akp", 100),
            ("collapse", 200),
            ("snap_collapse", 0),
            ("space_key", 200),
            ("snap_space", 0),
            ("escape_key", 400),
            ("snap_escape", 0),
            ("clear", 100),
            ("snap_clear", 0),
            ("inject_many", 400),
            ("snap_memory", 0),
            ("stop_feed", 60),
            ("inject_mode3", 260),
            ("snap_mode3", 0),
            ("file_state", 0),
            ("final", 0),
        ]
        self._index = 0
        self._snapshots = {}
        window._web_list[0].loadFinished.connect(self._on_load)
        QTimer.singleShot(90000, self._timeout)

    def _page(self):
        return self.window._web_list[0].page()

    def js(self, code, callback):
        self._page().runJavaScript(code, callback)

    def _on_load(self, ok):
        if not ok:
            return self._finish("页面加载失败")
        QTimer.singleShot(1200, self._poll_ready)

    def _poll_ready(self):
        self._ready_tries += 1
        self.js(JS["ready"], self._on_ready)

    def _on_ready(self, ready):
        if ready:
            feed_js = (BASE / "tests" / "test_feed.js").read_text(encoding="utf-8")
            self.js(feed_js + "\ntry { window.__J280_TEST_FEED.start(); 'ok'; }"
                    " catch (e) { String(e); }",
                    lambda _value: self._next())
            return
        if self._ready_tries > 40:
            return self._finish("等待 J280_APP.ready 超时")
        QTimer.singleShot(500, self._poll_ready)

    # ---- step machine ---------------------------------------------------
    def _next(self):
        if self._index >= len(self._steps):
            return self._finish(None)
        name, delay = self._steps[self._index]
        self._index += 1

        if name == "wait":
            QTimer.singleShot(delay, self._next)
            return
        if name == "prepare_load":
            saved = any_file(CFG_PATTERN)
            if saved:
                (TEST_DIR / "load_target.json").write_text(
                    saved[-1].read_text(encoding="utf-8-sig"), encoding="utf-8")
            self.report.setdefault("notes", []).append(
                "load_target from " + (saved[-1].name if saved else "none"))
            self._next()
            return
        if name == "final":
            return self._final()
        if name.startswith("snap_"):
            target = name[len("snap_"):]
            self.js(JS["snapshot"], lambda value: self._store_snapshot(target, value, delay))
            return
        code = JS.get(name)
        if code is None:
            return self._finish("未知步骤：" + name)
        self.js(code, lambda _value: QTimer.singleShot(delay, self._next))

    def _store_snapshot(self, target, value, delay):
        try:
            self._snapshots[target] = json.loads(value) if isinstance(value, str) else value
        except Exception as error:  # noqa: BLE001
            self._snapshots[target] = {"parse_error": str(error), "raw": value}
        QTimer.singleShot(delay, self._next)

    # ---- assertions -----------------------------------------------------
    def _check(self, name, condition, detail=""):
        self.report["checks"][name] = {"ok": bool(condition), "detail": detail}
        return bool(condition)

    def _final(self):
        snaps = self._snapshots
        bookmarks_initial = snaps.get("bookmarks_initial") or {}
        initial = snaps.get("initial") or {}
        bookmark_show = snaps.get("bookmark_show") or {}
        bookmark_hide = snaps.get("bookmark_hide") or {}
        drag = snaps.get("drag") or {}
        crosshair = snaps.get("crosshair") or {}
        dial_left = snaps.get("dial_left") or {}
        dial_right = snaps.get("dial_right") or {}
        nudge = snaps.get("after_nudge") or {}
        sent = snaps.get("after_send") or {}
        invalid = snaps.get("invalid") or {}
        config = snaps.get("config") or {}
        record = snaps.get("record") or {}
        pause_on = snaps.get("pause_on") or {}
        pause_off = snaps.get("pause_off") or {}
        tooltip = snaps.get("tooltip") or {}
        collapse = snaps.get("collapse") or {}
        space = snaps.get("space") or {}
        escape = snaps.get("escape") or {}
        clear = snaps.get("clear") or {}
        memory = snaps.get("memory") or {}
        mode3 = snaps.get("mode3") or {}
        abs_open = snaps.get("abs_open") or {}
        abs_apply = snaps.get("abs_apply") or {}

        def value_of(snap):
            akp = snap.get("akp") or {}
            return akp.get("value")

        def has_event(snap, needle):
            return any(needle in str(text) for text in (snap.get("eventTexts") or []))

        base = int(value_of(initial) or -150)
        self._check("initial_six_cards", initial.get("cards") == 6, str(initial.get("cards")))
        self._check("cards_default_hidden",
                    bookmarks_initial.get("bookmarks") == 6 and
                    bookmarks_initial.get("visibleCards") == 0 and
                    bookmarks_initial.get("specialBookmark") == "指定运动轨迹",
                    "bookmarks=%s visible=%s special=%s" % (
                        bookmarks_initial.get("bookmarks"), bookmarks_initial.get("visibleCards"),
                        bookmarks_initial.get("specialBookmark")))
        self._check("bookmarks_show_cards",
                    initial.get("visibleCards") == 2 and
                    initial.get("activeBookmarks") == 2,
                    "visible=%s active=%s" % (initial.get("visibleCards"),
                                               initial.get("activeBookmarks")))
        self._check("bookmark_toggle_show_hide",
                    bookmark_show.get("visibleCards") == 3 and
                    bookmark_show.get("activeBookmarks") == 3 and
                    bookmark_hide.get("visibleCards") == 2 and
                    bookmark_hide.get("activeBookmarks") == 2,
                    "show=%s/%s hide=%s/%s" % (
                        bookmark_show.get("visibleCards"), bookmark_show.get("activeBookmarks"),
                        bookmark_hide.get("visibleCards"), bookmark_hide.get("activeBookmarks")))
        self._check("mode3_button_present",
                    initial.get("mode3Disabled") is True,
                    "mode3Disabled=%s" % initial.get("mode3Disabled"))
        self._check("turns_row_controls",
                    str(initial.get("specialBookmark") or "").strip() == "指定运动轨迹" and
                    str(initial.get("turnsSetting") or "").strip() == "设置" and
                    initial.get("turnsNudges") == 0,
                    "special=%s setting=%s nudges=%s" % (
                        initial.get("specialBookmark"), initial.get("turnsSetting"),
                        initial.get("turnsNudges")))
        self._check("postgt_clean",
                    initial.get("postgtHint") == 0 and initial.get("postgtZero") == 0,
                    "hint=%s zero=%s" % (initial.get("postgtHint"), initial.get("postgtZero")))
        self._check("telemetry_abs_shown",
                    str(initial.get("absText") or "").startswith("ABS ") and
                    initial.get("latestAbs") is not None,
                    "absText=%s abs=%s" % (initial.get("absText"), initial.get("latestAbs")))
        self._check("telemetry_src_hld_shown",
                    "SRC" in str(initial.get("srcHldText")) and "HLD" in str(initial.get("srcHldText")),
                    str(initial.get("srcHldText")))
        self._check("firmware_version_y",
                    initial.get("version") == "y6", str(initial.get("version")))
        self._check("param_sub_only_key", initial.get("paramSub") == "AKP",
                    str(initial.get("paramSub")))
        self._check("tooltip_all_fields", initial.get("tooltipAllFields") is True,
                    str(initial.get("tooltipAllFields")))
        self._check("tooltip_swdir_dash", initial.get("tooltipSwdirDash") is True,
                    str(initial.get("tooltipSwdirDash")))
        self._check("card_footer_removed", initial.get("cardFoots") == 0,
                    "cardFoots=%s" % initial.get("cardFoots"))
        self._check("initial_inputs_filled", value_of(initial) not in (None, ""), str(value_of(initial)))
        self._check("defaults_from_config0", value_of(initial) == "-150", str(value_of(initial)))
        self._check("disconnected_mode_buttons_disabled",
                    initial.get("connected") is False and initial.get("mode1Disabled") is True,
                    "connected=%s disabled=%s" % (initial.get("connected"), initial.get("mode1Disabled")))
        self._check("sample_text_shows_frames", "已收" in str(initial.get("sampleText")),
                    str(initial.get("sampleText")))
        self._check("card_drag_moved",
                    drag.get("cardTop") is not None and initial.get("cardTop") is not None and
                    int(drag.get("cardTop")) > int(initial.get("cardTop")),
                    "before=%s after=%s" % (initial.get("cardTop"), drag.get("cardTop")))
        self._check("chart_crosshair", crosshair.get("crosshairActive") is True,
                    str(crosshair.get("crosshairActive")))
        left_v = int((dial_left.get("postgt") or {}).get("value") or 0)
        right_v = int((dial_right.get("postgt") or {}).get("value") or 0)
        self._check("postgt_dial_left", -520 <= left_v < -400, "left=%s" % left_v)
        self._check("postgt_dial_wrap", -520 <= right_v <= 519 and right_v > 400 and
                    (left_v < 0) != (right_v < 0),
                    "left=%s right=%s（底部 -520 ⇄ +519 轮回）" % (left_v, right_v))
        self._check("abs_editor_opens",
                    abs_open.get("absCardHidden") is False and
                    abs_open.get("specialActive") is True,
                    "hidden=%s active=%s" % (abs_open.get("absCardHidden"),
                                             abs_open.get("specialActive")))
        self._check("abs_editor_apply",
                    (abs_apply.get("turns") or {}).get("value") == "2203" and
                    abs_apply.get("absCardHidden") is True and
                    abs_apply.get("specialActive") is False,
                    "turns=%s hidden=%s active=%s" % ((abs_apply.get("turns") or {}).get("value"),
                                                      abs_apply.get("absCardHidden"),
                                                      abs_apply.get("specialActive")))
        self._check("abs_card_clean",
                    abs_apply.get("absCardTitle") == "指定运动轨迹" and
                    abs_apply.get("absEquation") is False and
                    abs_apply.get("absPhaseButtons") == 0 and
                    abs_apply.get("absRange") is False,
                    "title=%s eq=%s phaseBtns=%s range=%s" % (
                        abs_apply.get("absCardTitle"), abs_apply.get("absEquation"),
                        abs_apply.get("absPhaseButtons"), abs_apply.get("absRange")))
        self._check("abs_editor_event",
                    has_event(abs_apply, "绝对定位目标"),
                    str(abs_apply.get("eventTexts")))
        self._check("nudge_plus", str(int(base + 5)) == str(value_of(nudge)),
                    "base=%s after=%s" % (base, value_of(nudge)))
        self._check("send_warns_when_disconnected",
                    not (sent.get("sent") or {}) and has_event(sent, '参数未发送'),
                    "sent=%s events=%s" % (sent.get("sent"), sent.get("eventTexts")))
        self._check("invalid_dot", (invalid.get("akp") or {}).get("dot") == "invalid",
                    str((invalid.get("akp") or {}).get("dot")))
        self._check("invalid_aria", (invalid.get("akp") or {}).get("invalid") == "true",
                    str((invalid.get("akp") or {}).get("invalid")))
        self._check("config_saved_file", bool(any_file(CFG_PATTERN)), str(any_file(CFG_PATTERN)))
        self._check("config_load_restores", value_of(config) == str(int(base + 5)),
                    "expected=%s got=%s" % (base + 5, value_of(config)))
        self._check("record_csv_file", bool(any_file(CSV_PATTERN)), str(any_file(CSV_PATTERN)))
        self._check("record_rows", int(record.get("lastRecordCount") or 0) > 50,
                    "lastRecordCount=%s" % record.get("lastRecordCount"))
        self._check("pause_on", pause_on.get("pausedDisplay") is True, str(pause_on.get("pausedDisplay")))
        self._check("pause_off", pause_off.get("pausedDisplay") is False, str(pause_off.get("pausedDisplay")))
        self._check("hover_tooltip_removed",
                    tooltip.get("tooltipHidden") is True and
                    int(tooltip.get("tooltipLen") or 0) == 0,
                    "hidden=%s len=%s" % (tooltip.get("tooltipHidden"), tooltip.get("tooltipLen")))
        self._check("collapse_toggle", collapse.get("cardCollapsedFirst") is True,
                    str(collapse.get("cardCollapsedFirst")))
        self._check("space_pause", space.get("pausedDisplay") is True, str(space.get("pausedDisplay")))
        self._check("escape_exits_fullscreen_only",
                    escape.get("mode") == 1 and not has_event(escape, 'MODE 0 未发送'),
                    "mode=%s events=%s" % (escape.get("mode"), escape.get("eventTexts")))
        self._check("clear_rows", int(clear.get("rows") or 0) < 500, str(clear.get("rows")))
        self._check("memory_trimmed", 7000 <= int(memory.get("rows") or 0) <= 10000,
                    "rows=%s (cap 10000, trim 2500)" % memory.get("rows"))
        self._check("mode3_ui_text", "MODE 3" in str(mode3.get("modeText")),
                    str(mode3.get("modeText")))
        self._check("abs_src_hld_ui",
                    "ABS +12345" in str(mode3.get("absText")) and
                    "SRC 上位" in str(mode3.get("srcHldText")) and
                    "HLD 保持" in str(mode3.get("srcHldText")),
                    "abs=%s srcHld=%s" % (mode3.get("absText"), mode3.get("srcHldText")))
        self._check("mode3_hold_status",
                    "容差保持" in str(mode3.get("balanceText")),
                    str(mode3.get("balanceText")))
        self._check("no_js_errors", int(final_errors(snaps)) == 0, str(final_errors(snaps)))
        self.report["snapshots"] = snaps
        self.report["test_dir"] = str(TEST_DIR)
        self.report["ok"] = all(item["ok"] for item in self.report["checks"].values())
        self._finish(None if self.report["ok"] else "交互断言失败")

    # ---- finish ---------------------------------------------------------
    def _finish(self, error):
        if error:
            self.report["error"] = error
        self.report["elapsed_s"] = round(time.time() - self.started, 2)
        out = BASE / "tests" / "last_interaction.json"
        try:
            out.write_text(json.dumps(self.report, ensure_ascii=False, indent=2), encoding="utf-8")
        except OSError:
            pass
        checks = self.report.get("checks", {})
        failed = {k: v for k, v in checks.items() if not v.get("ok")}
        print("=" * 70)
        print("INTERACTION REPORT: " + ("PASS" if self.report.get("ok") else "FAIL"))
        if error:
            print("ERROR: " + error)
        print("checks: %d/%d passed" % (len(checks) - len(failed), len(checks)))
        if failed:
            print("FAILED:", json.dumps(failed, ensure_ascii=False, indent=2))
        print("=" * 70)
        self.exit_code = 0 if self.report.get("ok") else 1
        self.app.quit()

    def _timeout(self):
        self.report["error"] = "总超时（90s）"
        self.exit_code = 1
        self.app.quit()


def final_errors(snaps):
    for key in ("clear", "escape", "space", "collapse", "tooltip"):
        snap = snaps.get(key) or {}
        if "errors" in snap:
            return snap.get("errors") or 0
    return 0


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("J280 Interaction")
    window = mainWnd(minisize=(1280, 800), size=(1500, 950))
    window.show()
    runner = Runner(app, window)
    app.exec()
    sys.exit(runner.exit_code)


if __name__ == "__main__":
    main()
