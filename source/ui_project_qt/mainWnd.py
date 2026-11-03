# This Python file uses the following encoding: utf-8
"""J280 HTML 调试台窗口：无边框外壳 + QWebEngineView + QWebChannel。

本文件负责把 Python 后端 ``bridge.SerialBridge`` 以对象名 ``qt_mainWnd``
注册进 QWebChannel，并加载 ``res/main.html``。串口只由 Python 持有，前端
通过 ``window.J280Bridge`` 调用（见 res/js/bridge.js）。
"""

import json
import os

from PySide6.QtCore import QEvent, QObject, Qt, Signal, Slot
from PySide6.QtGui import QKeySequence, QShortcut
from PySide6.QtWebEngineCore import QWebEngineSettings
from PySide6.QtWidgets import QLabel

from CustomWidget.CustomWnd import CustomWnd
from bridge import SerialBridge
from globals import globalVar

# 深色窗口配色（wndBar / baseWidget / content）与网页背景
WND_BAR_COLOR = "#0a1520"
WND_BASE_COLOR = "#060d16"
WND_CONTENT_COLOR = "#040a12"
WEB_BG_COLOR = "#040a12"
WND_TITLE = "J280 上位机控制系统"


class WindowBridge(QObject):
    """仅暴露窗口全屏控制的轻量 QWebChannel 对象（注册名 qt_window）。

    不直接把 QMainWindow 注册进 WebChannel，避免其大量 Qt 属性产生
    “has no notify signal”警告。
    """

    fullscreenChanged = Signal(bool)

    def __init__(self, window: "mainWnd") -> None:
        super().__init__(window)
        self._window = window

    @Slot(result=str)
    def getWindowState(self) -> str:
        return self._window.getWindowState()

    @Slot(bool, result=str)
    def setFullscreen(self, enabled: bool) -> str:
        return self._window.setFullscreen(enabled)

    @Slot(result=str)
    def toggleFullscreen(self) -> str:
        return self._window.toggleFullscreen()


