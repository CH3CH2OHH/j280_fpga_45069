/*!
 * J280 · res/js/model3d.js
 * 旋转倒立摆（Rotary Inverted Pendulum）three.js 实时视图。
 * 依赖 ../vendor/three.min.js（r149 UMD，全局 THREE）；经典 script，无 ES module、无网络请求。
 * 暴露唯一全局：window.J280Model3D = { create(container, opts) -> PendulumView }
 *
 * PendulumView:
 *   update(state)              // 每帧由 app.js 调用；只写目标值，渲染循环内做平滑
 *   resize()                   // 容器尺寸变化时（内部另有 ResizeObserver 自适应）
 *   setCamera('iso'|'front'|'top')
 *   resetCamera()
 *   dispose()
 *   getStats()                 // 额外：{fps, triangles, calls, w, h, dpr}，供自测/性能核对
 *
 * state（spec §7.1；单位经 Lead 确认）：
 *   ang  摆杆角度 deg（相对竖直，0=竖直向上，可为 null）
 *   ref  参考角 deg（可为 null）
 *   pos  摆臂单圈相位 -520..+519（1040 count/圈）
 *   spd  摆臂速度 count/s（= dPOS/dt，仅用于量化速度感/待机，不参与姿态映射）
 *   dut  输出 duty（带符号）
 *   mode 0/1/2；st 状态位（bit0 接管窗口 / bit1 保护 / bit2 已接管 / bit3 保护暂停）
 *   sw   起摆状态机运行 bool|null
 *   lim  PWM 限幅 duty（整数）；dz 死区 duty（整数）
 *   enter/fall 接管/判倒角，单位 deg（app.js 已 /100 换算，本文件不再除 100）
 *   connected bool
 *
 * ---------------------------------------------------------------------------
 * 角度映射（契约 §7.1，务必与固件一致）：
 *   armYaw = pos / 1040 * 2π      // 摆臂绕世界 Y 轴偏航；POS 增加 → 偏航角增加，
 *                                 // 与 SPD（= dPOS/dt）同号，故方向一致。
 *   tilt   = ang * π / 180        // 摆杆相对竖直的倾角。
 *   摆杆在摆臂本地坐标系中绕 +X（摆臂的径向轴）旋转 -tilt：
 *     rodDir_local = (0, cos(tilt), -sin(tilt))
 *     → ang > 0 时摆杆向本地 -Z 倾斜；ang = 0 竖直向上；ang < 0 向 +Z。
 *   REF 幽灵杆同理：refTilt = ref * π / 180，绕同一轴旋转 -refTilt。
 *   世界坐标 = armGroup.rotation.y(armYaw) × (hinge + rodDir_local * L)。
 * ---------------------------------------------------------------------------
 */
