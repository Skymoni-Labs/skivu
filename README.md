<div align="center">
  <img src="assets/branding/skivu-approved.png" width="88" height="88" alt="Skivu 标志">
  <h1>Skivu</h1>
  <p><strong>每次对话，都有回应。</strong></p>
  <p>面向 Android 的开源 AI 聊天应用，让模型、角色与界面更贴合你的使用习惯。</p>
  <p>A customizable AI chat app for Android, built with Flutter.</p>
  <p>
    <a href="https://github.com/skyjjgw/skivu/releases/latest"><img src="https://img.shields.io/github/v/release/skyjjgw/skivu?style=flat-square&amp;color=356c82" alt="最新版本"></a>
    <img src="https://img.shields.io/badge/Android-7.0%2B-3d7c66?style=flat-square" alt="Android 7.0 及以上">
    <a href="https://github.com/skyjjgw/skivu/blob/main/pubspec.yaml"><img src="https://img.shields.io/badge/Flutter-3.41.9-4b8bb6?style=flat-square" alt="Flutter 3.41.9"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0--only-596273?style=flat-square" alt="GPL-3.0-only"></a>
  </p>
  <p>
    <a href="https://github.com/skyjjgw/skivu/releases/latest">下载安装</a> ·
    <a href="#核心功能">核心功能</a> ·
    <a href="#快速上手">快速上手</a> ·
    <a href="#开发与构建">开发文档</a> ·
    <a href="https://github.com/skyjjgw/skivu/issues">问题反馈</a>
  </p>
</div>

---

Skivu 将多模型对话、角色卡、独立会话与液态玻璃界面整合在一款手机应用中。你可以使用 Skymoni 账号同步可用模型与额度，也可以配置自己的模型 API，并分别调整聊天文字、输入框和界面的外观。

