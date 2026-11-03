/* =====================================================================
 * J280 半透明可拖动参数卡片（window.J280Cards）
 *
 * 职责（UI_PORT_SPEC.md 8.2）：
 *   - createCard：生成 .param-card 玻璃卡片（DOM 严格按 spec 4.2），
 *     卡头拖动（setPointerCapture + 4px 阈值）、折叠、最前 z-index、onChange 回调；
 *   - autoStack：初次纵向堆叠，超出 #stage 高度时从尾部开始折叠；
 *   - clampToStage：把卡片夹在 #stage 内。
 * 不负责参数值业务 / 发送逻辑（由 params.js 的行与 app.js 回调处理）。
 * 经典 script + IIFE，只暴露 window.J280Cards，无网络依赖。
 * ===================================================================== */
(function (global) {
  'use strict';

  var cardSeq = 0;
  var zTop = 100;
  var DRAG_THRESHOLD = 4;

  function toNumber(value, fallback) {
    var number = Number(value);
    return isFinite(number) ? number : fallback;
  }

  function clamp(value, low, high) {
    if (high < low) {
      return low;
    }
    return Math.max(low, Math.min(high, value));
  }

  /** #stage 在 #cardLayer 坐标系里的可视范围（layer 缺省时退回 stage 视口）。 */
  function stageBox() {
    var fallback = {
      left: 0,
      top: 0,
      width: toNumber(global.innerWidth, 1280),
      height: toNumber(global.innerHeight, 800)
    };
    var stage = document.getElementById('stage');
    if (!stage) {
      return fallback;
    }
    var layer = document.getElementById('cardLayer');
    var stageRect = stage.getBoundingClientRect();
    var layerRect = layer ? layer.getBoundingClientRect() : stageRect;
    return {
      left: stageRect.left - layerRect.left,
      top: stageRect.top - layerRect.top,
      width: stage.clientWidth || stageRect.width || fallback.width,
      height: stage.clientHeight || stageRect.height || fallback.height
    };
  }

  function readPos(el) {
    return {
      x: toNumber(parseFloat(el.style.left), 0),
      y: toNumber(parseFloat(el.style.top), 0)
    };
  }

  function isDragExcluded(target) {
    if (!target || !target.closest) {
      return false;
    }
    return !!target.closest('button, input, select, textarea, a, .card-collapse');
  }

  /** 把任意卡片元素夹在 #stage 内（供 app.js 布局/窗口尺寸变化后调用）。 */
  function clampToStage(el) {
    if (!el) {
      return null;
    }
    var box = stageBox();
    var width = el.offsetWidth || (el.getBoundingClientRect ? el.getBoundingClientRect().width : 0);
    var height = el.offsetHeight || (el.getBoundingClientRect ? el.getBoundingClientRect().height : 0);
    var pos = readPos(el);
    var x = Math.round(clamp(pos.x, box.left, box.left + Math.max(0, box.width - width)));
    var y = Math.round(clamp(pos.y, box.top, box.top + Math.max(0, box.height - height)));
    el.style.left = x + 'px';
    el.style.top = y + 'px';
    return {x: x, y: y};
  }

  /**
   * 创建一张参数卡片。
   * @param {Object} options {id,title,subtitle,width,bodyEl,footerText,maxBodyHeight,
   *                          defaultPos:{x,y},collapsed,badge,onChange(layout)}
   * @returns {Object} Card {el,id,setCollapsed,toggleCollapsed,isCollapsed,setPos,getPos,
   *                         bringToFront,setBadge,destroy}
   */
  function createCard(options) {
    var opts = options || {};
    var id = opts.id == null ? ('card-' + (++cardSeq)) : String(opts.id);
    var title = opts.title == null ? id : String(opts.title);
    var configuredWidth = Math.max(120, toNumber(opts.width, 280));

    var el = document.createElement('article');
    el.className = 'param-card';
    el.setAttribute('data-group', title);
    el.setAttribute('data-card-id', id);
    el.style.width = configuredWidth + 'px';
    el.style.left = '0px';
    el.style.top = '0px';
    el.style.zIndex = String((zTop += 1));

    /* ---------------------------------------------------------- 卡头 */
    var head = document.createElement('header');
    head.className = 'card-head';
    head.setAttribute('data-drag-handle', '');

    var accent = document.createElement('span');
    accent.className = 'card-accent';

    var titleEl = document.createElement('h3');
    titleEl.className = 'card-title';
    titleEl.textContent = title;

    var subEl = document.createElement('span');
    subEl.className = 'card-sub';
    subEl.textContent = opts.subtitle == null ? '' : String(opts.subtitle);

    var badge = document.createElement('span');
    badge.className = 'card-badge';
    badge.textContent = opts.badge == null ? '' : String(opts.badge);

    var collapseBtn = document.createElement('button');
    collapseBtn.type = 'button';
    collapseBtn.className = 'card-collapse';
    collapseBtn.title = '折叠/展开';
    collapseBtn.setAttribute('aria-label', '折叠');
    collapseBtn.textContent = '▾';

    head.appendChild(accent);
    head.appendChild(titleEl);
    head.appendChild(subEl);
    head.appendChild(badge);
    head.appendChild(collapseBtn);

    /* ---------------------------------------------------------- 卡体 / 卡脚 */
    var body = document.createElement('div');
    body.className = 'card-body';
    if (opts.maxBodyHeight != null) {
      body.style.maxHeight = Math.max(0, toNumber(opts.maxBodyHeight, 300)) + 'px';
    }
    if (opts.bodyEl) {
      body.appendChild(opts.bodyEl);
    }

    var foot = null;
    var footerText = (opts.footerText === null || opts.footerText === undefined)
      ? '回车发送单项 · 悬停查看说明'
      : String(opts.footerText);
    if (footerText) {
      foot = document.createElement('footer');
      foot.className = 'card-foot';
      var hint = document.createElement('span');
      hint.className = 'card-hint';
      hint.textContent = footerText;
      foot.appendChild(hint);
    }

    el.appendChild(head);
    el.appendChild(body);
    if (foot) el.appendChild(foot);

    var layer = document.getElementById('cardLayer');
    if (layer) {
      layer.appendChild(el);
    }

    /* ---------------------------------------------------------- 状态 / 回调 */
    function readLayout() {
      var pos = readPos(el);
      return {id: id, x: pos.x, y: pos.y, collapsed: isCollapsed()};
    }

    function emitChange() {
      if (typeof opts.onChange === 'function') {
        opts.onChange(readLayout());
      }
    }

    function isCollapsed() {
      return el.classList.contains('collapsed');
    }

    function setCollapsed(value, silent) {
      var next = !!value;
      if (isCollapsed() === next) {
        return;
      }
      el.classList.toggle('collapsed', next);
      collapseBtn.setAttribute('aria-label', next ? '展开' : '折叠');
      if (!silent) {
        emitChange();
      }
    }

    function toggleCollapsed() {
      setCollapsed(!isCollapsed(), false);
    }

    function setBadge(text) {
      badge.textContent = (text == null) ? '' : String(text);
    }

    function bringToFront() {
      zTop += 1;
      el.style.zIndex = String(zTop);
      return zTop;
    }

    function setPos(x, y) {
      var box = stageBox();
      var widthNow = el.offsetWidth || configuredWidth;
      var heightNow = el.offsetHeight || 0;
      var nextX = Math.round(clamp(toNumber(x, 0), box.left,
        box.left + Math.max(0, box.width - widthNow)));
      var nextY = Math.round(clamp(toNumber(y, 0), box.top,
        box.top + Math.max(0, box.height - heightNow)));
      el.style.left = nextX + 'px';
      el.style.top = nextY + 'px';
      return {x: nextX, y: nextY};
    }

    function getPos() {
      return readPos(el);
    }

    /* ---------------------------------------------------------- 拖动（4px 阈值） */
    var drag = null;

    function onPointerDown(event) {
      if (drag) {
        return;
      }
      if (event.button !== undefined && event.button !== 0) {
        return;
      }
      if (isDragExcluded(event.target)) {
        return;
      }
      var pos = readPos(el);
      drag = {
        pointerId: event.pointerId,
        startX: toNumber(event.clientX, 0),
        startY: toNumber(event.clientY, 0),
        left: pos.x,
        top: pos.y,
        moved: false,
        target: event.target
      };
      if (head.setPointerCapture && event.pointerId !== undefined) {
        try {
          head.setPointerCapture(event.pointerId);
        } catch (error) {
          /* 合成事件 / 指针已失效时不阻塞拖动逻辑 */
        }
      }
      bringToFront();
      if (event.preventDefault) {
        event.preventDefault();
      }
    }

    function onPointerMove(event) {
      if (!drag) {
        return;
      }
      if (drag.pointerId !== undefined && event.pointerId !== undefined &&
          drag.pointerId !== event.pointerId) {
        return;
      }
      var dx = toNumber(event.clientX, drag.startX) - drag.startX;
      var dy = toNumber(event.clientY, drag.startY) - drag.startY;
      if (!drag.moved) {
        if (Math.sqrt(dx * dx + dy * dy) <= DRAG_THRESHOLD) {
          return;
        }
        drag.moved = true;
        el.classList.add('dragging');
      }
      var box = stageBox();
      var widthNow = el.offsetWidth || configuredWidth;
      var heightNow = el.offsetHeight || 0;
      var x = clamp(drag.left + dx, box.left, box.left + Math.max(0, box.width - widthNow));
      var y = clamp(drag.top + dy, box.top, box.top + Math.max(0, box.height - heightNow));
      el.style.left = Math.round(x) + 'px';
      el.style.top = Math.round(y) + 'px';
      if (event.preventDefault) {
        event.preventDefault();
      }
    }

    function releaseCapture(pointerId) {
      if (head.releasePointerCapture && pointerId !== undefined) {
        try {
          head.releasePointerCapture(pointerId);
        } catch (error) {
          /* 已被释放或指针失效，忽略 */
        }
      }
    }

    function onPointerUp(event) {
      if (!drag) {
        return;
      }
      var state = drag;
      drag = null;
      el.classList.remove('dragging');
      releaseCapture(state.pointerId);
      if (state.moved) {
        emitChange();
        return;
      }
      // 未超过 4px：视为点击卡头空白处 → 折叠/展开。
      if (!isDragExcluded(state.target || event.target)) {
        toggleCollapsed();
      }
    }

    function onPointerCancel() {
      if (!drag) {
        return;
      }
      var state = drag;
      drag = null;
      el.classList.remove('dragging');
      releaseCapture(state.pointerId);
    }

    head.addEventListener('pointerdown', onPointerDown);
    head.addEventListener('pointermove', onPointerMove);
    head.addEventListener('pointerup', onPointerUp);
    head.addEventListener('pointercancel', onPointerCancel);

    collapseBtn.addEventListener('click', function (event) {
      event.preventDefault();
      event.stopPropagation();
      toggleCollapsed();
    });

    if (opts.collapsed) {
      el.classList.add('collapsed');
      collapseBtn.setAttribute('aria-label', '展开');
    }

    /* ---------------------------------------------------------- 初始位置 */
    var defaultPos = opts.defaultPos || {};
    setPos(toNumber(defaultPos.x, 10), toNumber(defaultPos.y, 10));

    function destroy() {
      drag = null;
      el.classList.remove('dragging');
      if (el.parentNode) {
        el.parentNode.removeChild(el);
      }
    }

    return {
      el: el,
      id: id,
      setCollapsed: setCollapsed,
      toggleCollapsed: toggleCollapsed,
      isCollapsed: isCollapsed,
      setPos: setPos,
      getPos: getPos,
      bringToFront: bringToFront,
      setBadge: setBadge,
      destroy: destroy
    };
  }

  /**
   * 初次纵向堆叠；超出 #stage 可用高度时从尾部开始折叠，直到放得下。
   * @param {Array} cards createCard 返回的卡片数组
   * @param {Object} options {x, y, gap, bottomMargin}
   * @returns {{collapsed: string[]}}
   */
  function autoStack(cards, options) {
    var opts = options || {};
    var list = (cards || []).filter(function (card) {
      return !!card && !!card.el;
    });
    if (!list.length) {
      return {collapsed: []};
    }
    var startX = toNumber(opts.x, 10);
    var startY = toNumber(opts.y, 10);
    var gap = Math.max(0, toNumber(opts.gap, 10));
    var bottomMargin = Math.max(0, toNumber(opts.bottomMargin, 12));
    var box = stageBox();
    var available = Math.max(0, box.height - startY - bottomMargin);

    function heights() {
      return list.map(function (card) {
        return card.el.offsetHeight || 0;
      });
    }

    function total(listHeights) {
      var sum = 0;
      for (var index = 0; index < listHeights.length; index += 1) {
        sum += listHeights[index];
      }
      return sum + gap * Math.max(0, listHeights.length - 1);
    }

    var sizes = heights();
    var collapsed = [];
    for (var index = list.length - 1; index >= 0; index -= 1) {
      if (total(sizes) <= available) {
        break;
      }
      if (list[index].isCollapsed()) {
        continue;
      }
      list[index].setCollapsed(true, true);
      collapsed.push(list[index].id);
      sizes[index] = list[index].el.offsetHeight || 0;
    }

    var y = startY;
    for (var cursor = 0; cursor < list.length; cursor += 1) {
      list[cursor].setPos(startX, y);
      y += (list[cursor].el.offsetHeight || 0) + gap;
    }
    return {collapsed: collapsed};
  }

  global.J280Cards = {
    createCard: createCard,
    autoStack: autoStack,
    clampToStage: clampToStage
  };
})(typeof window !== 'undefined' ? window : this);
