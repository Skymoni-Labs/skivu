# 安卓侧栏预览

`android_mirror.py` 在本机 `127.0.0.1:18771` 展示真实 Android 画面，独立于 `18781` 的 Flutter Web 预览。默认设备为已有的 `emulator-5554`，不创建或清空模拟器。

```powershell
python E:/zzz/ski-independent-ui/scripts/android_mirror.py
```

依赖已有 ADB 和开发机的 FFmpeg：默认路径写在脚本参数中，可用 `--adb` / `--ffmpeg` 指定。当前 FFmpeg 来自 PyPI 的 imageio-ffmpeg 0.6.0（封装 BSD-2-Clause，附带 GPL-enabled FFmpeg 7.1），安装于 D 盘构建工具目录，仅用于开发机视频转码，不进入 App、Web 发布包或仓库。

画面经 Android screenrecord H264 → FFmpeg MJPEG 连续传输；每个浏览器只取最新帧。静止页面的帧数可能不增长，不用此数值作为 App 性能基准。页面中的点击和松手后的滑动经 ADB 注入；鼠标拖动过程中不会实时驱动手机手势，键盘输入暂由 Android 自身处理。

服务仅监听 loopback，输入要求同源、随机会话令牌及 Skivu 在前台。不要把服务映射到公网。`/status` 可核对画面就绪和累计帧数。模拟器与服务为开发进程，重启电脑后需重新启动。结束服务时同时结束该脚本创建的 screenrecord 与 FFmpeg 子进程。
