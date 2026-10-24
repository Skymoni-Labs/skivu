<p align="center">
  <a href="https://skymoni.com/skivu/#gh-light-mode-only">
    <img src="docs/images/skivu-cover-zh.svg?v=brand-lockup#gh-light-mode-only" width="1280" alt="Skivu — 你的世界，由你定义。明暗主题动态银河封面">
  </a>
  <a href="https://skymoni.com/skivu/#gh-dark-mode-only">
    <img src="docs/images/skivu-cover-zh-dark.svg?v=brand-lockup#gh-dark-mode-only" width="1280" alt="Skivu — 你的世界，由你定义。明暗主题动态银河封面">
  </a>
</p>

<div align="center">
  <br>
  <p><img src="docs/images/skivu-app-icon-rounded.svg" width="52" height="52" alt="Skivu App icon"></p>
  <p><strong>简体中文</strong> · <a href="README.en.md">English</a></p>
  <p>
    <a href="https://skymoni.com/skivu/">官网</a> ·
    <a href="https://github.com/skyjjgw/skivu/releases/latest">下载 Android</a> ·
    <a href="https://skymoni.com/creators/skivu-beta">申请内测</a> ·
    <a href="https://skymoni.com/creators">社区</a> ·
    <a href="https://github.com/skyjjgw/skivu-plugins">插件共创</a>
  </p>
  <p>
    <a href="https://github.com/skyjjgw/skivu/releases/latest"><img src="https://img.shields.io/github/v/release/skyjjgw/skivu?style=flat&amp;labelColor=384657&amp;color=327fb5&amp;cacheSeconds=3600" alt="Latest release"></a>
    <img src="https://img.shields.io/badge/Android-7.0%2B-2c9b70?style=flat&amp;labelColor=384657" alt="Android 7.0+">
    <a href="pubspec.yaml"><img src="https://img.shields.io/badge/Flutter-3.41.9-20a4d0?style=flat&amp;labelColor=384657" alt="Flutter 3.41.9"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0--only-9964c5?style=flat&amp;labelColor=384657" alt="GPL-3.0-only"></a>
  </p>
</div>

Skivu 将模型连接、角色陪伴与外观定制放进同一个手机空间。你可以连接自己的模型 API，也可以使用 Skymoni 账号同步可用模型和额度；为同一个角色开启不同话题，各段对话独立保存历史、上下文与草稿。

**Android 是当前主要发布平台**，同一套 Flutter 源码也提供 Web 手机界面预览。这里维护 App 源码；产品官网、内测中心、社区与插件共创各有独立入口。

## 主要功能

- **模型连接**：OpenAI 兼容 Chat Completions、Responses、Claude Messages、Gemini Generate Content；在输入框直接搜索和切换模型，设置输出长度、流式与上下文。
- **角色会话**：自定义头像、角色卡和提示词；同一角色可拥有多段独立对话，支持搜索、重命名、置顶与重启恢复。
- **共用世界观**：独立管理世界、分类条目和场景，多位角色共用背景，各自选择场景。
- **分条确认与媒体**：多条气泡暂存后统一回复；支持分组自定义表情、打字描述语音／照片，以及系统语音转写和真实图片输入。
- **玻璃与版式**：调整模糊、透明度、顶栏与气泡样式；角色回复可选择居中、铺满一侧或全屏阅读布局。
- **分区外观**：界面、输入框、我的消息、角色回复、思考过程分别配置字体和颜色；支持导入字体、图片／视频背景和外观方案。
- **消息阅读**：平滑流式显示、可展开的思考区域、消息导航拨盘、收藏和回到底部；支持停止、重试与确认删除单轮对话。
- **语音通话**：水滴光球、字幕、静音与打断；语音合成支持系统、OpenAI 兼容、ElevenLabs、Azure 和自定义 HTTP。识别依赖 Android 系统语音服务及语言包。
- **账号与更新**：App 内登录、模型与额度同步、账号切换；校验 APK 摘要、大小、包名、版本及签名后，由 Android 系统确认安装。

