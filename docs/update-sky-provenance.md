# 更新页星空来源

背景沿用用户指定的 [Skymoni 网站](https://skymoni.com/) 深色主题，而非重新生成另一套星空。

- 上游：`skyjjgw/skymoni-source`，`frontend/web/src/features/home-discovery/void-backdrop.tsx`。
- 固定来源提交：`6424caee779b19d72f1aa636fed086d4b1b38c92`。
- 保留蓝黑色 RGB 配方、五层噪声、斜向银河、8129 随机种子、冷暖星点及光晕。
- 原生更新页使用网站背景首帧的离线渲染图 `assets/branding/skymoni-night-sky.png`。不依赖联网加载，不运行网站的鼠标排斥、漂移或流星；更新检查和说明展开动画由原生页面独立驱动。
- 复现：在安装 numpy/Pillow 的 Python 环境运行 `python scripts/render_skymoni_update_sky.py`。固定画幅 1080×2400，等效网站 412×916 CSS 像素；其他屏幕按比例覆盖裁切。

生成器是上游 AGPL-3.0-only 程序的独立适配，完整许可见 `licenses/SkymoniSky-AGPL-3.0.txt`。生成器随公开源码提供，不链接或打入 App。生成的背景图为该程序的图像输出，未包含程序代码，随本项目原创视觉材料按 GPL-3.0-only 提供。

2026-10-24 已核对线上发布包 `static/js/index.00646bde16.js`，SHA-256 `782a25a0af121ff665ad5be9cee961da4d35041564b5a5d896973205bc8ca148`，含同一噪声参数和 8129 种子。