(function () {
  'use strict';

  var TAU = Math.PI * 2;
  var DEG = Math.PI / 180;
  var POS_COUNTS = 1040;              // 编码器 1040 count/圈
  var LABEL_INTERVAL_MS = 110;        // 3D 数值标签节流（≥100 ms）
  var MAX_ERRORS = 60;

  // 主题色（与 style.css / charts.js 青蓝主色对齐）
  var C = {
    cyan: 0x3fe3ff,
    cyanDim: 0x1a7f9e,
    cyanDeep: 0x0b3c4e,
    green: 0x39e6a8,
    amber: 0xffc247,
    red: 0xff5d5d,
    purple: 0xb48cff,
    steel: 0xcfe6f2,
    metal: 0x84aec1,
    arm: 0x8fb6c7,
    darkSteel: 0x223b48,
    platform: 0x0e2836,
    platformTop: 0x0a2230,
    motor: 0x1b3140,
    motorDark: 0x0b1a23,
    glow: 0x1d8fb3
  };
  var CSS = {
    cyan: '#6feaff',
    amber: '#ffd36b',
    red: '#ff8a8a',
    green: '#5df0bd',
    dim: '#7fa3b8'
  };
  // 状态色（比主题青蓝更饱和，保证发光端头在 ACES 色调映射下仍能读出颜色）
  var ACC = {
    cyan: 0x00d9ff,
    amber: 0xffa600,
    red: 0xff2222,
    green: 0x00ff6a
  };

  // ---------------------------------------------------------------- 工具函数
  function clamp(v, a, b) { return v < a ? a : (v > b ? b : v); }
  function lerp(a, b, t) { return a + (b - a) * t; }
  function isNum(v) { return typeof v === 'number' && isFinite(v); }
  function nowMs() {
    return (window.performance && window.performance.now) ? window.performance.now() : Date.now();
  }
  // 帧率无关的平滑系数：dt 秒后等价于 60fps 下每帧 base 的 lerp
  function smoothK(base, dt) {
    return 1 - Math.pow(1 - clamp(base, 0.001, 0.99), clamp(dt, 0.001, 0.1) * 60);
  }
  function wrapPi(a) {
    a = (a + Math.PI) % TAU;
    if (a < 0) a += TAU;
    return a - Math.PI;
  }
  function pushError(source, err) {
    try {
      var arr = window.__J280_ERRORS;
      if (!arr || !arr.push) { arr = []; window.__J280_ERRORS = arr; }
      if (arr.length < MAX_ERRORS) {
        arr.push({
          time: new Date().toISOString(),
          source: 'model3d/' + source,
          message: String((err && err.message) || err)
        });
      }
      if (window.console && window.console.warn) window.console.warn('[J280Model3D:' + source + ']', err);
    } catch (e) { /* 错误上报本身绝不能再抛 */ }
  }

  // 一个实例的序号（用于注入的 <style> id）
  var STYLE_SEQ = 0;

  // ---------------------------------------------------------------- 公共 API
  var J280Model3D = {
    version: '1.0.0',
    create: create
  };
  window.J280Model3D = J280Model3D;

  // 降级空壳：THREE 缺失 / WebGL 不可用时保证 app.js 调用不抛异常
  function makeStub(fallbackEl) {
    return {
      update: function () {},
      resize: function () {},
      setCamera: function () {},
      resetCamera: function () {},
      dispose: function () {
        if (fallbackEl && fallbackEl.parentNode) fallbackEl.parentNode.removeChild(fallbackEl);
      },
      getStats: function () { return { fps: 0, triangles: 0, calls: 0, w: 0, h: 0, dpr: 1, fallback: true }; }
    };
  }

  function showFallback(container) {
    var el = document.createElement('div');
    el.className = 'm3d-fallback';
    el.textContent = '3D 组件未加载（three.js 缺失或 WebGL 不可用）';
    el.style.cssText = 'position:absolute;inset:0;display:flex;align-items:center;justify-content:center;' +
      'color:#7fa3b8;font:12px/1.6 "Microsoft YaHei UI",sans-serif;letter-spacing:.08em;' +
      'background:radial-gradient(circle at 50% 42%,rgba(10,40,56,.55),rgba(3,10,18,.2) 70%);' +
      'text-align:center;padding:24px;';
    try { container.appendChild(el); } catch (e) { /* ignore */ }
    return el;
  }

  // ---------------------------------------------------------------- create
  function create(container, opts) {
    opts = opts || {};

    if (!container || typeof container.appendChild !== 'function') {
      pushError('create', new Error('container 无效'));
      return makeStub(null);
    }

    // ---- THREE / WebGL 可用性检查 -------------------------------------
    if (typeof window.THREE === 'undefined' || !window.THREE.WebGLRenderer) {
      pushError('create', new Error('THREE 未加载'));
      return makeStub(showFallback(container));
    }
    var THREE = window.THREE;

    var FOV = isNum(opts.fov) ? clamp(opts.fov, 20, 70) : 38;
    var INTERACTIVE = opts.interactive !== false;
    var MAX_DPR = isNum(opts.maxPixelRatio) ? clamp(opts.maxPixelRatio, 1, 2) : 2;
    // 自测/截图用：instant=true 时跳过平滑（app.js 不传，生产仍为平滑模式）
    var INSTANT = opts.instant === true;

    var renderer = null;
    try {
      renderer = new THREE.WebGLRenderer({
        alpha: true,
        antialias: true,
        powerPreference: 'high-performance'
      });
    } catch (err) {
      pushError('webgl', err);
      return makeStub(showFallback(container));
    }
    if (!renderer || !renderer.domElement) {
      pushError('webgl', new Error('WebGLRenderer 初始化失败'));
      return makeStub(showFallback(container));
    }

    var disposed = false;
    var size = { w: 0, h: 0 };
    var sizeDirty = false;
    var styleEls = [];
    var ro = null;

    // 容器若不是定位元素，absolute 子节点会跑到别处；这里兜底 relative
    var containerStyle = window.getComputedStyle(container);
    if (containerStyle && containerStyle.position === 'static') {
      container.style.position = 'relative';
    }

    // ---- 渲染器基础 -----------------------------------------------------
    renderer.setClearColor(0x000000, 0);
    if ('outputEncoding' in renderer && THREE.sRGBEncoding !== undefined) {
      renderer.outputEncoding = THREE.sRGBEncoding;
    }
    if (THREE.ACESFilmicToneMapping !== undefined) {
      renderer.toneMapping = THREE.ACESFilmicToneMapping;
      renderer.toneMappingExposure = 1.0;
    }
    renderer.shadowMap.enabled = false;

    var canvas = renderer.domElement;
    canvas.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%;display:block;' +
      'background:transparent;touch-action:none;outline:none;cursor:grab;';
    container.appendChild(canvas);

    // ---- 场景 / 相机 / 环境 --------------------------------------------
    var scene = new THREE.Scene();
    var camera = new THREE.PerspectiveCamera(FOV, 1, 0.1, 220);
    var lookTarget = new THREE.Vector3(0, 1.58, 0);

    // ---- 共享贴图（发光点 / 环境反射）---------------------------------
    function makeGlowTexture() {
      var c = document.createElement('canvas');
      c.width = c.height = 128;
      var g = c.getContext('2d');
      var grad = g.createRadialGradient(64, 64, 0, 64, 64, 64);
      grad.addColorStop(0, 'rgba(255,255,255,1)');
      grad.addColorStop(0.22, 'rgba(255,255,255,0.62)');
      grad.addColorStop(0.55, 'rgba(255,255,255,0.18)');
      grad.addColorStop(1, 'rgba(255,255,255,0)');
      g.fillStyle = grad;
      g.fillRect(0, 0, 128, 128);
      var tex = new THREE.CanvasTexture(c);
      tex.minFilter = THREE.LinearFilter;
      tex.magFilter = THREE.LinearFilter;
      tex.generateMipmaps = false;
      if (THREE.sRGBEncoding !== undefined) tex.encoding = THREE.sRGBEncoding;
      return tex;
    }
    var glowTex = makeGlowTexture();

    var envRT = null;
    (function buildEnv() {
      // CanvasTexture + PMREM 造一张低分辨率环境图，让金属有青蓝反光（不依赖网络）
      try {
        var c = document.createElement('canvas');
        c.width = 256; c.height = 128;
        var g = c.getContext('2d');
        var grad = g.createLinearGradient(0, 0, 0, 128);
        grad.addColorStop(0, '#081826');
        grad.addColorStop(0.42, '#123a4c');
        grad.addColorStop(0.56, '#1e81a3');
        grad.addColorStop(0.63, '#0b2634');
        grad.addColorStop(1, '#02060a');
        g.fillStyle = grad;
        g.fillRect(0, 0, 256, 128);
        function blob(x, y, r, col) {
          var rg = g.createRadialGradient(x, y, 0, x, y, r);
          rg.addColorStop(0, col);
          rg.addColorStop(1, 'rgba(0,0,0,0)');
          g.fillStyle = rg;
          g.fillRect(0, 0, 256, 128);
        }
        blob(72, 40, 74, 'rgba(196,242,255,0.95)');
        blob(198, 52, 54, 'rgba(255,196,90,0.5)');
        blob(138, 96, 96, 'rgba(28,92,124,0.6)');
        var envTex = new THREE.CanvasTexture(c);
        envTex.mapping = THREE.EquirectangularReflectionMapping;
        if (THREE.sRGBEncoding !== undefined) envTex.encoding = THREE.sRGBEncoding;
        if (THREE.PMREMGenerator) {
          var pmrem = new THREE.PMREMGenerator(renderer);
          pmrem.compileEquirectangularShader();
          envRT = pmrem.fromEquirectangular(envTex);
          pmrem.dispose();
          scene.environment = envRT.texture;
        } else {
          scene.environment = envTex;
        }
        envTex.dispose();
      } catch (err) {
        pushError('envmap', err);
      }
    })();

    // ---- 灯光 -----------------------------------------------------------
    var lights = {
      ambient: new THREE.AmbientLight(0x2c6b85, 0.34),
      hemi: new THREE.HemisphereLight(0x3fe3ff, 0x02060c, 0.30),
      key: new THREE.DirectionalLight(0xe4f6ff, 1.0),
      rim: new THREE.DirectionalLight(0x2f9fc4, 0.5),
      fill: new THREE.DirectionalLight(0xffc247, 0.14),
      core: new THREE.PointLight(0x3fe3ff, 0.55, 8, 2),
      under: new THREE.PointLight(0x1d8fb3, 0.3, 4, 2)
    };
    lights.key.position.set(5.5, 9, 6.5);
    lights.rim.position.set(-6, 3.2, -5.5);
    lights.fill.position.set(-3, 1.4, 6);
    lights.core.position.set(0, 2.4, 0.4);
    lights.under.position.set(0, 0.5, 0);
    Object.keys(lights).forEach(function (k) { scene.add(lights[k]); });
    var dimLights = Object.keys(lights).map(function (k) {
      return { light: lights[k], base: lights[k].intensity };
    });

    // ---- 材质工具 -------------------------------------------------------
    function std(color, metalness, roughness, envInt) {
      return new THREE.MeshStandardMaterial({
        color: color,
        metalness: metalness,
        roughness: roughness,
        envMapIntensity: envInt === undefined ? 0.8 : envInt
      });
    }
    function additive(color, opacity) {
      return new THREE.MeshBasicMaterial({
        color: color,
        transparent: true,
        opacity: opacity,
        blending: THREE.AdditiveBlending,
        depthWrite: false,
        side: THREE.DoubleSide
      });
    }
    function addMesh(parent, geo, mat) {
      var m = new THREE.Mesh(geo, mat);
      parent.add(m);
      return m;
    }
    function addCyl(parent, rTop, rBottom, h, seg, mat, y) {
      var m = addMesh(parent, new THREE.CylinderGeometry(rTop, rBottom, h, seg), mat);
      m.position.y = y || 0;
      return m;
    }
    function addTorus(parent, radius, tube, mat, y) {
      var m = addMesh(parent, new THREE.TorusGeometry(radius, tube, 6, 128), mat);
      m.rotation.x = Math.PI / 2;
      m.position.y = y || 0;
      return m;
    }

    var dimMats = [];       // 静态自发光材质（mode 0 整体压暗
    function regDim(mat, emissiveBase, opacityBase) {
      dimMats.push({ mat: mat, e: emissiveBase, o: (opacityBase === undefined ? null : opacityBase) });
      return mat;
    }

    // =====================================================================
    // 1) 圆形金属平台 + 同心发光+ 辐射网格 + 光晕
    // =====================================================================
    var platformGroup = new THREE.Group();
    scene.add(platformGroup);

    var matBase = std(0x0b202b, 0.9, 0.32, 0.5);

    // 平台顶面：径向拉+ 暗刻线纹理（CanvasTexture，不依赖网络
    function makePlatformTexture() {
      var cv = document.createElement('canvas');
      cv.width = cv.height = 512;
      var g = cv.getContext('2d');
      var rg = g.createRadialGradient(256, 256, 6, 256, 256, 256);
      rg.addColorStop(0, 'rgba(22,54,66,0.98)');
      rg.addColorStop(0.52, 'rgba(10,30,40,0.98)');
      rg.addColorStop(0.86, 'rgba(16,44,56,0.98)');
      rg.addColorStop(1, 'rgba(7,20,27,1)');
      g.fillStyle = rg;
      g.beginPath();
      g.arc(256, 256, 256, 0, TAU);
      g.fill();
      // 细同心拉丝（用固定相位避免噪点闪烁）
      g.lineWidth = 1;
      for (var r = 12; r < 254; r += 2) {
        var alpha = 0.016 + 0.028 * (0.5 + 0.5 * Math.sin(r * 1.7));
        g.strokeStyle = 'rgba(126,196,222,' + alpha.toFixed(4) + ')';
        g.beginPath();
        g.arc(256, 256, r, 0, TAU);
        g.stroke();
      }
      // 15° 暗刻
      for (var a = 0; a < 360; a += 15) {
        var rad = a * Math.PI / 180;
        g.strokeStyle = 'rgba(84,190,220,0.10)';
        g.lineWidth = a % 90 === 0 ? 2 : 1;
        g.beginPath();
        g.moveTo(256 + Math.cos(rad) * 78, 256 + Math.sin(rad) * 78);
        g.lineTo(256 + Math.cos(rad) * 250, 256 + Math.sin(rad) * 250);
        g.stroke();
      }
      var tex = new THREE.CanvasTexture(cv);
      tex.minFilter = THREE.LinearFilter;
      tex.magFilter = THREE.LinearFilter;
      tex.generateMipmaps = false;
      if (THREE.sRGBEncoding !== undefined) tex.encoding = THREE.sRGBEncoding;
      return tex;
    }
    var matTop = new THREE.MeshStandardMaterial({
      map: makePlatformTexture(),
      color: 0xdceef5,
      metalness: 0.92,
      roughness: 0.38,
      envMapIntensity: 0.5
    });
    var matUnder = std(0x06121a, 0.8, 0.55, 0.25);

    var platBase = addMesh(platformGroup, new THREE.CylinderGeometry(2.44, 2.54, 0.18, 96), matBase);
    platBase.position.y = 0.09;
    var platTop = addMesh(platformGroup, new THREE.CircleGeometry(2.40, 96), matTop);
    platTop.rotation.x = -Math.PI / 2;
    platTop.position.y = 0.182;
    var platUnder = addMesh(platformGroup, new THREE.CylinderGeometry(2.54, 2.30, 0.08, 64), matUnder);
    platUnder.position.y = -0.02;

    // 平台面上 4 HUD 角标（L 形刻线，增强科技感）
    (function buildBrackets() {
      var pts = [];
      for (var i = 0; i < 4; i++) {
        var a = Math.PI / 4 + i * Math.PI / 2;
        var cx = Math.cos(a), cz = -Math.sin(a);
        var tx = -cz, tz = cx;
        var r = 2.16, len = 0.20, w = 0.055;
        pts.push(cx * (r - len), 0.203, cz * (r - len), cx * r, 0.203, cz * r);
        pts.push(cx * r, 0.203, cz * r, cx * r + tx * w, 0.203, cz * r + tz * w);
        pts.push(cx * r, 0.203, cz * r, cx * r - tx * w, 0.203, cz * r - tz * w);
      }
      var geo = new THREE.BufferGeometry();
      geo.setAttribute('position', new THREE.Float32BufferAttribute(pts, 3));
      var mat = new THREE.LineBasicMaterial({ color: 0x6fe6ff, transparent: true, opacity: 0.5 });
      var brackets = new THREE.LineSegments(geo, mat);
      brackets.frustumCulled = false;
      platformGroup.add(brackets);
      dimMats.push({ mat: mat, e: 0, o: 0.5 });
    })();

    // 平台侧壁发光环（主视觉边线）
    var rimMat = regDim(additive(C.cyan, 0.36), 0, 0.36);
    addTorus(platformGroup, 2.49, 0.016, rimMat, 0.10);
    var rimMat2 = regDim(additive(C.cyan, 0.16), 0, 0.16);
    addTorus(platformGroup, 2.36, 0.007, rimMat2, 0.19);

    // 同心圆环
    var ringMats = [];
    var ringDefs = [
      { r: 2.26, o: 0.26 },
      { r: 1.92, o: 0.17 },
      { r: 1.52, o: 0.12 },
      { r: 1.14, o: 0.09 }
    ];
    ringDefs.forEach(function (def) {
      var mat = regDim(additive(C.cyan, def.o), 0, def.o);
      ringMats.push({ mat: mat, base: def.o });
      addTorus(platformGroup, def.r, 0.0065, mat, 0.192);
    });

    // 外圈虚线环（暗）
    var outerRing = addTorus(platformGroup, 2.66, 0.005, additive(C.cyanDim, 0.12), 0.19);
    outerRing.material.opacity = 0.12;

    // 辐射网格
      (function buildGrid() {
      var pts = [];
      for (var i = 0; i < 24; i++) {
        var a = (i / 24) * TAU;
        var ca = Math.cos(a), sa = Math.sin(a);
        pts.push(ca * 0.98, 0.196, -sa * 0.98, ca * 2.32, 0.196, -sa * 2.32);
      }
      var geo = new THREE.BufferGeometry();
      geo.setAttribute('position', new THREE.Float32BufferAttribute(pts, 3));
      var grid = new THREE.LineSegments(geo, new THREE.LineBasicMaterial({
        color: 0x2a8aa8,
        transparent: true,
        opacity: 0.28
      }));
      grid.frustumCulled = false;
      platformGroup.add(grid);
      dimMats.push({ mat: grid.material, e: 0, o: 0.28 });
    })();

    // 外圈 72 刻度（InstancedMesh
      (function buildTicks() {
      var count = 72;
      var geo = new THREE.BoxGeometry(0.075, 0.01, 0.014);
      var mat = new THREE.MeshBasicMaterial({ color: C.cyan, transparent: true, opacity: 0.34 });
      var inst = new THREE.InstancedMesh(geo, mat, count);
      var m4 = new THREE.Matrix4();
      var q = new THREE.Quaternion();
      var e = new THREE.Euler();
      var p = new THREE.Vector3();
      var s = new THREE.Vector3(1, 1, 1);
      for (var i = 0; i < count; i++) {
        var a = (i / count) * TAU;
        e.set(0, a, 0);
        q.setFromEuler(e);
        p.set(Math.cos(a) * 2.30, 0.198, -Math.sin(a) * 2.30);
        m4.compose(p, q, s);
        inst.setMatrixAt(i, m4);
      }
      inst.instanceMatrix.needsUpdate = true;
      inst.frustumCulled = false;
      platformGroup.add(inst);
      dimMats.push({ mat: mat, e: 0, o: 0.34 });
    })();

    // 地面光晕（近似地面反射）+ 背景软光
    var haloMat = new THREE.MeshBasicMaterial({
      map: glowTex,
      color: 0x1f9fc4,
      transparent: true,
      opacity: 0.3,
      blending: THREE.AdditiveBlending,
      depthWrite: false
    });
    var halo = new THREE.Mesh(new THREE.CircleGeometry(5.4, 64), haloMat);
    halo.rotation.x = -Math.PI / 2;
    halo.position.y = -0.012;
    platformGroup.add(halo);

    var backdropMat = new THREE.SpriteMaterial({
      map: glowTex,
      color: 0x1d8fb3,
      transparent: true,
      opacity: 0.2,
      blending: THREE.AdditiveBlending,
      depthWrite: false
    });
    var backdrop = new THREE.Sprite(backdropMat);
    backdrop.position.set(0, 1.3, -1.2);
    backdrop.scale.set(6.6, 6.6, 1);
    scene.add(backdrop);

    // 扫描扇区（缓慢自转，待机时更亮）
    var scanMat = new THREE.MeshBasicMaterial({
      color: C.cyan,
      transparent: true,
      opacity: 0.16,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
      side: THREE.DoubleSide
    });
    var scan = addMesh(platformGroup, new THREE.RingGeometry(2.10, 2.17, 48, 1, 0, 0.9), scanMat);
    scan.rotation.x = -Math.PI / 2;
    scan.rotation.z = 0;
    scan.position.y = 0.204;
    var scan2 = addMesh(platformGroup, new THREE.RingGeometry(1.30, 1.34, 32, 1, 0, 1.6), scanMat);
    scan2.rotation.x = -Math.PI / 2;
    scan2.position.y = 0.206;

    // =====================================================================
    // 2) 底座电机：法机座 散热端盖 竖直短轴
    // =====================================================================
    var motorGroup = new THREE.Group();
    platformGroup.add(motorGroup);

    var matFlange = std(0x27424f, 0.85, 0.32, 0.85);
    var matMotor = std(C.motor, 0.82, 0.36, 0.95);
    var matMotorDark = std(C.motorDark, 0.78, 0.5, 0.45);
    var matFin = std(0x2b4b5b, 0.9, 0.3, 0.9);
    var matSteel = std(C.steel, 0.94, 0.24, 1.1);

    addCyl(motorGroup, 1.04, 1.12, 0.10, 56, matFlange, 0.23);       // 法兰
    addCyl(motorGroup, 0.78, 0.80, 0.82, 56, matMotor, 0.69);        // 机座
    addCyl(motorGroup, 0.66, 0.72, 0.12, 48, matMotorDark, 1.16);    // 端盖
    addCyl(motorGroup, 0.62, 0.62, 0.05, 48, matSteel, 1.24);        // 端盖压板
    addCyl(motorGroup, 0.13, 0.16, 0.44, 28, matSteel, 1.42);        // 竖直短轴
    addCyl(motorGroup, 0.205, 0.205, 0.06, 32, matMotorDark, 1.615); // 轴套
    addTorus(motorGroup, 0.80, 0.01, regDim(additive(C.cyan, 0.35), 0, 0.35), 0.32);
    addTorus(motorGroup, 0.79, 0.008, regDim(additive(C.cyan, 0.22), 0, 0.22), 1.06);

    // 散热槽（InstancedMesh
      (function buildFins() {
      var count = 18;
      var geo = new THREE.BoxGeometry(0.03, 0.60, 0.115);
      var inst = new THREE.InstancedMesh(geo, matFin, count);
      var m4 = new THREE.Matrix4();
      var q = new THREE.Quaternion();
      var e = new THREE.Euler();
      var p = new THREE.Vector3();
      var s = new THREE.Vector3(1, 1, 1);
      for (var i = 0; i < count; i++) {
        var a = (i / count) * TAU;
        e.set(0, a, 0);
        q.setFromEuler(e);
        p.set(Math.sin(a) * 0.795, 0.70, Math.cos(a) * 0.795);
        m4.compose(p, q, s);
        inst.setMatrixAt(i, m4);
      }
      inst.instanceMatrix.needsUpdate = true;
      motorGroup.add(inst);
    })();

    // 法兰螺栓（InstancedMesh
      (function buildBolts() {
      var count = 10;
      var geo = new THREE.CylinderGeometry(0.042, 0.042, 0.035, 10);
      var inst = new THREE.InstancedMesh(geo, matSteel, count);
      var m4 = new THREE.Matrix4();
      var q = new THREE.Quaternion();
      var p = new THREE.Vector3();
      var s = new THREE.Vector3(1, 1, 1);
      for (var i = 0; i < count; i++) {
        var a = (i / count) * TAU;
        p.set(Math.cos(a) * 0.94, 0.30, -Math.sin(a) * 0.94);
        m4.compose(p, q, s);
        inst.setMatrixAt(i, m4);
      }
      inst.instanceMatrix.needsUpdate = true;
      motorGroup.add(inst);
    })();

    // 状态灯 颗，位于电机朝向相机一侧）
    var ledMats = [];
    var ledDefs = [
      { key: 'takeover', color: C.green, tangent: -0.24, y: 0.92 },
      { key: 'protect', color: C.red, tangent: 0.0, y: 0.92 },
      { key: 'swing', color: C.amber, tangent: 0.24, y: 0.92 }
    ];
    var ledAngle = 0.62;
    var ledDir = new THREE.Vector3(Math.sin(ledAngle), 0, Math.cos(ledAngle));
    var ledTan = new THREE.Vector3(Math.cos(ledAngle), 0, -Math.sin(ledAngle));
    ledDefs.forEach(function (def) {
      var mat = new THREE.MeshStandardMaterial({
        color: 0x0a141a,
        metalness: 0.4,
        roughness: 0.3,
        emissive: new THREE.Color(def.color),
        emissiveIntensity: 0.05
      });
      var bulb = addMesh(motorGroup, new THREE.SphereGeometry(0.05, 16, 12), mat);
      var px = ledDir.x * 0.82 + ledTan.x * def.tangent;
      var pz = ledDir.z * 0.82 + ledTan.z * def.tangent;
      bulb.position.set(px, def.y, pz);
      var gmat = new THREE.SpriteMaterial({
        map: glowTex,
        color: def.color,
        transparent: true,
        opacity: 0,
        blending: THREE.AdditiveBlending,
        depthWrite: false
      });
      var sprite = new THREE.Sprite(gmat);
      sprite.position.set(px * 1.04, def.y, pz * 1.04);
      sprite.scale.set(0.5, 0.5, 1);
      motorGroup.add(sprite);
      ledMats.push({ mat: mat, glow: gmat, bulb: bulb });
    });

    // 端盖状态环
    var statusRingMat = additive(C.cyan, 0.25);
    addTorus(motorGroup, 0.57, 0.012, statusRingMat, 1.255);

    // =====================================================================
    // 3) 水平摆臂（绕 Y 轴旋转）+ 铰链 + 摆杆
    // =====================================================================
    var ARM_LEN = 1.95;          // 摆臂半径（中臂端铰链）；短臂 + 长摆杆更接近真实旋转倒立
    var ROD_LEN = 2.55;          // 摆杆长度
    var ARM_Y = 1.66;            // 摆臂高度（世Y
    var armGroup = new THREE.Group();
    armGroup.position.y = ARM_Y;
    scene.add(armGroup);

    var matArm = std(C.arm, 0.9, 0.28, 1.0);
    var matArmDark = std(0x2a4452, 0.86, 0.4, 0.7);

    var hub = addCyl(armGroup, 0.30, 0.32, 0.24, 36, matSteel, 0);
    addTorus(armGroup, 0.31, 0.012, regDim(additive(C.cyan, 0.65), 0, 0.65), 0.115);
    addTorus(armGroup, 0.24, 0.008, regDim(additive(C.cyan, 0.3), 0, 0.3), -0.115);

    // 横梁（从 -0.75 延伸+2.15
    var beamGeo = new THREE.BoxGeometry(2.70, 0.085, 0.16);
    var beam = addMesh(armGroup, beamGeo, matArm);
    beam.position.set(0.60, 0, 0);
    var beamEdges = new THREE.LineSegments(
      new THREE.EdgesGeometry(beamGeo),
      new THREE.LineBasicMaterial({ color: 0x9df2ff, transparent: true, opacity: 0.45 })
    );
    beamEdges.position.copy(beam.position);
    armGroup.add(beamEdges);

    // 横梁顶部发光
    var beamGlowMat = regDim(additive(C.cyan, 0.85), 0, 0.85);
    var beamGlow = addMesh(armGroup, new THREE.BoxGeometry(2.42, 0.012, 0.034), beamGlowMat);
    beamGlow.position.set(0.68, 0.054, 0);

    // 加强
      [0.40, 0.90, 1.40, 1.80].forEach(function (x) {
      var rib = addMesh(armGroup, new THREE.BoxGeometry(0.05, 0.15, 0.21), matArmDark);
      rib.position.set(x, 0.0, 0);
    });

    // 配重
    var cw = addMesh(armGroup, new THREE.CylinderGeometry(0.20, 0.20, 0.34, 28), matSteel);
    cw.rotation.z = Math.PI / 2;
    cw.position.set(-0.62, 0, 0);
    var cwCap = addMesh(armGroup, new THREE.CylinderGeometry(0.22, 0.22, 0.03, 28), matArmDark);
    cwCap.rotation.z = Math.PI / 2;
    cwCap.position.set(-0.80, 0, 0);
    var cwGlow = addTorus(armGroup, 0.205, 0.008, regDim(additive(C.cyan, 0.35), 0, 0.35), 0);
    cwGlow.rotation.x = 0;
    cwGlow.rotation.z = Math.PI / 2;
    cwGlow.position.set(-0.62, 0, 0);

    // 臂端铰链
    var hingeGroup = new THREE.Group();
    hingeGroup.position.set(ARM_LEN, 0, 0);
    armGroup.add(hingeGroup);

    [-0.17, 0.17].forEach(function (z) {
      var plate = addMesh(hingeGroup, new THREE.BoxGeometry(0.34, 0.30, 0.040), matArmDark);
      plate.position.set(0.02, 0.02, z);
      var plateEdge = new THREE.LineSegments(
        new THREE.EdgesGeometry(new THREE.BoxGeometry(0.34, 0.30, 0.040)),
        new THREE.LineBasicMaterial({ color: 0x8fe9ff, transparent: true, opacity: 0.35 })
      );
      plateEdge.position.copy(plate.position);
      hingeGroup.add(plateEdge);
    });
    var pin = addMesh(hingeGroup, new THREE.CylinderGeometry(0.085, 0.085, 0.42, 24), matSteel);
    pin.rotation.z = Math.PI / 2;
    [-0.22, 0.22].forEach(function (x) {
      var cap = addMesh(hingeGroup, new THREE.CylinderGeometry(0.10, 0.10, 0.03, 20), matArmDark);
      cap.rotation.z = Math.PI / 2;
      cap.position.x = x;
    });

    // 摆杆（绕铰链本地 +X 轴旋-tilt；见文件头映射注释）
    var rodGroup = new THREE.Group();
    hingeGroup.add(rodGroup);

    var rodMat = new THREE.MeshStandardMaterial({
      color: 0xdfeef7,
      metalness: 0.94,
      roughness: 0.18,
      envMapIntensity: 1.25,
      emissive: new THREE.Color(C.cyan),
      emissiveIntensity: 0.06
    });
    addCyl(rodGroup, 0.045, 0.062, ROD_LEN, 24, rodMat, ROD_LEN / 2 + 0.02);
    addCyl(rodGroup, 0.085, 0.098, 0.15, 24, matArmDark, 0.055);

    [0.40, 0.95, 1.50, 2.05].forEach(function (y) {
      var ring = addTorus(rodGroup, 0.058, 0.006, regDim(additive(C.cyan, 0.55), 0, 0.55), y);
      ring.rotation.x = Math.PI / 2;
    });

    var tipMat = new THREE.MeshStandardMaterial({
      color: 0x000000,
      metalness: 0.0,
      roughness: 1.0,
      envMapIntensity: 0.0,
      emissive: new THREE.Color(C.cyan),
      emissiveIntensity: 1.2
    });
    var tip = addMesh(rodGroup, new THREE.SphereGeometry(0.105, 24, 18), tipMat);
    tip.position.y = ROD_LEN + 0.02;
    var tipRingMat = additive(C.cyan, 0.4);
    var tipRing = addTorus(rodGroup, 0.152, 0.008, tipRingMat, ROD_LEN - 0.10);
    tipRing.rotation.x = Math.PI / 2;

    var tipGlowMat = new THREE.SpriteMaterial({
      map: glowTex,
      color: C.cyan,
      transparent: true,
      opacity: 0.8,
      blending: THREE.AdditiveBlending,
      depthWrite: false
    });
    var tipGlow = new THREE.Sprite(tipGlowMat);
    tipGlow.position.y = ROD_LEN + 0.02;
    tipGlow.scale.set(1.05, 1.05, 1);
    rodGroup.add(tipGlow);

    // ---- REF 幽灵杆 -----------------------------------------------------
    var refGroup = new THREE.Group();
    refGroup.visible = false;
    hingeGroup.add(refGroup);
    var refMat = new THREE.MeshBasicMaterial({
      color: 0xffa726,
      transparent: true,
      opacity: 0.5,
      blending: THREE.AdditiveBlending,
      depthWrite: false
    });
    addCyl(refGroup, 0.045, 0.045, ROD_LEN, 14, refMat, ROD_LEN / 2 + 0.02);
    var refTipMat = new THREE.MeshBasicMaterial({
      color: 0xffb733,
      transparent: true,
      opacity: 0.8,
      blending: THREE.AdditiveBlending,
      depthWrite: false
    });
    var refTip = addMesh(refGroup, new THREE.SphereGeometry(0.085, 14, 10), refTipMat);
    refTip.position.y = ROD_LEN + 0.02;
    // 幽灵杆上的刻度横
    for (var ry = 0.5; ry <= ROD_LEN * 0.92; ry += 0.4) {
      var tick = addMesh(refGroup, new THREE.BoxGeometry(0.17, 0.011, 0.011), refMat);
      tick.position.y = ry;
    }

    // ---- ANG 角度+ 刻度 ---------------------------------------------
    var angGroup = new THREE.Group();
    angGroup.position.set(0, 0, 0);
    hingeGroup.add(angGroup);

    (function buildAngleScale() {
      var pts = [];
      for (var a = -100; a <= 100; a += 5) {
        var rad = a * DEG;
        var major = (a % 30 === 0);
        var r0 = 0.80;
        var r1 = major ? 0.96 : 0.885;
        pts.push(0, Math.cos(rad) * r0, -Math.sin(rad) * r0);
        pts.push(0, Math.cos(rad) * r1, -Math.sin(rad) * r1);
      }
      // 0° 竖直参考轴
      pts.push(0, 0.26, 0, 0, 1.02, 0);
      var geo = new THREE.BufferGeometry();
      geo.setAttribute('position', new THREE.Float32BufferAttribute(pts, 3));
      var mat = new THREE.LineBasicMaterial({ color: 0x4fd6e8, transparent: true, opacity: 0.45 });
      var scale = new THREE.LineSegments(geo, mat);
      scale.frustumCulled = false;
      angGroup.add(scale);
      dimMats.push({ mat: mat, e: 0, o: 0.45 });
    })();

    var ARC_SEG = 40;
    var arcGeo = new THREE.BufferGeometry();
    arcGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array((ARC_SEG + 1) * 3), 3));
    var arcMat = new THREE.LineBasicMaterial({
      color: C.cyan,
      transparent: true,
      opacity: 0.95,
      blending: THREE.AdditiveBlending
    });
    var arcLine = new THREE.Line(arcGeo, arcMat);
    arcLine.frustumCulled = false;
    angGroup.add(arcLine);
    var arcMarkerMat = new THREE.MeshBasicMaterial({
      color: C.cyan,
      transparent: true,
      opacity: 0.95,
      blending: THREE.AdditiveBlending,
      depthWrite: false
    });
    var arcMarker = addMesh(angGroup, new THREE.SphereGeometry(0.036, 12, 10), arcMarkerMat);
    arcMarker.frustumCulled = false;
    var lastArcTilt = 1e9;

    // 接管窗口 ±ENTER 的两条绿色刻度（enter 单位 deg，由 app.js 换算后传入）
    var enterGeo = new THREE.BufferGeometry();
    enterGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(12), 3));
    var enterMat = new THREE.LineBasicMaterial({
      color: 0x39e6a8,
      transparent: true,
      opacity: 0.5
    });
    var enterLine = new THREE.LineSegments(enterGeo, enterMat);
    enterLine.frustumCulled = false;
    angGroup.add(enterLine);
    var lastEnterDeg = -1;
    function updateEnterTicks() {
      if (lastEnterDeg === target.enter) return;
      lastEnterDeg = target.enter;
      var e = clamp(target.enter, 0, 90) * DEG;
      var r0 = 0.80, r1 = 0.995;
      var arr = enterGeo.attributes.position.array;
      arr[0] = 0; arr[1] = Math.cos(e) * r0; arr[2] = -Math.sin(e) * r0;
      arr[3] = 0; arr[4] = Math.cos(e) * r1; arr[5] = -Math.sin(e) * r1;
      arr[6] = 0; arr[7] = Math.cos(e) * r0; arr[8] = Math.sin(e) * r0;
      arr[9] = 0; arr[10] = Math.cos(e) * r1; arr[11] = Math.sin(e) * r1;
      enterGeo.attributes.position.needsUpdate = true;
    }

    // =====================================================================
    // 4) POS 相位指针 + 外环刻度 + DUT 输出+ 能量
    // =====================================================================
    var pointerGroup = new THREE.Group();
    pointerGroup.position.y = 0.20;
    platformGroup.add(pointerGroup);

    var pointerMat = new THREE.MeshStandardMaterial({
      color: 0x0c2733,
      metalness: 0.4,
      roughness: 0.3,
      emissive: new THREE.Color(C.cyan),
      emissiveIntensity: 1.1
    });
    var blade = addMesh(pointerGroup, new THREE.ConeGeometry(0.075, 0.30, 4), pointerMat);
    blade.rotation.z = -Math.PI / 2;
    blade.position.set(2.24, 0.03, 0);
    var pointerDot = addMesh(pointerGroup, new THREE.SphereGeometry(0.045, 14, 10), new THREE.MeshBasicMaterial({
      color: C.cyan,
      transparent: true,
      opacity: 0.95,
      blending: THREE.AdditiveBlending,
      depthWrite: false
    }));
    pointerDot.position.set(2.24, 0.03, 0);
    var pointerGlowMat = new THREE.SpriteMaterial({
      map: glowTex,
      color: C.cyan,
      transparent: true,
      opacity: 0.55,
      blending: THREE.AdditiveBlending,
      depthWrite: false
    });
    var pointerGlow = new THREE.Sprite(pointerGlowMat);
    pointerGlow.position.set(2.22, 0.05, 0);
    pointerGlow.scale.set(0.55, 0.55, 1);
    pointerGroup.add(pointerGlow);
    // 0 相位参考短刻度
    var zeroMat = new THREE.MeshBasicMaterial({ color: C.cyanDim, transparent: true, opacity: 0.7 });
    var zeroTick = addMesh(platformGroup, new THREE.BoxGeometry(0.16, 0.012, 0.02), zeroMat);
    zeroTick.position.set(2.34, 0.205, 0);

    // DUT 半环（正/负方向各半圈；亮= |dut|/lim
    var dutPosMat = new THREE.MeshBasicMaterial({
      color: C.cyan,
      transparent: true,
      opacity: 0.08,
      depthWrite: false,
      side: THREE.DoubleSide
    });
    var dutNegMat = new THREE.MeshBasicMaterial({
      color: C.cyan,
      transparent: true,
      opacity: 0.08,
      depthWrite: false,
      side: THREE.DoubleSide
    });
    var dutRingPos = addMesh(platformGroup, new THREE.RingGeometry(2.74, 2.82, 64, 1, -Math.PI / 2, Math.PI), dutPosMat);
    dutRingPos.rotation.x = -Math.PI / 2;
    dutRingPos.position.y = 0.26;
    var dutRingNeg = addMesh(platformGroup, new THREE.RingGeometry(2.74, 2.82, 64, 1, Math.PI / 2, Math.PI), dutNegMat);
    dutRingNeg.rotation.x = -Math.PI / 2;
    dutRingNeg.position.y = 0.26;

    // 能量环（MODE 2 起摆运行时的琥珀旋转环）
    var energyGroup = new THREE.Group();
    energyGroup.visible = false;
    platformGroup.add(energyGroup);
    var energyMats = [];
    function energyRing(radius, tube, y, opacity) {
      var mat = new THREE.MeshBasicMaterial({
        color: 0xff9a1e,
        transparent: true,
        opacity: 0,
        blending: THREE.AdditiveBlending,
        depthWrite: false
      });
      mat.userData.baseOpacity = opacity;
      energyMats.push(mat);
      var ring = addTorus(energyGroup, radius, tube, mat, y);
      return ring;
    }
    energyRing(3.04, 0.028, 0.36, 0.85);
    energyRing(2.97, 0.016, 0.54, 0.55);

    var energyDashGroup = new THREE.Group();
    energyGroup.add(energyDashGroup);
    for (var di = 0; di < 6; di++) {
      var dmat = new THREE.MeshBasicMaterial({
        color: 0xffb733,
        transparent: true,
        opacity: 0,
        blending: THREE.AdditiveBlending,
        depthWrite: false,
        side: THREE.DoubleSide
      });
      dmat.userData.baseOpacity = 0.8;
      energyMats.push(dmat);
      var dash = addMesh(energyDashGroup, new THREE.RingGeometry(3.00, 3.12, 12, 1, di * TAU / 6, 0.52), dmat);
      dash.rotation.x = -Math.PI / 2;
      dash.position.y = 0.43;
    }
    // 3 颗沿能量环旋转的琥珀光点（起摆运行时可见，强化“能量”动感）
    var energySparkGroup = new THREE.Group();
    energyGroup.add(energySparkGroup);
    var sparkMat = new THREE.MeshBasicMaterial({
      color: 0xffc247,
      transparent: true,
      opacity: 0,
      blending: THREE.AdditiveBlending,
      depthWrite: false
    });
    sparkMat.userData.baseOpacity = 0.95;
    energyMats.push(sparkMat);
    for (var si = 0; si < 3; si++) {
      var sa = (si / 3) * TAU;
      var spark = addMesh(energySparkGroup, new THREE.SphereGeometry(0.055, 10, 8), sparkMat);
      spark.position.set(Math.cos(sa) * 3.02, 0.36 + 0.06 * si, -Math.sin(sa) * 3.02);
    }

    // =====================================================================
    // 5) 粒子（空间尘埃，增加纵深
    // =====================================================================
    var particlesGroup = new THREE.Group();
    scene.add(particlesGroup);
    var particleMat = new THREE.PointsMaterial({
      color: 0x63d8f0,
      size: 0.032,
      transparent: true,
      opacity: 0.5,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
      sizeAttenuation: true
    });
    (function buildParticles() {
      var n = 150;
      var arr = new Float32Array(n * 3);
      for (var i = 0; i < n; i++) {
        var r = 2.0 + Math.random() * 2.6;
        var a = Math.random() * TAU;
        arr[i * 3] = Math.cos(a) * r;
        arr[i * 3 + 1] = 0.15 + Math.random() * 4.2;
        arr[i * 3 + 2] = -Math.sin(a) * r;
      }
      var geo = new THREE.BufferGeometry();
      geo.setAttribute('position', new THREE.BufferAttribute(arr, 3));
      particlesGroup.add(new THREE.Points(geo, particleMat));
    })();

    // =====================================================================
    // 6) CanvasTexture Sprite 数值标签（ANG / REF / POS / DUT
    // =====================================================================
    function roundRect(ctx, x, y, w, h, r) {
      ctx.beginPath();
      ctx.moveTo(x + r, y);
      ctx.arcTo(x + w, y, x + w, y + h, r);
      ctx.arcTo(x + w, y + h, x, y + h, r);
      ctx.arcTo(x, y + h, x, y, r);
      ctx.arcTo(x, y, x + w, y, r);
      ctx.closePath();
    }

    function makeLabel(prefix, x, y, z, parent) {
      var cv = document.createElement('canvas');
      cv.width = 320;
      cv.height = 72;
      var ctx = cv.getContext('2d');
      var tex = new THREE.CanvasTexture(cv);
      tex.minFilter = THREE.LinearFilter;
      tex.magFilter = THREE.LinearFilter;
      tex.generateMipmaps = false;
      if (THREE.sRGBEncoding !== undefined) tex.encoding = THREE.sRGBEncoding;
      var mat = new THREE.SpriteMaterial({
        map: tex,
        transparent: true,
        depthWrite: false,
        depthTest: false        // HUD 标签：始终压在模型之上，避免摆杆切断文字
      });
      var sp = new THREE.Sprite(mat);
      sp.position.set(x, y, z);
      sp.scale.set(1.15, 0.259, 1);
      sp.renderOrder = 30;
      sp.userData = { canvas: cv, ctx: ctx, texture: tex, prefix: prefix, key: '' };
      parent.add(sp);
      return sp;
    }

    function setLabel(sprite, value, accentCss) {
      if (!sprite) return;
      var key = value + '|' + accentCss;
      if (sprite.userData.key === key) return;
      sprite.userData.key = key;
      var ctx = sprite.userData.ctx;
      var W = 320, H = 72;
      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = 'rgba(4,14,24,0.84)';
      roundRect(ctx, 3, 7, W - 6, 58, 11);
      ctx.fill();
      ctx.strokeStyle = 'rgba(120,220,255,0.26)';
      ctx.lineWidth = 2;
      roundRect(ctx, 3, 7, W - 6, 58, 11);
      ctx.stroke();
      // 左侧色条
      ctx.fillStyle = accentCss;
      roundRect(ctx, 9, 13, 6, 46, 3);
      ctx.fill();
      ctx.textBaseline = 'middle';
      ctx.font = 'bold 21px Consolas, "Cascadia Mono", monospace';
      ctx.fillStyle = 'rgba(150,196,216,0.92)';
      ctx.fillText(sprite.userData.prefix, 26, 37);
      var pw = ctx.measureText(sprite.userData.prefix).width;
      ctx.font = 'bold 38px Consolas, "Cascadia Mono", monospace';
      ctx.fillStyle = accentCss;
      ctx.fillText(value, 26 + pw + 12, 37);
      sprite.userData.texture.needsUpdate = true;
    }

    // ANG / REF 标签用屏幕空间偏移锚定在铰链右侧（始终位于摆杆右侧、上下错开）；
    // POS 跟随相位指针；DUT 固定在平台前右缘外侧
    var angLabel = makeLabel('ANG', 0, 0, 0, scene);
    var refLabel = makeLabel('REF', 0, 0, 0, scene);
    var posLabel = makeLabel('POS', 0, 0, 0, scene);
    var dutLabel = makeLabel('DUT', 0, 0, 0, scene);

    // =====================================================================
    // 7) 状态机 / 平滑目标
    // =====================================================================
    var target = {
      ang: 0, hasAng: false,
      ref: 0, hasRef: false,
      pos: 0, hasPos: false,
      spd: 0,
      dut: 0, hasDut: false,
      mode: -1,
      st: 0,
      sw: false,
      lim: 300,
      dz: 20,
      enter: 10,
      fall: 15,
      connected: false
    };
    var view = {
      tilt: 0,
      refTilt: 0,
      yaw: 0,
      yawTarget: 0,
      ratio: 0,
      dim: 1,
      energy: 0,
      idle: 1
    };
    var posRawLast = null;
    var hasAnyData = false;
    var lastUpdateTs = nowMs();
    var lastLabelAt = -1e9;
    var nowS = 0;

    function fmtAngle(v) {
      if (!isNum(v)) return '--';
      return (v < 0 ? '-' : '+') + Math.abs(v).toFixed(2) + '\u00b0';
    }
    function fmtCount(v) {
      if (!isNum(v)) return '--';
      var n = Math.round(v);
      var s = String(Math.abs(n));
      while (s.length < 4) s = '0' + s;
      return (n < 0 ? '-' : '+') + s;
    }

    function update(state) {
      if (disposed || !state || typeof state !== 'object') return;
      lastUpdateTs = nowMs();
      if (state.connected === true) target.connected = true;
      else if (state.connected === false) target.connected = false;

      if (isNum(state.ang)) {
        target.ang = clamp(state.ang, -720, 720);
        target.hasAng = true;
      }
      if (state.ref === null) {
        target.hasRef = false;
      } else if (isNum(state.ref)) {
        target.ref = clamp(state.ref, -720, 720);
        target.hasRef = true;
      }
      if (isNum(state.pos)) {
        target.pos = state.pos;
        target.hasPos = true;
        // POS 单圈回绕 连续偏航角（避免 ±520 lerp 绕远路）
        var raw = (state.pos / POS_COUNTS) * TAU;
        if (posRawLast === null) {
          posRawLast = raw;
          view.yawTarget = raw;
        } else {
          view.yawTarget += wrapPi(raw - posRawLast);
          posRawLast = raw;
        }
      }
      if (isNum(state.spd)) target.spd = state.spd;
      if (isNum(state.dut)) {
        target.dut = state.dut;
        target.hasDut = true;
      }
      if (isNum(state.mode)) target.mode = Math.round(state.mode);
      if (isNum(state.st)) target.st = Math.round(state.st);
      if (state.sw === true) target.sw = true;
      else if (state.sw === false) target.sw = false;
      if (isNum(state.lim) && state.lim > 0) target.lim = state.lim;
      if (isNum(state.dz)) target.dz = state.dz;
      if (isNum(state.enter)) target.enter = state.enter;
      if (isNum(state.fall) && state.fall > 0) target.fall = state.fall;

      if (target.hasAng || target.hasPos || target.hasDut) hasAnyData = true;
    }

    // =====================================================================
    // 8) 每帧更新
    // =====================================================================
    var colorTmpA = new THREE.Color(0x00d9ff);
    var colorTmpB = new THREE.Color(0xffa600);
    var colorTmpC = new THREE.Color(0xff2a2a);
    var colorTmp = new THREE.Color();

    function dutColor() {
      var r = view.ratio;
      if (r < 0.55) colorTmp.copy(colorTmpA).lerp(colorTmpB, r / 0.55);
      else colorTmp.copy(colorTmpB).lerp(colorTmpC, (r - 0.55) / 0.45);
      return colorTmp;
    }

    function updateArc() {
      if (Math.abs(view.tilt - lastArcTilt) < 0.0008) return;
      lastArcTilt = view.tilt;
      var arr = arcGeo.attributes.position.array;
      var r = 0.74;
      for (var i = 0; i <= ARC_SEG; i++) {
        var a = view.tilt * (i / ARC_SEG);
        arr[i * 3] = 0;
        arr[i * 3 + 1] = Math.cos(a) * r;
        arr[i * 3 + 2] = -Math.sin(a) * r;
      }
      arcGeo.attributes.position.needsUpdate = true;
      arcMarker.position.set(0, Math.cos(view.tilt) * r, -Math.sin(view.tilt) * r);
    }

    function refreshLabels() {
      var accent = CSS.cyan;
      if (target.hasAng) {
        var aa = Math.abs(target.ang);
        if (aa >= target.fall * 0.98) accent = CSS.red;
        else if (aa >= target.fall * 0.7) accent = CSS.amber;
      }
      setLabel(angLabel, target.hasAng ? fmtAngle(target.ang) : '--', accent);
      setLabel(refLabel, target.hasRef ? fmtAngle(target.ref) : '--', CSS.amber);
      setLabel(posLabel, target.hasPos ? fmtCount(target.pos) : '--', CSS.cyan);
      var dutAccent = view.ratio >= 0.8 ? CSS.red : (view.ratio >= 0.45 ? CSS.amber : CSS.cyan);
      setLabel(dutLabel, target.hasDut ? fmtCount(target.dut) : '--', dutAccent);
    }

    function step(dt, now) {
      nowS = now * 0.001;
      var t = nowS;

      // ---- 平滑目标 -----------------------------------------------------
      var idleTarget = (!hasAnyData || (now - lastUpdateTs) > 1500) ? 1 : 0;
      view.idle += (idleTarget - view.idle) * smoothK(0.03, dt);

      var tiltTarget = target.hasAng ? clamp(target.ang, -170, 170) * DEG : 0;
      var refTiltTarget = target.hasRef ? clamp(target.ref, -170, 170) * DEG : 0;
      if (!target.hasPos) view.yawTarget += dt * 0.12;   // 无 POS 数据时缓慢自转展示
      var ratioTarget = target.hasDut ?
 clamp(Math.abs(target.dut) / Math.max(1, target.lim), 0, 1) : 0;
      var dimTarget = target.mode === 0 ? 0.42 : 1;
      if (!hasAnyData) dimTarget = 0.9;
      var energyTarget = (target.mode === 2 && target.sw) ? 1 : 0;

      if (INSTANT) {
        view.tilt = tiltTarget;
        view.refTilt = refTiltTarget;
        view.yaw = view.yawTarget;
        view.ratio = ratioTarget;
        view.dim = dimTarget;
        view.energy = energyTarget;
      } else {
        // lerp≈0.18（tilt/refTilt）、偏航 0.28（POS 100 Hz 更新下减少拖影）
        view.tilt += (tiltTarget - view.tilt) * smoothK(0.18, dt);
        view.refTilt += (refTiltTarget - view.refTilt) * smoothK(0.16, dt);
        view.yaw += (view.yawTarget - view.yaw) * smoothK(0.28, dt);
        view.ratio += (ratioTarget - view.ratio) * smoothK(0.2, dt);
        view.dim += (dimTarget - view.dim) * smoothK(0.08, dt);
        view.energy += (energyTarget - view.energy) * smoothK(0.09, dt);
      }

      // ---- 姿态（角度映射见文件头）-------------------------------------
      armGroup.rotation.y = view.yaw;       // armYaw = pos/1040*2π
      rodGroup.rotation.x = -view.tilt;     // rodDir = (0, cos, -sin)
      refGroup.rotation.x = -view.refTilt;
      refGroup.visible = target.hasRef;
      pointerGroup.rotation.y = view.yaw;   // POS 相位指针与摆臂同
      updateArc();
      updateEnterTicks();

      // ---- 状态判定 -----------------------------------------------------
      var danger = target.hasAng && Math.abs(target.ang) >= target.fall * 0.98;
      var warn = target.hasAng && Math.abs(target.ang) >= target.fall * 0.7;
      var protect = (target.st & 2) !== 0;
      var paused = (target.st & 8) !== 0;
      var takeover = (target.st & 4) !== 0;
      var swing = target.mode === 2 && target.sw;
      var pulseFast = 0.5 + 0.5 * Math.sin(t * 11);
      var pulseSlow = 0.5 + 0.5 * Math.sin(t * 4.2);
      var dimK = 0.3 + 0.7 * view.dim;    // mode 0 整体压暗

      var accent = ACC.cyan;
      if (protect || paused || danger) accent = ACC.red;
      else if (takeover) accent = ACC.green;
      else if (warn) accent = ACC.amber;

      // ---- 摆杆端头 / 摆杆 / 角度弧 ------------------------------------
      var pulse = (protect || danger) ? pulseFast : (paused ? pulseSlow : 0.55);
      tipMat.emissive.setHex(accent);
      tipMat.emissiveIntensity = (0.85 + 1.0 * pulse) * (0.35 + 0.65 * view.dim);
      tipGlowMat.color.setHex(accent);
      tipGlowMat.opacity = (0.42 + 0.45 * pulse) * (0.35 + 0.65 * view.dim);
      tipRingMat.color.setHex(accent);
      tipRingMat.opacity = (0.22 + 0.3 * pulse) * (0.35 + 0.65 * view.dim);
      rodMat.emissive.setHex(accent);
      rodMat.emissiveIntensity = 0.04 + 0.07 * view.dim;
      arcMat.color.setHex(accent);
      arcMat.opacity = 0.55 + 0.4 * view.dim;
      arcMarkerMat.color.setHex(accent);
      arcMarkerMat.opacity = (0.6 + 0.4 * pulse) * (0.35 + 0.65 * view.dim);

      // ---- REF 幽灵杆 ---------------------------------------------------
      refMat.opacity = 0.24 + 0.10 * dimK + 0.05 * (0.5 + 0.5 * Math.sin(t * 1.6));

      // ---- DUT 输出环 ---------------------------------------------------
      var dc = dutColor();
      dutPosMat.color.copy(dc);
      dutNegMat.color.copy(dc);
      var on = 0.14 + 0.7 * view.ratio;
      var sign = target.dut >= 0 ? 1 : -1;
      dutPosMat.opacity = (sign > 0 ? on : 0.04) * dimK;
      dutNegMat.opacity = (sign < 0 ? on : 0.04) * dimK;

      // ---- 状态灯 -------------------------------------------------------
      ledMats[0].mat.emissiveIntensity = takeover ? 1.3 : 0.04;
      ledMats[0].glow.opacity = takeover ? (0.55 + 0.15 * Math.sin(t * 3)) : 0;
      ledMats[1].mat.emissiveIntensity = protect ? (0.5 + 1.2 * pulseFast) : 0.04;
      ledMats[1].glow.opacity = protect ? (0.25 + 0.55 * pulseFast) : 0;
      ledMats[2].mat.emissiveIntensity = swing ? (0.5 + 1.0 * pulseSlow) : 0.04;
      ledMats[2].glow.opacity = swing ? (0.25 + 0.45 * pulseSlow) : 0;
      statusRingMat.color.setHex(accent);
      statusRingMat.opacity = (0.16 + 0.5 * (protect || danger ? pulseFast : (takeover ? 0.6 : 0.3))) * dimK;

      // ---- 能量环（MODE 2 && SW）---------------------------------------
      energyGroup.visible = view.energy > 0.01;
      if (energyGroup.visible) {
        energyGroup.rotation.y += dt * (1.2 + 0.9 * view.energy);
        energyDashGroup.rotation.y -= dt * 2.4;
        energySparkGroup.rotation.y += dt * 3.2;
        var eb = view.energy * (0.55 + 0.45 * pulseSlow) * view.dim;
        for (var ei = 0; ei < energyMats.length; ei++) {
          energyMats[ei].opacity = energyMats[ei].userData.baseOpacity * eb;
        }
      }

      // ---- 平台呼吸 / 光晕 / 扫描 ---------------------------------------
      var breath = 0.5 + 0.5 * Math.sin(t * 1.15);
      var breathK = 0.65 + 0.35 * breath * (0.35 + 0.65 * view.idle);
      for (var ri = 0; ri < ringMats.length; ri++) {
        ringMats[ri].mat.opacity = ringMats[ri].base * breathK * dimK;
      }
      haloMat.opacity = (0.3 + 0.2 * breathK) * dimK;
      backdropMat.opacity = (0.14 + 0.1 * breathK) * (0.35 + 0.65 * view.dim);
      scanMat.opacity = (0.08 + 0.22 * view.idle) * dimK;
      scan.rotation.z = t * 0.55;
      scan2.rotation.z = -t * 0.32;
      particlesGroup.rotation.y = -t * 0.035;
      particleMat.opacity = 0.34 + 0.16 * (0.5 + 0.5 * Math.sin(t * 0.8));

      // ---- 静态自发光材质 / 灯光整体压暗 ---------------------------------
      for (var di = 0; di < dimMats.length; di++) {
        var dm = dimMats[di];
        if (dm.o !== null) dm.mat.opacity = dm.o * dimK;
        if (dm.mat.emissiveIntensity !== undefined && dm.e) dm.mat.emissiveIntensity = dm.e * dimK;
      }
      for (var li = 0; li < dimLights.length; li++) {
        dimLights[li].light.intensity = dimLights[li].base * (0.3 + 0.7 * view.dim);
      }

      // ---- 数值标签（≥100 ms 节流；内容不变不重建纹理）-----------------
      if (now - lastLabelAt >= LABEL_INTERVAL_MS) {
        lastLabelAt = now;
        refreshLabels();
      }

      // ---- 相机 ---------------------------------------------------------
      updateCamera(dt);
      updateLabelTransforms();
    }

    // =====================================================================
    // 9) 相机与鼠标交互
    // =====================================================================
    // ---- 取景包络（世界坐标采样点，用于按容器宽高比自适应取景）--------
    // 覆盖：平台面、能量环、摆臂圆周、摆杆 ±90° 扫掠、标签包络、顶点辉光
    var ENV_PTS = [];
    (function buildEnvelope() {
      function ring(r, y, n) {
        for (var i = 0; i < n; i++) {
          var a = (i / n) * TAU;
          ENV_PTS.push(new THREE.Vector3(Math.cos(a) * r, y, -Math.sin(a) * r));
        }
      }
      ring(2.45, 0.0, 24);      // 平台外缘
      ring(2.45, 0.18, 24);
      ring(3.12, 0.36, 16);     // 能量环 / DUT 环
      ring(3.12, 0.54, 16);
      ring(ARM_LEN, ARM_Y, 12); // 摆臂末端圆周
      var rl = ROD_LEN + 0.25;  // 摆杆长度 + 端头辉光
      for (var yi = 0; yi < 8; yi++) {
        var yaw = (yi / 8) * TAU;
        var hx = Math.cos(yaw) * ARM_LEN;
        var hz = -Math.sin(yaw) * ARM_LEN;
        for (var ti = -90; ti <= 90; ti += 45) {
          var tt = ti * DEG;
          var st = Math.sin(tt), ct = Math.cos(tt);
          ENV_PTS.push(new THREE.Vector3(
            hx - st * Math.sin(yaw) * rl,
            ARM_Y + ct * rl,
            hz - st * Math.cos(yaw) * rl
          ));
        }
      }
    })();

    var HALF_W0 = 3.42;   // 粗略初始半宽（仅用于迭代起点
    var baseDist = 12;
    var baseTargetY = 1.55;
    var probeCam = new THREE.PerspectiveCamera(FOV, 1, 0.1, 300);
    var probeV = new THREE.Vector3();
    var cam = {
      az: 0.62,
      el: 0.54,
      zoom: 1,
      azT: 0.62,
      elT: 0.54,
      zoomT: 1,
      dragging: false
    };
    var VIEWS = {
      iso: { az: 0.62, el: 0.54, zoom: 1 },
      front: { az: 0.0, el: 0.13, zoom: 1 },
      top: { az: 0.0, el: 1.40, zoom: 1, fitZoom: 1.0 }
    };
    // 可选：create(container, {camera:'front'}) 直接以指定视角起步（自测/截图用）
    if (opts.camera && VIEWS[opts.camera]) {
      var v0 = VIEWS[opts.camera];
      cam.az = cam.azT = v0.az;
      cam.el = cam.elT = v0.el;
      cam.zoom = cam.zoomT = v0.zoom;
    }

    // 用给定视角/距离/注视高度投影包络，返回屏幕像素包围盒
    function projectEnvelope(points, az, el, dist, targetY, aspect) {
      probeCam.aspect = aspect;
      probeCam.fov = FOV;
      probeCam.updateProjectionMatrix();
      var ce = Math.cos(el), se = Math.sin(el);
      var ca = Math.cos(az), sa = Math.sin(az);
      probeCam.position.set(sa * ce * dist, targetY + se * dist, ca * ce * dist);
      probeCam.lookAt(0, targetY, 0);
      probeCam.updateMatrixWorld(true);
      var minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9;
      for (var i = 0; i < points.length; i++) {
        probeV.copy(points[i]).project(probeCam);
        var sx = (probeV.x * 0.5 + 0.5) * size.w;
        var sy = (1 - (probeV.y * 0.5 + 0.5)) * size.h;
        if (sx < minX) minX = sx;
        if (sx > maxX) maxX = sx;
        if (sy < minY) minY = sy;
        if (sy > maxY) maxY = sy;
      }
      return { x0: minX, x1: maxX, y0: minY, y1: maxY };
    }

    // 单视角自适应取景
    //   1) 距离同时满足「水平安全区」与「垂直安全区」：每轮按 max(宽比, 高比) 缩放，
    //      收敛后既不裁切也不因视口变宽而把距离按宽度线性拉近（宽视口由高度决定距离）；
    //   2) 垂直：让整个姿态包络在安全区（顶部约 100px、底部约 90px）内居中；
    //   3) 标签另行做屏幕安全区 clamp，不参与物理解算。

    function computeFramingFor(az, el, zoom) {
      if (size.w <= 0 || size.h <= 0) return { dist: 12, targetY: 1.55 };
      var aspect = size.w / size.h;
      var tanV = Math.tan(FOV * 0.5 * DEG);
      var safeTop = Math.max(100, size.h * 0.105);            // 指标条 / 顶部状态块
      var safeBottom = size.h - Math.max(90, size.h * 0.10);  // 底部分析条
      var safeH = Math.max(160, safeBottom - safeTop);
      var safeW = size.w * 0.94;
      var d = HALF_W0 / (tanV * aspect);
      var targetY = 1.55;
      var it, bb;
      // 1) 距离：宽度与高度同时适配（取 max 缩放，宽视口不会过度拉近）
      for (it = 0; it < 12; it++) {
        bb = projectEnvelope(ENV_PTS, az, el, d, targetY, aspect);
        var sx = Math.max(1, bb.x1 - bb.x0) / safeW;
        var sy = Math.max(1, bb.y1 - bb.y0) / safeH;
        var k = Math.max(sx, sy);
        d *= clamp(k, 0.55, 1.8);
        if (Math.abs(k - 1) < 0.008) break;
      }
      // 2) 应用视角自带缩放（俯视略小），再按最终距离把包络垂直居中
      d = d / (zoom || 1);
      var pxW = size.h / (2 * d * tanV);
      for (it = 0; it < 5; it++) {
        bb = projectEnvelope(ENV_PTS, az, el, d, targetY, aspect);
        var cy = (bb.y0 + bb.y1) * 0.5;
        var desired = (safeTop + safeBottom) * 0.5 - 4;
        targetY -= (cy - desired) / pxW;
        if (Math.abs(cy - desired) < 0.5) break;
      }
      return { dist: d, targetY: targetY };
    }

    var VIEW_FRAME = { iso: { dist: 12, targetY: 1.5 }, front: { dist: 12, targetY: 1.5 }, top: { dist: 12, targetY: 1.5 } };
    var activeViewName = (opts.camera && VIEWS[opts.camera]) ? opts.camera : 'iso';

    function computeFraming() {
      if (size.w <= 0 || size.h <= 0) return;
      ['iso', 'front', 'top'].forEach(function (name) {
        var v = VIEWS[name];
        VIEW_FRAME[name] = computeFramingFor(v.az, v.el, v.fitZoom || 1);
      });
      var cur = VIEW_FRAME[activeViewName] || VIEW_FRAME.iso;
      baseDist = cur.dist;
      baseTargetY = cur.targetY;
    }

    function updateCamera(dt) {
      var k = INSTANT ? 1 : smoothK(cam.dragging ? 0.55 : 0.14, dt);
      cam.az += (cam.azT - cam.az) * k;
      cam.el += (cam.elT - cam.el) * k;
      cam.zoom += (cam.zoomT - cam.zoom) * k;
      // 视角切换时取景参数平滑过渡（缩放已包含在 VIEW_FRAME.dist 中）
      var frame = VIEW_FRAME[activeViewName] || VIEW_FRAME.iso;
      baseDist += (frame.dist - baseDist) * (INSTANT ? 1 : smoothK(0.10, dt));
      baseTargetY += (frame.targetY - baseTargetY) * (INSTANT ? 1 : smoothK(0.10, dt));

      var tY = baseTargetY;
      lookTarget.set(0, tY, 0);
      var r = baseDist * cam.zoom;
      var ce = Math.cos(cam.el);
      camera.position.set(
        Math.sin(cam.az) * ce * r,
        tY + Math.sin(cam.el) * r,
        Math.cos(cam.az) * ce * r
      );
      camera.lookAt(lookTarget);
      camera.updateMatrixWorld();
    }

    // 标签屏幕空间锚定：ANG/REF 始终在铰链右侧上下错开；POS 跟随指针；DUT 固定前右缘外侧
    var labelRight = new THREE.Vector3();
    var labelUp = new THREE.Vector3();
    var hingeWorld = new THREE.Vector3();
    var labelNDC = new THREE.Vector3();
    // 把标签中心夹在安全区（避开指标条 / 分析条 / 右上按钮列），投影结果反算回世界坐标
    function clampLabel(sprite) {
      if (!sprite.visible) return;
      var v = labelNDC.copy(sprite.position).project(camera);
      var pxW = size.h / (2 * baseDist * cam.zoom * Math.tan(FOV * 0.5 * DEG));
      var halfPx = 0.5 * sprite.scale.x * pxW;
      var marginX = 10 + halfPx;
      var topPx = Math.max(96, size.h * 0.105) + halfPx * 0.6;
      var botPx = 84 + halfPx * 0.6;
      var screenY = (1 - (v.y * 0.5 + 0.5)) * size.h;
      var rightPx = (screenY < 340) ? (86 + halfPx) : (10 + halfPx);
      var nx0 = -1 + (2 * marginX) / size.w;
      var nx1 = 1 - (2 * rightPx) / size.w;
      var nyTop = 1 - (2 * topPx) / size.h;
      var nyBot = -1 + (2 * botPx) / size.h;
      var changed = false;
      if (v.x < nx0) { v.x = nx0; changed = true; }
      if (v.x > nx1) { v.x = nx1; changed = true; }
      if (v.y > nyTop) { v.y = nyTop; changed = true; }
      if (v.y < nyBot) { v.y = nyBot; changed = true; }
      if (changed) {
        v.unproject(camera);
        sprite.position.copy(v);
      }
    }

    function updateLabelTransforms() {
      var e = camera.matrixWorld.elements;
      labelRight.set(e[0], e[1], e[2]);
      labelUp.set(e[4], e[5], e[6]);
      var cy = Math.cos(view.yaw), sy = Math.sin(view.yaw);
      hingeWorld.set(cy * ARM_LEN, ARM_Y, -sy * ARM_LEN);
      // 俯视时缩小标签，避免顶到右上角视图按钮
      var k = 1 - 0.20 * clamp((cam.el - 0.8) / 0.6, 0, 1);
      var dx = 0.82;
      var dyA = 1.02;
      var dyR = 1.72;
      angLabel.position.set(
        hingeWorld.x + labelRight.x * dx + labelUp.x * dyA,
        hingeWorld.y + labelRight.y * dx + labelUp.y * dyA,
        hingeWorld.z + labelRight.z * dx + labelUp.z * dyA
      );
      refLabel.position.set(
        hingeWorld.x + labelRight.x * dx + labelUp.x * dyR,
        hingeWorld.y + labelRight.y * dx + labelUp.y * dyR,
        hingeWorld.z + labelRight.z * dx + labelUp.z * dyR
      );
      // POS 标签跟随相位指针（平台外环）；DUT 标签固定在平台前右缘外侧
      posLabel.position.set(cy * 2.62, 0.78, -sy * 2.62);
      dutLabel.position.set(2.28, 0.40, 1.62);
      angLabel.scale.set(1.15 * k, 0.259 * k, 1);
      refLabel.scale.set(1.15 * k, 0.259 * k, 1);
      posLabel.scale.set(1.15 * k, 0.259 * k, 1);
      dutLabel.scale.set(1.15 * k, 0.259 * k, 1);
      refLabel.visible = target.hasRef;
      clampLabel(angLabel);
      clampLabel(refLabel);
      clampLabel(posLabel);
      clampLabel(dutLabel);
    }

    function setCamera(name) {
      var v = VIEWS[name];
      if (!v) return;
      activeViewName = name;
      cam.azT = v.az;
      cam.elT = v.el;
      cam.zoomT = v.zoom;
      cam.dragging = false;
    }
    function resetCamera() { setCamera('iso'); }

    // 拖拽环绕
    var dragState = { active: false, id: -1, x: 0, y: 0 };
    function onPointerDown(e) {
      if (!INTERACTIVE || e.button !== 0) return;
      dragState.active = true;
      dragState.id = e.pointerId;
      dragState.x = e.clientX;
      dragState.y = e.clientY;
      cam.dragging = true;
      canvas.style.cursor = 'grabbing';
      try { canvas.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ }
      e.preventDefault();
    }
    function onPointerMove(e) {
      if (!dragState.active || e.pointerId !== dragState.id) return;
      var dx = e.clientX - dragState.x;
      var dy = e.clientY - dragState.y;
      dragState.x = e.clientX;
      dragState.y = e.clientY;
      cam.azT -= dx * 0.0062;
      cam.elT = clamp(cam.elT + dy * 0.0055, 0.10, 1.44);
      e.preventDefault();
    }
    function onPointerUp(e) {
      if (!dragState.active || (e.pointerId !== undefined && e.pointerId !== dragState.id)) return;
      dragState.active = false;
      cam.dragging = false;
      canvas.style.cursor = 'grab';
      try { canvas.releasePointerCapture(dragState.id); } catch (err) { /* ignore */ }
    }
    function onWheel(e) {
      if (!INTERACTIVE) return;
      e.preventDefault();
      cam.zoomT = clamp(cam.zoomT * Math.exp(e.deltaY * 0.0011), 0.55, 2.4);
    }
    function onDblClick() { resetCamera(); }

    if (INTERACTIVE) {
      canvas.addEventListener('pointerdown', onPointerDown);
      canvas.addEventListener('pointermove', onPointerMove);
      canvas.addEventListener('pointerup', onPointerUp);
      canvas.addEventListener('pointercancel', onPointerUp);
      canvas.addEventListener('wheel', onWheel, { passive: false });
      canvas.addEventListener('dblclick', onDblClick);
    }

    // =====================================================================
    // 10) 右上角视图按钮 + 左下角 caption（DOM 由 model3d.js 生成）
    // =====================================================================
    var uiEl = document.createElement('div');
    uiEl.className = 'm3d-ui';
    var btnDefs = [
      { key: 'iso', text: 'ISO', title: '等轴 3/4 视角' },
      { key: 'front', text: '正视', title: '正面视角' },
      { key: 'top', text: '俯视', title: '俯视视角' },
      { key: 'reset', text: '重置', title: '恢复默认视角（或双击画面）' }
    ];
    btnDefs.forEach(function (def) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'm3d-view-btn';
      b.textContent = def.text;
      b.title = def.title;
      b.setAttribute('data-view', def.key);
      b.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        if (def.key === 'reset') resetCamera();
        else setCamera(def.key);
      });
      uiEl.appendChild(b);
    });
    container.appendChild(uiEl);

    // 仅在宿主没有为这些类提供样式时注入最小兜底样式（避免覆盖 style.css 设计）
      (function ensureFallbackStyles() {
      var css = '';
      var uiPos = '';
      try {
        uiPos = window.getComputedStyle(uiEl).position;
      } catch (err) { /* ignore */ }
      if (uiPos === 'static') {
        css += '.m3d-ui{position:absolute;right:12px;top:88px;display:flex;flex-direction:column;gap:6px;z-index:6;pointer-events:none;}' +
          '.m3d-view-btn{pointer-events:auto;min-width:58px;padding:5px 9px;font:11px/1.4 Consolas,"Cascadia Mono",monospace;' +
          'letter-spacing:.10em;color:#9adcef;background:rgba(8,24,38,.62);border:1px solid rgba(63,227,255,.30);' +
          'border-radius:2px;cursor:pointer;backdrop-filter:blur(6px);transition:background .15s,color .15s,border-color .15s;}' +
          '.m3d-view-btn:hover{color:#dffbff;background:rgba(20,64,88,.78);border-color:rgba(63,227,255,.7);' +
          'box-shadow:0 0 10px rgba(63,227,255,.28);}' +
          '.m3d-view-btn:active{transform:translateY(1px);}';
      }
      if (css) {
        var st = document.createElement('style');
        st.id = 'm3d-inline-style-' + (++STYLE_SEQ);
        st.textContent = css;
        document.head.appendChild(st);
        styleEls.push(st);
      }
    })();

    // =====================================================================
    // 11) 尺寸 / resize / 渲染循环 / 释放
    // =====================================================================
    function readSize() {
      var w = 0, h = 0;
      try {
        w = container.clientWidth || 0;
        h = container.clientHeight || 0;
      } catch (err) { /* ignore */ }
      return { w: Math.max(0, Math.round(w)), h: Math.max(0, Math.round(h)) };
    }

    function applySize() {
      var s = readSize();
      size = s;
      if (s.w <= 0 || s.h <= 0) {
        canvas.style.visibility = 'hidden';
        return;
      }
      canvas.style.visibility = 'visible';
      var dpr = Math.min(window.devicePixelRatio || 1, MAX_DPR);
      renderer.setPixelRatio(dpr);
      renderer.setSize(s.w, s.h, false);
      camera.aspect = s.w / s.h;
      camera.updateProjectionMatrix();
      // 按容器宽高比自适应取景
      computeFraming();
      dprNow = dpr;
    }

    function resize() {
      sizeDirty = false;
      if (disposed) return;
      applySize();
    }

    var dprNow = 1;
    var rafId = 0;
    var lastFrameTs = 0;
    var lastErrTs = 0;
    var fpsFrames = 0;
    var fpsTs = 0;
    var fps = 0;
    var lastTriangles = 0;
    var lastCalls = 0;

    function reportFrameError(err) {
      var t = nowMs();
      if (t - lastErrTs < 1000) return;
      lastErrTs = t;
      pushError('frame', err);
    }

    function loop(ts) {
      rafId = window.requestAnimationFrame(loop);
      if (disposed) return;
      try {
        if (sizeDirty) resize();
        if (size.w <= 0 || size.h <= 0) return;
        if (document.hidden) return;
        var dt = lastFrameTs ? Math.min(0.1, (ts - lastFrameTs) / 1000) : 0.016;
        lastFrameTs = ts;
        step(dt, ts);
        renderer.render(scene, camera);
        lastTriangles = renderer.info && renderer.info.render ? renderer.info.render.triangles : 0;
        lastCalls = renderer.info && renderer.info.render ? renderer.info.render.calls : 0;
        fpsFrames++;
        if (ts - fpsTs > 500) {
          fps = fpsTs ? (fpsFrames * 1000) / (ts - fpsTs) : 0;
          fpsFrames = 0;
          fpsTs = ts;
        }
      } catch (err) {
        reportFrameError(err);
      }
    }

    // 初始尺寸 + 监听
    applySize();
    if (typeof window.ResizeObserver !== 'undefined') {
      try {
        ro = new window.ResizeObserver(function () { sizeDirty = true; });
        ro.observe(container);
      } catch (err) {
        pushError('resizeobserver', err);
      }
    }
    function onWinResize() { sizeDirty = true; }
    window.addEventListener('resize', onWinResize);

    // 初始无数据：显示 '--' 与缓慢待机呼吸
    refreshLabels();
    rafId = window.requestAnimationFrame(loop);

    function dispose() {
      if (disposed) return;
      disposed = true;
      try { window.cancelAnimationFrame(rafId); } catch (err) { /* ignore */ }
      window.removeEventListener('resize', onWinResize);
      if (ro) {
        try { ro.disconnect(); } catch (err) { /* ignore */ }
        ro = null;
      }
      if (INTERACTIVE) {
        canvas.removeEventListener('pointerdown', onPointerDown);
        canvas.removeEventListener('pointermove', onPointerMove);
        canvas.removeEventListener('pointerup', onPointerUp);
        canvas.removeEventListener('pointercancel', onPointerUp);
        canvas.removeEventListener('wheel', onWheel);
        canvas.removeEventListener('dblclick', onDblClick);
      }
      // 释放场景内几何 / 材质 / 贴图
      try {
        scene.traverse(function (obj) {
          if (obj.geometry) {
            try { obj.geometry.dispose(); } catch (err) { /* ignore */ }
          }
          var mats = obj.material ? (Array.isArray(obj.material) ? obj.material : [obj.material]) : [];
          for (var i = 0; i < mats.length; i++) {
            var m = mats[i];
            if (!m) continue;
            if (m.map) { try { m.map.dispose(); } catch (err) { /* ignore */ } }
            if (m.emissiveMap) { try { m.emissiveMap.dispose(); } catch (err) { /* ignore */ } }
            if (m.alphaMap) { try { m.alphaMap.dispose(); } catch (err) { /* ignore */ } }
            try { m.dispose(); } catch (err) { /* ignore */ }
          }
        });
        if (glowTex) glowTex.dispose();
        if (envRT) envRT.dispose();
      } catch (err) {
        pushError('dispose', err);
      }
      try { renderer.dispose(); } catch (err) { /* ignore */ }
      try { if (renderer.forceContextLoss) renderer.forceContextLoss(); } catch (err) { /* ignore */ }
      // 移除本实例创建的 DOM
      [canvas, uiEl].forEach(function (el) {
        if (el && el.parentNode) el.parentNode.removeChild(el);
      });
      styleEls.forEach(function (el) {
        if (el.parentNode) el.parentNode.removeChild(el);
      });
      styleEls = [];
    }

    function getStats() {
      return {
        fps: Math.round(fps * 10) / 10,
        triangles: lastTriangles,
        calls: lastCalls,
        w: size.w,
        h: size.h,
        dpr: dprNow,
        dist: Math.round(baseDist * 10) / 10,
        targetY: Math.round(baseTargetY * 100) / 100,
        fallback: false
      };
    }

    return {
      update: update,
      resize: function () { sizeDirty = false; applySize(); },
      setCamera: setCamera,
      resetCamera: resetCamera,
      dispose: dispose,
      getStats: getStats
    };
  }

})();
