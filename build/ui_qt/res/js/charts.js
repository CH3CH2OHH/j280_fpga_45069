/*!
 * J280 · charts.js — 5 路 Canvas 示波器曲线（经典 script，仅暴露 window.J280Charts）
 * ===========================================================================
 * 行为基准：project/gui/j280_debug_gui.py（Tk 版）
 *   - 纯函数 226-381 行、ScopePlot 514-750 行、SERIES_STYLE/THEME 211-220 行
 *   - _update_analysis 1710-1741 行（配 windowStats/estimateOscillation/
 *     countReversals/diagnose，供 app.js 移植）
 *
 * 公共 API（UI_PORT_SPEC.md §6.1）
 *   THEME, SERIES_STYLE, ENC_CPR
 *   niceTicks(low, high, count)            formatTick(value)
 *   splitWrap(times, values, threshold)    envelope(points, xLeft, xRight, columns)
 *   trendPoints(points, tauMs, wrap)       smoothRange(current, target, shrink)
 *   windowStats(values)                    estimateOscillation(times, values, minAmplitude)
 *   countReversals(values, deadband)       diagnose(posFreq, posAmp, angFreq, angAmp,
 *                                                   flipsPerS, dutyRms)
 *   createPlot(canvas, opts) -> ScopePlot
 *
 * ScopePlot
 *   draw(times, rows, t0, t1, settings)
 *     times: number[]；rows: [{ang,ref,raw,pos,spd,dut,tgt,...}]（值可为 null）
 *     settings = { mode:'趋势'|'原始'|'叠加', tauMs:40, lockY:false,
 *                  crosshair:null|{t,row} }
 *   setOverlays([{name, getValue:()=>number|null, color, dash:[4,3]}])
 *   legendHitTest(x, y) -> 名称|null      // 命中即内部翻转 hidden 并返回名称
 *   resetRange()
 *   destroy()
 *   timeAt(x) -> number|null              // 画布 CSS 像素 → 时间；越界返回 null
 *   getViewRange() -> {t0, t1}|null
 *
 * 与 Tk 版的已知差异（均不影响契约）
 *   1. Tk create_line(smooth=True) 的样条用 canvas 二次曲线（相邻中点）近似；
 *   2. 图例/读数的 -0.00 归零为 +0.00（只影响极小的负噪声显示）；
 *   3. windowStats 返回 [mean, rms, peakToPeak] 数组，同时带 .mean/.rms/.peakToPeak；
 *      estimateOscillation 返回 [freq|null, amplitude] 数组，同时带 .freq/.amplitude；
 *      两种写法（解构 / 属性）都可用；
 *   4. 画布背景为半透明 rgba(7,19,32,.52)，让 .chart-box 的玻璃底透出。
 * ===========================================================================
 */
