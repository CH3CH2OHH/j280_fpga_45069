/* J280 自动化测试用的遥测注入源（产品界面不加载此文件）。
 * 用法（Qt 测试脚本）：
 *   1) runJavaScript(本文件内容)
 *   2) runJavaScript("window.__J280_TEST_FEED.start()")
 * 通过公开测试接口 J280_APP.test.injectTelemetry() 以 100 Hz 送入合成样本，
 * 仅用于截图/交互测试，不代表真实倒立摆动力学。
 */
(function (window) {
  'use strict';
  var FRAME_SECONDS = 0.01;
  var BATCH = 5;
  var INTERVAL_MS = 50;

  function noise(amplitude) { return (Math.random() * 2 - 1) * amplitude; }

  var feed = {
    timer: null,
    frame: 0,
    posContinuous: 0,
    start: function () {
      this.stop();
      this.frame = 0;
      this.posContinuous = 0;
      var self = this;
      this.timer = window.setInterval(function () { self.tick(); }, INTERVAL_MS);
      this.tick();
    },
    stop: function () {
      if (this.timer !== null) {
        window.clearInterval(this.timer);
        this.timer = null;
      }
    },
    tick: function () {
      var rows = [];
      for (var i = 0; i < BATCH; i++) {
        this.frame += 1;
        rows.push(this.row());
      }
      var app = window.J280_APP;
      if (app && app.test && typeof app.test.injectTelemetry === 'function') {
        app.test.injectTelemetry(rows);
      }
    },
    row: function () {
      var t = this.frame * FRAME_SECONDS;
      var omega = 2 * Math.PI / 7.2;
      var posVelocity = 470 * omega * Math.cos(omega * t);
      this.posContinuous += posVelocity * FRAME_SECONDS;
      var posWrapped = ((this.posContinuous + 520) % 1040 + 1040) % 1040 - 520;
      var pos = Math.round(posWrapped);
      if (pos > 519) pos = 519;
      if (pos < -520) pos = -520;
      var ang = 1.15 * Math.sin(2 * Math.PI * 1.72 * t) +
        0.22 * Math.sin(2 * Math.PI * 0.23 * t) + noise(0.04);
      var ref = -0.4 + 0.18 * Math.sin(2 * Math.PI * 0.31 * t);
      var dut = -ang * 150;
      if (dut > 300) dut = 300;
      if (dut < -300) dut = -300;
      var raw = Math.round(508 + ang / 0.332 + noise(1.6));
      if (raw < 0) raw = 0;
      if (raw > 1023) raw = 1023;
      return {
        t: Math.round(t * 100) / 100,
        ang: Math.round(ang * 100) / 100,
        raw: raw,
        pos: pos,
        abs: Math.round(this.posContinuous),
        spd: Math.round(Math.round(posVelocity / 62.5) * 62.5),
        dut: Math.round(dut),
        ref: Math.round(ref * 100) / 100,
        mode: 1,
        st: 5,
        sw: false,
        src: false,
        hld: false,
        ver: 'y6',
        cc: 6
      };
    }
  };

  window.__J280_TEST_FEED = feed;
}(window));