Android 是当前主要发布平台；同一套 Flutter 源码也提供 Web 手机界面预览。版本变化与安装包以 [Releases](https://github.com/skyjjgw/skivu/releases) 为准。

## 核心功能

| 功能 | 说明 |
| --- | --- |
| 模型接入 | 支持多种模型接口协议；在输入框直接搜索、切换模型，管理输出长度、上下文与流式选项。 |
| 角色会话 | 自定义角色头像、人物设定与提示词；同一角色可拥有多段对话，共用角色卡，各自保存聊天记录、上下文与草稿。 |
| 玻璃界面 | 透明玻璃材质、浮动输入框与侧栏推拉交互；可调整模糊、透明度、顶栏样式及消息气泡。 |
| 外观配置 | 界面、输入框、我的消息、角色回复、思考过程分别设置字体与颜色；支持自定义字体、图片／视频背景和外观方案。 |
| 消息导航 | 平滑流式显示、可展开的思考区域、消息导航拨盘与回到底部；支持搜索、收藏、重命名、置顶及确认删除单轮对话。 |
| 语音通话 | 水滴光球通话界面、字幕、静音与打断；支持 Android 系统语音及可配置的云端语音合成服务。 |
| 账号更新 | App 内账号登录、模型与额度同步、账号切换；应用内检查更新，校验安装包后交由 Android 系统确认安装。 |

角色列表保留头像、对话数量及展开状态，重启后恢复当前会话。角色回复可选择居中、铺满一侧或全屏阅读布局，气泡样式与文字排版分别配置。

附件上传、插件执行及右侧工作区尚未开放，相关入口显示“即将开放”。

## 下载与安装

前往 **[最新版本](https://github.com/skyjjgw/skivu/releases/latest)**，在 Assets 中下载 APK，按 Android 系统提示安装。已安装用户也可通过 **设置 → 检查更新** 获取新版本。

| 项目 | 要求 |
| --- | --- |
| 系统 | Android 7.0 / API 24 及以上 |
| 架构 | `arm64-v8a`、`x86_64` |
| 安装包 | Universal APK，包含上述两种架构 |
| 应用标识 | `com.skyjjgw.independent.ski` |

当前内测安装包沿用既有开发签名，支持同签名覆盖升级。自行构建的 APK 若使用不同证书，不能直接覆盖已发布版本；面向独立分发时，请配置自己的发布签名。

## 快速上手

### 连接模型

选择适合自己的接入方式：

- **Skymoni 账号**：进入 **设置 → 中转站账号** 登录，同步账号可用模型、钱包／订阅与内测状态。内测资格和额度由服务端审批与发放，可通过保留的网页入口申请。
- **自定义 API**：进入 **设置 → 模型与服务**，添加服务地址、密钥与模型，选择对应协议并测试连接。

当前支持的文字模型协议：

| 协议 | 接口类型 |
| --- | --- |
| OpenAI 兼容 | Chat Completions |
| OpenAI Responses | Responses API |
| Claude | Messages API |
| Gemini | Generate Content API |

模型列表、可用功能和计费取决于所选服务。Skivu 不附带共享 API Key 或模型额度；服务商预设用于简化配置，实际兼容范围见 [接口接入说明](API-INTEGRATION-SOURCES.md)。

### 创建角色与对话

在角色管理中设置名称、头像、描述、性格、场景、关系、示例对话与开场白。点击聊天头像可编辑对应角色卡或自己的身份卡，保存后的设定用于后续模型请求。

左侧面板按角色组织对话：点击角色展开已有会话，或在角色下新建对话；顶部“新建对话”会先选择角色。同一角色的设定共享，各段对话的历史与上下文独立。

### 调整外观与语音

在外观设置中分别调整字体、文字颜色、背景、玻璃与消息版式，预览后自动保存。聊天底部统计可按需开关；服务端未返回的数据以 `—` 显示。

语音合成支持系统、OpenAI 兼容、ElevenLabs、Azure 和自定义 HTTP 服务。语音识别依赖 Android 系统服务及语言包，云端合成使用你配置的服务账号。

## 数据与隐私

- 聊天记录、角色、草稿与外观配置保存在本机，支持聊天数据备份与恢复。
- API 密钥、账号会话和语音连接凭据通过 `flutter_secure_storage` 单独保存，不进入聊天备份；App 不保存账号登录密码。
- 发起对话时，消息及相关角色设定会发送给所选模型服务。云端语音合成会发送待朗读文本，系统语音识别也可能使用网络服务。
- 仓库不包含账号凭据、运行数据库或签名私钥。账号与更新流程见 [账号与更新说明](APP-ACCOUNT-UPDATES.md)。

## 开发与构建

开发基线为 **Flutter 3.41.9 / Dart 3.11.5**。Android 构建需要 Android SDK 与 JDK 17；Dart 版本约束见 [pubspec.yaml](pubspec.yaml)。

### 获取源码并运行

```sh
git clone https://github.com/skyjjgw/skivu.git
cd skivu
flutter pub get
flutter devices
flutter run -d <android-device-id>
```

Web 手机界面预览：

```sh
flutter run -d chrome
```

Web 直连模型接口需要服务端允许 CORS，浏览器与 Android App 的数据分别保存。Web 预览不代表 Android 原生语音、安装更新等能力在浏览器中可用。

### 检查与打包

```sh
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64,android-x64
```

APK 输出到 `build/app/outputs/flutter-apk/app-release.apk`。提交改动前请运行与改动相关的检查；涉及手机布局、键盘、玻璃材质或侧栏交互时，请同时在 Android 设备或模拟器上验证。

### 项目结构

```text
lib/        应用界面、模型接入、会话状态与外观配置
android/    Android 原生语音、平台适配与安装更新
assets/     品牌资源与内置字体
shaders/    水滴光球 Shader
test/       协议、状态、布局与交互测试
licenses/   第三方许可证与版权通知
web/        Web 预览入口
```

## 反馈与贡献

欢迎通过 [Issues](https://github.com/skyjjgw/skivu/issues) 提交问题或功能建议，也欢迎提交范围清晰的 [Pull Request](https://github.com/skyjjgw/skivu/pulls)。

报告问题时，请提供 App 版本、Android 版本、设备型号、复现步骤及必要截图；分享前请移除 API Key、账号会话和私人聊天内容。提交代码时请说明改动目的、验证方式，并保留相关第三方声明。

## 文档与许可证

| 文档 | 内容 |
| --- | --- |
| [账号与更新](APP-ACCOUNT-UPDATES.md) | 账号登录、模型与额度同步、应用内更新流程 |
| [接口接入](API-INTEGRATION-SOURCES.md) | 模型与语音协议、配置来源及兼容范围 |
| [模块来源](MODULE-MIGRATION.md) | 消息导航与通话界面的来源、适配范围 |
| [水滴光球](ORB-PROVENANCE.txt) | 光球绘制组件与 Shader 的来源记录 |
| [第三方声明](THIRD_PARTY_NOTICES.md) | 依赖、字体与分发通知 |

本项目原创代码采用 **GNU General Public License v3.0 only（GPL-3.0-only）**，详见 [LICENSE](LICENSE) 和 [COPYRIGHT](COPYRIGHT)。第三方组件与字体适用各自许可证，相关正文保留在 [licenses/](licenses/)。

液态玻璃效果基于 **Liquid Glass Easy**（MIT）；内置字体包括 **Noto Sans SC、Noto Serif SC、Roboto Mono**。感谢相关开源项目与贡献者。
