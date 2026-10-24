# 开放插件

Skivu 0.2.38 / SDK 1.0 支持独立的 HTML/CSS/JavaScript 插件，包括 ES modules、Canvas、随包资源、交互页面、聊天动作和完整聊天界面。插件无需宿主内的第三方 ID/renderer 白名单；安装后由用户授权、启用。实际业务代码由插件包下载，不编入 APK。

从插件市场进入「开放插件与开发者」，可从官方或用户添加的 HTTPS 目录安装，也可导入本地 `.skivu.json`。官方目录协议为 `3.0`，与保留的界面预设协议 `1.0`、技能/MCP 协议 `2.0` 分开。下载校验 SHA-256、精确字节数、清单与最低版本；失败保留旧包，更新重置授权。默认卸载保留本插件存档，也可选择一并清除。

开发规范、打包工具、类型定义和完整可编辑示例：[Skivu Plugins](https://github.com/skyjjgw/skivu-plugins/blob/main/docs/open-plugin-sdk.md)。使用 `python tools/build_web_plugin.py templates/web-plugin --output dist/my-plugin.skivu.json` 打包。宿主自动提供 `/skivu-sdk.js`，通过 `await Skivu.call(method, params)` 调用能力；`host.info` 用于能力探测。

已开放：按插件隔离的原子存档、文件工作区、第三方密钥、系统文件选择与保存、剪贴板、所选角色/聊天上下文、经确认的角色修改/消息写入、角色提示词贡献、模型文字生成、权限控制的外部网络。网络支持自定义域名/端口；另获 `network.local` 权限后，可连接用户自己的本机/局域网/HTTP 辅助服务，用其提供 Python、Node 或 stdio MCP。App 不直接执行任意 shell 或原生反射。

模型生成每次由宿主确认，沿用当前模型、账号/内测鉴权、额度和未发布模型保护；返回文字与 usage，不返回配置或身份材料。插件无法读取宿主账号、模型密钥、签名、后台管理能力或服务器内部配置。插件自己的 secrets 空间仅用于其自有第三方服务。

Android 独立编写的 WebView 平台视图仅服务当前包的虚拟源，禁止直接外部页面、iframe、文件 URL、任意原生桥和浏览器原始联网；外部通信经权限代理。代理不附加宿主身份，不跟随跳转，对解析后的目标地址固定连接并保留 TLS 主机名验证。宿主服务器、其解析地址和云元数据/链路本地地址不向插件开放。运行页关闭、停用、卸载或更新后拒绝迟到的桥接响应，取消模型和网络任务。

当前运行平台为 Android，Web 手机预览能编译但不执行开放插件。单包 32 MiB，解码资源合计 24 MiB；单资源/文件/网络响应 8 MiB，512 个包内资源；单个 JSON 存档 10 MiB、每插件存档 64 MiB、文件工作区 128 MiB。插件没有后台常驻执行承诺，可靠保存必须等待 API 成功，不能依赖 unload。旧技能和手动 MCP 的能力与限制见 [EXTENSION-MARKET.md](EXTENSION-MARKET.md)。

实现参考 [Android WebView 桥接边界](https://developer.android.com/privacy-and-security/risks/insecure-webview-native-bridges)、[WebSettings](https://developer.android.com/reference/android/webkit/WebSettings) 和 [Flutter Platform Views](https://docs.flutter.dev/platform-integration/android/platform-views)。宿主与 SDK 为独立实现，没有搬用其他 App 的插件宿主/运行时。
