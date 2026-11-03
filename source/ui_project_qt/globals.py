# This Python file uses the following encoding: utf-8
import os
import sys


def _is_frozen() -> bool:
    return bool(getattr(sys, "frozen", False))


class globalVar:
    # 源码运行：ui_project_qt/；exe 运行：exe 所在目录（res/ 与 data/ 放在 exe 旁边）
    IS_FROZEN = _is_frozen()
    SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
    APP_DIR = (os.path.dirname(os.path.abspath(sys.executable))
               if IS_FROZEN else SOURCE_DIR)
    RES_DIR = os.path.join(APP_DIR, "res")
    DATA_DIR = os.path.join(APP_DIR, "data")
    # 兼容旧引用：源码工程目录
    PROJECT_DIR = SOURCE_DIR
