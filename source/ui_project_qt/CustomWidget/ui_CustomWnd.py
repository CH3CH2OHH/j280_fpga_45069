# -*- coding: utf-8 -*-

################################################################################
## Form generated from reading UI file 'CustomWnd.ui'
##
## Created by: Qt User Interface Compiler version 6.12.0
##
## WARNING! All changes made in this file will be lost when recompiling UI file!
################################################################################

from PySide6.QtCore import (QCoreApplication, QDate, QDateTime, QLocale,
    QMetaObject, QObject, QPoint, QRect,
    QSize, QTime, QUrl, Qt)
from PySide6.QtGui import (QBrush, QColor, QConicalGradient, QCursor,
    QFont, QFontDatabase, QGradient, QIcon,
    QImage, QKeySequence, QLinearGradient, QPainter,
    QPalette, QPixmap, QRadialGradient, QTransform)
from PySide6.QtWidgets import (QApplication, QFrame, QHBoxLayout, QMainWindow,
    QPushButton, QSizePolicy, QSpacerItem, QVBoxLayout,
    QWidget)

class Ui_MainWindow(object):
    def setupUi(self, MainWindow):
        if not MainWindow.objectName():
            MainWindow.setObjectName(u"MainWindow")
        MainWindow.resize(659, 375)
        MainWindow.setCursor(QCursor(Qt.CursorShape.ArrowCursor))
        icon = QIcon()
        icon.addFile(u"icon.ico", QSize(), QIcon.Mode.Normal, QIcon.State.Off)
        MainWindow.setWindowIcon(icon)
        MainWindow.setStyleSheet(u"QFrame{\n"
"	border:none;\n"
"	margin: 0px;\n"
"}")
        self.baseWidget = QWidget(MainWindow)
        self.baseWidget.setObjectName(u"baseWidget")
        self.baseWidget.setStyleSheet(u"#baseWidget {\n"
"	background-color: #ffffff; \n"
"}")
        self.verticalLayout = QVBoxLayout(self.baseWidget)
        self.verticalLayout.setSpacing(0)
        self.verticalLayout.setObjectName(u"verticalLayout")
        self.verticalLayout.setContentsMargins(4, 4, 4, 4)
        self.wndBar = QFrame(self.baseWidget)
        self.wndBar.setObjectName(u"wndBar")
        self.wndBar.setMaximumSize(QSize(16777215, 30))
        self.wndBar.setCursor(QCursor(Qt.CursorShape.ArrowCursor))
        self.wndBar.setStyleSheet(u"#wndBar {\n"
"	background-color: #ffffff;\n"
"}")
        self.wndBar.setLineWidth(0)
        self.wndBarLayout = QHBoxLayout(self.wndBar)
        self.wndBarLayout.setSpacing(0)
        self.wndBarLayout.setObjectName(u"wndBarLayout")
        self.wndBarLayout.setContentsMargins(0, 0, 0, 0)
        self.wndBarXspacer = QSpacerItem(40, 20, QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Minimum)

        self.wndBarLayout.addItem(self.wndBarXspacer)

        self.btnMin = QPushButton(self.wndBar)
        self.btnMin.setObjectName(u"btnMin")
        self.btnMin.setMaximumSize(QSize(16777215, 16777215))
        self.btnMin.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        self.btnMin.setStyleSheet(u"QPushButton {\n"
"	border: none;\n"
"	background-color: transparent; \n"
"	min-width: 30px; \n"
"	min-height: 30px; \n"
"	color: rgb(204, 204, 204);\n"
"	font-size: 20px;\n"
"	padding: 0px;    \n"
"}\n"
"\n"
"QPushButton:hover {\n"
"	background-color: rgba(255, 255, 255, 80);   \n"
"	font-size: 22px;\n"
"	color: #000000;\n"
"}\n"
"\n"
"QPushButton:pressed {\n"
"	background-color: #c0c0c0;   \n"
"}")
        self.btnMin.setAutoDefault(False)

        self.wndBarLayout.addWidget(self.btnMin)

        self.btnMax = QPushButton(self.wndBar)
        self.btnMax.setObjectName(u"btnMax")
        self.btnMax.setMaximumSize(QSize(16777215, 16777215))
        self.btnMax.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        self.btnMax.setStyleSheet(u"QPushButton {\n"
"	border: none;\n"
"	background-color: transparent; \n"
"	min-width: 30px; \n"
"	min-height: 30px; \n"
"	color: rgb(204, 204, 204);\n"
"	font-size: 20px;\n"
"	padding: 0px;    \n"
"}\n"
"\n"
"QPushButton:hover {\n"
"	background-color: rgba(255, 255, 255, 80);   \n"
"	font-size: 22px;\n"
"	color: #000000;\n"
"}\n"
"\n"
"QPushButton:pressed {\n"
"	background-color: #c0c0c0;   \n"
"}")

        self.wndBarLayout.addWidget(self.btnMax)

        self.btnClose = QPushButton(self.wndBar)
        self.btnClose.setObjectName(u"btnClose")
        self.btnClose.setMinimumSize(QSize(30, 30))
        self.btnClose.setMaximumSize(QSize(16777215, 16777215))
        self.btnClose.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        self.btnClose.setStyleSheet(u"QPushButton {\n"
"	border: none;\n"
"	background-color: transparent; \n"
"	min-width: 30px; \n"
"	min-height: 30px; \n"
"	color: rgb(204, 204, 204);\n"
"	font-size: 20px;\n"
"	padding: 0px;    \n"
"}\n"
"QPushButton:hover {\n"
"	background-color: rgba(173, 0, 3, 180);\n"
"	color: #ffffff;\n"
"	font-size: 22px;\n"
"}\n"
"QPushButton:pressed {\n"
"	background-color: rgba(173, 0, 3, 220);   \n"
"}")
        self.btnClose.setFlat(False)

        self.wndBarLayout.addWidget(self.btnClose)


        self.verticalLayout.addWidget(self.wndBar)

        self.content = QFrame(self.baseWidget)
        self.content.setObjectName(u"content")
        self.content.setCursor(QCursor(Qt.CursorShape.ArrowCursor))
        self.content.setStyleSheet(u"#content {\n"
"	background-color: #ffffff; \n"
"}")
        self.content.setFrameShape(QFrame.Shape.StyledPanel)
        self.content.setFrameShadow(QFrame.Shadow.Raised)
        self.content.setLineWidth(0)
        self.contentLayout = QHBoxLayout(self.content)
        self.contentLayout.setSpacing(0)
        self.contentLayout.setObjectName(u"contentLayout")
        self.contentLayout.setContentsMargins(0, 0, 0, 0)

        self.verticalLayout.addWidget(self.content)

        MainWindow.setCentralWidget(self.baseWidget)
        self.content.raise_()
        self.wndBar.raise_()

        self.retranslateUi(MainWindow)

        self.btnMax.setDefault(False)
        self.btnClose.setDefault(False)


        QMetaObject.connectSlotsByName(MainWindow)
    # setupUi

    def retranslateUi(self, MainWindow):
        MainWindow.setWindowTitle(QCoreApplication.translate("MainWindow", u"MainWindow", None))
        self.btnMin.setText(QCoreApplication.translate("MainWindow", u"~", None))
        self.btnMax.setText(QCoreApplication.translate("MainWindow", u"o", None))
        self.btnClose.setText(QCoreApplication.translate("MainWindow", u"x", None))
    # retranslateUi