class mainWnd(CustomWnd):
    """主窗体：保留 CustomWnd 的无边框/缩放/标题栏逻辑，换成 HTML 界面。"""

    # 供前端按钮/状态更新使用（QWebChannel 对象 qt_window）
    fullscreenChanged = Signal(bool)

    def __init__(self, minisize: tuple[int, int] = (1280, 800),
                 size: tuple[int, int] = (1280, 720)) -> None:
        super().__init__(minisize=minisize, size=size)
        self.setWindowTitle("J280 上位机控制系统")
        self.setWndValue(
            wnd_color=(WND_BAR_COLOR, WND_BASE_COLOR, WND_CONTENT_COLOR),
            resize_enable=True,
            wa_native_wnd=True,
        )

        # 全屏状态：进入时去掉 4px 外边距并隐藏标题栏（不可拖动），退出时恢复。
        # 注意：_fullscreen_margins 与 CustomWnd._normal_margins 分开，避免从最大化
        # 进入全屏时把“最大化时的 0 边距”误记为普通窗口边距。
        self._fullscreen_active = False
        self._fullscreen_margins = (4, 4, 4, 4)
        self._fullscreen_resize_enable = getattr(self, "_resize_enable", True)
        self._capture_normal_metrics()
        self._fullscreen_shortcut = QShortcut(QKeySequence("F11"), self)
        self._fullscreen_shortcut.setContext(Qt.ShortcutContext.ApplicationShortcut)
        self._fullscreen_shortcut.activated.connect(self.toggle_fullscreen)
        # Esc：退出全屏（不再用于停机）
        self._escape_shortcut = QShortcut(QKeySequence("Esc"), self)
        self._escape_shortcut.setContext(Qt.ShortcutContext.ApplicationShortcut)
        self._escape_shortcut.activated.connect(self._exit_fullscreen_by_esc)

        # SerialBridge 由 CustomWnd.creat_web_engine 实例化并注册为 qt_mainWnd
        self.creat_web_engine(
            SerialBridge,
            "qt_mainWnd",
            bg_color=WEB_BG_COLOR,
            load_finish_cb=self._html_loaded_finish_cb,
        )
        self._install_title_label()
        self._enable_local_web_settings()
        # 注册窗口控制对象，供 HTML 全屏按钮/状态更新调用
        try:
            self._window_bridge = WindowBridge(self)
            self.fullscreenChanged.connect(self._window_bridge.fullscreenChanged.emit)
            self.channel.registerObject("qt_window", self._window_bridge)
        except Exception as error:
            print(f"[mainWnd] 注册 qt_window 失败: {error}")
        self.load_html(0, os.path.join(globalVar.RES_DIR, "main.html"),
                       from_internet=False)

    # ------------------------------------------------------------------
    # 标题栏
    # ------------------------------------------------------------------
    def _install_title_label(self) -> None:
        """在无边框窗口的标题条左侧加一行小字，避免 30px 条只剩系统按钮。"""
        try:
            label = QLabel(WND_TITLE, self.ui.wndBar)
            label.setStyleSheet(
                "QLabel { color: #3f7c94; background: transparent;"
                " font: 10px 'Consolas'; padding-left: 12px; letter-spacing: 1px; }"
            )
            self.ui.wndBarLayout.insertWidget(0, label)
            self._title_label = label
        except Exception:
            self._title_label = None

    # ------------------------------------------------------------------
    # 全屏 / 最大化
    # ------------------------------------------------------------------
    def _capture_normal_metrics(self) -> None:
        """记录普通窗口下的边距与可缩放状态，供退出全屏时恢复。

        使用 CustomWnd 保存的稳定普通边距，而不是当前 contentsMargins：
        从最大化（边距 0）进入全屏时，若读当前值会把 0 当成普通边距，导致
        全屏退出后窗口边框/缩放手柄消失。
        """
        margins = getattr(self, "_normal_margins", (4, 4, 4, 4))
        self._fullscreen_margins = (margins[0], margins[1], margins[2], margins[3])
        self._fullscreen_resize_enable = getattr(self, "_resize_enable", True)

    def toggle_fullscreen(self) -> None:
        """F11 / HTML 全屏按钮：在真全屏与普通窗口之间切换。"""
        if self.isFullScreen():
            self.showNormal()
        else:
            self._capture_normal_metrics()
            self.showFullScreen()

    def _exit_fullscreen_by_esc(self) -> None:
        """Esc 快捷键：仅在全屏时生效，退出全屏。"""
        if self.isFullScreen():
            self.showNormal()

    def _apply_fullscreen_state(self, fullscreen: bool) -> None:
        if fullscreen == self._fullscreen_active:
            return
        self._fullscreen_active = fullscreen
        if fullscreen:
            # 全屏：去掉内容边距、隐藏标题栏（拖动不可用）
            self.ui.verticalLayout.setContentsMargins(0, 0, 0, 0)
            self.ui.wndBar.hide()
            self._resize_enable = False
        else:
            left, top, right, bottom = self._fullscreen_margins
            self.ui.verticalLayout.setContentsMargins(left, top, right, bottom)
            self.ui.wndBar.show()
            self._resize_enable = self._fullscreen_resize_enable
        try:
            self.fullscreenChanged.emit(bool(fullscreen))
        except Exception:
            pass

    def changeEvent(self, event) -> None:
        if event.type() == QEvent.Type.WindowStateChange:
            try:
                self._apply_fullscreen_state(self.isFullScreen())
            except Exception:
                pass
        super().changeEvent(event)

    # ---- 供 QWebChannel(qt_window) 调用 ---------------------------------
    @Slot(result=str)
    def getWindowState(self) -> str:
        return json.dumps({
            "ok": True,
            "fullscreen": bool(self.isFullScreen()),
            "maximized": bool(self.isMaximized()),
        })

    @Slot(bool, result=str)
    def setFullscreen(self, enabled: bool) -> str:
        if bool(enabled):
            if not self.isFullScreen():
                self.toggle_fullscreen()
        elif self.isFullScreen():
            self.showNormal()
        return self.getWindowState()

    @Slot(result=str)
    def toggleFullscreen(self) -> str:
        self.toggle_fullscreen()
        return self.getWindowState()

    # 标题栏“o”按钮沿用 CustomWnd.maxWnd（最大化/还原）。
    # 最大化时的去边框与标题栏拖动屏蔽在 CustomWnd.eventFilter/changeEvent 中实现。

    # ------------------------------------------------------------------
    # WebEngine 设置
    # ------------------------------------------------------------------
    def _enable_local_web_settings(self) -> None:
        """显式开启本地 file:// 访问与 WebGL（3D 摆杆模型依赖）。"""
        if not self._web_list:
            return
        try:
            settings = self._web_list[0].settings()
        except Exception:
            return
        for attribute_name in (
            "JavascriptEnabled",
            "LocalContentCanAccessFileUrls",
            "WebGLEnabled",
            "Accelerated2dCanvasEnabled",
        ):
            attribute = getattr(QWebEngineSettings.WebAttribute, attribute_name, None)
            if attribute is None:
                continue
            try:
                settings.setAttribute(attribute, True)
            except Exception:
                pass

    # ------------------------------------------------------------------
    # 生命周期
    # ------------------------------------------------------------------
    def _html_loaded_finish_cb(self, ok: bool, web_id: int) -> None:
        print(f"web({web_id})加载完成: {ok}")

    def closeEvent(self, event) -> None:
        """关闭前尽力发送 MODE 0 并释放串口，避免窗口退出后端口仍被占用。"""
        for bridge in getattr(self, "_bridge_list", []):
            shutdown = getattr(bridge, "shutdown", None)
            if callable(shutdown):
                try:
                    shutdown()
                except Exception as error:  # noqa: BLE001 - 关闭阶段不能抛异常
                    print(f"[mainWnd] 关闭串口失败: {error}")
        super().closeEvent(event)