(function (global) {
  'use strict';

  /* =======================================================================
   * 常量 / 主题
   * ==================================================================== */

  var ENC_CPR = 1040;          // 编码器单圈计数（ANG 与 POS 换算基准）
  var DT_BREAK = 0.12;         // 相邻样本 dt 超过该值即断线（串口断帧不连线）
  var FLOAT_SERIES = { ANG: true, REF: true };   // 遥测里按 float 显示为 +0.00 的系列

  // UI_PORT_SPEC.md §6.2
  var THEME = {
    bg: '#071320', grid: '#123047', grid2: '#0d2436', axis: '#6f92a8',
    text: '#d9ecf7', dim: '#54748a', zero: '#2b5a78', band: '#1d4460',
    cross: '#e9f1f8', warn: '#e8b45a'
  };

  // 与原 Python SERIES_STYLE 完全一致：名称 -> (颜色, 单位)
  var SERIES_STYLE = {
    ANG: ['#ff6b5e', '°'], REF: ['#ffc247', '°'], RAW: ['#5ad1a4', 'ADC'],
    POS: ['#5aa9ff', 'count'], TGT: ['#a9c7ff', 'count'],
    SPD: ['#4fd6c2', 'count/s'], DUT: ['#c79bff', 'duty']
  };

  var FONT_MONO = 'Consolas, "Cascadia Mono", "Microsoft YaHei UI", monospace';
  var FONT_UI = '"Microsoft YaHei UI", "Segoe UI", sans-serif';
  var FONT_TITLE = 'bold 11px ' + FONT_UI;
  var FONT_CHIP = 'bold 10px ' + FONT_MONO;
  var FONT_CROSS = 'bold 10px ' + FONT_MONO;
  var FONT_TICK = '9px ' + FONT_MONO;
  var FONT_EMPTY = '12px ' + FONT_UI;

  // 绘图区内边距（CSS 像素）：左留给 Y 刻度、上留给标题与图例、下留给 X 标签
  var M = { left: 56, right: 12, top: 24, bottom: 18 };
  var CHART_BG = 'rgba(7,19,32,0.52)';

  /* =======================================================================
   * 纯函数（1:1 移植 Python 参考实现；可离线测试）
   * ==================================================================== */

  /**
   * Python nice_ticks(low, high, count=5)：返回 [low, high] 内约 count 个“整齐”刻度。
   */
  function niceTicks(low, high, count) {
    if (count === null || count === undefined) count = 5;
    if (typeof low !== 'number' || typeof high !== 'number') return [];
    if (!isFinite(low) || !isFinite(high)) return [];
    var span = high - low;
    if (span <= 0) return [low];
    var raw = span / Math.max(1, count);
    var lg = Math.log(raw) / Math.LN10;
    var magnitude = Math.pow(10, Math.floor(lg));
    var factors = [1, 2, 2.5, 5, 10];
    var step = 10 * magnitude;
    for (var i = 0; i < factors.length; i++) {
      step = factors[i] * magnitude;
      if (raw <= step) break;
    }
    var first = Math.ceil(low / step) * step;
    var ticks = [];
    var value = first;
    // 50 个上限与 Python 一致，防御 step 下溢导致的死循环
    while (value <= high + step * 1e-9 && ticks.length < 50) {
      ticks.push(Math.round(value * 1e10) / 1e10);
      value += step;
    }
    return ticks;
  }

  /** Python format_tick(value)：按量级选小数位并去尾零，避免出现 -0.0。 */
  function formatTick(value) {
    if (typeof value !== 'number' || !isFinite(value)) return '--';
    if (Math.abs(value) < 1e-9) return '0';
    var abs = Math.abs(value);
    if (abs >= 100) return value.toFixed(0);
    if (abs >= 10) return stripZeros(value.toFixed(1));
    return stripZeros(value.toFixed(2));
  }

  function stripZeros(text) {
    if (text.indexOf('.') < 0) return text;
    return text.replace(/0+$/, '').replace(/\.$/, '');
  }

  /** Python split_wrap(times, values, threshold)：在相邻跳变超过 threshold 处切段。 */
  function splitWrap(times, values, threshold) {
    var segments = [];
    var current = [];
    var previous = null;
    var n = Math.min(times ? times.length : 0, values ? values.length : 0);
    for (var i = 0; i < n; i++) {
      var stamp = times[i];
      var value = values[i];
      if (typeof stamp !== 'number' || !isFinite(stamp) ||
          typeof value !== 'number' || !isFinite(value)) {
        // 容错：null/NaN 视为断点（Tk 版调用前已过滤，这里只是不让脏数据抛异常）
        if (current.length) segments.push(current);
        current = [];
        previous = null;
        continue;
      }
      if (threshold !== null && threshold !== undefined &&
          previous !== null && Math.abs(value - previous) > threshold) {
        if (current.length) segments.push(current);
        current = [];
      }
      current.push([stamp, value]);
      previous = value;
    }
    if (current.length) segments.push(current);
    return segments;
  }

  /** Python _bucket_points：每列只保留首/末/最小/最大（保尖峰）。 */
  function flushEnvelopeBucket(out, k, firstIdx, lastIdx, minIdx, maxIdx) {
    var picks = [firstIdx, minIdx, maxIdx, lastIdx];
    picks.sort(function (a, b) { return a - b; });
    for (var i = 0; i < picks.length; i++) {
      if (i === 0 || picks[i] !== picks[i - 1]) out[k++] = picks[i];
    }
    return k;
  }

  /**
   * 内部核心：把 [start, end) 压缩为每像素列最多 4 个点的下标序列。
   * 返回写入 out 的点数。out 需至少 4*columns+8 个槽位。
   */
  function envelopeIndices(xs, ys, start, end, xLeft, xRight, columns, out) {
    var n = end - start;
    if (n <= 0) return 0;
    var i, k = 0;
    var cols = Math.floor(columns);
    if (!(cols >= 2) || !(xRight > xLeft)) {
      for (i = start; i < end; i++) out[k++] = i;
      return k;
    }
    if (n <= cols * 2) {
      for (i = start; i < end; i++) out[k++] = i;
      return k;
    }
    var width = (xRight - xLeft) / cols;
    var currentCol = -1;
    var firstIdx = start, minIdx = start, maxIdx = start, lastIdx = start;
    for (i = start; i < end; i++) {
      var col = Math.floor((xs[i] - xLeft) / width);
      if (!isFinite(col)) col = 0;
      if (col < 0) col = 0; else if (col > cols - 1) col = cols - 1;
      if (currentCol < 0) {
        currentCol = col;
        firstIdx = minIdx = maxIdx = lastIdx = i;
        continue;
      }
      if (col !== currentCol) {
        k = flushEnvelopeBucket(out, k, firstIdx, lastIdx, minIdx, maxIdx);
        currentCol = col;
        firstIdx = minIdx = maxIdx = lastIdx = i;
      } else {
        lastIdx = i;
        if (ys[i] < ys[minIdx]) minIdx = i;
        if (ys[i] > ys[maxIdx]) maxIdx = i;
      }
    }
    k = flushEnvelopeBucket(out, k, firstIdx, lastIdx, minIdx, maxIdx);
    return k;
  }

  /**
   * Python envelope(points, x_left, x_right, columns)：
   * 把 (t, v) 序列压缩为每像素列最多 4 个点（首、最小、最大、末），保留尖峰。
   */
  function envelope(points, xLeft, xRight, columns) {
    var list = points || [];
    var n = list.length;
    var cols = Math.floor(columns);
    if (n <= cols * 2 || !(cols >= 2) || !(xRight > xLeft)) return list.slice();
    var xs = new Float64Array(n);
    var ys = new Float64Array(n);
    for (var i = 0; i < n; i++) {
      xs[i] = list[i][0];
      ys[i] = list[i][1];
    }
    var idx = new Int32Array(cols * 4 + 8);
    var m = envelopeIndices(xs, ys, 0, n, xLeft, xRight, cols, idx);
    var out = new Array(m);
    for (var k = 0; k < m; k++) out[k] = list[idx[k]];
    return out;
  }

  /** Python 最短有符号差：pos 单圈回绕时用于趋势展开。 */
  function wrapValue(value) {
    var half = ENC_CPR / 2;
    return ((((value + half) % ENC_CPR) + ENC_CPR) % ENC_CPR) - half;
  }

  function shortestDelta(value, origin) {
    var delta = value - origin;
    var wrapped = wrapValue(delta);
    var half = ENC_CPR / 2;
    if (wrapped === -half && delta > 0) return half;
    return wrapped;
  }

  /**
   * 内部核心：Python trend_points 的低通主体（写入 outX/outY，避免每帧分配）。
   * wrap 非空时先按 1040 展开再滤波，输出再折回 [-520, 520)。
   */
  function lowPassInto(xs, ys, n, tauMs, wrap, outX, outY) {
    var tau = Math.max((typeof tauMs === 'number' && isFinite(tauMs) ? tauMs : 40) / 1000, 0.001);
    var lastT = null;
    var lastRaw = 0;
    var filtered = 0;
    var unwrapped = 0;
    for (var i = 0; i < n; i++) {
      var stamp = xs[i];
      var value = ys[i];
      if (lastT === null || stamp - lastT > DT_BREAK || stamp <= lastT) {
        // 断帧/时间回退：重建历史，不跨断点滤波
        unwrapped = value;
        filtered = value;
      } else {
        unwrapped += wrap ? shortestDelta(value, lastRaw) : (value - lastRaw);
        var alpha = 1 - Math.exp(-(stamp - lastT) / tau);
        filtered += alpha * (unwrapped - filtered);
      }
      outX[i] = stamp;
      outY[i] = wrap ? wrapValue(filtered) : filtered;
      lastT = stamp;
      lastRaw = value;
    }
    return n;
  }

  /** Python trend_points(points, tau_ms=40, wrap=None)：仅用于显示的低通。 */
  function trendPoints(points, tauMs, wrap) {
    var list = points || [];
    var n = list.length;
    var xs = new Float64Array(n);
    var ys = new Float64Array(n);
    var m = 0;
    for (var i = 0; i < n; i++) {
      var p = list[i];
      if (!p) continue;
      var stamp = p[0];
      var value = p[1];
      if (typeof stamp !== 'number' || !isFinite(stamp)) continue;
      if (typeof value !== 'number' || !isFinite(value)) continue;
      xs[m] = stamp;
      ys[m] = value;
      m++;
    }
    var ox = new Float64Array(m);
    var oy = new Float64Array(m);
    lowPassInto(xs, ys, m, tauMs, wrap, ox, oy);
    var out = new Array(m);
    for (var k = 0; k < m; k++) out[k] = [ox[k], oy[k]];
    return out;
  }

  /** Python smooth_range(current, target, shrink=0.12)：扩张立即生效、收缩缓慢逼近。 */
  function smoothRange(current, target, shrink) {
    if (shrink === null || shrink === undefined) shrink = 0.12;
    if (!target) return current || null;
    if (!current || !isFinite(current[0]) || !isFinite(current[1])) {
      return [target[0], target[1]];
    }
    var low = target[0] < current[0]
      ? target[0]
      : current[0] + (target[0] - current[0]) * shrink;
    var high = target[1] > current[1]
      ? target[1]
      : current[1] + (target[1] - current[1]) * shrink;
    return [low, high];
  }

  /**
   * Python window_stats(values)：返回 (均值, RMS, 峰峰值)；空序列返回 null。
   * 返回数组 [mean, rms, peakToPeak]，并附带同名属性。
   */
  function windowStats(values) {
    var list = values || [];
    var n = 0, sum = 0, square = 0, min = Infinity, max = -Infinity;
    for (var i = 0; i < list.length; i++) {
      var v = list[i];
      if (typeof v !== 'number' || !isFinite(v)) continue;
      n++;
      sum += v;
      square += v * v;
      if (v < min) min = v;
      if (v > max) max = v;
    }
    if (!n) return null;
    var mean = sum / n;
    var rms = Math.sqrt(square / n);
    var peakToPeak = max - min;
    var out = [mean, rms, peakToPeak];
    out.mean = mean;
    out.rms = rms;
    out.peakToPeak = peakToPeak;
    return out;
  }

  function oscResult(freq, amplitude) {
    var out = [freq, amplitude];
    out.freq = freq;
    out.amplitude = amplitude;
    return out;
  }

  /**
   * Python estimate_oscillation(times, values, min_amplitude=0.0)：
   * 迟滞均值穿越法估计频率与半幅值；数据不足/幅值过小时频率为 null。
   * 返回 [freq|null, amplitude]，并附带 .freq/.amplitude。
   */
  function estimateOscillation(times, values, minAmplitude) {
    var n = Math.min(times ? times.length : 0, values ? values.length : 0);
    if (minAmplitude === null || minAmplitude === undefined) minAmplitude = 0;
    if (n < 20 || !(times[n - 1] - times[0] >= 1.0)) return oscResult(null, 0);
    var i, value;
    var mean = 0, min = Infinity, max = -Infinity;
    for (i = 0; i < n; i++) {
      value = values[i];
      mean += value;
      if (value < min) min = value;
      if (value > max) max = value;
    }
    mean /= n;
    var amplitude = (max - min) / 2;
    if (!(amplitude > minAmplitude)) return oscResult(null, amplitude);
    var hyst = Math.max(amplitude * 0.15, 1e-9);
    var flips = [];
    var state = 0;
    for (i = 0; i < n; i++) {
      var deviation = values[i] - mean;
      if (deviation > hyst && state <= 0) {
        if (state === -1) flips.push(times[i]);
        state = 1;
      } else if (deviation < -hyst && state >= 0) {
        if (state === 1) flips.push(times[i]);
        state = -1;
      }
    }
    if (flips.length < 2 || flips[flips.length - 1] <= flips[0]) {
      return oscResult(null, amplitude);
    }
    // 相邻穿越间隔为半个周期；用首末穿越时刻平均，避免窗口端点量化误差
    var freq = (flips.length - 1) / (2 * (flips[flips.length - 1] - flips[0]));
    return oscResult(freq, amplitude);
  }

  /** Python count_reversals(values, deadband=5)：统计输出变号次数。 */
  function countReversals(values, deadband) {
    if (deadband === null || deadband === undefined) deadband = 5;
    var last = 0;
    var count = 0;
    for (var i = 0; i < (values ? values.length : 0); i++) {
      var value = values[i];
      if (typeof value !== 'number' || !isFinite(value)) continue;
      var sign = value > deadband ? 1 : (value < -deadband ? -1 : 0);
      if (sign && last && sign !== last) count++;
      if (sign) last = sign;
    }
    return count;
  }

  /** Python diagnose(...)：根据摆动统计给出调参提示（启发式，仅供参考）。 */
  function diagnose(posFreq, posAmp, angFreq, angAmp, flipsPerS, dutyRms) {
    var hints = [];
    if (flipsPerS >= 8 && dutyRms > 25) {
      hints.push('输出频繁换向：对照原始波形；先试 DZLP+1，核对 DZW/DZ；不要只凭平滑趋势加大滤波。');
    }
    if (posFreq !== null && posFreq !== undefined && posAmp > 6 && posFreq < 1.5) {
      hints.push('位置在 ±' + posAmp.toFixed(0) + ' count、' + posFreq.toFixed(2) + ' Hz 慢摆：检查 AKI=0、' +
        'DZW 是否使小命令推不动，以及 PKD/RLP 的阻尼与延迟；逐项对比，勿只加积分。');
    }
    if (angAmp > 0.8 && (angFreq === null || angFreq === undefined || angFreq > 1.5)) {
      hints.push('角度 ±' + angAmp.toFixed(1) + '° 振荡：检查 ALP/DLP 滞后是否过大（先对照 ALP=0/1、DLP=1/2）。');
    }
    if (!hints.length) {
      if (posAmp <= 3 && angAmp <= 0.5) {
        hints.push('状态良好：位置与角度均在小范围内。');
      } else {
        hints.push('暂无明显问题征兆；继续观察 10 s 以上。');
      }
    }
    return hints.join(' ');
  }

  /* =======================================================================
   * 内部小工具
   * ==================================================================== */

  function colorOf(name) {
    var style = SERIES_STYLE[name];
    return style ? style[0] : THEME.dim;
  }

  function parseHex(color) {
    if (typeof color !== 'string' || color.length !== 7 || color.charAt(0) !== '#') return null;
    var r = parseInt(color.slice(1, 3), 16);
    var g = parseInt(color.slice(3, 5), 16);
    var b = parseInt(color.slice(5, 7), 16);
    if (!isFinite(r) || !isFinite(g) || !isFinite(b)) return null;
    return [r, g, b];
  }

  /** Python ScopePlot._dim：向画布底色混合，画出压暗的原始包络。 */
  function dimColor(color, factor) {
    if (factor === null || factor === undefined) factor = 0.62;
    var rgb = parseHex(color);
    var base = parseHex(THEME.bg);
    if (!rgb || !base) return color;
    return 'rgb(' + Math.round(base[0] + (rgb[0] - base[0]) * factor) + ',' +
      Math.round(base[1] + (rgb[1] - base[1]) * factor) + ',' +
      Math.round(base[2] + (rgb[2] - base[2]) * factor) + ')';
  }

  function withAlpha(color, alpha) {
    var rgb = parseHex(color);
    if (!rgb) return color;
    return 'rgba(' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ',' + alpha + ')';
  }

  function clampValue(value, low, high) {
    return value < low ? low : (value > high ? high : value);
  }

  /** X 轴标签：相对最新时刻的 +/-Ns（>6 s 用整数秒）。 */
  function xAxisLabel(delta, span) {
    var digits = span > 6 ? 0 : 1;
    var threshold = Math.pow(10, -digits) / 2;
    var value = Math.abs(delta) < threshold ? 0 : delta;
    var text = value.toFixed(digits);
    if (text.charAt(0) !== '-') text = '+' + text;
    return text + 's';
  }

  function stripSignZero(text) {
    return /^[-+]0(\.0+)?$/.test(text) ? text.slice(1) : text;
  }

  /** 图例芯片数值：float +0.00 / RAW 0000 / 整数 +0。 */
  function formatChipValue(name, value) {
    if (value === null || value === undefined || typeof value !== 'number' || !isFinite(value)) return '--';
    if (FLOAT_SERIES[name]) return formatFloat2(value);
    if (name === 'RAW') return formatRaw4(value);
    return formatIntSigned(value);
  }

  function formatFloat2(value) {
    if (Math.abs(value) < 0.005) return '+0.00';
    var text = value.toFixed(2);
    if (text.charAt(0) !== '-') text = '+' + text;
    return stripSignZero(text);
  }

  function formatRaw4(value) {
    var n = Math.round(value);
    var digits = String(Math.abs(n));
    var need = n < 0 ? 3 : 4;
    while (digits.length < need) digits = '0' + digits;
    return (n < 0 ? '-' : '') + digits;
  }

  function formatIntSigned(value) {
    var n = Math.round(value);
    var text = String(n);
    if (n >= 0) text = '+' + text;
    return stripSignZero(text);
  }

  function ellipsize(ctx, text, maxWidth) {
    if (!(maxWidth > 0)) return '';
    if (ctx.measureText(text).width <= maxWidth) return text;
    var out = text;
    while (out.length > 1) {
      out = out.slice(0, out.length - 1);
      if (ctx.measureText(out + '…').width <= maxWidth) return out + '…';
    }
    return '…';
  }

  function safeOverlayValue(overlay) {
    if (!overlay || typeof overlay.getValue !== 'function') return null;
    var value;
    try {
      value = overlay.getValue();
    } catch (error) {
      return null;
    }
    if (value === null || value === undefined) return null;
    value = Number(value);
    return isFinite(value) ? value : null;
  }

  /** 与 Python 的 split_wrap + “dt>0.12 断线” 等价：只在断点处回调区间。 */
  function eachRun(xs, ys, count, wrapThreshold, cb) {
    if (count <= 0) return;
    var start = 0;
    for (var i = 1; i < count; i++) {
      var dt = xs[i] - xs[i - 1];
      var isBreak = dt > DT_BREAK || dt < 0;
      if (!isBreak && wrapThreshold !== null && wrapThreshold !== undefined &&
          Math.abs(ys[i] - ys[i - 1]) > wrapThreshold) {
        isBreak = true;
      }
      if (isBreak) {
        if (i > start) cb(start, i);
        start = i;
      }
    }
    if (count > start) cb(start, count);
  }

  var ERROR_LIMIT = 50;

  function reportError(where, error) {
    try {
      var message = 'charts.js ' + where + ': ' +
        (error && error.message ? error.message : String(error));
      var list = global.__J280_ERRORS;
      if (!list) {
        list = [];
        global.__J280_ERRORS = list;
      }
      if (Array.isArray(list) && list.length < ERROR_LIMIT) list.push(message);
    } catch (ignored) { /* 上报失败不能影响绘制 */ }
  }

  /* =======================================================================
   * ScopePlot
   * ==================================================================== */

  function ScopePlot(canvas, opts) {
    opts = opts || {};
    var ctx = (canvas && typeof canvas.getContext === 'function') ? canvas.getContext('2d') : null;
    if (!ctx) throw new TypeError('J280Charts.createPlot: canvas 无效或 2D 上下文不可用');

    this.canvas = canvas;
    this.ctx = ctx;
    this.key = opts.key || canvas.id || 'chart';
    this.title = opts.title || '';
    this.unit = opts.unit || '';
    this.series = Array.isArray(opts.series) ? opts.series.slice() : [];
    // 标题可由外层 HUD 标题条渲染（app.js 传 drawTitle:false），此时减小顶部内边距
    this._topMargin = (opts.topMargin === null || opts.topMargin === undefined)
      ? M.top : Number(opts.topMargin);
    this._drawTitleEnabled = opts.drawTitle !== false;
    this.includeZero = !!opts.includeZero;
    this.symmetric = !!opts.symmetric;
    this.wrapThreshold = (opts.wrapThreshold === null || opts.wrapThreshold === undefined)
      ? null : Number(opts.wrapThreshold);

    this.hidden = new Set();
    this.overlays = [];
    this.yrange = null;
    this.view = null;
    this.chips = [];
    this.dpr = 1;
    this.cssW = 0;
    this.cssH = 0;
    this._destroyed = false;

    this._seriesBuf = {};        // 每系列有效样本缓冲（scratch，逐帧重算）
    this._sx = new Float64Array(0);
    this._sy = new Float64Array(0);
    this._px = new Float64Array(0);
    this._py = new Float64Array(0);
    this._envIdx = new Int32Array(0);

    this._measure(true);

    var self = this;
    if (typeof global.ResizeObserver === 'function') {
      this._ro = new global.ResizeObserver(function () { self._measure(false); });
      this._ro.observe(canvas);
    } else {
      this._ro = null;
    }
    this._onWindowResize = function () { self._measure(false); };
    if (global.addEventListener) global.addEventListener('resize', this._onWindowResize);
  }

  /* ---------------------------- 尺寸 / DPR ---------------------------- */

  ScopePlot.prototype._measure = function (force) {
    var rect = null;
    try {
      rect = this.canvas.getBoundingClientRect();
    } catch (error) {
      rect = null;
    }
    var w = rect ? rect.width : 0;
    var h = rect ? rect.height : 0;
    var dpr = Math.min(Math.max(global.devicePixelRatio || 1, 1), 2);
    if (!(w >= 2) || !(h >= 2)) {
      if (!this.cssW || !this.cssH) {
        w = 520;   // 尚未布局/脱离文档时的兜底尺寸，ResizeObserver 会立刻纠正
        h = 140;
      } else {
        w = this.cssW;
        h = this.cssH;
      }
    }
    w = Math.round(w);
    h = Math.round(h);
    if (!force && w === this.cssW && h === this.cssH && dpr === this.dpr) return;
    this.cssW = w;
    this.cssH = h;
    this.dpr = dpr;
    var bw = Math.max(1, Math.round(w * dpr));
    var bh = Math.max(1, Math.round(h * dpr));
    if (this.canvas.width !== bw) this.canvas.width = bw;
    if (this.canvas.height !== bh) this.canvas.height = bh;
  };

  ScopePlot.prototype._plotRect = function () {
    var top = this._topMargin;
    return {
      x: M.left,
      y: top,
      w: Math.max(10, this.cssW - M.left - M.right),
      h: Math.max(10, this.cssH - top - M.bottom)
    };
  };

  /* ----------------------------- 坐标换算 ----------------------------- */

  ScopePlot.prototype.xOf = function (stamp) {
    var v = this.view;
    if (!v) return 0;
    return v.x + (stamp - v.t0) / (v.t1 - v.t0) * v.pw;
  };

  ScopePlot.prototype.yOf = function (value) {
    var v = this.view;
    if (!v) return 0;
    return v.y + (v.yHigh - value) / (v.yHigh - v.yLow) * v.ph;
  };

  /**
   * 画布 CSS 像素 x → 时间戳（Lead 追加的跨图光标联动接口）。
   * 无视图、x 在绘图区之外、或结果超出 [t0, t1] 时返回 null。
   */
  ScopePlot.prototype.timeAt = function (x) {
    var v = this.view;
    if (!v || typeof x !== 'number' || !isFinite(x)) return null;
    if (!(v.pw > 0)) return null;
    if (x < v.x || x > v.x + v.pw) return null;
    var stamp = v.t0 + (x - v.x) / v.pw * (v.t1 - v.t0);
    if (!isFinite(stamp) || stamp < v.t0 || stamp > v.t1) return null;
    return stamp;
  };

  ScopePlot.prototype.getViewRange = function () {
    var v = this.view;
    if (!v) return null;
    return { t0: v.t0, t1: v.t1 };
  };

  /* ------------------------------- 绘制 ------------------------------- */

  ScopePlot.prototype.draw = function (times, rows, t0, t1, settings) {
    if (this._destroyed) return;
    try {
      if (this.cssW < 2 || this.cssH < 2) {
        this._measure(true);
        if (this.cssW < 2 || this.cssH < 2) return;
      }
      this._draw(times, rows, t0, t1, settings || {});
    } catch (error) {
      reportError('draw(' + this.key + ')', error);
    }
  };

  ScopePlot.prototype._draw = function (times, rows, t0, t1, settings) {
    var ctx = this.ctx;
    var w = this.cssW;
    var h = this.cssH;
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = CHART_BG;
    ctx.fillRect(0, 0, w, h);

    var n = Math.min(times ? times.length : 0, rows ? rows.length : 0);
    if (!rows || !times || n <= 0 || !(t1 > t0)) {
      this.view = null;
      this.chips = [];
      this._drawEmpty(ctx, w, h);
      return;
    }

    var mode = (settings.mode === '原始' || settings.mode === '叠加') ? settings.mode : '趋势';
    var tauMs = Number(settings.tauMs);
    if (!isFinite(tauMs) || tauMs <= 0) tauMs = 40;
    var lockY = !!settings.lockY;

    // 1) 逐系列抽取有效样本（null / NaN 全部过滤）
    var prepared = [];
    var byName = {};
    var i, j;
    for (i = 0; i < this.series.length; i++) {
      var name = this.series[i];
      var buf = this._fillValid(times, rows, n, name);
      prepared.push(buf);
      byName[name] = buf;
    }

    // 2) 自动 Y 范围（可见系列 + overlay；全部隐藏时回退到全部系列，避免范围乱跳）
    var lo = Infinity;
    var hi = -Infinity;
    var used = false;
    for (i = 0; i < prepared.length; i++) {
      if (this.hidden.has(prepared[i].name)) continue;
      var ys0 = prepared[i].y;
      var m0 = prepared[i].count;
      for (j = 0; j < m0; j++) {
        var v0 = ys0[j];
        if (v0 < lo) lo = v0;
        if (v0 > hi) hi = v0;
      }
      if (m0) used = true;
    }
    for (i = 0; i < this.overlays.length; i++) {
      var ov = safeOverlayValue(this.overlays[i]);
      if (ov === null) continue;
      if (ov < lo) lo = ov;
      if (ov > hi) hi = ov;
      used = true;
    }
    if (!used) {
      for (i = 0; i < prepared.length; i++) {
        var ys1 = prepared[i].y;
        var m1 = prepared[i].count;
        for (j = 0; j < m1; j++) {
          var v1 = ys1[j];
          if (v1 < lo) lo = v1;
          if (v1 > hi) hi = v1;
        }
        if (m1) used = true;
      }
    }
    if (!used) {
      lo = 0;
      hi = 0;
    }
    if (this.includeZero) {
      if (lo > 0) lo = 0;
      if (hi < 0) hi = 0;
    }
    if (this.symmetric) {
      var bound = Math.max(Math.abs(lo), Math.abs(hi), 1e-6);
      lo = -bound;
      hi = bound;
    }
    var pad = (hi - lo < 1e-9) ? Math.max(Math.abs(hi) * 0.1, 1.0) : (hi - lo) * 0.10;
    var target = [lo - pad, hi + pad];
    if (!(lockY && this.yrange)) this.yrange = smoothRange(this.yrange, target);
    var yLow = this.yrange ? this.yrange[0] : target[0];
    var yHigh = this.yrange ? this.yrange[1] : target[1];
    if (!isFinite(yLow) || !isFinite(yHigh) || !(yHigh > yLow)) {
      yLow = -1;
      yHigh = 1;
      this.yrange = [yLow, yHigh];
    }

    var t0n = Number(t0);
    var t1n = Number(t1);
    if (!isFinite(t0n) || !isFinite(t1n) || !(t1n > t0n)) {
      this.view = null;
      this.chips = [];
      this._drawEmpty(ctx, w, h);
      return;
    }

    var rect = this._plotRect();
    this.view = {
      t0: t0n, t1: t1n,
      yLow: yLow, yHigh: yHigh,
      x: rect.x, y: rect.y, pw: rect.w, ph: rect.h
    };

    // 3) 网格 / 刻度 / 0 线
    this._drawGrid(ctx);
    // 4) overlay 参考线（限幅 / 死区 / 目标）
    this._drawOverlays(ctx, yLow, yHigh);
    // 5) 曲线
    for (i = 0; i < prepared.length; i++) {
      if (this.hidden.has(prepared[i].name)) continue;
      this._drawSeries(ctx, prepared[i], mode, tauMs);
    }
    // 6) 绘图区边框
    ctx.setLineDash([]);
    ctx.lineWidth = 1;
    ctx.strokeStyle = THEME.band;
    ctx.strokeRect(Math.round(rect.x) + 0.5, Math.round(rect.y) + 0.5,
      Math.max(1, Math.round(rect.w) - 1), Math.max(1, Math.round(rect.h) - 1));
    // 7) 标题（左上）与图例芯片（右上，含最新值）
    var chips = this._layoutChips(ctx, w, byName);
    this._drawTitle(ctx, w, chips);
    this._paintChips(ctx, chips);
    this.chips = chips;
    // 8) 跨图十字光标（最后画，保证在最上层）
    if (settings.crosshair) this._drawCrosshair(ctx, settings.crosshair);
  };

  ScopePlot.prototype._drawEmpty = function (ctx, w, h) {
    this._drawTitle(ctx, w, null);
    ctx.save();
    ctx.font = FONT_EMPTY;
    ctx.fillStyle = THEME.dim;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText('等待串口遥测…', w / 2, h / 2);
    ctx.restore();
  };

  ScopePlot.prototype._drawGrid = function (ctx) {
    var v = this.view;
    if (!v) return;
    var left = v.x, top = v.y, pw = v.pw, ph = v.ph;
    var i, tick, y, x;
    ctx.save();
    ctx.lineWidth = 1;

    // Y 轴：niceTicks 4 个（与原 Tk 一致）
    ctx.font = FONT_TICK;
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'right';
    var yTicks = niceTicks(v.yLow, v.yHigh, 4);
    ctx.strokeStyle = THEME.grid;
    ctx.beginPath();
    for (i = 0; i < yTicks.length; i++) {
      y = Math.round(this.yOf(yTicks[i])) + 0.5;
      if (y < top - 1 || y > top + ph + 1) continue;
      ctx.moveTo(left, y);
      ctx.lineTo(left + pw, y);
    }
    ctx.stroke();
    ctx.fillStyle = THEME.axis;
    for (i = 0; i < yTicks.length; i++) {
      y = this.yOf(yTicks[i]);
      if (y < top - 1 || y > top + ph + 1) continue;
      ctx.fillText(formatTick(yTicks[i]), left - 6, y);
    }

    // X 轴：相对最新时刻的 +/-Ns
    var span = v.t1 - v.t0;
    var xTicks = niceTicks(v.t0, v.t1, 6);
    ctx.strokeStyle = THEME.grid2;
    ctx.beginPath();
    for (i = 0; i < xTicks.length; i++) {
      x = Math.round(this.xOf(xTicks[i])) + 0.5;
      if (x < left - 1 || x > left + pw + 1) continue;
      ctx.moveTo(x, top);
      ctx.lineTo(x, top + ph);
    }
    ctx.stroke();
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    ctx.fillStyle = THEME.axis;
    for (i = 0; i < xTicks.length; i++) {
      x = this.xOf(xTicks[i]);
      if (x < left - 1 || x > left + pw + 1) continue;
      var label = xAxisLabel(xTicks[i] - v.t1, span);
      var half = ctx.measureText(label).width / 2;
      var tx = Math.max(half + 2, Math.min(this.cssW - half - 2, x));
      ctx.fillText(label, tx, top + ph + 4);
    }

    // 0 线（范围内才画）
    if (v.yLow <= 0 && v.yHigh >= 0) {
      y = Math.round(this.yOf(0)) + 0.5;
      ctx.strokeStyle = THEME.zero;
      ctx.setLineDash([4, 3]);
      ctx.beginPath();
      ctx.moveTo(left, y);
      ctx.lineTo(left + pw, y);
      ctx.stroke();
      ctx.setLineDash([]);
    }
    ctx.restore();
  };

  ScopePlot.prototype._drawOverlays = function (ctx, yLow, yHigh) {
    var v = this.view;
    if (!v || !this.overlays.length) return;
    var i;
    var labels = [];
    ctx.save();
    ctx.font = FONT_TICK;
    ctx.lineWidth = 1;
    for (i = 0; i < this.overlays.length; i++) {
      var overlay = this.overlays[i];
      var value = safeOverlayValue(overlay);
      if (value === null || value < yLow || value > yHigh) continue;
      var y = Math.round(this.yOf(value)) + 0.5;
      var color = overlay.color || THEME.dim;
      ctx.strokeStyle = color;
      ctx.setLineDash(overlay.dash && overlay.dash.length ? overlay.dash : [4, 3]);
      ctx.beginPath();
      ctx.moveTo(v.x, y);
      ctx.lineTo(v.x + v.pw, y);
      ctx.stroke();
      labels.push({ y: y, text: overlay.name || '', color: color });
    }
    ctx.setLineDash([]);
    // 右端名称：按屏幕位置排序并保持 10px 最小间距，避免 ±LIM/±DZ 窄带标签互相覆盖
    labels.sort(function (a, b) { return a.y - b.y; });
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';
    var lastY = -Infinity;
    for (i = 0; i < labels.length; i++) {
      // 贴近上下边框时把标签挪到线的另一侧，避免标签被边框/虚线穿过
      var preferred = labels[i].y - 7;
      if (preferred < v.y + 9) preferred = labels[i].y + 9;
      if (preferred > v.y + v.ph - 9) preferred = labels[i].y - 9;
      var labelY = Math.max(preferred, lastY + 10);
      labelY = Math.min(labelY, v.y + v.ph - 6);
      if (labels[i].text) {
        ctx.fillStyle = labels[i].color;
        ctx.fillText(labels[i].text, v.x + v.pw - 3, labelY);
      }
      lastY = labelY;
    }
    ctx.restore();
  };

  ScopePlot.prototype._drawSeries = function (ctx, buf, mode, tauMs) {
    var name = buf.name;
    var color = colorOf(name);
    var xs = buf.x;
    var ys = buf.y;
    var m = buf.count;
    if (!m) return;
    var wrap = this.wrapThreshold;

    if (name === 'REF' || name === 'TGT') {
      // 参考/目标通常是阶跃线：趋势模式不套低通；原始模式仍用包络保留台阶。
      if (mode === '原始') this._strokeRuns(ctx, xs, ys, m, dimColor(color), 1.3, true, false);
      else this._strokeRuns(ctx, xs, ys, m, color, 2.0, false, false);
      return;
    }
    if (mode === '原始') {
      this._strokeRuns(ctx, xs, ys, m, dimColor(color), 1.3, true, false);
    } else if (mode === '趋势') {
      var trendCount = this._lowPass(xs, ys, m, tauMs, wrap);
      this._strokeRuns(ctx, this._sx, this._sy, trendCount, color, 2.2, false, true);
    } else {
      // 叠加：暗色原始包络 + 亮色趋势折线
      this._strokeRuns(ctx, xs, ys, m, dimColor(color), 1.3, true, false);
      var trendCount2 = this._lowPass(xs, ys, m, tauMs, wrap);
      this._strokeRuns(ctx, this._sx, this._sy, trendCount2, color, 2.2, false, true);
    }
  };

  ScopePlot.prototype._lowPass = function (xs, ys, n, tauMs, wrap) {
    if (this._sx.length < n) {
      this._sx = new Float64Array(n);
      this._sy = new Float64Array(n);
    }
    lowPassInto(xs, ys, n, tauMs, wrap, this._sx, this._sy);
    return n;
  };

  ScopePlot.prototype._strokeRuns = function (ctx, xs, ys, count, color, width, useEnvelope, smooth) {
    var self = this;
    var v = this.view;
    if (!v || count <= 0) return;
    var columns = Math.max(60, Math.floor(v.pw));
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.setLineDash([]);
    eachRun(xs, ys, count, this.wrapThreshold, function (start, end) {
      if (useEnvelope) self._strokeEnvelopeRun(ctx, xs, ys, start, end, columns);
      else self._strokeThinRun(ctx, xs, ys, start, end, smooth);
    });
  };

  ScopePlot.prototype._strokeEnvelopeRun = function (ctx, xs, ys, start, end, columns) {
    var capacity = columns * 4 + 8;
    if (this._envIdx.length < capacity) this._envIdx = new Int32Array(capacity);
    var m = envelopeIndices(xs, ys, start, end, this.view.t0, this.view.t1, columns, this._envIdx);
    if (m < 2) return;
    var v = this.view;
    var i, index;
    ctx.beginPath();
    for (i = 0; i < m; i++) {
      index = this._envIdx[i];
      if (i === 0) {
        ctx.moveTo(this.xOf(xs[index]), this.yOf(clampValue(ys[index], v.yLow, v.yHigh)));
      } else {
        ctx.lineTo(this.xOf(xs[index]), this.yOf(clampValue(ys[index], v.yLow, v.yHigh)));
      }
    }
    ctx.stroke();
  };

  ScopePlot.prototype._strokeThinRun = function (ctx, xs, ys, start, end, smooth) {
    var v = this.view;
    if (!v) return;
    var total = end - start;
    if (total <= 0) return;
    var limit = Math.max(2, Math.floor(v.pw));
    var step = total > limit ? Math.ceil(total / limit) : 1;
    var i;

    if (smooth) {
      var need = Math.ceil(total / step) + 2;
      if (this._px.length < need) {
        this._px = new Float64Array(need);
        this._py = new Float64Array(need);
      }
      var px = this._px;
      var py = this._py;
      var k = 0;
      var lastIndex = -1;
      for (i = start; i < end; i += step) {
        px[k] = this.xOf(xs[i]);
        py[k] = this.yOf(clampValue(ys[i], v.yLow, v.yHigh));
        lastIndex = i;
        k++;
      }
      if (lastIndex !== end - 1) {
        px[k] = this.xOf(xs[end - 1]);
        py[k] = this.yOf(clampValue(ys[end - 1], v.yLow, v.yHigh));
        k++;
      }
      if (k < 2) return;
      // Tk smooth=True 的近似：相邻中点之间用二次曲线，端点保持精确
      ctx.beginPath();
      ctx.moveTo(px[0], py[0]);
      if (k > 2) {
        for (i = 1; i < k - 1; i++) {
          ctx.quadraticCurveTo(px[i], py[i],
            (px[i] + px[i + 1]) * 0.5, (py[i] + py[i + 1]) * 0.5);
        }
      }
      ctx.lineTo(px[k - 1], py[k - 1]);
      ctx.stroke();
      return;
    }

    ctx.beginPath();
    var first = true;
    var lastEmitted = -1;
    for (i = start; i < end; i += step) {
      var cx = this.xOf(xs[i]);
      var cy = this.yOf(clampValue(ys[i], v.yLow, v.yHigh));
      if (first) {
        ctx.moveTo(cx, cy);
        first = false;
      } else {
        ctx.lineTo(cx, cy);
      }
      lastEmitted = i;
    }
    if (lastEmitted !== end - 1) {
      var lx = this.xOf(xs[end - 1]);
      var ly = this.yOf(clampValue(ys[end - 1], v.yLow, v.yHigh));
      if (first) ctx.moveTo(lx, ly); else ctx.lineTo(lx, ly);
    }
    ctx.stroke();
  };

  ScopePlot.prototype._layoutChips = function (ctx, width, byName) {
    var chips = [];
    var right = width - M.right;
    var chipH = 15;
    ctx.save();
    ctx.font = FONT_CHIP;
    for (var i = this.series.length - 1; i >= 0; i--) {
      var name = this.series[i];
      var buf = byName[name];
      var latest = (buf && buf.count > 0) ? buf.y[buf.count - 1] : null;
      var label = name + ' ' + formatChipValue(name, latest);
      var chipW = Math.ceil(ctx.measureText(label).width) + 10;
      var x0 = right - chipW;
      if (x0 < M.left + 2) break;    // 空间不足时不再画（避免压住标题）
      chips.push({
        name: name, label: label, color: colorOf(name),
        x0: x0, y0: 2, x1: right, y1: 2 + chipH
      });
      right = x0 - 6;
    }
    ctx.restore();
    return chips;
  };

  ScopePlot.prototype._drawTitle = function (ctx, width, chips) {
    if (!this._drawTitleEnabled) return;
    if (!this.title && !this.unit) return;
    var text = this.title + (this.unit ? ' [' + this.unit + ']' : '');
    var limit = (chips && chips.length)
      ? (chips[chips.length - 1].x0 - 8 - M.left)
      : (width - M.right - M.left);
    ctx.save();
    ctx.font = FONT_TITLE;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    ctx.fillStyle = THEME.text;
    ctx.fillText(ellipsize(ctx, text, Math.max(16, limit)), M.left, 2);
    ctx.restore();
  };

  ScopePlot.prototype._paintChips = function (ctx, chips) {
    if (!chips.length) return;
    var i;
    ctx.save();
    ctx.font = FONT_CHIP;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    for (i = 0; i < chips.length; i++) {
      var chip = chips[i];
      var width = chip.x1 - chip.x0;
      var height = chip.y1 - chip.y0;
      if (this.hidden.has(chip.name)) {
        ctx.fillStyle = 'rgba(7,19,32,0.9)';
        ctx.fillRect(chip.x0, chip.y0, width, height);
        ctx.strokeStyle = withAlpha(chip.color, 0.45);
        ctx.lineWidth = 1;
        ctx.strokeRect(chip.x0 + 0.5, chip.y0 + 0.5, width - 1, height - 1);
        ctx.fillStyle = withAlpha(chip.color, 0.55);
      } else {
        ctx.fillStyle = chip.color;
        ctx.fillRect(chip.x0, chip.y0, width, height);
        ctx.fillStyle = THEME.bg;
      }
      ctx.fillText(chip.label, chip.x0 + width / 2, chip.y0 + height / 2 + 0.5);
    }
    ctx.restore();
  };

  ScopePlot.prototype._drawCrosshair = function (ctx, crosshair) {
    var v = this.view;
    if (!v || !crosshair || typeof crosshair.t !== 'number' || !isFinite(crosshair.t)) return;
    if (crosshair.t < v.t0 || crosshair.t > v.t1) return;
    var x = this.xOf(crosshair.t);
    var row = crosshair.row || null;
    var i, name, value, color, y;

    ctx.save();
    ctx.strokeStyle = withAlpha(THEME.cross, 0.85);
    ctx.lineWidth = 1;
    ctx.setLineDash([3, 3]);
    ctx.beginPath();
    ctx.moveTo(x, v.y);
    ctx.lineTo(x, v.y + v.ph);
    ctx.stroke();
    ctx.setLineDash([]);

    var parts = [];
    for (i = 0; i < this.series.length; i++) {
      name = this.series[i];
      if (this.hidden.has(name)) continue;
      value = this._rowValue(row, name);
      if (value === null) continue;
      y = this.yOf(clampValue(value, v.yLow, v.yHigh));
      color = colorOf(name);
      ctx.beginPath();
      ctx.arc(x, y, 3.2, 0, Math.PI * 2);
      ctx.fillStyle = THEME.bg;
      ctx.fill();
      ctx.strokeStyle = color;
      ctx.lineWidth = 1.5;
      ctx.stroke();
      parts.push(name + ' ' + (FLOAT_SERIES[name] ? formatFloat2(value) : formatIntSigned(value)));
    }

    if (parts.length) {
      var text = parts.join('   ');
      ctx.font = FONT_CROSS;
      ctx.textBaseline = 'top';
      var textWidth = ctx.measureText(text).width;
      var tx, align;
      if (x + 8 + textWidth <= this.cssW - 2) {
        tx = x + 8;
        align = 'left';
      } else if (x - 8 - textWidth >= 2) {
        tx = x - 8;
        align = 'right';
      } else {
        tx = Math.max(2, Math.min(this.cssW - 2 - textWidth, x + 8));
        align = 'left';
      }
      ctx.textAlign = align;
      ctx.fillStyle = THEME.cross;
      ctx.fillText(text, tx, v.y + 3);
    }
    ctx.restore();
  };

  /* --------------------------- 公开方法 --------------------------- */

  ScopePlot.prototype.setOverlays = function (list) {
    this.overlays = [];
    if (!Array.isArray(list)) return;
    for (var i = 0; i < list.length; i++) {
      var item = list[i];
      if (!item || typeof item.getValue !== 'function') continue;
      this.overlays.push({
        name: item.name === null || item.name === undefined ? '' : String(item.name),
        getValue: item.getValue,
        color: item.color || THEME.dim,
        dash: Array.isArray(item.dash) ? item.dash.slice() : [4, 3]
      });
    }
  };

  ScopePlot.prototype.legendHitTest = function (x, y) {
    if (typeof x !== 'number' || typeof y !== 'number') return null;
    for (var i = 0; i < this.chips.length; i++) {
      var chip = this.chips[i];
      if (x >= chip.x0 && x <= chip.x1 && y >= chip.y0 && y <= chip.y1) {
        if (this.hidden.has(chip.name)) this.hidden.delete(chip.name);
        else this.hidden.add(chip.name);
        return chip.name;
      }
    }
    return null;
  };

  ScopePlot.prototype.resetRange = function () {
    this.yrange = null;
  };

  ScopePlot.prototype.destroy = function () {
    this._destroyed = true;
    if (this._ro) {
      try { this._ro.disconnect(); } catch (ignored) { /* 忽略 */ }
      this._ro = null;
    }
    if (global.removeEventListener && this._onWindowResize) {
      global.removeEventListener('resize', this._onWindowResize);
    }
    this._onWindowResize = null;
    this.ctx = null;
    this.canvas = null;
    this.view = null;
    this.chips = [];
  };

  /* --------------------------- 内部数据/工具 --------------------------- */

  ScopePlot.prototype._bufFor = function (name) {
    var buf = this._seriesBuf[name];
    if (!buf) {
      buf = { name: name, count: 0, x: new Float64Array(0), y: new Float64Array(0) };
      this._seriesBuf[name] = buf;
    }
    return buf;
  };

  ScopePlot.prototype._fillValid = function (times, rows, n, name) {
    var buf = this._bufFor(name);
    if (buf.x.length < n) {
      buf.x = new Float64Array(n);
      buf.y = new Float64Array(n);
    }
    var xs = buf.x;
    var ys = buf.y;
    var key = name.toLowerCase();
    var count = 0;
    for (var i = 0; i < n; i++) {
      var row = rows[i];
      if (!row) continue;
      var value = row[key];
      if (value === undefined) value = row[name];   // 兼容大写键
      if (value === null || typeof value !== 'number' || !isFinite(value)) continue;
      xs[count] = times[i];
      ys[count] = value;
      count++;
    }
    buf.count = count;
    return buf;
  };

  ScopePlot.prototype._rowValue = function (row, name) {
    if (!row) return null;
    var value = row[name.toLowerCase()];
    if (value === undefined) value = row[name];
    if (value === null || value === undefined) return null;
    value = Number(value);
    return isFinite(value) ? value : null;
  };

  /* =======================================================================
   * 导出
   * ==================================================================== */

  global.J280Charts = {
    ENC_CPR: ENC_CPR,
    THEME: THEME,
    SERIES_STYLE: SERIES_STYLE,
    niceTicks: niceTicks,
    formatTick: formatTick,
    splitWrap: splitWrap,
    envelope: envelope,
    trendPoints: trendPoints,
    smoothRange: smoothRange,
    windowStats: windowStats,
    estimateOscillation: estimateOscillation,
    countReversals: countReversals,
    diagnose: diagnose,
    createPlot: function (canvas, opts) {
      return new ScopePlot(canvas, opts);
    }
  };
})(window);
