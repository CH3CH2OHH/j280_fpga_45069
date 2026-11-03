# three.js（本地 vendored，离线使用）

- 文件：`three.min.js`
- 版本：**r149 / 0.149.0**（UMD 经典构建，全局 `THREE`）
- 来源：`https://cdn.jsdelivr.net/npm/three@0.149.0/build/three.min.js`（构建时下载，运行时**不访问网络**）
- 许可：MIT（three.js 项目）
- 用途：`../js/model3d.js` 的旋转倒立摆 3D 渲染

注意：

1. QWebEngine 以 `file://` 加载页面，**ES module 会被 CORS 拦截**，因此必须保留这种 UMD 经典构建；
2. 不要把引用改成 CDN/网络地址，本工程要求完全离线可用；
3. 升级版本时需同时确认 `THREE` 全局 API 与 `model3d.js` 兼容，并重新跑
   `ui_project_qt/tests/capture_qt.py` 与 `_dev/model3d-dev/model_test.html` 回归。
