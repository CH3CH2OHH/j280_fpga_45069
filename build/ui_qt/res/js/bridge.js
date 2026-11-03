/*
 * J280 · 前端桥接层（res/js/bridge.js）
 * ---------------------------------------------------------------------------
 * 唯一全局：window.J280Bridge = { createBackend() }
 *
 * 职责：
 *  1. Qt 桌面端：通过 QWebChannel（对象名 qt_mainWnd）调用 Python SerialBridge
 *     槽，把 callback 风格封装成 Promise，并转发 Py→JS 的
 *     telemetry / status / eventLog 信号。
 *  2. 普通浏览器（无 Qt / qwebchannel.js 加载失败）：优雅降级 ——
 *     available === false，串口方法返回 {ok:false,error:'仅桌面端支持串口'}，
 *     保存用 Blob 下载、载入用 #fileInputConfig、状态用 localStorage。
 *     默认参数由 Python 后端读取 data/config0.json；浏览器下不可用。
 *
 * 契约见 docs/UI_PORT_SPEC.md 第 9 节；遥测行 schema 见 9.3。
 * 本文件为经典 script（无 ES module），严格模式，IIFE 包裹。
 */
(function (window) {
  'use strict';

  var STATE_KEY = 'j280.ui_state';
  var QWEBCHANNEL_TIMEOUT_MS = 4000;

  // -------------------------------------------------------------------------
  // 工具函数
  // -------------------------------------------------------------------------
  function parseJson(raw, fallback) {
    if (raw === null || raw === undefined) return fallback;
    if (typeof raw === 'object') return raw;
    try {
      return JSON.parse(String(raw));
    } catch (error) {
      return fallback;
    }
  }

  function reportInternalError(where, error) {
    try {
      window.__J280_ERRORS = window.__J280_ERRORS || [];
      if (window.__J280_ERRORS.length < 50) {
        window.__J280_ERRORS.push({
          source: 'J280Bridge.' + where,
          message: String(error && error.message ? error.message : error),
          time: (new Date()).toISOString()
        });
      }
    } catch (ignored) { /* 不能因为错误上报再抛错 */ }
    try {
      if (window.console && console.error) console.error('[J280Bridge] ' + where, error);
    } catch (ignored) { /* ignore */ }
  }

  function safeFilename(name, fallback) {
    var text = String(name === null || name === undefined ? '' : name);
    text = text.replace(/[<>:"/\\|?*\u0000-\u001f]/g, '_').replace(/^[. ]+|[. ]+$/g, '');
    if (!text) text = fallback;
    return text;
  }

  // -------------------------------------------------------------------------
  // Backend
  // -------------------------------------------------------------------------
  function Backend() {
    this._qt = null;
    this._win = null;
    this._available = false;
    this._initialized = false;
    this._initPromise = null;

    this._realConnected = false;
    this._realPort = null;
    this._ports = [];

    this._lastStatus = { connected: false, port: null };
  }

  // ------------------------------------------------------------------
  // 生命周期
  // ------------------------------------------------------------------
  Backend.prototype.init = function () {
    var self = this;
    if (this._initPromise) return this._initPromise;
    this._initPromise = new Promise(function (resolve) {
      var settled = false;

      function finishWithoutQt() {
        if (settled) return;
        settled = true;
        self._available = false;
        self._initialized = true;
        resolve(self);
      }

      var hasChannel = (typeof QWebChannel === 'function') &&
        (typeof qt !== 'undefined') && qt && qt.webChannelTransport;
      if (!hasChannel) {
        finishWithoutQt();
        return;
      }

      var fallbackTimer = window.setTimeout(finishWithoutQt, QWEBCHANNEL_TIMEOUT_MS);
      try {
        new QWebChannel(qt.webChannelTransport, function (channel) {
          try {
            var bridgeObject = channel && channel.objects && channel.objects.qt_mainWnd;
            if (!bridgeObject) {
              window.clearTimeout(fallbackTimer);
              finishWithoutQt();
              return;
            }
            window.clearTimeout(fallbackTimer);
            if (settled) return;
            self._attachQt(bridgeObject, channel);
            self._call('getStatus', []).then(function (result) {
              if (settled) return;
              if (result && result.ok) {
                self._realConnected = !!result.connected;
                self._realPort = result.port || null;
                self._ports = Array.isArray(result.ports) ? result.ports.slice() : [];
              }
              self._available = true;
              self._initialized = true;
              self._lastStatus = {
                connected: self._realConnected,
                port: self._realPort
              };
              settled = true;
              self._dispatchStatus(self._lastStatus);
              resolve(self);
            });
          } catch (error) {
            window.clearTimeout(fallbackTimer);
            reportInternalError('init.channel', error);
            finishWithoutQt();
          }
        });
      } catch (error) {
        window.clearTimeout(fallbackTimer);
        reportInternalError('init', error);
        finishWithoutQt();
      }
    });
    return this._initPromise;
  };

  Backend.prototype._attachQt = function (bridgeObject, channel) {
    var self = this;
    this._qt = bridgeObject;
    this._win = (channel && channel.objects && channel.objects.qt_window)
      ? channel.objects.qt_window : null;

    function connectSignal(signal, handler) {
      try {
        if (signal && typeof signal.connect === 'function') signal.connect(handler);
      } catch (error) {
        reportInternalError('attach.connect', error);
      }
    }

    if (this._win) {
      connectSignal(this._win.fullscreenChanged, function (fullscreen) {
        self._dispatchWindowState({ fullscreen: !!fullscreen });
      });
    }

    connectSignal(bridgeObject.telemetry, function (raw) {
      var rows = parseJson(raw, null);
      if (Array.isArray(rows) && rows.length) self._dispatchTelemetry(rows);
    });
    connectSignal(bridgeObject.status, function (raw) {
      var parsed = parseJson(raw, null);
      if (!parsed || typeof parsed !== 'object') return;
      self._realConnected = !!parsed.connected;
      self._realPort = parsed.port || null;
      self._lastStatus = {
        connected: !!parsed.connected,
        port: parsed.port || null,
        error: parsed.error || undefined
      };
      self._dispatchStatus(self._lastStatus);
    });
    connectSignal(bridgeObject.eventLog, function (raw) {
      var parsed = parseJson(raw, null);
      if (!parsed || typeof parsed !== 'object') return;
      self._dispatchEvent(parsed.level || 'info', String(parsed.text || ''));
    });
  };

  Backend.prototype._call = function (name, args) {
    var qtObject = this._qt;
    if (!qtObject || typeof qtObject[name] !== 'function') {
      return Promise.resolve({ ok: false, error: '仅桌面端支持串口' });
    }
    var argv = (args || []).slice();
    return new Promise(function (resolve) {
      var done = false;
      function finish(value) {
        if (done) return;
        done = true;
        resolve(value);
      }
      try {
        qtObject[name].apply(qtObject, argv.concat([function (raw) {
          var parsed = parseJson(raw, null);
          if (parsed && typeof parsed === 'object') {
            finish(parsed);
          } else {
            finish({ ok: false, error: '后端返回非 JSON 数据' });
          }
        }]));
      } catch (error) {
        finish({ ok: false, error: String(error && error.message ? error.message : error) });
      }
    });
  };

  Backend.prototype._callWindow = function (name, args) {
    var winObject = this._win;
    if (!winObject || typeof winObject[name] !== 'function') {
      return Promise.resolve({ ok: false, error: '窗口控制不可用（仅桌面端）' });
    }
    var argv = (args || []).slice();
    return new Promise(function (resolve) {
      var done = false;
      function finish(value) {
        if (done) return;
        done = true;
        resolve(value);
      }
      try {
        winObject[name].apply(winObject, argv.concat([function (raw) {
          var parsed = parseJson(raw, null);
          if (parsed && typeof parsed === 'object') finish(parsed);
          else finish({ ok: false, error: '窗口控制返回非 JSON 数据' });
        }]));
      } catch (error) {
        finish({ ok: false, error: String(error && error.message ? error.message : error) });
      }
    });
  };

  // ------------------------------------------------------------------
  // Py→JS 信号分发（app.js 覆写 onTelemetry / onStatus / onEvent / onWindowState）
  // ------------------------------------------------------------------
  Backend.prototype.onTelemetry = function (rows) { void rows; };
  Backend.prototype.onStatus = function (status) { void status; };
  Backend.prototype.onEvent = function (level, text) { void level; void text; };
  Backend.prototype.onWindowState = function (state) { void state; };

  Backend.prototype._dispatchTelemetry = function (rows) {
    try {
      if (typeof this.onTelemetry === 'function') this.onTelemetry(rows);
    } catch (error) {
      reportInternalError('onTelemetry', error);
    }
  };

  Backend.prototype._dispatchStatus = function (status) {
    this._lastStatus = status;
    try {
      if (typeof this.onStatus === 'function') this.onStatus(status);
    } catch (error) {
      reportInternalError('onStatus', error);
    }
  };

  Backend.prototype._dispatchWindowState = function (state) {
    try {
      if (typeof this.onWindowState === 'function') this.onWindowState(state);
    } catch (error) {
      reportInternalError('onWindowState', error);
    }
  };

  Backend.prototype._dispatchEvent = function (level, text) {
    try {
      if (typeof this.onEvent === 'function') this.onEvent(level, text);
    } catch (error) {
      reportInternalError('onEvent', error);
    }
  };

  // ------------------------------------------------------------------
  // 串口 API
  // ------------------------------------------------------------------
  Backend.prototype.listPorts = function () {
    var self = this;
    if (!this._available) return Promise.resolve([]);
    return this._call('listPorts', []).then(function (result) {
      if (result && result.ok && Array.isArray(result.ports)) {
        self._ports = result.ports.slice();
        return self._ports.slice();
      }
      if (result && result.error) self._dispatchEvent('warn', '刷新串口失败：' + result.error);
      return self._ports.slice();
    });
  };

  /** 公开状态查询（与 Python getStatus 槽对应；无 Qt 时返回降级状态）。 */
  Backend.prototype.getStatus = function () {
    if (!this._available) {
      return Promise.resolve({ ok: true, connected: false, port: null, ports: [] });
    }
    return this._call('getStatus', []);
  };

  /** 读取 Python 侧 data/config0.json 作为唯一默认参数（Qt 专用；浏览器不可读本地文件）。 */
  Backend.prototype.loadDefaults = function () {
    if (!this._available) {
      return Promise.resolve({ ok: false, error: '仅桌面端可读取默认参数文件 data/config0.json' });
    }
    return this._call('loadDefaults', []);
  };

  // ------------------------------------------------------------------
  // 窗口控制（全屏进入/退出/状态；Qt 对象 qt_window）
  // ------------------------------------------------------------------
  Backend.prototype.getWindowState = function () {
    if (!this._win) {
      return Promise.resolve({ ok: true, fullscreen: false, maximized: false });
    }
    return this._callWindow('getWindowState', []);
  };

  Backend.prototype.setFullscreen = function (enabled) {
    if (!this._win) {
      return Promise.resolve({ ok: false, error: '仅桌面端支持全屏' });
    }
    return this._callWindow('setFullscreen', [!!enabled]);
  };

  Backend.prototype.toggleFullscreen = function () {
    if (!this._win) {
      return Promise.resolve({ ok: false, error: '仅桌面端支持全屏' });
    }
    return this._callWindow('toggleFullscreen', []);
  };

  Backend.prototype.openPort = function (port) {
    var self = this;
    var text = String(port === null || port === undefined ? '' : port).trim();
    if (!this._available) {
      return Promise.resolve({ ok: false, error: '仅桌面端支持串口' });
    }
    if (!text) return Promise.resolve({ ok: false, error: '请选择串口' });
    return this._call('openPort', [text]).then(function (result) {
      if (result && result.ok) {
        self._realConnected = true;
        self._realPort = text;
        self._lastStatus = { connected: true, port: text };
      }
      return result;
    });
  };

  Backend.prototype.closePort = function () {
    var self = this;
    if (!this._available) {
      return Promise.resolve({ ok: false, error: '仅桌面端支持串口' });
    }
    return this._call('closePort', []).then(function (result) {
      if (result && result.ok) {
        self._realConnected = false;
        self._realPort = null;
        self._lastStatus = { connected: false, port: null };
      }
      return result;
    });
  };

  Backend.prototype.sendParam = function (name, value) {
    if (!this._available) {
      return Promise.resolve({ ok: false, error: '仅桌面端支持串口' });
    }
    return this._call('sendParam', [String(name || ''), String(value === null || value === undefined ? '' : value)]);
  };

  Backend.prototype.sendAll = function (values) {
    if (!this._available) {
      return Promise.resolve({ ok: false, error: '仅桌面端支持串口' });
    }
    var payload = values && typeof values === 'object' ? values : {};
    return this._call('sendAll', [JSON.stringify(payload)]);
  };

  Backend.prototype.setMode = function (mode) {
    var number = Number(mode);
    if (!(number === 0 || number === 1 || number === 2 || number === 3)) {
      return Promise.resolve({ ok: false, error: 'MODE 只支持 0=停机、1=手动稳定、2=自动起摆、3=绝对位置' });
    }
    if (!this._available) {
      return Promise.resolve({ ok: false, error: '仅桌面端支持串口' });
    }
    return this._call('setMode', [number]);
  };

  // ------------------------------------------------------------------
  // 文件 API：Qt 用 Python 对话框；浏览器用 Blob / FileInput
  // ------------------------------------------------------------------
  Backend.prototype.saveConfig = function (obj, defaultName) {
    var text = JSON.stringify(obj === null || obj === undefined ? {} : obj, null, 2);
    var name = safeFilename(defaultName, 'j280_config.json');
    if (this._available) {
      return this._call('saveConfig', [text, name]);
    }
    return Promise.resolve(this._download(name, text + '\n', 'application/json'));
  };

  Backend.prototype.loadConfig = function () {
    var self = this;
    if (this._available) return this._call('loadConfig', []);
    return this._pickFile().then(function (result) {
      if (result && result.ok) {
        self._dispatchEvent('info', '已载入配置：' + (result.path || '本地文件'));
      }
      return result;
    });
  };

  Backend.prototype.saveCsv = function (text, defaultName) {
    var csv = String(text === null || text === undefined ? '' : text);
    var name = safeFilename(defaultName, 'j280_record.csv');
    if (this._available) {
      return this._call('saveCsv', [csv, name]);
    }
    var bom = csv.charAt(0) === '\uFEFF' ? '' : '\uFEFF';
    return Promise.resolve(this._download(name, bom + csv, 'text/csv;charset=utf-8'));
  };

  Backend.prototype.saveState = function (obj) {
    var text = JSON.stringify(obj === null || obj === undefined ? {} : obj, null, 2);
    if (this._available) {
      return this._call('saveState', [text]);
    }
    try {
      window.localStorage.setItem(STATE_KEY, text);
      return Promise.resolve({ ok: true });
    } catch (error) {
      return Promise.resolve({ ok: false, error: '本机状态保存失败：' + error });
    }
  };

  Backend.prototype.loadState = function () {
    if (this._available) return this._call('loadState', []);
    try {
      var text = window.localStorage.getItem(STATE_KEY);
      if (!text) return Promise.resolve({ ok: false, error: '没有本机状态' });
      return Promise.resolve({ ok: true, text: text });
    } catch (error) {
      return Promise.resolve({ ok: false, error: '本机状态读取失败：' + error });
    }
  };

  Backend.prototype.shutdown = function () {
    if (this._qt) {
      try {
        this._qt.shutdown(function () { /* 页面即将关闭，忽略结果 */ });
      } catch (error) {
        reportInternalError('shutdown', error);
      }
    }
    return { ok: true };
  };

  Backend.prototype._syncStatus = function () {
    var self = this;
    if (!this._available) {
      this._lastStatus = { connected: false, port: null };
      this._dispatchStatus(this._lastStatus);
      return Promise.resolve(this._lastStatus);
    }
    return this._call('getStatus', []).then(function (result) {
      if (result && result.ok) {
        self._realConnected = !!result.connected;
        self._realPort = result.port || null;
        self._ports = Array.isArray(result.ports) ? result.ports.slice() : self._ports;
        self._lastStatus = {
          connected: !!result.connected,
          port: result.port || null
        };
      } else {
        self._lastStatus = {
          connected: false,
          port: null,
          error: result && result.error
        };
      }
      self._dispatchStatus(self._lastStatus);
      return self._lastStatus;
    });
  };

  // ------------------------------------------------------------------
  // 浏览器文件下载 / 载入
  // ------------------------------------------------------------------
  Backend.prototype._download = function (filename, text, mime) {
    try {
      var blob = new Blob([text], { type: mime || 'application/octet-stream' });
      var url = window.URL.createObjectURL(blob);
      var anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = filename;
      anchor.style.display = 'none';
      document.body.appendChild(anchor);
      anchor.click();
      window.setTimeout(function () {
        try {
          window.URL.revokeObjectURL(url);
          if (anchor.parentNode) anchor.parentNode.removeChild(anchor);
        } catch (ignored) { /* ignore */ }
      }, 1500);
      return { ok: true, path: filename };
    } catch (error) {
      return { ok: false, error: '浏览器下载失败：' + error };
    }
  };

  Backend.prototype._pickFile = function () {
    var self = this;
    return new Promise(function (resolve) {
      var input = document.getElementById('fileInputConfig');
      if (!input) {
        resolve({ ok: false, error: '页面缺少 #fileInputConfig 文件输入' });
        return;
      }
      var settled = false;
      var finish = function (result) {
        if (settled) return;
        settled = true;
        try {
          input.removeEventListener('change', onChange);
        } catch (ignored) { /* ignore */ }
        try {
          window.removeEventListener('focus', onFocus);
        } catch (ignored) { /* ignore */ }
        resolve(result);
      };

      var readFile = function (file) {
        if (!file) {
          finish({ ok: false, error: '已取消载入', canceled: true });
          return;
        }
        try {
          if (typeof file.text === 'function') {
            file.text().then(function (text) {
              finish({ ok: true, text: String(text), path: file.name });
            }, function (error) {
              finish({ ok: false, error: '读取文件失败：' + error });
            });
          } else {
            var reader = new FileReader();
            reader.onload = function () {
              finish({ ok: true, text: String(reader.result || ''), path: file.name });
            };
            reader.onerror = function () {
              finish({ ok: false, error: '读取文件失败' });
            };
            reader.readAsText(file, 'utf-8');
          }
        } catch (error) {
          finish({ ok: false, error: '读取文件失败：' + error });
        }
      };

      var onChange = function () {
        readFile(input.files && input.files[0]);
      };
      var onFocus = function () {
        window.setTimeout(function () {
          if (!settled && (!input.files || !input.files.length)) {
            finish({ ok: false, error: '已取消载入', canceled: true });
          }
        }, 700);
      };

      input.addEventListener('change', onChange);
      window.addEventListener('focus', onFocus);
      try {
        input.value = '';
        input.click();
      } catch (error) {
        finish({ ok: false, error: '无法打开文件选择框：' + error });
      }
      // 兜底：用户长时间不操作时结束 Promise，避免 app.js 一直等待
      window.setTimeout(function () {
        if (!settled) finish({ ok: false, error: '已取消载入', canceled: true });
      }, 120000);
      void self;
    });
  };

  // ------------------------------------------------------------------
  // 只读属性
  // ------------------------------------------------------------------
  Object.defineProperties(Backend.prototype, {
    available: {
      get: function () { return this._available; }
    },
    connected: {
      get: function () { return this._realConnected; }
    },
    status: {
      get: function () { return this._lastStatus; }
    },
    ports: {
      get: function () { return (this._ports || []).slice(); }
    }
  });

  // -------------------------------------------------------------------------
  // 唯一全局
  // -------------------------------------------------------------------------
  window.J280Bridge = {
    createBackend: function () { return new Backend(); }
  };
}(window));
