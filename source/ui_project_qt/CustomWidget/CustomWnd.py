# This Python file uses the following encoding: utf-8
# 导入转化的UI文件
from CustomWidget.ui_CustomWnd import Ui_MainWindow 

# 导入PySide6模块
from PySide6.QtCore import Qt, QPoint, QEvent, QUrl, QObject, QTimer
from PySide6.QtGui import QMouseEvent, QColor
from PySide6.QtWidgets import QMainWindow, QWidget, QLayout, QApplication, QLabel
from PySide6.QtWebEngineWidgets import QWebEngineView
from PySide6.QtWebChannel import QWebChannel
from PySide6.QtWebEngineCore import QWebEnginePage

from typing import Type, Callable
import ctypes

class CustomWnd(QMainWindow):
    def __init__(self, parent:QWidget|None = None, minisize:tuple[int, int] = (600, 400), size:tuple[int, int] = (600, 400))->None:
        '''
        :param minisize: (w, h), 设置窗口最小尺寸
        :param size: (w, h), 设置窗口当前尺寸
        :param enable_trans: 是否支持绘制窗口透明度, 禁用掉提升性能
        :param enable_webengine_optimize: 是否禁用系统默认背景和让系统合成器接管来优化QWebEngine的表现
        '''
        super().__init__(parent)

        self._resize_enable = True

        self.ui = Ui_MainWindow() # 挂载UI控件
        self.ui.setupUi(self)
        # 记录普通窗口的内容边距，最大化时临时置 0（去边框），还原时恢复
        margins = self.ui.verticalLayout.contentsMargins()
        self._normal_margins = (margins.left(), margins.top(),
                                margins.right(), margins.bottom())
        # 设置无边框，无标题栏
        self.setWindowFlags(Qt.WindowType.Window|Qt.WindowType.FramelessWindowHint|Qt.WindowType.WindowMinimizeButtonHint|Qt.WindowType.WindowSystemMenuHint|Qt.WindowType.WindowMaximizeButtonHint)
        self.setMinimumSize(*minisize) # 设置最小大小
        self.resize(*size)
        self.setCenter()

        # 绑定标题栏按钮逻辑
        self.ui.btnClose.released.connect(self.closeWnd)
        self.ui.btnMax.released.connect(self.maxWnd)
        self.ui.btnMin.released.connect(self.minWnd)

        # 对central widget(baseWidget)开鼠标跟踪+事件过滤, 用于缩放热区检测
        self.ui.baseWidget.setMouseTracking(True)
        self.ui.baseWidget.installEventFilter(self)

        # 对标题栏进行事件过滤, 用于标题栏拖拽
        self.ui.wndBar.installEventFilter(self)
        self._not_start_move = True
        self._moving = False
        self._moving_timer = QTimer(self)
        self._moving_timer.setInterval(20)
        self._moving_timer.timeout.connect(self._release_check)

        # QWebEngineView优化项
        self._enable_webengine_optimize = False
        self._web_list: list[QWebEngineView] = []
        self._bridge_list: list[QObject] = []
        self.channel = None
        # 快照容器
        self._pixmap = None
        self._snapshot_label = QLabel(self.ui.content)
        self.ui.contentLayout.addWidget(self._snapshot_label)
        self._snapshot_label.hide()

    def _get_edges(self, pos: QPoint, border: int = 4) -> Qt.Edge|None:
        """
        返回 pos(相对本窗口的坐标)所在的缩放热区对应边; 不在热区则返回 None;
        
        :param pos: 要判断的pos;
        :param border: 缩放热区边宽度;
        """
        if self.isMaximized():
            return None

        w, h = self.width(), self.height()
        x, y = pos.x(), pos.y()

        edges = Qt.Edge(0)
        if x <= border:
            edges |= Qt.Edge.LeftEdge
        elif x >= w - border:
            edges |= Qt.Edge.RightEdge
        if y <= border:
            edges |= Qt.Edge.TopEdge
        elif y >= h - border:
            edges |= Qt.Edge.BottomEdge

        return Qt.Edge(edges) if edges else None

    def _release_check(self):
        buttons = bool(ctypes.windll.user32.GetAsyncKeyState(0x01) & 0x8000)
        if buttons: # 左键仍按住
            return 

        if not self._moving: # 定时器可能会误触发? 以防万一
            self._moving_timer.stop()
            return
        
        if self._enable_webengine_optimize:
            # 清理快照容器
            self._snapshot_label.hide()
            self._snapshot_label.clear()
            self._pixmap = None
            for web in self._web_list:
                web.setVisible(True)
                web.page().setLifecycleState(QWebEnginePage.LifecycleState.Active)
        self._moving_timer.stop()
        self._moving = False

    def eventFilter(self, watched: QWidget, event: QMouseEvent|QEvent):
        '''用事件过滤器递归监听, 实时更新缩放指针于触发原生拖拽缩放'''
        if watched == self.ui.baseWidget and self._resize_enable and isinstance(event, QMouseEvent): # baseWidget
            ev_t = event.type()
            ev_b = event.button()
            if ev_t == QEvent.Type.MouseMove or ev_t == QEvent.Type.Enter: # 鼠标移动
                edges = self._get_edges(event.position().toPoint())
                if edges is None:
                    self.ui.baseWidget.setCursor(Qt.CursorShape.ArrowCursor)
                elif edges == (Qt.Edge.TopEdge|Qt.Edge.LeftEdge) or edges == (Qt.Edge.BottomEdge|Qt.Edge.RightEdge):
                    self.ui.baseWidget.setCursor(Qt.CursorShape.SizeFDiagCursor)
                elif edges == (Qt.Edge.TopEdge|Qt.Edge.RightEdge) or edges == (Qt.Edge.BottomEdge|Qt.Edge.LeftEdge):
                    self.ui.baseWidget.setCursor(Qt.CursorShape.SizeBDiagCursor)
                elif edges & (Qt.Edge.LeftEdge|Qt.Edge.RightEdge):
                    self.ui.baseWidget.setCursor(Qt.CursorShape.SizeHorCursor)
                elif edges & (Qt.Edge.TopEdge|Qt.Edge.BottomEdge):
                    self.ui.baseWidget.setCursor(Qt.CursorShape.SizeVerCursor)
                else:
                    self.ui.baseWidget.setCursor(Qt.CursorShape.ArrowCursor)

            elif ev_t == QEvent.Type.MouseButtonPress and ev_b == Qt.MouseButton.LeftButton: # 鼠标拖动
                edges = self._get_edges(event.position().toPoint())
                if edges is not None:
                    self.windowHandle().startSystemResize(edges) # 启动系统原生缩放
                    return True # 吞掉该事件, 避免与子控件点击冲突

        elif watched == self.ui.wndBar and isinstance(event, QMouseEvent): # wndBar
            # 最大化时去掉边框并屏蔽标题栏拖动；全屏由 mainWnd 处理（隐藏标题栏）
            if self.isMaximized() or self.isFullScreen():
                self._moving = False
                self._not_start_move = True
                return True
            pos = event.position().toPoint()
            ev_t = event.type()
            ev_b = event.button()
            if (ev_b & Qt.MouseButton.LeftButton) and (ev_t == QEvent.Type.MouseButtonPress):
                self._moving = True
                self._not_start_move = True
            
            if self._moving:
                # 左键移动, 且不在标题栏按钮区域
                if ev_t == QEvent.Type.MouseMove and not self.ui.btnMin.geometry().contains(pos) and not self.ui.btnMax.geometry().contains(pos) and not self.ui.btnClose.geometry().contains(pos) and self._not_start_move:
                    if not self.windowHandle().startSystemMove():
                        return False
                    if self._enable_webengine_optimize:
                        # 清理快照容器
                        self._snapshot_label.clear()
                        self._pixmap = None
                        # 截取当前窗口快照
                        self._pixmap = self.ui.content.grab()
                        self._snapshot_label.setPixmap(self._pixmap)
                        # 冻结所有 webview
                        for web in self._web_list:
                            web.setVisible(False)
                            web.page().setLifecycleState(QWebEnginePage.LifecycleState.Frozen)
                        self._snapshot_label.show()
                    
                    self._not_start_move = False
                    self._moving_timer.start()
                    return True
                
            
        return super().eventFilter(watched, event)

    def changeEvent(self, event: QEvent) -> None:
        """窗口最大化/还原时切换内容边距（最大化去边框，还原恢复）。"""
        if event.type() == QEvent.Type.WindowStateChange:
            self._sync_maximized_chrome()
        super().changeEvent(event)

    def _sync_maximized_chrome(self) -> None:
        """最大化（非全屏）时把内容边距置 0；普通窗口恢复保存的边距。

        全屏由 mainWnd 统一处理（隐藏标题栏、边距 0），这里不覆盖。
        """
        if self.isFullScreen():
            return
        left, top, right, bottom = self._normal_margins
        if self.isMaximized():
            self.ui.verticalLayout.setContentsMargins(0, 0, 0, 0)
            self.ui.wndBar.setCursor(Qt.CursorShape.ArrowCursor)
        else:
            self.ui.verticalLayout.setContentsMargins(left, top, right, bottom)

    def closeWnd(self):
        """关闭窗口"""
        self.close()

    def minWnd(self)->None:
        """风格化关闭按钮的回调函数"""
        self.showMinimized()

    def maxWnd(self)->None:
        """窗口最大化+还原的回调函数"""
        # 借由系统 MINMAXINFO 限制, 最大化/还原都由 Qt 原生完成
        if self.isMaximized():
            self.showNormal()
        else:
            self.showMaximized()

    def setWndValue(self, btn_visible:tuple[bool|None, bool|None, bool|None] = (None, None, None), resize_enable:bool|None = None, minisize:tuple[None|int, None|int] = (None, None), wnd_color:tuple[None|str, None|str, None|str] = (None, None, None), wa_native_wnd:bool|None = None, wa_trans_bg:bool|None = None)-> None:
        """
        setWndValue 的 Docstring

        :param btn_visible: (min, max, close), True=显示, False=隐藏;
        :param resize_enable: 是否允许改变窗口大小, True=启用, False=禁用;
        :param minisize: 窗口的最小尺寸, (w, h);
        :param wnd_color: 窗口颜色值, (wndBar, wndBorder, wndBg), #RRGGBBAA;
        :param wa_native_wnd: 是否使用本地窗口, True=使用, False=不使用, 当窗口含有opengl|webengine时, 建议置True;
        :param wa_trans_bg: 是否使用透明背景, True=使用, False=不使用;
        """
        if btn_visible[0] is not None:
            self.ui.btnMin.setVisible(btn_visible[0])

        if btn_visible[1] is not None:
            self.ui.btnMax.setVisible(btn_visible[1])

        if btn_visible[2] is not None:
            self.ui.btnClose.setVisible(btn_visible[2])

        if (resize_enable is not None):
            self._resize_enable = resize_enable

        # 这样写是为了只调用一次父类函数
        if (minisize[0] is not None) and minisize[1] is None:
            self.setMinimumSize(minisize[0], self.minimumSize().height())
        elif (minisize[1] is not None) and minisize[0] is None:
            self.setMinimumSize(self.minimumSize().width(), minisize[1])
        elif (minisize[1] is not None) and (minisize[0] is not None):
            self.setMinimumSize(minisize[0], minisize[1])

        if wnd_color[0] is not None:
            self.ui.wndBar.setStyleSheet("#wndBar {background-color:"+ str(wnd_color[0]) +";}")

        if wnd_color[1] is not None:
            self.ui.baseWidget.setStyleSheet("#baseWidget {background-color:"+ str(wnd_color[1]) +";}")

        if wnd_color[2] is not None:
            self.ui.content.setStyleSheet("#content {background-color:"+ str(wnd_color[2]) +";}")

        if wa_native_wnd is not None:
            self.setAttribute(Qt.WidgetAttribute.WA_NativeWindow, wa_native_wnd)

        if wa_trans_bg is not None:
            self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, wa_trans_bg)

    def setCenter(self)->None:
        """使本窗口窗口居中于中心, 如果有父窗口, 居于父窗口中心; 如果没有, 居于屏幕中心"""
        p_wnd = self.parentWidget()
        s_rect = self.geometry()  # 获取窗口的位置矩形

        if p_wnd is not None:
            # 有父窗口: s_rect是相对父窗口的局部坐标，无需加父窗口x、y
            p_w = p_wnd.width()
            p_h = p_wnd.height()
            self.move((p_w - s_rect.width()) // 2, (p_h - s_rect.height()) // 2) # 计算相对居中位置的偏移
        else:
            # 无父窗口: s_rect是全局坐标
            g_rect = self.screen().availableGeometry() # 获取屏幕大小
            self.move((g_rect.width() - s_rect.width()) // 2, (g_rect.height() - s_rect.height()) // 2)

    def creat_web_engine(self, bridge_cls:Type[QObject], register_name:str, ui_layout:QLayout|None = None, bg_color:str = "#ffffff", load_finish_cb:Callable[[bool, int],None]|None = None):
        """
        创建web engine组件, 铺满self.ui.content
        
        :param bridge_cls: 一个继承自 QObject 的类, 用于和前端通信;
        :param register_name: 前端的注册名称, 不能和以往的注册名称重复;
        :param ui_layout: webview的父布局, 为None时, 添加到self.ui.content.layout()中; 自定义布局时, 请确保布局的父组件在self.ui.content上;
        :param bg_color: webview的背景颜色值;
        :param load_finish_cb: HTML加载完成后的回调函数, 参数为bool(True=成功, False=失败), int(触发事件的webview ID);
        """
        # 1. 创建浏览器组件并挂载到self.ui.content
        web = QWebEngineView()
        web.page().setBackgroundColor(QColor(bg_color))

        if ui_layout is None:
            self.ui.contentLayout.addWidget(web)
        else:
            ui_layout.addWidget(web)

        # 2. 初始化通信通道
        if self.channel is None:
            self.channel = QWebChannel()
        bridge = bridge_cls()
        self.channel.registerObject(register_name, bridge)

        self._web_list.append(web)
        self._bridge_list.append(bridge)
        if load_finish_cb is not None:
            web.loadFinished.connect(lambda load_status: load_finish_cb(load_status, self._bridge_list.index(bridge)))
        
        # 3. 绑定通道到网页
        web.page().setWebChannel(self.channel)
        self._enable_webengine_optimize = True

    def load_html(self, web_id:int, html_path:str, from_internet:bool = False):
        """
        加载html
        
        :param web_id: webview的ID, 从0开始
        :param html_path: html文件路径(绝对路径)
        :param from_internet: True=从互联网加载, False=从本地加载
        """
        if from_internet:
            self._web_list[web_id].load(QUrl(html_path))
        else:
            self._web_list[web_id].load(QUrl.fromLocalFile(html_path))
