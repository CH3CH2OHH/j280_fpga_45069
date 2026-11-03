/* ============================================================================
 * J280 · 运动与平衡调试台 —— 应用编排（app.js）
 *
 * 依赖（经典 script，必须在本文件之前加载）：
 *   params.js  -> window.J280Params
 *   cards.js   -> window.J280Cards
 *   charts.js  -> window.J280Charts
 *   model3d.js -> window.J280Model3D
 *   bridge.js  -> window.J280Bridge
 *
 * 职责：遥测环形缓冲 / 指标与状态 / 5 路曲线 / 3D 状态 / 参数卡片 / JSON 配置
 *       读写 / 参数组 / 记录 CSV / 摆动分析 / 事件日志 / 状态持久化 / 快捷键。
 * 行为基准：project/gui/j280_debug_gui.py（Tk 版）。
 * ========================================================================== */
(function () {
  'use strict';

  /* ------------------------------ 常量 ---------------------------------- */
  var ENC_CPR = 1040;
  var TELEM_HZ = 100;
  // 显示缓冲上限：100 Hz 下 10000 帧≈100 s，超过后一次性丢弃最早 2500 帧，
  // 保留约 75 s（覆盖最大 60 s 时间窗），避免长时间接收时内存持续增长。
  var BUFFER_MAX = 10000;
  var BUFFER_TRIM = 2500;
  // 记录缓冲上限（100 Hz≈5 分钟）；达到上限自动停止记录，保存成功后释放。
  var RECORD_MAX = 30000;
  var EVENTS_MAX = 500;
  var SAVE_DEBOUNCE_MS = 800;
  var DRAW_INTERVAL_MS = 45;        // ~22 fps，与原 GUI 50 ms 重绘相当
  var ANALYSIS_INTERVAL_MS = 250;
  var DEFAULT_WINDOW_S = 10;
  var CSV_EXTRA_FIELDS = ['time_s', 'ang', 'ref', 'ref_cdeg', 'raw', 'pos',
    'pos_absolute', 'src_local', 'spd', 'dut', 'mode', 'bal_status',
    'swing_active', 'position_hold', 'version', 'config_count', 'tgt', 'tgt_abs',
    'pos_total', 'pos_error'];

  var PLOT_DEFS = [
    { key: 'angle', canvasId: 'chartAngle', title: '摆杆角度', series: ['ANG', 'REF'],
      unit: '°', includeZero: true, symmetric: true, wrapThreshold: null },
    { key: 'position', canvasId: 'chartPosition', title: '编码器相位',
      series: ['POS', 'TGT'], unit: 'count', includeZero: false, symmetric: false,
      wrapThreshold: ENC_CPR / 2 },
    { key: 'speed', canvasId: 'chartSpeed', title: '摆臂速度', series: ['SPD'],
      unit: 'count/s', includeZero: true, symmetric: false, wrapThreshold: null },
    { key: 'duty', canvasId: 'chartDuty', title: '电机输出', series: ['DUT'],
      unit: 'duty', includeZero: true, symmetric: true, wrapThreshold: null },
    { key: 'raw', canvasId: 'chartRaw', title: 'ADC 原始值', series: ['RAW'],
      unit: 'ADC', includeZero: false, symmetric: false, wrapThreshold: null }
  ];

  var CARD_MAX_BODY = [0, 250, 250, 220, 160, 250];   // 0 = 不限制
  var CARD_DEFAULT_COLLAPSED = [false, false, false, false, false, false];

  /* --------------------------- 全局错误收集 ------------------------------ */
  var errors = window.__J280_ERRORS = window.__J280_ERRORS || [];
  var lastErrorKey = '';
  var lastErrorAt = 0;

  function reportError(err, where) {
    var message = err && err.message ? err.message : String(err);
    var key = where + '|' + message;
    var now = Date.now();
    if (key === lastErrorKey && now - lastErrorAt < 2000) return;
    lastErrorKey = key; lastErrorAt = now;
    var item = { where: where || 'app', message: message, time: new Date().toISOString() };
    if (err && err.stack) item.stack = String(err.stack).slice(0, 1200);
    errors.push(item);
    if (errors.length > 200) errors.splice(0, errors.length - 200);
    var banner = document.getElementById('errorBanner');
    if (banner) {
      banner.hidden = false;
      banner.textContent = '界面错误（' + (where || 'app') + '）：' + message +
        (errors.length > 1 ? '（累计 ' + errors.length + ' 条）' : '');
    }
    addEvent('error', '界面错误（' + (where || 'app') + '）：' + message);
    if (window.console && console.error) console.error('[J280]', where, err);
  }

  window.addEventListener('error', function (ev) {
    var message = (ev && ev.message) || '';
    // ResizeObserver 的“loop completed”提示是浏览器噪声，不是业务错误
    if (/ResizeObserver loop/i.test(message)) return;
    reportError(ev.error || new Error(message || 'unknown error'), 'window');
  });
  window.addEventListener('unhandledrejection', function (ev) {
    reportError(ev.reason || new Error('unhandled rejection'), 'promise');
  });

  /* ------------------------------ 工具 ---------------------------------- */
  function $(id) { return document.getElementById(id); }
  function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }
  function mod(v, m) { return ((v % m) + m) % m; }
  function numOrNull(v) { var n = Number(v); return Number.isFinite(n) ? n : null; }
  function intOrNull(v) { var n = Number(v); return Number.isFinite(n) ? Math.round(n) : null; }
  function signed(v, digits) {
    if (v == null) return '--';
    var s = Number(v).toFixed(digits);
    return (Number(v) >= 0 ? '+' : '') + s;
  }
  function pad4(v) { return String(Math.round(Number(v))).padStart(4, '0'); }
  function timeStr(d) {
    d = d || new Date();
    function p(n) { return n < 10 ? '0' + n : '' + n; }
    return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }
  function fileStamp(d) {
    d = d || new Date();
    function p(n) { return n < 10 ? '0' + n : '' + n; }
    return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '_' +
      p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
  }
  function nowStamp(d) {
    d = d || new Date();
    function p(n) { return n < 10 ? '0' + n : '' + n; }
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' +
      p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }
  function lowerBound(arr, value) {
    var lo = 0, hi = arr.length;
    while (lo < hi) { var mid = (lo + hi) >> 1; if (arr[mid] < value) lo = mid + 1; else hi = mid; }
    return lo;
  }
  function upperBound(arr, value) {
    var lo = 0, hi = arr.length;
    while (lo < hi) { var mid = (lo + hi) >> 1; if (arr[mid] <= value) lo = mid + 1; else hi = mid; }
    return lo;
  }
  function csvCell(v) {
    if (v === null || v === undefined) return '';
    var s = String(v);
    if (s.indexOf('"') >= 0) s = s.replace(/"/g, '""');
    if (/[",\r\n]/.test(s)) s = '"' + s + '"';
    return s;
  }

  /* ------------------------------ 状态 ---------------------------------- */
  var state = {
    backend: null,
    modelView: null,
    ready: false,
    status: { connected: false, port: '', error: null },
    lastVersion: '',
    fullscreen: false,
    times: [],
    rows: [],
    latest: null,
    recorded: [],
    recording: false,
    recordWarned: false,
    lastRecordCount: 0,
    positionPrevious: null,
    positionUnwrapped: null,
    request: null,                 // {mode, at}
    sentValues: {},                // 本机最近成功发送的参数（非板端读回）
    sentSnapshot: Object.freeze({}),
    paramRows: {},
    cards: {},                     // groupTitle -> Card
    cardLayout: {},                // groupTitle -> {x,y,collapsed}
    absCard: null,                 // TURNS_POSTGT 图形卡片（可拖动）
    absCardSaved: null,            // 上次关闭时的图形卡片位置/折叠
    savedCards: null,
    savedPort: '',
    display: { mode: '趋势', tauMs: 40, windowS: DEFAULT_WINDOW_S, paused: false, lockY: false },
    freezeT: null,
    crosshair: null,
    analysisCache: '',
    events: [],
    saveTimer: null,
    startedAt: Date.now()
  };

  var els = null;
  var plots = {};                  // key -> ScopePlot
  var plotCanvases = {};           // key -> canvas

  /* --------------------------- 启动遮罩文本 ------------------------------ */
  function setBootText(text) {
    var el = els && els.bootText;
    if (el) el.textContent = text;
  }

  /* --------------------------- DOM 缓存 ---------------------------------- */
  var DOM_IDS = [
    'bootOverlay', 'bootText', 'topbar', 'portSelect', 'btnRefreshPorts', 'btnConnect',
    'connStatus', 'btnMode1', 'btnMode2', 'btnMode3', 'btnStop', 'btnSendAll', 'btnSaveConfig',
    'btnLoadConfig', 'btnFullscreenOn', 'btnFullscreenOff', 'modeText', 'balanceText',
    'positionErrorText', 'absText', 'srcHldText', 'sampleText',
    'viewport', 'model3d', 'metricAng', 'metricRef', 'metricRaw', 'metricPos',
    'metricSpd', 'metricDut', 'analysisSummary', 'analysisHint', 'chartsPane',
    'displayMode', 'trendMs', 'plotWindow', 'pauseToggle', 'lockYToggle',
    'btnRecordStart', 'btnRecordSave', 'btnClear', 'recordStatus', 'chartAngle',
    'chartPosition', 'chartSpeed', 'chartDuty', 'chartRaw', 'eventLog', 'eventList',
    'btnClearEvents', 'cardLayer', 'stage', 'bookmarkRail', 'tooltip', 'toastLayer', 'fileInputConfig',
    'errorBanner', 'absCardTemplate', 'absHideCard', 'absApply',
    'absApplySend', 'absTurnsInput', 'absTurnsMinus', 'absTurnsPlus',
    'absTurnsCanvas', 'absPhaseInput', 'absPhaseCanvas', 'absPhaseLimit'
  ];

  function cacheDom() {
    els = {};
    var missing = [];
    for (var i = 0; i < DOM_IDS.length; i++) {
      var id = DOM_IDS[i];
      els[id] = $(id);
      if (!els[id]) missing.push(id);
    }
    if (missing.length) throw new Error('DOM 缺少元素：' + missing.join(', '));
  }

  /* --------------------------- 事件日志 ---------------------------------- */
  function addEvent(level, text) {
    if (!els || !els.eventList) return;
    level = level || 'info';
    var item = { level: level, text: String(text), time: new Date() };
    state.events.push(item);
    if (state.events.length > EVENTS_MAX) state.events.shift();
    var li = document.createElement('li');
    li.className = 'event-item';
    li.dataset.level = level;
    var ts = document.createElement('span');
    ts.className = 'event-time';
    ts.textContent = timeStr(item.time);
    li.appendChild(ts);
    li.appendChild(document.createTextNode('  ' + item.text));
    els.eventList.appendChild(li);
    while (els.eventList.children.length > EVENTS_MAX) {
      els.eventList.removeChild(els.eventList.firstChild);
    }
    els.eventList.scrollTop = els.eventList.scrollHeight;
  }

  function showToast(text, kind, ms) {
    if (!els || !els.toastLayer) return;
    var map = { ok: 'toast-ok', info: 'toast-ok', warn: 'toast-warn', err: 'toast-err', error: 'toast-err' };
    var el = document.createElement('div');
    el.className = 'toast ' + (map[kind] || 'toast-ok');
    el.textContent = text;
    els.toastLayer.appendChild(el);
    while (els.toastLayer.children.length > 4) els.toastLayer.removeChild(els.toastLayer.firstChild);
    setTimeout(function () {
      el.classList.add('out');
      setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, 260);
    }, ms || 3200);
  }

  /* --------------------------- 悬浮提示 ---------------------------------- */
  function showTooltip(html, anchorEl) {
    if (!els || !els.tooltip) return;
    els.tooltip.innerHTML = html;
    els.tooltip.hidden = false;
    positionTooltip(anchorEl);
  }
  function positionTooltip(anchorEl) {
    if (!els || !els.tooltip || !anchorEl) return;
    var rect = anchorEl.getBoundingClientRect();
    var tip = els.tooltip;
    var tw = tip.offsetWidth || 340;
    var th = tip.offsetHeight || 220;
    var x = rect.right + 12;
    if (x + tw > window.innerWidth - 8) x = rect.left - tw - 12;
    if (x < 8) x = 8;
    var y = rect.top - 6;
    if (y + th > window.innerHeight - 8) y = Math.max(8, window.innerHeight - th - 8);
    if (y < 8) y = 8;
    tip.style.left = x + 'px';
    tip.style.top = y + 'px';
  }
  function hideTooltip() {
    if (els && els.tooltip) els.tooltip.hidden = true;
  }

  /** 把 toast 容器放到顶栏下方，避免短暂遮住 MODE/停机按钮。 */
  function updateToastPosition() {
    if (!els || !els.toastLayer || !els.topbar) return;
    try {
      els.toastLayer.style.top = (els.topbar.offsetHeight + 10) + 'px';
    } catch (e) { /* ignore */ }
  }

  /* --------------------------- 参数辅助 ---------------------------------- */
  function paramRow(name) { return state.paramRows[name] || null; }

  function parseIntEntry(text) {
    if (window.J280Params && J280Params.parseIntEntry) return J280Params.parseIntEntry(text);
    var t = String(text == null ? '' : text).trim();
    if (!t) return { ok: false, value: null, error: '不能为空' };
    var n = Number(t);
    if (!Number.isFinite(n) || Math.round(n) !== n) return { ok: false, value: null, error: '必须是整数' };
    return { ok: true, value: n, error: null };
  }

  function paramNumber(name, fallback) {
    var row = paramRow(name);
    if (!row) return fallback;
    var parsed = parseIntEntry(row.getText());
    return parsed.ok ? parsed.value : fallback;
  }

  function paramStatusText(name) {
    var row = paramRow(name);
    if (!row) return '未下发';
    var parsed = parseIntEntry(row.getText());
    if (!parsed.ok) return '输入无效';
    if (window.J280Params && J280Params.validate) {
      var checked = J280Params.validate(name, parsed.value);
      if (!checked.ok) return '输入无效';
    }
    if (Object.prototype.hasOwnProperty.call(state.sentValues, name)) {
      return state.sentValues[name] === parsed.value ? '已下发' : '已修改未下发';
    }
    return '未下发';
  }

  function refreshParamDot(name) {
    var row = paramRow(name);
    if (!row) return;
    var statusText = paramStatusText(name);
    var key = statusText === '输入无效' ? 'invalid' :
      statusText === '已下发' ? 'sent' :
        statusText === '已修改未下发' ? 'dirty' : 'default';
    if (row.setStatus) row.setStatus(key, statusText);
  }

  function refreshAllDots() {
    var order = (J280Params.ORDER || Object.keys(J280Params.PARAMS));
    for (var i = 0; i < order.length; i++) refreshParamDot(order[i]);
  }

  function collectParamValues() {
    var values = {};
    var invalid = [];
    var order = (J280Params.ORDER || Object.keys(J280Params.PARAMS));
    for (var i = 0; i < order.length; i++) {
      var name = order[i];
      var row = paramRow(name);
      if (!row) continue;
      var parsed = parseIntEntry(row.getText());
      if (!parsed.ok) invalid.push(name + '：' + parsed.error);
      else values[name] = parsed.value;
    }
    return { values: values, invalid: invalid };
  }

  function freezeSent() { return Object.freeze(Object.assign({}, state.sentValues)); }

  function applyConfigValues(values) {
    var applied = {};
    var skipped = [];
    if (!values || typeof values !== 'object') return { applied: applied, skipped: ['配置不是对象'] };
    var keys = Object.keys(values);
    for (var i = 0; i < keys.length; i++) {
      var name = keys[i];
      if (!window.J280Params || !J280Params.PARAMS[name]) { skipped.push(name + '：未知参数'); continue; }
      var raw = values[name];
      var parsed;
      if (typeof raw === 'string') parsed = parseIntEntry(raw);
      else if (typeof raw === 'number') parsed = { ok: true, value: raw, error: null };
      else { skipped.push(name + '：类型无效'); continue; }
      if (!parsed.ok) { skipped.push(name + '：' + parsed.error); continue; }
      var checked = J280Params.validate(name, parsed.value);
      if (!checked.ok) { skipped.push(name + '：' + checked.error); continue; }
      var row = paramRow(name);
      if (!row) { skipped.push(name + '：未创建'); continue; }
      row.setValue(String(checked.value));
      applied[name] = checked.value;
    }
    refreshAllDots();
    saveStateSoon();
    return { applied: applied, skipped: skipped };
  }

  /* --------------------------- 窗口全屏 ---------------------------------- */
  function updateFullscreenUI() {
    if (!els) return;
    els.btnFullscreenOn.hidden = !!state.fullscreen;
    els.btnFullscreenOff.hidden = !state.fullscreen;
  }

  function applyWindowState(windowState) {
    if (!windowState || typeof windowState !== 'object') return;
    if (typeof windowState.fullscreen === 'boolean') {
      state.fullscreen = windowState.fullscreen;
    }
    updateFullscreenUI();
  }

  function requestFullscreen(enabled) {
    if (!state.backend || typeof state.backend.setFullscreen !== 'function') {
      addEvent('warn', '全屏控制不可用（仅桌面端支持）');
      return;
    }
    state.backend.setFullscreen(!!enabled).then(function (res) {
      if (res && res.ok) applyWindowState(res);
      else addEvent('warn', '全屏切换失败：' + ((res && res.error) || '未知错误'));
    }).catch(function (error) {
      addEvent('warn', '全屏切换失败：' + (error && error.message || error));
    });
  }

  async function refreshWindowState() {
    if (!state.backend || typeof state.backend.getWindowState !== 'function') return;
    try {
      var res = await state.backend.getWindowState();
      if (res && res.ok) applyWindowState(res);
    } catch (error) { /* 非致命 */ }
  }

  /* --------------------------- 后端状态 ---------------------------------- */
  function updateConnectionUI() {
    if (!els) return;
    var connected = !!(state.status && state.status.connected);
    els.connStatus.textContent = connected ? ('已连接 ' + (state.status.port || '')) : '未连接';
    els.connStatus.dataset.state = connected ? 'ok' : 'idle';
    els.btnConnect.textContent = connected ? '断开' : '连接';
    els.btnRefreshPorts.disabled = connected;
    els.portSelect.disabled = connected;
    var buttons = [els.btnMode1, els.btnMode2, els.btnMode3, els.btnStop, els.btnSendAll];
    for (var i = 0; i < buttons.length; i++) buttons[i].disabled = !connected;
  }

  function applyStatus(next) {
    if (!next || typeof next !== 'object') return;
    var wasOn = !!(state.status && state.status.connected);
    state.status = {
      connected: !!next.connected,
      port: next.port || '',
      error: next.error || null
    };
    var on = !!state.status.connected;
    if (!wasOn && on) {
      // 连接建立：清空显示缓冲与“已下发”标记，与原 GUI 一致
      clearData(true);
      state.sentValues = {};
      state.sentSnapshot = freezeSent();
      refreshAllDots();
    } else if (wasOn && !on) {
      state.request = null;
      state.latest = null;
      state.sentValues = {};
      state.sentSnapshot = freezeSent();
      if (els) {
        els.modeText.textContent = 'MODE --';
        els.balanceText.textContent = '等待遥测';
        els.positionErrorText.textContent = '位置误差 --';
        els.absText.textContent = 'ABS --';
        els.srcHldText.textContent = 'SRC -- · HLD --';
        els.sampleText.textContent = '已收 0 帧';
      }
      refreshAllDots();
    }
    if (state.status.error) addEvent('warn', String(state.status.error));
    updateConnectionUI();
  }

  /* --------------------------- 遥测处理 ---------------------------------- */
  function shortestDelta(value, origin) {
    var delta = Number(value) - Number(origin);
    var wrapped = mod(delta + ENC_CPR / 2, ENC_CPR) - ENC_CPR / 2;
    if (wrapped === -ENC_CPR / 2 && delta > 0) return ENC_CPR / 2;
    return wrapped;
  }

  function normalizeTelemetry(raw) {
    if (!raw || typeof raw !== 'object') return null;
    var t = numOrNull(raw.t);
    if (t === null) t = state.times.length ? state.times[state.times.length - 1] + 1 / TELEM_HZ : 0;
    var sw = null;
    if (raw.sw === true || raw.sw === 1) sw = true;
    else if (raw.sw === false || raw.sw === 0) sw = false;
    var src = null;
    if (raw.src === true || raw.src === 1) src = true;
    else if (raw.src === false || raw.src === 0) src = false;
    var hld = null;
    if (raw.hld === true || raw.hld === 1) hld = true;
    else if (raw.hld === false || raw.hld === 0) hld = false;
    var mode = intOrNull(raw.mode) === null ? 0 : intOrNull(raw.mode);
    var sentPost = Object.prototype.hasOwnProperty.call(state.sentValues, 'POSTGT')
      ? state.sentValues.POSTGT : null;
    var sentTurns = Object.prototype.hasOwnProperty.call(state.sentValues, 'TURNS_POSTGT')
      ? state.sentValues.TURNS_POSTGT : null;
    // MODE3 的 POSTGT 无效，曲线目标改用 TURNS_POSTGT 折算到单圈
    var chartTgt = mode === 3 ? singleTurnTarget(sentTurns) : sentPost;
    var row = {
      t: t,
      ang: numOrNull(raw.ang),
      raw: intOrNull(raw.raw),
      pos: intOrNull(raw.pos),
      abs: intOrNull(raw.abs),
      spd: intOrNull(raw.spd),
      dut: intOrNull(raw.dut),
      ref: numOrNull(raw.ref),
      mode: mode,
      st: intOrNull(raw.st) === null ? 0 : intOrNull(raw.st),
      sw: sw,
      src: src,
      hld: hld,
      ver: raw.ver != null ? String(raw.ver) : '',
      cc: intOrNull(raw.cc),
      tgt: chartTgt,
      tgtAbs: mode === 3 ? sentTurns : null,
      sentSnap: state.sentSnapshot
    };
    return row;
  }

  /** 把绝对计数目标折算到单圈 [-520,519]，仅用于单圈 POS/TGT 曲线。 */
  function singleTurnTarget(value) {
    if (value === null || value === undefined || !isFinite(Number(value))) return null;
    var counts = Number(value);
    return ((counts + ENC_CPR / 2) % ENC_CPR + ENC_CPR) % ENC_CPR - ENC_CPR / 2;
  }

  function storeRow(row) {
    var times = state.times;
    if (times.length && row.t <= times[times.length - 1]) {
      row.t = times[times.length - 1] + 1 / TELEM_HZ;
    }
    var pos = row.pos;
    if (row.abs !== null) {
      // Vy 遥测提供 32 位累计计数时直接使用，避免单圈展开误差
      state.positionUnwrapped = row.abs;
      state.positionPrevious = pos;
      row.pos_total = row.abs;
    } else if (pos === null) {
      row.pos_total = null;
    } else if (state.positionPrevious === null) {
      state.positionUnwrapped = pos;
      state.positionPrevious = pos;
      row.pos_total = pos;
    } else {
      state.positionUnwrapped += shortestDelta(pos, state.positionPrevious);
      state.positionPrevious = pos;
      row.pos_total = state.positionUnwrapped;
    }
    if (row.mode === 3) {
      row.pos_error = (row.abs !== null && row.tgtAbs !== null)
        ? (row.abs - row.tgtAbs) : null;
    } else {
      row.pos_error = (row.tgt !== null && pos !== null)
        ? shortestDelta(pos, row.tgt) : null;
    }
    times.push(row.t);
    state.rows.push(row);
    if (state.rows.length > BUFFER_MAX) {
      var drop = BUFFER_TRIM;
      times.splice(0, drop);
      state.rows.splice(0, drop);
    }
    if (state.recording) {
      if (state.recorded.length >= RECORD_MAX) {
        if (!state.recordWarned) {
          state.recordWarned = true;
          addEvent('warn', '记录缓冲已达上限，自动停止记录');
        }
        stopRecordingWithoutSave();
      } else {
        state.recorded.push(row);
      }
    }
  }

  function ingestTelemetry(rows) {
    if (!Array.isArray(rows) || !rows.length) return;
    var last = null;
    for (var i = 0; i < rows.length; i++) {
      var row = normalizeTelemetry(rows[i]);
      if (!row) continue;
      storeRow(row);
      last = row;
    }
    if (last) {
      state.latest = last;
      updateReadout(last);
    }
    updateSampleText();
  }

  /* --------------------------- 读数/状态 -------------------------------- */
  function statusText(status, mode, swingActive) {
    if (status & 8) return '输出保护暂停；模式保持，可恢复或重发当前模式';
    if (status & 4) return '角度环已接管';
    if (status & 2) return '超角度保护；回到接管角度窗口后恢复';
    if (mode === 3) {
      if (status & 1) return 'MODE 3 绝对位置：角度已到接管窗口，等待接管';
      return 'MODE 3 绝对位置：等待摆杆直立窗口后接管';
    }
    if (mode === 2 && swingActive) return '自动起摆驱动中（SW=1）';
    if ((mode === 1 || mode === 2) && (status & 1)) return '角度在接管范围，等待接管';
    if (mode === 1) return '手动稳定模式，等待角度接管';
    if (mode === 2) return '起摆等待捕获；若已在零位附近会直接稳定';
    if (mode === 0) return '停机';
    return '未知模式 ' + mode + '：请先停机';
  }

  function updateReadout(row) {
    if (!row || !els) return;
    els.metricAng.textContent = row.ang === null ? '--' : signed(row.ang, 2);
    els.metricRef.textContent = row.ref === null ? '--' : signed(row.ref, 2);
    els.metricRaw.textContent = row.raw === null ? '--' : pad4(row.raw);
    els.metricPos.textContent = row.pos === null ? '--' : signed(row.pos, 0);
    els.metricSpd.textContent = row.spd === null ? '--' : signed(row.spd, 0);
    els.metricDut.textContent = row.dut === null ? '--' : signed(row.dut, 0);

    els.modeText.textContent = row.mode === 3 ? 'MODE 3 · 绝对定位' : 'MODE ' + row.mode;
    var version = row.ver || '';
    if (version && version !== state.lastVersion) {
      state.lastVersion = version;
      var shownVersion = /^[Vv]/.test(version) ? version : ('V' + version);
      addEvent('info', '固件 ' + shownVersion + ' · 1040 count/圈 · 103B 扩展遥测');
    }
    var error = row.pos_error;
    els.positionErrorText.textContent = error === null
      ? '位置误差 --（目标未发送）'
      : ('位置误差 ' + signed(error, 1) + ' count');
    els.absText.textContent = row.abs === null || row.abs === undefined
      ? 'ABS --' : ('ABS ' + signed(row.abs, 0));
    var srcText = row.src === null || row.src === undefined
      ? 'SRC --' : (row.src ? 'SRC 本地' : 'SRC 上位');
    var hldText = row.hld === null || row.hld === undefined
      ? 'HLD --' : (row.hld ? 'HLD 保持' : 'HLD 关');
    els.srcHldText.textContent = srcText + ' · ' + hldText;
    els.balanceText.textContent = statusText(row.st, row.mode, row.sw);
    if (row.hld === true && row.mode !== 0 && (row.st & 4) && !(row.st & 10)) {
      els.balanceText.textContent = '容差保持中 · 角度闭环持续纠偏';
    }

    // MODE 请求确认 / 超时
    if (state.request) {
      if (row.mode === state.request.mode) {
        addEvent('ok', '板端已确认 MODE ' + row.mode);
        state.request = null;
      } else if (Date.now() - state.request.at > 1000) {
        addEvent('warn', 'MODE ' + state.request.mode + ' 未获遥测确认；当前报告 MODE ' + row.mode);
        state.request = null;
      }
    }
    updateSampleText();
  }

  function updateSampleText() {
    if (!els || !els.sampleText) return;
    els.sampleText.textContent = '已收 ' + state.rows.length + ' 帧';
    if (els.recordStatus) {
      els.recordStatus.textContent = state.recording
        ? ('记录中 ' + state.recorded.length + ' 帧') : '未记录';
    }
  }

  /* --------------------------- 参数交互 ---------------------------------- */
  function handleParamInput(name) {
    refreshParamDot(name);
    saveStateSoon();
  }

  function handleNudge(name, dir) {
    var row = paramRow(name);
    if (!row) return;
    var current = parseIntEntry(row.getText());
    var baseValue = current.ok ? current.value : J280Params.PARAMS[name].default;
    var next = J280Params.nudge(name, baseValue, dir);
    row.setValue(String(next));
    handleParamInput(name);
  }

  /* --------------------------- 绝对定位目标（x 圈 + y 相位） ------------------ */
  var absEditor = {
    open: false, turns: 0, phase: 0, count: 0,
    draggingPhase: false, draggingTurns: false
  };

  function absInt(value, fallback) {
    var n = Number(value);
    return isFinite(n) ? Math.round(n) : (fallback || 0);
  }

  function absSigned(value) {
    var n = absInt(value, 0);
    return (n > 0 ? '+' : '') + n;
  }

  function absClampTurns(value) {
    return Math.max(-32, Math.min(32, absInt(value, 0)));
  }

  function absSetTurns(value) {
    var turns = absClampTurns(value);
    var bounds = J280Params.absPhaseBounds(turns);
    var phase = Math.max(bounds[0], Math.min(bounds[1], absEditor.phase));
    absEditor.turns = turns;
    absEditor.phase = phase;
    absRenderEditor();
  }

  function absSetPhase(value) {
    var bounds = J280Params.absPhaseBounds(absEditor.turns);
    absEditor.phase = Math.max(bounds[0], Math.min(bounds[1], absInt(value, 0)));
    absRenderEditor();
  }

  function absSetCount(value) {
    var split = J280Params.absDecompose(value);
    absEditor.turns = split.turns;
    absEditor.phase = split.phase;
    absEditor.count = split.count;
    absRenderEditor();
  }

  function absCanvas2D(canvas, fallbackW, fallbackH) {
    if (!canvas) return null;
    var rect = canvas.getBoundingClientRect();
    var width = Math.max(80, Math.round(rect.width || fallbackW));
    var height = Math.max(40, Math.round(rect.height || fallbackH));
    var dpr = Math.min(2, window.devicePixelRatio || 1);
    if (canvas.width !== Math.round(width * dpr) || canvas.height !== Math.round(height * dpr)) {
      canvas.width = Math.round(width * dpr);
      canvas.height = Math.round(height * dpr);
    }
    var ctx = canvas.getContext('2d');
    if (!ctx) return null;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, width, height);
    return {ctx: ctx, width: width, height: height};
  }

  function drawAbsTurns() {
    var setup = absCanvas2D(els.absTurnsCanvas, 420, 88);
    if (!setup) return;
    var ctx = setup.ctx;
    var width = setup.width;
    var height = setup.height;
    var pad = 18;
    var span = width - pad * 2;
    var cy = height * 0.56;
    var turns = absEditor.turns;

    function xPos(value) { return pad + (value + 32) / 64 * span; }

    // 装饰性“线圈”底纹
    ctx.beginPath();
    ctx.strokeStyle = 'rgba(63, 227, 255, 0.16)';
    ctx.lineWidth = 1.2;
    for (var px = pad; px <= width - pad; px += 2) {
      var wy = cy - 15 + Math.sin((px - pad) / 17) * 8;
      if (px === pad) ctx.moveTo(px, wy); else ctx.lineTo(px, wy);
    }
    ctx.stroke();

    // 轴线与刻度
    ctx.beginPath();
    ctx.strokeStyle = 'rgba(63, 227, 255, 0.22)';
    ctx.lineWidth = 1;
    ctx.moveTo(pad, cy + 16);
    ctx.lineTo(width - pad, cy + 16);
    ctx.stroke();
    for (var t = -32; t <= 32; t++) {
      var x = xPos(t);
      var major = (t % 8 === 0);
      ctx.beginPath();
      ctx.strokeStyle = major ? 'rgba(63, 227, 255, 0.55)' : 'rgba(63, 227, 255, 0.18)';
      ctx.lineWidth = major ? 1.4 : 1;
      ctx.moveTo(x, cy + 16);
      ctx.lineTo(x, cy + (major ? 27 : 22));
      ctx.stroke();
    }

    // 当前圈数游标
    var xNow = xPos(turns);
    ctx.save();
    ctx.shadowColor = 'rgba(63, 227, 255, 0.8)';
    ctx.shadowBlur = 10;
    ctx.beginPath();
    ctx.strokeStyle = '#3fe3ff';
    ctx.lineWidth = 2;
    ctx.moveTo(xNow, 12);
    ctx.lineTo(xNow, cy + 16);
    ctx.stroke();
    ctx.beginPath();
    ctx.fillStyle = '#3fe3ff';
    ctx.arc(xNow, cy - 2, 5, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
    ctx.fillStyle = '#eaf9ff';
    ctx.font = '600 13px Consolas, "Cascadia Mono", monospace';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'bottom';
    ctx.fillText((turns > 0 ? '+' : '') + turns + ' 圈', Math.max(30, Math.min(width - 30, xNow)), cy - 12);
    ctx.textAlign = 'left';
  }

  function drawAbsPhase() {
    var setup = absCanvas2D(els.absPhaseCanvas, 220, 220);
    if (!setup) return;
    var ctx = setup.ctx;
    var size = Math.min(setup.width, setup.height);
    var cx = setup.width / 2;
    var cy = setup.height / 2;
    var radius = size / 2 - 28;
    var phase = absEditor.phase;
    var valueAngle = phase / 1040 * Math.PI * 2;
    var start = -Math.PI / 2;

    ctx.lineWidth = 10;
    ctx.strokeStyle = 'rgba(63, 227, 255, 0.14)';
    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    ctx.stroke();

    // 当前圈数允许的相位范围（在 ±32 圈边界会被截断）
    var bounds = J280Params.absPhaseBounds(absEditor.turns);
    if (bounds[0] > -520 || bounds[1] < 519) {
      var a0 = bounds[0] / 1040 * Math.PI * 2;
      var a1 = bounds[1] / 1040 * Math.PI * 2;
      ctx.beginPath();
      ctx.lineWidth = 14;
      ctx.strokeStyle = 'rgba(255, 194, 71, 0.16)';
      ctx.arc(cx, cy, radius, start + a0, start + a1, false);
      ctx.stroke();
    }

    for (var i = 0; i < 52; i++) {
      var angle = i / 52 * Math.PI * 2;
      var major = (i % 13 === 0);
      ctx.beginPath();
      ctx.strokeStyle = major ? 'rgba(63, 227, 255, 0.52)' : 'rgba(63, 227, 255, 0.18)';
      ctx.lineWidth = major ? 1.5 : 1;
      ctx.moveTo(cx + Math.sin(angle) * (radius + 8), cy - Math.cos(angle) * (radius + 8));
      ctx.lineTo(cx + Math.sin(angle) * (radius + (major ? 14 : 11)),
                 cy - Math.cos(angle) * (radius + (major ? 14 : 11)));
      ctx.stroke();
    }

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
    ctx.arc(px, py, 4.5, 0, Math.PI * 2);
    ctx.fill();

    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = '#eaf9ff';
    ctx.font = '600 22px Consolas, "Cascadia Mono", monospace';
    ctx.fillText(absSigned(phase), cx, cy - 4);
    ctx.fillStyle = '#6f93a9';
    ctx.font = '9px Consolas, "Cascadia Mono", monospace';
    ctx.fillText('相位 count', cx, cy + 16);
    ctx.fillStyle = '#7fa3b8';
    ctx.fillText('0', cx, cy - radius - 15);
    ctx.fillText('+260', cx + radius + 15, cy);
    ctx.fillText('-260', cx - radius - 15, cy);
    ctx.textAlign = 'left';
  }

  function absRenderEditor() {
    if (!absEditor.open || !els) return;
    absEditor.count = J280Params.absCompose(absEditor.turns, absEditor.phase);
    var split = J280Params.absDecompose(absEditor.count);
    absEditor.turns = split.turns;
    absEditor.phase = split.phase;
    absEditor.count = split.count;
    var active = document.activeElement;
    if (active !== els.absTurnsInput) els.absTurnsInput.value = String(split.turns);
    if (active !== els.absPhaseInput) els.absPhaseInput.value = absSigned(split.phase);
    var bounds = J280Params.absPhaseBounds(split.turns);
    els.absPhaseLimit.hidden = !(bounds[0] > -520 || bounds[1] < 519);
    drawAbsTurns();
    drawAbsPhase();
  }

  function absCardStartPoint() {
    var stage = els.stage.getBoundingClientRect();
    var width = 430;
    var x = Math.round(stage.width * 0.44 - width / 2);
    x = Math.max(280, Math.min(stage.width - width - 16, x));
    return {x: Math.max(12, x), y: 150};
  }

  function createAbsCard() {
    if (state.absCard) return state.absCard;
    if (!window.J280Cards || !els.absCardTemplate) return null;
    var body = document.createElement('div');
    body.className = 'abs-card-body';
    while (els.absCardTemplate.firstChild) {
      body.appendChild(els.absCardTemplate.firstChild);
    }
    var start = absCardStartPoint();
    var card = J280Cards.createCard({
      id: 'abs-target-card',
      title: '指定运动轨迹',
      width: 430,
      bodyEl: body,
      footerText: '',
      maxBodyHeight: 540,
      defaultPos: start,
      collapsed: false,
      onChange: function (layout) {
        state.absCardSaved = layout;
        saveStateNow();
      }
    });
    if (!card) return null;
    state.absCard = card;
    els.cardLayer.appendChild(card.el);
    if (state.absCardSaved) {
      try {
        if (state.absCardSaved.x != null && state.absCardSaved.y != null) {
          card.setPos(state.absCardSaved.x, state.absCardSaved.y);
        }
        if (typeof state.absCardSaved.collapsed === 'boolean') {
          card.setCollapsed(state.absCardSaved.collapsed);
        }
      } catch (e) { /* 旧布局无效时使用默认位置 */ }
    }
    card.el.hidden = true;
    return card;
  }

  function setAbsCardVisible(visible) {
    if (visible) {
      var card = createAbsCard();
      if (!card) return;
      var row = paramRow('TURNS_POSTGT');
      var parsed = row ? parseIntEntry(row.getText()) : {ok: false};
      absEditor.open = true;
      card.el.hidden = false;
      if (window.J280Cards && J280Cards.clampToStage) {
        try { J280Cards.clampToStage(card.el); } catch (e) { /* ignore */ }
      }
      absSetCount(parsed.ok ? parsed.value : 0);
      hideTooltip();
      window.requestAnimationFrame(function () {
        if (absEditor.open) absRenderEditor();
      });
    } else {
      absEditor.open = false;
      if (state.absCard) state.absCard.el.hidden = true;
    }
    if (els && els.bookmarkRail) {
      var special = els.bookmarkRail.querySelector('.bookmark-special');
      if (special) {
        special.classList.toggle('active', !!visible);
        special.setAttribute('aria-pressed', visible ? 'true' : 'false');
      }
    }
  }

  function toggleAbsTargetCard() {
    setAbsCardVisible(!absEditor.open);
  }

  function applyAbsTarget(send) {
    if (!absEditor.open) return;
    var count = J280Params.absCompose(absEditor.turns, absEditor.phase);
    var split = J280Params.absDecompose(count);
    var row = paramRow('TURNS_POSTGT');
    if (!row) return;
    row.setValue(String(count));
    handleParamInput('TURNS_POSTGT');
    addEvent('info', '绝对定位目标：' + split.turns + ' 圈 + ' + absSigned(split.phase) +
      ' 相位 = ' + count + ' count');
    if (send) sendParameter('TURNS_POSTGT');
  }

  function bindAbsEditorEvents() {
    if (!els || !els.absCardTemplate) return;
    els.absHideCard.addEventListener('click', function () { setAbsCardVisible(false); });
    els.absApply.addEventListener('click', function () { applyAbsTarget(false); });
    els.absApplySend.addEventListener('click', function () { applyAbsTarget(true); });

    els.absTurnsMinus.addEventListener('click', function () { absSetTurns(absEditor.turns - 1); });
    els.absTurnsPlus.addEventListener('click', function () { absSetTurns(absEditor.turns + 1); });
    els.absTurnsInput.addEventListener('input', function () {
      var parsed = parseIntEntry(els.absTurnsInput.value);
      if (parsed.ok) absSetTurns(parsed.value);
    });
    els.absTurnsInput.addEventListener('change', function () {
      var parsed = parseIntEntry(els.absTurnsInput.value);
      absSetTurns(parsed.ok ? parsed.value : absEditor.turns);
    });
    els.absTurnsInput.addEventListener('blur', function () {
      els.absTurnsInput.value = String(absEditor.turns);
    });
    els.absTurnsInput.addEventListener('keydown', function (event) {
      if (event.key === 'Enter') { event.preventDefault(); applyAbsTarget(false); }
    });

    els.absPhaseInput.addEventListener('input', function () {
      var parsed = parseIntEntry(els.absPhaseInput.value);
      if (parsed.ok) absSetPhase(parsed.value);
    });
    els.absPhaseInput.addEventListener('change', function () {
      var parsed = parseIntEntry(els.absPhaseInput.value);
      absSetPhase(parsed.ok ? parsed.value : absEditor.phase);
    });
    els.absPhaseInput.addEventListener('blur', function () {
      els.absPhaseInput.value = absSigned(absEditor.phase);
    });
    els.absPhaseInput.addEventListener('keydown', function (event) {
      if (event.key === 'Enter') { event.preventDefault(); applyAbsTarget(false); }
    });

    function turnFromEvent(event) {
      var rect = els.absTurnsCanvas.getBoundingClientRect();
      var ratio = (event.clientX - rect.left - 18) / Math.max(1, rect.width - 36);
      return Math.max(-32, Math.min(32, Math.round(ratio * 64 - 32)));
    }
    els.absTurnsCanvas.addEventListener('pointerdown', function (event) {
      absEditor.draggingTurns = true;
      try { els.absTurnsCanvas.setPointerCapture(event.pointerId); } catch (err) { /* ignore */ }
      absSetTurns(turnFromEvent(event));
      els.absTurnsCanvas.focus();
      event.preventDefault();
    });
    els.absTurnsCanvas.addEventListener('pointermove', function (event) {
      if (absEditor.draggingTurns) absSetTurns(turnFromEvent(event));
    });
    function endTurnDrag(event) {
      if (!absEditor.draggingTurns) return;
      absEditor.draggingTurns = false;
      try { els.absTurnsCanvas.releasePointerCapture(event.pointerId); } catch (err) { /* ignore */ }
    }
    els.absTurnsCanvas.addEventListener('pointerup', endTurnDrag);
    els.absTurnsCanvas.addEventListener('pointercancel', endTurnDrag);
    els.absTurnsCanvas.addEventListener('wheel', function (event) {
      event.preventDefault();
      absSetTurns(absEditor.turns + (event.deltaY < 0 ? 1 : -1));
    }, {passive: false});
    els.absTurnsCanvas.addEventListener('keydown', function (event) {
      if (event.key === 'ArrowLeft' || event.key === 'ArrowDown') {
        event.preventDefault(); absSetTurns(absEditor.turns - 1);
      } else if (event.key === 'ArrowRight' || event.key === 'ArrowUp') {
        event.preventDefault(); absSetTurns(absEditor.turns + 1);
      } else if (event.key === 'Home') {
        event.preventDefault(); absSetTurns(0);
      }
    });

    function phaseFromEvent(event) {
      var rect = els.absPhaseCanvas.getBoundingClientRect();
      var dx = event.clientX - (rect.left + rect.width / 2);
      var dy = event.clientY - (rect.top + rect.height / 2);
      var angle = Math.atan2(dx, -dy);
      var value = Math.round(angle / (Math.PI * 2) * 1040);
      return ((value + 520) % 1040 + 1040) % 1040 - 520;
    }
    els.absPhaseCanvas.addEventListener('pointerdown', function (event) {
      absEditor.draggingPhase = true;
      try { els.absPhaseCanvas.setPointerCapture(event.pointerId); } catch (err) { /* ignore */ }
      absSetPhase(phaseFromEvent(event));
      els.absPhaseCanvas.focus();
      event.preventDefault();
    });
    els.absPhaseCanvas.addEventListener('pointermove', function (event) {
      if (absEditor.draggingPhase) absSetPhase(phaseFromEvent(event));
    });
    function endPhaseDrag(event) {
      if (!absEditor.draggingPhase) return;
      absEditor.draggingPhase = false;
      try { els.absPhaseCanvas.releasePointerCapture(event.pointerId); } catch (err) { /* ignore */ }
    }
    els.absPhaseCanvas.addEventListener('pointerup', endPhaseDrag);
    els.absPhaseCanvas.addEventListener('pointercancel', endPhaseDrag);
    els.absPhaseCanvas.addEventListener('wheel', function (event) {
      event.preventDefault();
      absSetPhase(absEditor.phase + (event.deltaY < 0 ? 10 : -10));
    }, {passive: false});
    els.absPhaseCanvas.addEventListener('keydown', function (event) {
      if (event.key === 'ArrowLeft' || event.key === 'ArrowDown') {
        event.preventDefault(); absSetPhase(absEditor.phase - 10);
      } else if (event.key === 'ArrowRight' || event.key === 'ArrowUp') {
        event.preventDefault(); absSetPhase(absEditor.phase + 10);
      } else if (event.key === 'Home') {
        event.preventDefault(); absSetPhase(0);
      }
    });

    window.addEventListener('resize', function () {
      if (absEditor.open) absRenderEditor();
    });
  }

  function showParamTip(name) {
    // 已按需求移除参数悬停说明框；保留函数占位，避免调用点报错。
    void name;
  }

  async function sendParameter(name) {
    if (!state.status.connected) { addEvent('warn', '参数未发送：串口未连接（' + name + '）'); return false; }
    if (state.latest && state.latest.src === true) {
      addEvent('warn', '参数未发送：当前为本地调参模式，请用板上 SW1 切回上位机');
      return false;
    }
    if (state.latest && window.J280Params && !J280Params.supportsParameter(name, state.latest.ver)) {
      addEvent('warn', '参数未发送：' + name + ' 需要更新固件');
      return false;
    }
    var row = paramRow(name);
    if (!row) return false;
    var parsed = parseIntEntry(row.getText());
    if (!parsed.ok) {
      addEvent('warn', '参数未发送：' + name + '，' + parsed.error);
      refreshParamDot(name);
      return false;
    }
    if (window.J280Params && J280Params.validate) {
      var checked = J280Params.validate(name, parsed.value);
      if (!checked.ok) {
        addEvent('warn', '参数未发送：' + name + '，' + checked.error);
        refreshParamDot(name);
        return false;
      }
      parsed.value = checked.value;
    }
    var res;
    try { res = await state.backend.sendParam(name, parsed.value); }
    catch (e) { res = { ok: false, error: String(e && e.message || e) }; }
    if (!res || !res.ok) {
      addEvent('warn', '参数未发送：' + name + '，' + ((res && res.error) || '未知错误'));
      return false;
    }
    state.sentValues[name] = parsed.value;
    state.sentSnapshot = freezeSent();
    refreshParamDot(name);
    addEvent('info', '参数已发送：' + name + '=' + parsed.value);
    saveStateSoon();
    return true;
  }

  async function sendAllParameters() {
    var collected = collectParamValues();
    if (collected.invalid.length) {
      var detail = collected.invalid.slice(0, 5).join('；');
      if (collected.invalid.length > 5) detail += ' …';
      addEvent('warn', '全部参数未发送：' + detail);
      return false;
    }
    if (!state.status.connected) { addEvent('warn', '全部参数未发送：串口未连接'); return false; }
    if (state.latest && state.latest.src === true) {
      addEvent('warn', '全部参数未发送：当前为本地调参模式，请用板上 SW1 切回上位机');
      return false;
    }
    if (state.latest && window.J280Params) {
      var unsupported = Object.keys(collected.values).filter(function (name) {
        return !J280Params.supportsParameter(name, state.latest.ver);
      });
      if (unsupported.length) {
        addEvent('warn', '全部参数未发送：以下参数需要更新固件：' + unsupported.join('、'));
        return false;
      }
    }
    var res;
    try { res = await state.backend.sendAll(collected.values); }
    catch (e) { res = { ok: false, error: String(e && e.message || e) }; }
    if (!res || !res.ok) {
      addEvent('warn', '全部参数未发送：' + ((res && res.error) || '未知错误'));
      return false;
    }
    state.sentValues = Object.assign({}, collected.values);
    state.sentSnapshot = freezeSent();
    refreshAllDots();
    var count = (res && res.count) || Object.keys(collected.values).length;
    addEvent('info', '已发送全部 ' + count + ' 项参数；板端帧计数可确认接收活动，不能读回具体值');
    saveStateSoon();
    return true;
  }

  async function requestMode(mode) {
    if (mode === 0) { requestStop(); return; }
    if (!state.status.connected) { addEvent('warn', 'MODE ' + mode + ' 未发送：串口未连接'); return; }
    var ok = await sendAllParameters();
    if (!ok) return;
    var res;
    try { res = await state.backend.setMode(mode); }
    catch (e) { res = { ok: false, error: String(e && e.message || e) }; }
    if (!res || !res.ok) {
      addEvent('warn', 'MODE ' + mode + ' 发送失败：' + ((res && res.error) || '未知错误'));
      return;
    }
    state.request = { mode: mode, at: Date.now() };
    addEvent('info', '已发送 MODE ' + mode + '；等待 FPGA 遥测确认');
  }

  function requestStop() {
    if (!state.status.connected) { addEvent('warn', 'MODE 0 未发送：串口未连接'); return; }
    var pending = state.backend.setMode(0);
    Promise.resolve(pending).then(function (res) {
      if (res && res.ok) {
        state.request = { mode: 0, at: Date.now() };
        addEvent('info', '已发送 MODE 0');
      } else {
        addEvent('warn', 'MODE 0 发送失败：' + ((res && res.error) || '未知错误') + '；请使用实体急停');
      }
    }).catch(function (e) {
      addEvent('warn', 'MODE 0 发送失败：' + (e && e.message || e) + '；请使用实体急停');
    });
  }

  /* --------------------------- 默认参数 / JSON --------------------------- */
  /** 启动时从 data/config0.json 载入唯一默认参数（Python 后端读取，Qt 专用）。 */
  async function loadDefaultParams() {
    setBootText('正在载入唯一默认配置 data/config0.json…');
    var res;
    try { res = await state.backend.loadDefaults(); }
    catch (e) { res = { ok: false, error: String(e && e.message || e) }; }
    if (res && res.ok && res.text) {
      var data;
      try { data = JSON.parse(res.text); }
      catch (e) {
        addEvent('warn', '默认参数 JSON 解析失败：' + e.message);
        return;
      }
      var values = (data && data.params && typeof data.params === 'object') ? data.params : data;
      var result = applyConfigValues(values);
      var applied = Object.keys(result.applied).length;
      if (applied) addEvent('info', '已载入唯一默认配置 data/config0.json（' + applied + ' 项）');
      if (result.skipped.length) {
        addEvent('warn', '默认参数部分跳过：' + result.skipped.slice(0, 6).join('；'));
      }
    } else {
      addEvent('warn', '默认参数载入失败：' + ((res && res.error) || '未知错误') +
        '；使用固件内置默认值');
    }
  }

  async function saveConfigFile() {
    var collected = collectParamValues();
    if (collected.invalid.length) {
      addEvent('warn', '保存配置失败：参数输入无效或越界（' + collected.invalid.slice(0, 6).join('；') + '）');
      return;
    }
    var config = { format: 'j280_gui_config', created: nowStamp(), params: collected.values };
    var res;
    try { res = await state.backend.saveConfig(config, 'j280_config_' + fileStamp() + '.json'); }
    catch (e) { res = { ok: false, error: String(e && e.message || e) }; }
    if (res && res.ok) {
      addEvent('ok', '已保存参数配置：' + (res.path || ''));
      showToast('参数配置已保存', 'ok');
    } else {
      addEvent('warn', '保存配置失败：' + ((res && res.error) || '未知错误'));
    }
  }

  async function loadConfigFile() {
    var res;
    try { res = await state.backend.loadConfig(); }
    catch (e) { res = { ok: false, error: String(e && e.message || e) }; }
    if (!res || !res.ok) {
      if (res && res.canceled) return;
      addEvent('warn', '载入配置失败：' + ((res && res.error) || '未知错误'));
      return;
    }
    var data;
    try { data = JSON.parse(res.text); }
    catch (e) { addEvent('warn', '载入配置失败：JSON 解析错误：' + e.message); return; }
    if (!data || typeof data !== 'object' || Array.isArray(data)) {
      addEvent('warn', '载入配置失败：顶层必须是 JSON 对象');
      return;
    }
    var values = (data.params && typeof data.params === 'object' && !Array.isArray(data.params))
      ? data.params : data;
    var result = applyConfigValues(values);
    if (!Object.keys(result.applied).length) {
      var detail = result.skipped.length ? ('；' + result.skipped.slice(0, 6).join('；')) : '';
      addEvent('warn', '载入配置失败：没有可应用的参数' + detail);
      return;
    }
    var message = '已载入配置：' + (res.path ? res.path.split(/[\\/]/).pop() : '') +
      '（应用 ' + Object.keys(result.applied).length + ' 项，尚未发送到 FPGA）';
    if (result.skipped.length) {
      message += '；跳过 ' + result.skipped.length + ' 项：' + result.skipped.slice(0, 6).join('；');
    }
    addEvent('ok', message);
    showToast('已载入 JSON 参数配置', 'ok');
  }

  /* --------------------------- 记录 / CSV ------------------------------- */
  function buildCsv(records) {
    var order = (J280Params.ORDER || Object.keys(J280Params.PARAMS));
    var fields = CSV_EXTRA_FIELDS.slice();
    for (var i = 0; i < order.length; i++) fields.push('sent_' + order[i]);
    var start = records[0].t;
    var lines = [fields.join(',')];
    for (var r = 0; r < records.length; r++) {
      var row = records[r];
      var out = {
        time_s: (row.t - start).toFixed(6),
        ang: row.ang === null ? '' : row.ang.toFixed(2),
        ref: row.ref === null ? '' : row.ref.toFixed(2),
        ref_cdeg: row.ref === null ? '' : Math.round(row.ref * 100),
        raw: row.raw === null ? '' : row.raw,
        pos: row.pos === null ? '' : row.pos,
        pos_absolute: row.abs === null || row.abs === undefined ? '' : row.abs,
        src_local: row.src === null || row.src === undefined ? '' : (row.src ? 1 : 0),
        spd: row.spd === null ? '' : row.spd,
        dut: row.dut === null ? '' : row.dut,
        mode: row.mode,
        bal_status: row.st,
        swing_active: row.sw === null ? '' : (row.sw ? 1 : 0),
        position_hold: row.hld === null || row.hld === undefined ? '' : (row.hld ? 1 : 0),
        version: row.ver || '',
        config_count: row.cc === null ? '' : row.cc,
        tgt: row.tgt === null ? '' : row.tgt,
        tgt_abs: row.tgtAbs === null || row.tgtAbs === undefined ? '' : row.tgtAbs,
        pos_total: row.pos_total === null ? '' : row.pos_total.toFixed(2),
        pos_error: row.pos_error === null ? '' : row.pos_error.toFixed(3)
      };
      var snap = row.sentSnap || {};
      for (var k = 0; k < order.length; k++) {
        var name = order[k];
        out['sent_' + name] = Object.prototype.hasOwnProperty.call(snap, name) ? snap[name] : '';
      }
      var cells = [];
      for (var f = 0; f < fields.length; f++) cells.push(csvCell(out[fields[f]]));
      lines.push(cells.join(','));
    }
    return lines.join('\r\n') + '\r\n';
  }

  function updateRecordUi() {
    if (!els) return;
    els.btnRecordStart.disabled = state.recording;
    els.btnRecordSave.disabled = !state.recording;
    updateSampleText();
  }

  function startRecording() {
    if (state.recording) { addEvent('info', '已在记录中'); return; }
    state.recorded = [];
    state.recordWarned = false;
    state.recording = true;
    updateRecordUi();
    addEvent('info', '开始记录：记录缓冲已清空；实时曲线不受影响');
  }

  function stopRecordingWithoutSave() {
    state.recording = false;
    updateRecordUi();
  }

  async function stopRecordingAndSave() {
    if (!state.recording) { addEvent('info', '停止记录：当前没有进行中的记录'); return; }
    state.recording = false;
    updateRecordUi();
    var records = state.recorded;
    if (!records.length) { addEvent('warn', '无记录：本次未收到遥测帧'); return; }
    var csv = buildCsv(records);
    var res;
    try { res = await state.backend.saveCsv(csv, 'j280_' + fileStamp() + '.csv'); }
    catch (e) { res = { ok: false, error: String(e && e.message || e) }; }
    if (!res || !res.ok) {
      if (res && res.canceled) { addEvent('info', '已停止记录（未保存）'); return; }
      addEvent('warn', '记录保存失败：' + ((res && res.error) || '未知错误'));
      return;
    }
    addEvent('ok', '已保存 ' + records.length + ' 帧记录：' + (res.path || ''));
    showToast('已保存 ' + records.length + ' 帧 CSV', 'ok');
    // 保存成功后立即释放记录缓冲，避免长时间运行占用内存
    state.lastRecordCount = records.length;
    state.recorded = [];
    updateRecordUi();
  }

  function clearData(silent) {
    state.times.length = 0;
    state.rows.length = 0;
    state.freezeT = null;
    state.crosshair = null;
    for (var key in plots) {
      if (plots[key] && plots[key].resetRange) {
        try { plots[key].resetRange(); } catch (e) { /* ignore */ }
      }
    }
    if (!state.recording) {
      state.positionPrevious = null;
      state.positionUnwrapped = null;
    }
    if (!silent) addEvent('info', '已清空显示缓冲；记录缓冲不受影响');
    updateSampleText();
  }

  /* --------------------------- 状态持久化 ------------------------------- */
  function collectUiState() {
    var cards = {};
    Object.keys(state.cards).forEach(function (title) {
      var card = state.cards[title];
      if (!card) return;
      var pos = card.getPos ? card.getPos() : { x: 8, y: 8 };
      cards[title] = { x: pos.x, y: pos.y, collapsed: card.isCollapsed() };
    });
    return {
      ui_version: 3,
      port: (els && els.portSelect.value) || state.status.port || '',
      plot_window: els ? els.plotWindow.value : '10 秒',
      display_mode: els ? els.displayMode.value : '趋势',
      trend_ms: els ? els.trendMs.value : '40 ms',
      cards: cards,
      abs_card: state.absCard ? (function () {
        var pos = state.absCard.getPos ? state.absCard.getPos() : { x: 320, y: 150 };
        return { x: pos.x, y: pos.y, collapsed: state.absCard.isCollapsed() };
      })() : (state.absCardSaved || null)
    };
  }

  function saveStateSoon() {
    if (state.saveTimer) clearTimeout(state.saveTimer);
    state.saveTimer = setTimeout(function () {
      state.saveTimer = null;
      saveStateNow();
    }, SAVE_DEBOUNCE_MS);
  }

  async function saveStateNow() {
    if (!state.backend) return;
    // 启动阶段布局尚未稳定（窗口尺寸/卡片 reflow 完成前）不落盘，避免保存 0 坐标的坏布局
    if (!state.ready) return;
    var snapshot;
    try { snapshot = collectUiState(); } catch (e) { return; }
    try { await state.backend.saveState(snapshot); } catch (e) { /* 非致命 */ }
  }

  function readDisplayFromControls() {
    return {
      mode: els.displayMode.value,
      tauMs: parseInt(els.trendMs.value, 10) || 40,
      windowS: parseInt(els.plotWindow.value, 10) || DEFAULT_WINDOW_S,
      paused: !!els.pauseToggle.checked,
      lockY: !!els.lockYToggle.checked
    };
  }

  function restoreUiState(saved) {
    if (!saved || typeof saved !== 'object') return;
    var cards = saved.cards;
    state.savedCards = (cards && typeof cards === 'object' && Object.keys(cards).length)
      ? cards : null;
    state.absCardSaved = (saved.abs_card && typeof saved.abs_card === 'object')
      ? saved.abs_card : null;
    state.savedPort = saved.port || '';
    // 参数不再随状态恢复：每次启动都以 data/config0.json 为默认值
    if (saved.display_mode && ['趋势', '原始', '叠加'].indexOf(saved.display_mode) >= 0) {
      els.displayMode.value = saved.display_mode;
    }
    if (saved.trend_ms && ['20 ms', '40 ms', '80 ms'].indexOf(saved.trend_ms) >= 0) {
      els.trendMs.value = saved.trend_ms;
    }
    if (saved.plot_window && ['5 秒', '10 秒', '30 秒', '60 秒'].indexOf(saved.plot_window) >= 0) {
      els.plotWindow.value = saved.plot_window;
    }
    state.display = readDisplayFromControls();
    ensurePortOption(state.savedPort);
    applyCardLayout();
    refreshAllDots();
  }

  /** 卡片默认起始点：左侧书签栏右侧、状态 HUD 下方。 */
  function cardStartPoint() {
    var stage = els.stage.getBoundingClientRect();
    var hud = document.getElementById('statusHud');
    var x = 14;
    var y = 146;
    var rail = els.bookmarkRail ? els.bookmarkRail.getBoundingClientRect() : null;
    if (rail && rail.width > 0) {
      x = Math.max(x, Math.round(rail.right - stage.left + 12));
      y = Math.max(y, Math.round(rail.top - stage.top));
    }
    if (hud) {
      var rect = hud.getBoundingClientRect();
      y = Math.max(y, Math.round(rect.bottom - stage.top + 10));
    }
    return { x: x, y: y };
  }

  function positionBookmarkRail() {
    if (!els || !els.bookmarkRail) return;
    var stage = els.stage.getBoundingClientRect();
    var hud = document.getElementById('statusHud');
    var top = 150;
    if (hud) {
      top = Math.max(120, Math.round(hud.getBoundingClientRect().bottom - stage.top + 8));
    }
    els.bookmarkRail.style.top = top + 'px';
    els.bookmarkRail.style.maxHeight = Math.max(180, Math.round(stage.height - top - 120)) + 'px';
  }

  function buildBookmarks() {
    if (!els || !els.bookmarkRail) return;
    els.bookmarkRail.innerHTML = '';
    var caption = document.createElement('div');
    caption.className = 'bookmark-caption';
    caption.innerHTML = '<span>调整参数</span>';
    els.bookmarkRail.appendChild(caption);
    var index = 1;
    Object.keys(state.cards).forEach(function (title) {
      var card = state.cards[title];
      if (!card) return;
      var button = document.createElement('button');
      button.type = 'button';
      button.className = 'bookmark-item';
      button.setAttribute('data-group', title);
      button.setAttribute('aria-label', '显示或隐藏 ' + title + ' 参数卡片');
      var number = document.createElement('span');
      number.className = 'bookmark-index';
      number.textContent = (index < 10 ? '0' : '') + index;
      var label = document.createElement('span');
      label.className = 'bookmark-label';
      var short = document.createElement('span');
      short.className = 'bookmark-short';
      var group = J280Params.GROUPS[index - 1] || {};
      short.textContent = group.short || title;
      var name = document.createElement('span');
      name.className = 'bookmark-name';
      name.textContent = title;
      label.appendChild(short);
      label.appendChild(name);
      var count = document.createElement('span');
      count.className = 'bookmark-count';
      count.textContent = String(group.names ? group.names.length : '');
      button.appendChild(number);
      button.appendChild(label);
      button.appendChild(count);
      button.addEventListener('click', function () { toggleGroupCard(title); });
      els.bookmarkRail.appendChild(button);
      index += 1;
    });

    var divider = document.createElement('div');
    divider.className = 'bookmark-divider';
    divider.innerHTML = '<span>TOOL</span>';
    els.bookmarkRail.appendChild(divider);

    var special = document.createElement('button');
    special.type = 'button';
    special.className = 'bookmark-item bookmark-special';
    special.setAttribute('data-special', 'abs-target');
    special.setAttribute('aria-label', '显示或隐藏指定运动轨迹卡片');
    var sIndex = document.createElement('span');
    sIndex.className = 'bookmark-index';
    sIndex.textContent = '◆';
    var sLabel = document.createElement('span');
    sLabel.className = 'bookmark-label';
    var sShort = document.createElement('span');
    sShort.className = 'bookmark-short';
    sShort.textContent = '轨迹';
    var sName = document.createElement('span');
    sName.className = 'bookmark-name';
    sName.textContent = '指定运动轨迹';
    sLabel.appendChild(sShort);
    sLabel.appendChild(sName);
    var sCount = document.createElement('span');
    sCount.className = 'bookmark-count';
    sCount.textContent = 'M3';
    special.appendChild(sIndex);
    special.appendChild(sLabel);
    special.appendChild(sCount);
    special.addEventListener('click', function () { toggleAbsTargetCard(); });
    els.bookmarkRail.appendChild(special);
  }

  function updateBookmarkState(title, visible) {
    if (!els || !els.bookmarkRail) return;
    var buttons = els.bookmarkRail.querySelectorAll('.bookmark-item');
    for (var i = 0; i < buttons.length; i++) {
      if (buttons[i].getAttribute('data-group') === title) {
        buttons[i].classList.toggle('active', !!visible);
        buttons[i].setAttribute('aria-pressed', visible ? 'true' : 'false');
      }
    }
  }

  function visibleGroupCards() {
    var list = [];
    Object.keys(state.cards).forEach(function (title) {
      var card = state.cards[title];
      if (card && card.el && !card.el.hidden) list.push(card);
    });
    return list;
  }

  function ensureGroupCardPlacement(card) {
    if (!card || !card.el) return;
    var stage = els.stage.getBoundingClientRect();
    var start = cardStartPoint();
    var pos = card.getPos ? card.getPos() : { x: start.x, y: start.y };
    var x = Math.max(start.x, pos.x || start.x);
    var y = Math.max(start.y, pos.y || start.y);
    var rect = card.el.getBoundingClientRect();
    var maxBottom = start.y;
    var overlaps = false;
    visibleGroupCards().forEach(function (other) {
      if (other === card) return;
      var r = other.el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) return;
      maxBottom = Math.max(maxBottom, Math.round(r.bottom - stage.top + 8));
      var hit = !(rect.right <= r.left + 2 || r.right <= rect.left + 2 ||
                  rect.bottom <= r.top + 2 || r.bottom <= rect.top + 2);
      if (hit) overlaps = true;
    });
    if (overlaps) {
      x = start.x;
      y = Math.max(start.y, maxBottom);
    }
    card.setPos(x, y);
    if (window.J280Cards && J280Cards.clampToStage) {
      try { J280Cards.clampToStage(card.el); } catch (e) { /* ignore */ }
    }
  }

  function setGroupCardVisible(title, visible) {
    var card = state.cards[title];
    if (!card || !card.el) return;
    if (visible) {
      card.el.hidden = false;
      ensureGroupCardPlacement(card);
    } else {
      card.el.hidden = true;
    }
    updateBookmarkState(title, visible);
  }

  function toggleGroupCard(title) {
    var card = state.cards[title];
    if (!card || !card.el) return;
    setGroupCardVisible(title, !!card.el.hidden);
  }

  function hideAllGroupCards() {
    Object.keys(state.cards).forEach(function (title) {
      var card = state.cards[title];
      if (card && card.el) card.el.hidden = true;
      updateBookmarkState(title, false);
    });
  }

  function findCardBlockers() {
    var list = cardRectList();
    if (!list.length) return false;
    var blockers = [];
    ['statusHud', 'metricStrip', 'bookmarkRail'].forEach(function (id) {
      var el = document.getElementById(id);
      if (!el) return;
      var r = el.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) blockers.push(r);
    });
    for (var i = 0; i < list.length; i++) {
      for (var b = 0; b < blockers.length; b++) {
        var r = blockers[b];
        var overlap = !(list[i].right <= r.left + 1 || r.right <= list[i].left + 1 ||
                        list[i].bottom <= r.top + 1 || r.bottom <= list[i].top + 1);
        if (overlap) return true;
      }
    }
    return false;
  }

  function applyCardLayout() {
    if (!state.savedCards) return;
    var titles = Object.keys(state.savedCards);
    // 旧版本/异常状态可能把卡片存到 (0,0) 或极小坐标：视为无效布局，直接重排
    var invalid = false;
    titles.forEach(function (title) {
      var layout = state.savedCards[title];
      if (!layout) return;
      if (typeof layout.x !== 'number' || typeof layout.y !== 'number' ||
          layout.x < 5 || layout.y < 5) invalid = true;
    });
    if (invalid) {
      state.savedCards = null;
      reflowCards();
      saveStateNow();
      return;
    }
    titles.forEach(function (title) {
      var card = state.cards[title];
      var layout = state.savedCards[title];
      if (!card || !layout) return;
      if (typeof layout.x === 'number' && typeof layout.y === 'number' && card.setPos) {
        card.setPos(layout.x, layout.y);
      }
      if (typeof layout.collapsed === 'boolean' && card.setCollapsed) {
        card.setCollapsed(layout.collapsed);
      }
    });
    // 旧布局（左侧停靠区）或窗口尺寸变化后可能重叠/压住 HUD：重新纵向排布。
    if (findCardOverlaps().length || findCardBlockers()) {
      reflowCards();
      saveStateNow();
    }
  }

  function cardRectList() {
    var list = [];
    Object.keys(state.cards).forEach(function (title) {
      var card = state.cards[title];
      if (!card || !card.el || card.el.hidden) return;
      var rect = card.el.getBoundingClientRect();
      list.push({
        title: title,
        el: card.el,
        left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom
      });
    });
    return list;
  }

  function findCardOverlaps() {
    var list = cardRectList();
    var pairs = [];
    for (var i = 0; i < list.length; i++) {
      for (var j = i + 1; j < list.length; j++) {
        var a = list[i], b = list[j];
        var overlap = !(a.right <= b.left + 2 || b.right <= a.left + 2 ||
                        a.bottom <= b.top + 2 || b.bottom <= a.top + 2);
        if (overlap) pairs.push([a.title, b.title]);
      }
    }
    return pairs;
  }

  function reflowCards() {
    if (!window.J280Cards || !J280Cards.autoStack) return false;
    var list = visibleGroupCards();
    if (!list.length) return false;
    try {
      var start = cardStartPoint();
      J280Cards.autoStack(list, { x: start.x, y: start.y, gap: 10, bottomMargin: 12 });
      return true;
    } catch (e) {
      reportError(e, 'reflowCards');
      return false;
    }
  }

  /* --------------------------- 串口 ------------------------------------- */
  function ensurePortOption(port) {
    if (!els || !els.portSelect || !port) return;
    for (var i = 0; i < els.portSelect.options.length; i++) {
      if (els.portSelect.options[i].value === port) { els.portSelect.value = port; return; }
    }
    var option = document.createElement('option');
    option.value = port;
    option.textContent = port;
    els.portSelect.appendChild(option);
    els.portSelect.value = port;
  }

  async function refreshPorts() {
    var ports = [];
    try {
      var list = await state.backend.listPorts();
      if (Array.isArray(list)) ports = list.slice();
    } catch (e) { reportError(e, 'listPorts'); }
    var current = els.portSelect.value || state.savedPort || '';
    if (current && ports.indexOf(current) < 0) ports.unshift(current);
    els.portSelect.innerHTML = '';
    if (!ports.length) {
      var empty = document.createElement('option');
      empty.value = '';
      empty.textContent = '无可用串口';
      els.portSelect.appendChild(empty);
    } else {
      for (var i = 0; i < ports.length; i++) {
        var option = document.createElement('option');
        option.value = ports[i];
        option.textContent = ports[i];
        els.portSelect.appendChild(option);
      }
      els.portSelect.value = ports.indexOf(current) >= 0 ? current : ports[0];
    }
    saveStateSoon();
  }

  async function toggleConnection() {
    if (state.status.connected) {
      try { await state.backend.closePort(); } catch (e) { reportError(e, 'closePort'); }
      return;
    }
    var port = els.portSelect.value;
    if (!port) { addEvent('warn', '未连接：请选择 FPGA 对应的串口'); return; }
    var res;
    try { res = await state.backend.openPort(port); }
    catch (e) { res = { ok: false, error: String(e && e.message || e) }; }
    if (!res || !res.ok) {
      addEvent('warn', '串口连接失败：' + ((res && res.error) || '未知错误'));
    }
  }

  /* --------------------------- 曲线绘制 ---------------------------------- */
  function buildCharts() {
    if (!window.J280Charts) throw new Error('J280Charts 未加载');
    for (var i = 0; i < PLOT_DEFS.length; i++) {
      var def = PLOT_DEFS[i];
      var canvas = els[def.canvasId];
      if (!canvas) continue;
      var plot = J280Charts.createPlot(canvas, {
        key: def.key,
        title: def.title,
        series: def.series,
        unit: def.unit,
        includeZero: def.includeZero,
        symmetric: def.symmetric,
        wrapThreshold: def.wrapThreshold,
        // 标题由 chart-box 内的 HUD 标题条显示，画布内不再重复绘制
        drawTitle: false,
        topMargin: 24
      });
      plots[def.key] = plot;
      plotCanvases[def.key] = canvas;
      bindPlotInteraction(def.key, canvas, plot);
    }
    if (!pluginsReady() || !J280Charts.SERIES_STYLE) return;
    if (plots.position && plots.position.setOverlays) {
      plots.position.setOverlays([{
        name: '目标', color: '#a9c7ff', dash: [4, 3],
        getValue: function () {
          var mode = state.latest ? state.latest.mode : 0;
          if (mode === 3) return singleTurnTarget(paramNumber('TURNS_POSTGT', null));
          return paramNumber('POSTGT', null);
        }
      }]);
    }
    if (plots.duty && plots.duty.setOverlays) {
      plots.duty.setOverlays([
        {
          name: '+LIM', color: '#8a5a5a', dash: [2, 3],
          getValue: function () { return paramNumber('LIM', null); }
        },
        {
          name: '-LIM', color: '#8a5a5a', dash: [2, 3],
          getValue: function () {
            var v = paramNumber('LIM', null);
            return v === null ? null : -v;
          }
        },
        {
          name: '+DZ', color: '#5a8a5a', dash: [1, 3],
          getValue: function () { return paramNumber('DZ', null); }
        },
        {
          name: '-DZ', color: '#5a8a5a', dash: [1, 3],
          getValue: function () {
            var v = paramNumber('DZ', null);
            return v === null ? null : -v;
          }
        }
      ]);
    }
  }

  function pluginsReady() { return !!(window.J280Charts && J280Charts.SERIES_STYLE); }

  function bindPlotInteraction(key, canvas, plot) {
    canvas.addEventListener('mousemove', function (event) {
      try {
        if (!state.times.length) return;
        var rect = canvas.getBoundingClientRect();
        var x = event.clientX - rect.left;
        var t = plot.timeAt ? plot.timeAt(x) : null;
        if (t === null || t === undefined) { state.crosshair = null; return; }
        var row = nearestRow(t);
        if (!row) { state.crosshair = null; return; }
        state.crosshair = { t: t, row: row };
      } catch (e) { /* ignore */ }
    });
    canvas.addEventListener('mouseleave', function () {
      state.crosshair = null;
    });
    canvas.addEventListener('click', function (event) {
      try {
        var rect = canvas.getBoundingClientRect();
        var x = event.clientX - rect.left;
        var y = event.clientY - rect.top;
        if (plot.legendHitTest) plot.legendHitTest(x, y);
      } catch (e) { /* ignore */ }
    });
  }

  function nearestRow(t) {
    var times = state.times;
    if (!times.length) return null;
    var index = lowerBound(times, t);
    if (index >= times.length) index = times.length - 1;
    else if (index > 0 && Math.abs(times[index - 1] - t) < Math.abs(times[index] - t)) index -= 1;
    return state.rows[index] || null;
  }

  function visibleSlice() {
    var times = state.times;
    var rows = state.rows;
    if (!times.length) return { times: [], rows: [], t0: 0, t1: 1 };
    var span = state.display.windowS;
    var t1 = (state.display.paused && state.freezeT !== null)
      ? state.freezeT : times[times.length - 1];
    var t0 = t1 - span;
    var start = lowerBound(times, t0);
    var end = upperBound(times, t1);
    return {
      times: times.slice(start, end),
      rows: rows.slice(start, end),
      t0: t0,
      t1: t1
    };
  }

  function drawCharts() {
    var slice = visibleSlice();
    var settings = {
      mode: state.display.mode,
      tauMs: state.display.tauMs,
      lockY: state.display.lockY,
      paused: state.display.paused,
      crosshair: state.crosshair
    };
    for (var key in plots) {
      var plot = plots[key];
      if (!plot) continue;
      try {
        plot.draw(slice.times, slice.rows, slice.t0, slice.t1, settings);
      } catch (e) {
        reportError(e, 'chart:' + key);
      }
    }
  }

  /* --------------------------- 摆动分析 ---------------------------------- */
  function setAnalysis(summary, hint) {
    if (!els) return;
    if (summary === state.analysisCache) return;
    state.analysisCache = summary;
    els.analysisSummary.textContent = summary;
    els.analysisHint.textContent = hint || '';
    els.analysisHint.hidden = !hint;
  }

  function updateAnalysis() {
    if (!window.J280Charts || !J280Charts.estimateOscillation) return;
    var slice = visibleSlice();
    var rows = slice.rows;
    var times = slice.times;
    if (rows.length < 30) {
      setAnalysis('等待数据（需要 ≥1 s 有效遥测）', '');
      return;
    }
    var pos = [], ang = [], dut = [];
    for (var i = 0; i < rows.length; i++) {
      pos.push(rows[i].pos === null ? 0 : Number(rows[i].pos));
      ang.push(rows[i].ang === null ? 0 : Number(rows[i].ang));
      dut.push(rows[i].dut === null ? 0 : Number(rows[i].dut));
    }
    var unwrapped = [];
    var offset = 0;
    var previous = pos[0];
    for (var p = 0; p < pos.length; p++) {
      var value = pos[p];
      if (value - previous > ENC_CPR / 2) offset -= ENC_CPR;
      else if (previous - value > ENC_CPR / 2) offset += ENC_CPR;
      unwrapped.push(value + offset);
      previous = value;
    }
    var posResult = J280Charts.estimateOscillation(times, unwrapped, 1.0) || [null, 0];
    var angResult = J280Charts.estimateOscillation(times, ang, 0.05) || [null, 0];
    var posFreq = posResult[0], posAmp = posResult[1];
    var angFreq = angResult[0], angAmp = angResult[1];
    var duration = Math.max(times[times.length - 1] - times[0], 1e-6);
    var flips = J280Charts.countReversals(dut) / duration;
    var stats = J280Charts.windowStats(dut);
    var dutyRms = stats ? stats[1] : 0;

    function fmt(freq, amp, unit) {
      return '±' + Number(amp).toFixed(1) + unit + (freq ? '@' + Number(freq).toFixed(2) + 'Hz' : '');
    }
    var summary = '摆动分析（当前窗）：位置 ' + fmt(posFreq, posAmp, 'count') +
      '  |  角度 ' + fmt(angFreq, angAmp, '°') +
      '  |  输出换向 ' + flips.toFixed(1) + ' 次/s' +
      '  |  DUT RMS ' + Number(dutyRms).toFixed(0);
    var balancing = !!(state.latest && (state.latest.st & 4));
    var hint = '';
    if (balancing && J280Charts.diagnose) {
      hint = J280Charts.diagnose(posFreq, posAmp, angFreq, angAmp, flips, dutyRms);
    }
    setAnalysis(summary, hint);
  }

  /* --------------------------- 3D 模型 ---------------------------------- */
  function modelState() {
    var latest = state.latest;
    return {
      ang: latest && latest.ang !== null ? latest.ang : null,
      ref: latest && latest.ref !== null ? latest.ref : null,
      pos: latest && latest.pos !== null ? latest.pos : null,
      spd: latest && latest.spd !== null ? latest.spd : null,
      dut: latest && latest.dut !== null ? latest.dut : null,
      mode: latest ? latest.mode : 0,
      st: latest ? latest.st : 0,
      sw: latest ? latest.sw : null,
      lim: paramNumber('LIM', 300),
      dz: paramNumber('DZ', 0),
      enter: paramNumber('ENTER', 1000) / 100,
      fall: paramNumber('FALL', 1500) / 100,
      connected: !!state.status.connected
    };
  }

  /* --------------------------- 卡片构建 ---------------------------------- */
  function buildCards() {
    if (!window.J280Params || !window.J280Cards) throw new Error('params.js / cards.js 未加载');
    var groups = J280Params.GROUPS || [];
    var created = [];
    for (var i = 0; i < groups.length; i++) {
      (function (group, index) {
        var bodyEl = document.createElement('div');
        bodyEl.className = 'card-body-inner';
        for (var k = 0; k < group.names.length; k++) {
          var name = group.names[k];
          var row = J280Params.createParamRow(name, {
            onInput: function (n) { handleParamInput(n); },
            onEnter: function (n) { sendParameter(n); },
            onNudge: function (n, dir) { handleNudge(n, dir); },
            onSend: function (n) { sendParameter(n); },
            onAbsEdit: function (n) { toggleAbsTargetCard(); },
            onTipEnter: function (n) { showParamTip(n); },
            onTipLeave: hideTooltip
          });
          state.paramRows[name] = row;
          // 输入框先填固件内置默认值；启动后由 loadDefaultParams() 载入 data/config0.json
          if (J280Params.PARAMS[name] && row.setValue) {
            row.setValue(String(J280Params.PARAMS[name].default));
          }
          bodyEl.appendChild(row.el);
        }
        // POSTGT 的圆形表盘放到“编码器位置外环”卡片最前面，避免被滚动条埋在底部
        if (group.names.indexOf('POSTGT') >= 0 &&
            state.paramRows.POSTGT && bodyEl.firstChild) {
          bodyEl.insertBefore(state.paramRows.POSTGT.el, bodyEl.firstChild);
        }
        var start = cardStartPoint();
        var card = J280Cards.createCard({
          id: 'group-' + index,
          title: group.title,
          subtitle: '',
          width: 280,
          bodyEl: bodyEl,
          footerText: '',
          maxBodyHeight: CARD_MAX_BODY[index] || null,
          defaultPos: { x: start.x, y: start.y },
          collapsed: !!CARD_DEFAULT_COLLAPSED[index],
          onChange: function (layout) {
            state.cardLayout[group.title] = layout;
            // 卡片拖动/折叠结束时立即落盘，避免关闭窗口快于去抖时间导致布局丢失
            saveStateNow();
          }
        });
        if (card && card.el && !card.el.parentNode) els.cardLayer.appendChild(card.el);
        // 所有参数卡片默认隐藏，由左侧书签显示/隐藏
        if (card && card.el) card.el.hidden = true;
        state.cards[group.title] = card;
        created.push(card);
      })(groups[i], i);
    }
    // 初次 autoStack 延迟到 initAsync（页面布局稳定后）执行，避免在高度未确定时把卡片全部折叠
    state.createdCards = created;
    buildBookmarks();
  }

  /* --------------------------- 事件绑定 ---------------------------------- */
  function bindEvents() {
    els.btnRefreshPorts.addEventListener('click', function () { refreshPorts(); });
    els.btnConnect.addEventListener('click', toggleConnection);
    els.portSelect.addEventListener('change', function () { saveStateSoon(); });
    els.btnMode1.addEventListener('click', function () { requestMode(1); });
    els.btnMode2.addEventListener('click', function () { requestMode(2); });
    els.btnMode3.addEventListener('click', function () { requestMode(3); });
    els.btnStop.addEventListener('click', requestStop);
    els.btnSendAll.addEventListener('click', function () { sendAllParameters(); });
    els.btnSaveConfig.addEventListener('click', saveConfigFile);
    els.btnLoadConfig.addEventListener('click', loadConfigFile);
    els.btnFullscreenOn.addEventListener('click', function () { requestFullscreen(true); });
    els.btnFullscreenOff.addEventListener('click', function () { requestFullscreen(false); });

    els.displayMode.addEventListener('change', function () {
      state.display = readDisplayFromControls();
      saveStateSoon();
    });
    els.trendMs.addEventListener('change', function () {
      state.display = readDisplayFromControls();
      saveStateSoon();
    });
    els.plotWindow.addEventListener('change', function () {
      state.display = readDisplayFromControls();
      state.crosshair = null;
      saveStateSoon();
    });
    els.pauseToggle.addEventListener('change', handlePauseChange);
    els.lockYToggle.addEventListener('change', function () {
      state.display = readDisplayFromControls();
      saveStateSoon();
    });
    els.btnRecordStart.addEventListener('click', startRecording);
    els.btnRecordSave.addEventListener('click', stopRecordingAndSave);
    els.btnClear.addEventListener('click', function () { clearData(false); });
    els.btnClearEvents.addEventListener('click', function () {
      els.eventList.innerHTML = '';
      state.events.length = 0;
      addEvent('info', '事件日志已清空');
    });

    document.addEventListener('keydown', handleKeydown);
    bindAbsEditorEvents();
    document.addEventListener('pointerdown', function (event) {
      if (els.tooltip && !els.tooltip.hidden) {
        if (!els.tooltip.contains(event.target)) hideTooltip();
      }
    });
    window.addEventListener('resize', function () {
      hideTooltip();
      positionBookmarkRail();
      // 窗口尺寸变化后把可见卡片夹回 #stage，避免卡片跑到可视区外
      if (window.J280Cards && J280Cards.clampToStage) {
        visibleGroupCards().forEach(function (card) {
          try { J280Cards.clampToStage(card.el); } catch (e) { /* ignore */ }
        });
        if (state.absCard && absEditor.open && state.absCard.el) {
          try { J280Cards.clampToStage(state.absCard.el); } catch (e) { /* ignore */ }
        }
        if (findCardOverlaps().length) reflowCards();
        saveStateSoon();
      }
      updateToastPosition();
    });
  }

  function handlePauseChange() {
    var paused = !!els.pauseToggle.checked;
    state.display.paused = paused;
    state.display = readDisplayFromControls();
    if (paused) {
      state.freezeT = state.times.length ? state.times[state.times.length - 1] : null;
      addEvent('info', '画面已暂停（空格恢复；数据仍在后台接收）');
    } else {
      state.freezeT = null;
      addEvent('info', '画面已恢复实时');
    }
    saveStateSoon();
  }

  function togglePause() {
    els.pauseToggle.checked = !els.pauseToggle.checked;
    handlePauseChange();
  }

  function handleKeydown(event) {
    // 绝对定位图形卡片打开时：Esc 收起卡片，其它按键交给输入框/画布/全局快捷键
    if (absEditor.open && event.key === 'Escape') {
      event.preventDefault();
      setAbsCardVisible(false);
      return;
    }
    var target = event.target;
    var tag = (target && target.tagName) ? target.tagName.toUpperCase() : '';
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || (target && target.isContentEditable)) {
      return;
    }
    if (event.key === 'Escape') {
      event.preventDefault();
      // Esc 改为退出全屏（不再用于停机）
      if (state.fullscreen) requestFullscreen(false);
      return;
    }
    if (event.code === 'Space' || event.key === ' ') {
      event.preventDefault();
      togglePause();
    }
  }

  /* --------------------------- 主循环 ------------------------------------ */
  var lastDraw = 0;
  var lastAnalysis = 0;
  var firstDrawDone = false;

  function loop(timestamp) {
    window.requestAnimationFrame(loop);
    try {
      if (state.modelView && state.modelView.update) {
        state.modelView.update(modelState());
      }
      if (timestamp - lastDraw >= DRAW_INTERVAL_MS) {
        lastDraw = timestamp;
        drawCharts();
        if (timestamp - lastAnalysis >= ANALYSIS_INTERVAL_MS) {
          lastAnalysis = timestamp;
          updateAnalysis();
        }
        if (!firstDrawDone) {
          firstDrawDone = true;
          if (els && els.bootText) els.bootText.textContent = '就绪';
        }
      }
    } catch (e) {
      reportError(e, 'loop');
    }
  }

  /* --------------------------- 初始化 ------------------------------------ */
  function assertModules() {
    var required = ['J280Params', 'J280Cards', 'J280Charts', 'J280Model3D', 'J280Bridge'];
    var missing = [];
    for (var i = 0; i < required.length; i++) {
      if (!window[required[i]]) missing.push(required[i]);
    }
    if (missing.length) throw new Error('前端模块未加载：' + missing.join(', '));
  }

  function fail(error) {
    reportError(error, 'boot');
    if (els && els.bootText) els.bootText.textContent = '初始化失败：' + (error && error.message || error);
    if (els && els.errorBanner) {
      els.errorBanner.hidden = false;
      els.errorBanner.textContent = '初始化失败：' + (error && error.message || error);
    }
  }

  async function initAsync() {
    setBootText('正在连接后端…');
    try { await state.backend.init(); }
    catch (e) { reportError(e, 'backend.init'); }
    setBootText('正在恢复界面设置…');
    try {
      var res = await state.backend.loadState();
      if (res && res.ok && res.text) {
        var saved = JSON.parse(res.text);
        restoreUiState(saved);
      }
    } catch (e) {
      addEvent('warn', '状态恢复失败：' + (e && e.message || e));
    }
    // 默认参数固定来自 data/config0.json（不随上次关闭状态恢复）
    await loadDefaultParams();
    await refreshPorts();
    state.display = readDisplayFromControls();
    // 等一帧确保 QWebEngine 完成布局后再排布卡片（否则可能按 0 高度全部折叠）
    await new Promise(function (resolve) {
      if (window.requestAnimationFrame) window.requestAnimationFrame(function () { resolve(); });
      else window.setTimeout(resolve, 0);
    });
    positionBookmarkRail();
    if (!state.savedCards) reflowCards();
    else if (findCardOverlaps().length || findCardBlockers()) reflowCards();
    // 清掉启动阶段由 refreshPorts 排队的自动保存，避免把初始布局误写进状态文件
    if (state.saveTimer) {
      clearTimeout(state.saveTimer);
      state.saveTimer = null;
    }
    updateConnectionUI();
    refreshAllDots();
    updateToastPosition();
    addEvent('info', '上位机已就绪：请选择串口并连接');
    state.ready = true;
    API.ready = true;
    state.startedAt = Date.now();
    await refreshWindowState();
    updateFullscreenUI();
    if (els.bootOverlay) {
      els.bootOverlay.classList.add('hidden');
      setTimeout(function () {
        if (els.bootOverlay && els.bootOverlay.parentNode) els.bootOverlay.parentNode.removeChild(els.bootOverlay);
      }, 500);
    }
  }

  function boot() {
    try {
      assertModules();
      cacheDom();
      state.backend = J280Bridge.createBackend();
      API.backend = state.backend;
      state.backend.onTelemetry = ingestTelemetry;
      state.backend.onStatus = applyStatus;
      state.backend.onEvent = function (level, text) { addEvent(level, text); };
      state.backend.onWindowState = applyWindowState;
      buildCharts();
      try {
        state.modelView = J280Model3D.create(els.model3d, {});
      } catch (e) {
        reportError(e, 'model3d');
      }
      buildCards();
      API.cards = state.cards;
      bindEvents();
      updateToastPosition();
      updateConnectionUI();
      updateSampleText();
      updateFullscreenUI();
      updateRecordUi();
      window.requestAnimationFrame(loop);
      initAsync().catch(fail);
    } catch (e) {
      fail(e);
    }
  }

  /* --------------------------- 测试 API ---------------------------------- */
  var API = window.J280_APP = {
    ready: false,
    backend: null,
    plots: plots,
    cards: null,
    test: {}
  };

  API.test.loadDefaultParams = loadDefaultParams;
  API.test.openAbsEditor = function () { setAbsCardVisible(true); };
  API.test.closeAbsEditor = function () { setAbsCardVisible(false); };
  API.test.setGroupCardVisible = function (title, visible) {
    setGroupCardVisible(title, !!visible);
  };
  API.test.visibleGroupCards = function () {
    return visibleGroupCards().map(function (card) { return card.el.getAttribute('data-group'); });
  };
  API.test.getAbsTarget = function () {
    return {open: absEditor.open, turns: absEditor.turns,
      phase: absEditor.phase, count: absEditor.count};
  };
  API.test.setAbsTarget = function (turns, phase) {
    if (!absEditor.open) setAbsCardVisible(true);
    absSetTurns(turns);
    absSetPhase(phase);
    return {turns: absEditor.turns, phase: absEditor.phase, count: absEditor.count};
  };
  API.test.requestFullscreen = requestFullscreen;
  API.test.getWindowState = refreshWindowState;
  API.test.getParams = function () {
    var out = {};
    Object.keys(state.paramRows).forEach(function (name) {
      out[name] = state.paramRows[name].getText();
    });
    return out;
  };
  API.test.setParam = function (name, value) {
    var row = paramRow(name);
    if (!row) return false;
    row.setValue(String(value));
    handleParamInput(name);
    return true;
  };
  API.test.applyConfigObject = applyConfigValues;
  API.test.exportConfigObject = function () {
    var collected = collectParamValues();
    return { format: 'j280_gui_config', created: nowStamp(), params: collected.values };
  };
  API.test.setDisplay = function (options) {
    options = options || {};
    if (options.mode) els.displayMode.value = options.mode;
    if (options.tauMs) els.trendMs.value = options.tauMs + ' ms';
    if (options.windowS) els.plotWindow.value = options.windowS + ' 秒';
    state.display = readDisplayFromControls();
    return state.display;
  };
  API.test.getStateSnapshot = function () { return collectUiState(); };
  API.test.saveStateNow = saveStateNow;
  API.test.getErrors = function () { return errors.slice(); };
  API.test.injectTelemetry = function (rows) { ingestTelemetry(rows); };
  API.test.latestRow = function () { return state.latest; };
  API.test.recordBuffer = function () { return state.recorded.slice(); };
  API.test.lastRecordCount = function () { return state.lastRecordCount; };
  API.test.getRuntime = function () {
    return {
      ready: state.ready,
      status: Object.assign({}, state.status),
      rows: state.rows.length,
      recorded: state.recorded.length,
      recording: state.recording,
      display: Object.assign({}, state.display),
      latest: state.latest,
      sentValues: Object.assign({}, state.sentValues),
      request: state.request
    };
  };
  API.test.startRecord = startRecording;
  API.test.stopRecordAndSave = stopRecordingAndSave;
  API.test.stopRecord = function () {
    if (state.recording) stopRecordingWithoutSave();
  };
  API.test.buildCsv = function () { return buildCsv(state.recorded); };
  API.test.clearData = function () { clearData(false); };
  API.test.getEvents = function () { return state.events.slice(); };
  API.test.getChartHidden = function () {
    var out = {};
    Object.keys(plots).forEach(function (key) {
      var plot = plots[key];
      out[key] = plot && plot.hidden ? Array.from(plot.hidden) : [];
    });
    return out;
  };

  // 调试期间便于查看的引用（不作为稳定 API）
  Object.defineProperty(API, 'state', { get: function () { return state; } });
  Object.defineProperty(API, 'params', { get: function () { return state.paramRows; } });

  /* --------------------------- 启动 ------------------------------------- */
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