插件市场可安装微信／QQ 界面数据包，0.2.36 新增任务技能与手动 MCP 工具连接。任意第三方脚本执行及右侧工作区尚未开放。模型和语音服务的可用功能及计费取决于所选服务，仓库不附带共享 API Key 或模型额度。

## 官网、社区与相关项目

- **[Skivu 官网](https://skymoni.com/skivu/)**：产品介绍、交互展示与 [品牌宣传片](https://skymoni.com/skivu/#brand-film)。
- **[内测中心](https://skymoni.com/creators/skivu-beta)**：申请内测、查看账号资格和管理员分配的专属额度。
- **[交流社区](https://skymoni.com/creators)**：使用反馈、角色提示词、功能讨论与作品分享。
- **[Skivu Plugins](https://github.com/skyjjgw/skivu-plugins)**：插件开发规范、模板、示例与社区目录，提供规范、示例与可安装的界面数据包。
- **[Skymoni 服务](https://skymoni.com/)**：可选的账号与模型服务接入；App 也支持自定义模型 API。
- **[网站与服务源码](https://github.com/skyjjgw/skymoni-source)**：关联网站和服务的源码发布、版本及许可记录。

## 下载与参与内测

在 **[GitHub 最新版本](https://github.com/skyjjgw/skivu/releases/latest)** 的 Assets 中下载 APK。已安装用户也可使用 **设置 → 检查更新**。每版发布说明记录版本、对应源码、文件大小和 SHA-256。

支持 **Android 7.0 / API 24 及以上**；Universal APK 包含 `arm64-v8a` 和 `x86_64`。应用标识为 `com.skyjjgw.independent.ski`。

APK 公开下载，**内测额度需要单独申请并获批准**：

1. 使用 Skymoni 社区账号进入 [内测中心](https://skymoni.com/creators/skivu-beta)，提交申请。
2. 审核通过后，由管理员手动分配独立的 App 内测额度。
3. 在 Skivu 内登录同一账号，同步资格、模型与额度。

内测额度与站内钱包／订阅分别管理；内测不可用或耗尽时，不会自动改扣钱包。自定义模型 API 接入也可独立使用。

当前内测安装包沿用既有开发签名，支持同签名覆盖升级。自行构建时若使用不同证书，不能直接覆盖已发布版本；独立分发请配置自己的发布签名。

## 开始使用

1. **连接模型**：在 **设置 → 中转站账号** 登录，或在 **模型与服务** 添加自己的地址、密钥、协议与模型并测试连接。
2. **创建角色**：填写头像、描述、性格、场景、关系、示例对话和开场白；点击聊天头像可编辑角色卡或自己的身份卡。
3. **开启话题**：侧栏顶部“新建对话”先选择角色，角色下的新建操作自动绑定该角色。不同会话的记录、上下文与草稿独立。
4. **调整体验**：在 **设置 → 外观与体验** 配置文字、背景、玻璃与消息版式；语音连接在 **语音与通话** 单独管理。

配置范围和协议说明见 [接口接入文档](API-INTEGRATION-SOURCES.md)。公网自定义模型地址使用 HTTPS；HTTP 仅用于可信本机或明确的私网 IP。

0.2.32 的上下文预算、本地存储与恢复、弱网启动和群聊语音说明见 [App 可靠性改进](docs/app-reliability.md)。

## 插件共创

[Skivu Plugins](https://github.com/skyjjgw/skivu-plugins) 已开放社区参与。当前 App 可从目录安装、启用、更新和卸载官方微信／QQ 界面预设包；它们共用本机角色与聊天资料，渲染器随 App 发布。

0.2.36 的[技能与 MCP 工具](docs/EXTENSION-MARKET.md)使用独立扩展目录：技能安装后需主动启用，才会附带指导和内嵌参考资料；MCP 由用户配置 HTTPS 服务、选择工具并手动执行。包校验固定提交、摘要及字节数，保留原作者、许可、修改声明与源码。未适配的上游执行环境不作为已接入能力上架。

旧 `0.1-draft` 投稿草案继续保留。当前 App 不执行任意第三方脚本；新增渲染能力需要宿主源码修改与 App 发版。请按仓库当前目录、示例及校验规则提交内容。

[开发规范](https://github.com/skyjjgw/skivu-plugins/blob/main/docs/development.md) · [模板](https://github.com/skyjjgw/skivu-plugins/tree/main/templates/prompt-pack) · [目录规范](https://github.com/skyjjgw/skivu-plugins/blob/main/docs/catalog.md) · [提交收录](https://github.com/skyjjgw/skivu-plugins/blob/main/CONTRIBUTING.md) · [开放路线](https://github.com/skyjjgw/skivu-plugins/blob/main/docs/roadmap.md)

## 开发与贡献

开发基线为 **Flutter 3.41.9 / Dart 3.11.5**，Android 构建需要 Android SDK 和 JDK 17。Dart 约束见 [pubspec.yaml](pubspec.yaml)。

<details>
<summary><strong>从源码运行、检查与打包</strong></summary>

```sh
git clone https://github.com/skyjjgw/skivu.git
cd skivu
flutter pub get
flutter devices
flutter run -d <android-device-id>
```

```sh
# Web 手机界面预览
flutter run -d chrome

# 检查
flutter analyze
flutter test

# Universal Android APK
flutter build apk --release --target-platform android-arm64,android-x64
```

APK 输出到 `build/app/outputs/flutter-apk/app-release.apk`。Android 与浏览器的数据分别保存；Web 直连接口依赖服务端 CORS，原生语音与安装更新不属于 Web 预览能力。

</details>

- **App 问题与建议**：提交 [Issue](https://github.com/skyjjgw/skivu/issues)，附版本、Android 版本、设备、复现步骤及必要截图。
- **代码与文档**：提交范围清晰的 [Pull Request](https://github.com/skyjjgw/skivu/pulls)，说明目的与验证方式；手机界面改动需在 Android 设备或模拟器验证。
- **插件与规范**：在 [Skivu Plugins](https://github.com/skyjjgw/skivu-plugins) 按贡献指南参与。
- **使用体验与角色提示词**：欢迎在 [社区](https://skymoni.com/creators) 分享。公开前请移除凭据、会话令牌与私人聊天内容。

## 数据与隐私

聊天记录、角色、草稿和外观配置保存在本机，支持系统文件备份与恢复。Android 聊天记录从旧偏好迁移至应用私有目录中的双代校验文件；恢复前会显示内容数量并确认替换。清空记录会清理自动恢复副本，已导出的文件与剪贴板需自行管理。API 密钥、账号会话和语音连接凭据通过 `flutter_secure_storage` 单独保存，不进入聊天备份；App 不保存账号登录密码。

发起对话时，相关消息与角色设定会发送给所选模型服务。云端语音合成会发送待朗读文本，系统识别也可能联网。

## 文档与许可

[账号与更新](APP-ACCOUNT-UPDATES.md) · [接口接入](API-INTEGRATION-SOURCES.md) · [模块来源](MODULE-MIGRATION.md) · [光球来源](ORB-PROVENANCE.txt) · [第三方声明](THIRD_PARTY_NOTICES.md)

本项目原创代码采用 **GNU GPL v3.0 only（GPL-3.0-only）**，见 [LICENSE](LICENSE) 和 [COPYRIGHT](COPYRIGHT)。第三方组件、字体及独立插件保留各自许可证；随附声明见 [licenses/](licenses/)。

玻璃效果使用 **Liquid Glass Easy**（MIT），内置字体包括 **Noto Sans SC、Noto Serif SC、Roboto Mono**。感谢相关开源项目与贡献者。

## Star History

<p align="center">
  <a href="https://www.star-history.com/?repos=skyjjgw%2Fskivu&amp;type=date&amp;legend=top-left">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=skyjjgw/skivu&amp;type=date&amp;theme=dark&amp;legend=top-left">
      <img src="https://api.star-history.com/chart?repos=skyjjgw/skivu&amp;type=date&amp;legend=top-left" width="800" alt="Skivu 的 GitHub Star 历史趋势">
    </picture>
  </a>
</p>
