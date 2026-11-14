# 第三方声明（Third-Party Notices）

本文件集中列出 dsh-go 复制或改写进源码的第三方代码与素材，以及随 App 一起分发的字体、原生库和 Linux 运行时组件。源文件头那一行 `Portions derived from …` 指向这里。

- App 内「设置 › 开源许可」页随 APK 分发同样的声明（`app/lib/ui/common/third_party_licenses.dart`，字体在 `app/lib/ui/settings/font_licenses.dart`）。
- Dart / Flutter 依赖应按 `app/pubspec.lock`（以及本地包的 lock）核对直接与传递依赖；Flutter 从包根 `LICENSE` 收集许可并显示在许可证页。这里不逐包重复，发行前仍须核验实际 APK 的许可资产，不能仅凭依赖声明认定已收录。
- 许可证全文见文末「许可证全文」。
- 本项目自己的许可见 `LICENSE`（AGPL-3.0）；品牌标识和吉祥物美术不属于第三方，也不在 AGPL 授权范围内，见 `ASSETS.md`。

## 一、复制或改写进源码的代码

### Phase（经作者许可使用）

| 项 | 内容 |
|---|---|
| 项目 | Phase，https://github.com/CikeSeven/phase （基于提交 `c209f6f`） |
| 版权人 | Copyright (c) 2026 CikeSeven |
| 许可 | 经作者许可使用 |
| 用途 | 手机操控：无障碍读屏与操作、控制浮层，以及「不打扰模式」的特权虚拟屏 |

上游路径前缀为 `android/app/src/main/kotlin/app/xiangyue/phase/`；本仓库路径前缀为 `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/phone/`。

| 本仓库文件 | 上游来源 |
|---|---|
| `a11y/Actuator.kt` | `accessibility/AccessibilityDriver.kt`、`vision/VisualDriver.kt` |
| `a11y/ControlOverlay.kt` | `accessibility/TaskOverlay.kt` |
| `a11y/MainScreenDriver.kt` | `accessibility/AccessibilityDriver.kt` |
| `a11y/PhoneA11yService.kt` | `accessibility/PhaseAccessibilityService.kt` |
| `a11y/ScreenShooter.kt` | `vision/VisualDriver.kt` |
| `background/PrivilegedDisplayCore.kt` | `shizuku/ShizukuDeviceService.kt`、`DisplayTextConnection.kt`、`DisplayTextInput.kt` |
| `background/PrivilegedDisplayEntry.kt` | `shizuku/ShizukuDeviceService.kt` |
| `background/PrivilegedProtocol.kt` | 失败原因码集合 |
| `background/ShizukuStarter.kt` | `shizuku/ShizukuConnection.kt` |
| `app/android/app/src/main/res/xml/phone_accessibility_service.xml` | `accessibility_service.xml` |

声明原文：

```text
Portions of the phone control feature are derived from Phase
(https://github.com/CikeSeven/phase), Copyright (c) 2026 CikeSeven,
used with the author's permission.
```

### go.dshtui.com 首页（作者交付使用）

| 项 | 内容 |
|---|---|
| 作品 | DSH Go 展示网站：HTML、CSS、JavaScript、内容检查与发布脚本、八张功能展示图 |
| 作者 | ClayGao233 / 采云师烧饼（https://github.com/ClayGao233 、https://space.bilibili.com/28879571） |
| 许可 | 作者交付给本项目用于 go.dshtui.com；交付包未附许可证声明，不在本仓库的 AGPL-3.0 授权范围内 |
| 用途 | `https://go.dshtui.com/` 首页 |

本仓库位置：`site/home/`。在交付版本上的改动：产品名统一写作「DSH Go」，填写作者、下载、仓库、贡献者和分享元信息（`dist/site-config.js`），加入页面 CSP、下载二维码、第二个下载链接和 Star 数（`dist/index.html`、`dist/author-ui.js`、`dist/refinements.css` 末尾），统一换行符；没有发布的工作文件（作者说明、备份脚本、未用到的图片）未收入。功能展示图依据 DSH Go 的界面截图制作，含 DSH Go 的品牌图形和鲸娘形象（见 `ASSETS.md`）。页底保留作者的「网页开发」署名。

### PiPilot（MIT）

| 项 | 内容 |
|---|---|
| 项目 | PiPilot，https://github.com/CikeSeven/pi_pilot |
| 版权人 | Copyright (c) 2026 CikeSeven |
| 许可 | MIT |
| 用途 | 聊天界面、通用组件、抽屉外壳与主题的结构和部分实现 |

均在 `app/lib/ui/` 下：

- `chat/`：`chat_header.dart`、`chat_list.dart`、`chat_screen.dart`、`composer.dart`、`model_sheet.dart`
- `chat/render/`：`ansi_text.dart`、`code_block.dart`、`diff_view.dart`、`markdown_body.dart`
- `chat/widgets/`：`approval_card.dart`、`assistant_message.dart`、`question_card.dart`、`thinking_pill.dart`、`tool_row.dart`、`user_bubble.dart`
- `common/`：`app_sheet.dart`、`glass_pill.dart`、`overscroll_forwarder.dart`、`sheet_navigator.dart`、`status_dot.dart`、`streaming_cursor.dart`、`tool_glyph.dart`
- `settings/`：`diagnostics_page.dart`、`settings_widgets.dart`
- `shell/`：`drawer_drag.dart`、`home_shell.dart`、`sessions_drawer.dart`
- `theme/`：`accent.dart`、`app_theme.dart`、`backdrop.dart`、`highlight_theme.dart`、`motion.dart`、`palette.dart`、`semantic_colors.dart`、`shapes.dart`、`squircle.dart`、`typography.dart`

### dartssh2（MIT，已修改）

- 来源：dartssh2 4.1.0（https://pub.dev/packages/dartssh2/versions/4.1.0），上游 https://github.com/vicajilau/dartssh2。
- 本仓库位置：`packages/dartssh2/`；保留包内原始 `LICENSE`，Flutter 按本地依赖收集许可。
- 本地改动：增加认证后启用的 `zlib@openssh.com` 压缩、关闭选项、重协商时的压缩流切换及对应测试；不修改密码算法。来源归档校验与维护说明见包内说明。

### DeepSeek Harness（MIT）

| 项 | 内容 |
|---|---|
| 项目 | DeepSeek Harness，https://github.com/deepseek-ai/deepseek-harness |
| 版权人 | Copyright (c) 2026 DeepSeek |
| 许可 | MIT |
| 用途 | 移植官方客户端的若干算法与图形；部分组件的结构与行为参照其 Web 客户端 |

| 本仓库文件 | 上游来源 | 用途 |
|---|---|---|
| `app/lib/ui/chat/secret_mask.dart` | `@deepseek-ai/dsh-client-ui-secret-mask` | 凭据格式、线性匹配与遮挡；眼睛图标 |
| `app/lib/ui/chat/widgets/artifact_card.dart` | `@deepseek-ai/dsh-client-ui-deliverables`（`PresentedFileCard`、`Deliverables`） | 交付文件卡片 |
| `app/lib/state/session_search.dart` | `@deepseek-ai/dsh-client-ui-workspace`（`deriveSearchResults`） | 对话搜索结果合并 |
| `app/lib/ui/features/schedule_editor/cron.dart` | `@deepseek-ai/dsh-client-ui-schedule`（`task-cron.js`） | 定时任务的 cron 解析与中文描述 |
| `app/lib/ui/engine_settings/namespace_copy.dart` | 官方设置页（`dsh-client-ui-settings-*`、`dsh-client-ui-chat`、`dsh-client-ui-conversation` 等）与各包 README 的中文文案 | 引擎设置项的中文文案 |
| `app/lib/ui/common/think_glyph.dart` | `@deepseek-ai/dsh-web-frontend`（`IconThinkOutline`） | 思考图标轮廓 |
| `packages/dsh_client/lib/src/binary_response.dart` | `@deepseek-ai/dsh-client-connection`（`parseBinaryResponse`） | 二进制结果解码 |
| `packages/dsh_client/lib/src/deliverables.dart` | `@deepseek-ai/dsh-client-ui-deliverables`（`isPresentedData`、`isPresentedFile`、`presentedForClosing`） | 交付文件校验与按轮选取 |
| `runtime/patches/route-guard.diff` | `dsh-host-webserver` | 运行时构建时打到 DSH 上的补丁 |

此外，App 中部分组件的结构与行为参照 DeepSeek Harness 的 Web 客户端（MIT），包括消息操作、提及、输入区 dock、回合过程、产物、工作区、终端和定时任务等，不逐文件列出。

### DS Bot（Apache-2.0，已修改）

| 项 | 内容 |
|---|---|
| 项目 | DS Bot，https://github.com/Fei2411/DeepSeek-Bot （基于提交 `1bebe82`） |
| 版权人 | Copyright 2026 Fei2411 and the DS Bot contributors |
| 许可 | Apache License 2.0 |
| 用途 | 可交互回复（dsh-ui）的规范化、校验、上限、摘要、选择规则与图表刻度；DS Bot 客户端的配色与默认颜色 |

以下文件均已修改，每个文件第二行起有 `Modified: …` 说明改动：

| 本仓库文件 | 上游来源 |
|---|---|
| `app/lib/ui/chat/dsh_ui/dsh_ui_model.dart` | `ds-bot/src/shared/views.js`（`normalizeView`、校验与上限、`viewSummary`） |
| `app/lib/ui/chat/dsh_ui/dsh_ui_reply.dart` | `ds-bot/src/shared/views.js`（`validateOptions`） |
| `app/lib/ui/chat/dsh_ui/dsh_ui_chart.dart` | `ds-bot/src/client/widget-chart.js`（`niceTicks`、数值轴、提示框） |
| `app/test/chat/dsh_ui/dsh_ui_model_test.dart` | `ds-bot/test/views.test.js` 的用例 |
| `packages/dsh_client/lib/src/dsbot_api.dart` | `src/client/inks.js`（配色表）、`src/client/characters.js`（`fnv1a`、`defaultColor`） |
| `app/android/.../runtime/GuestSetup.kt` | `ds-bot/src/host/tools.js`、`prompt.js`（`show_view` 说明与提示规则） |
| `app/lib/ui/bots/bot_mention.dart` | `ds-bot/src/shared/mentions.js`（「所有人」与地址判定等提及规则） |

DS Bot 的 NOTICE 原文附在文末。

### ds-harness-remote（MIT）

| 项 | 内容 |
|---|---|
| 项目 | ds-harness-remote，https://github.com/liguobao/ds-harness-remote |
| 版权人 | Copyright (c) 2026 DSH Remote contributors |
| 许可 | MIT（全文另见 `packages/dsh_remote/LICENSE-ds-harness-remote`） |
| 用途 | 远程连接：协议、分帧、校验、加密信道、直连（WebRTC）与连接逻辑 |
| 对应上游版本 | `7e387df`（Host 插件 0.6.0）；工作区上传协议参考 `479b94341c0d0de63846f21d0fcca26997d158d1`（Host 插件 0.6.2） |

路径均相对 `packages/dsh_remote/`：

| 本仓库文件 | 上游来源 |
|---|---|
| `lib/src/server/server_api.dart` | `apps/android/src/services/api.ts`（`RemoteServerApi`，含 `turnCredentials`）、`docs/protocol.md`、`docs/plugin-integration.md` |
| `lib/src/account/remote_account.dart` | `apps/android/src/services/server-session-manager.ts`、`device-directory.ts`、`connection.ts`（含直连失败后另开纯 Relay 连接）、`packages/plugin/src/cli.ts` |
| `lib/src/carrier/tunnel_carrier.dart` | `packages/client-core/src/remote-gateway.ts`；白名单来自 `packages/plugin/src/harness-remote-bridge.ts`、`terminal-policy.ts`；工作区上传协议与文件名校验参考 `docs/protocol.md`、`packages/plugin/src/workspace-upload.ts`、`rpc-router.ts`（`479b943`），Dart 重写，遵守协议绝对上限，具体路径/版本限制以主机回复为准 |
| `lib/src/crypto/noise_ik.dart` | `packages/crypto/src/noise.ts`、`packages/crypto/src/index.ts`（会话封装）；Noise IK 状态机为本项目自行实现，经上游作者同意 |
| `lib/src/channel/secure_channel.dart` | `packages/plugin/src/client-secure-transport.ts`、`packages/plugin/src/server-connection.ts` |
| `lib/src/channel/rpc_client.dart` | `packages/client-core/src/index.ts`（`RemoteClientCore`） |
| `lib/src/protocol/control.dart` | `packages/protocol/src/index.ts`（信封、校验、限额、协商、Relay data frame） |
| `lib/src/protocol/messages.dart` | `packages/protocol/src/index.ts`（`RemoteMessage`、`SecureMessageCodec`、RPC 载荷） |
| `lib/src/transport/relay_transport.dart` | `packages/webrtc/src/index.ts`（`RelayTransport`，含 Relay data socket 的 attach）；attach 后发送 `transport.selected`、直连能力协商与 signaling 收发来自 `packages/webrtc/src/adaptive-transport.ts` |
| `lib/src/transport/webrtc_transport.dart` | `packages/webrtc/src/adaptive-transport.ts`（`negotiate`、`tryWebRtc`、ICE 服务器获取与超时）、`packages/webrtc/src/rtc-data-channel.ts`（发起方、远端候选缓存、选路重试） |
| `lib/src/transport/rtc_chunking.dart` | `packages/webrtc/src/rtc-chunking.ts`（`RTCH` 分块，线格式逐字节一致） |
| `lib/src/transport/peer_connection.dart` | `packages/webrtc/src/rtc-data-channel.ts`（`inspectSelectedPath`、LAN 判定）、`packages/webrtc/src/rtc-adapter.ts`（地址范围、`stunOnlyIceServers`、DataChannel 名称） |
| `lib/src/util/bytes.dart` | `packages/protocol/src/wire-json.ts`（拒绝重复字段）、`packages/protocol/src/index.ts`（规范 Base64URL） |
| `test/fixtures/noise-ik.json` | `fixtures/crypto/v1/noise-ik.json`（原样复制） |
| `test/fixtures/protocol-v1/` | `fixtures/protocol/v1`（原样复制） |
| `tool/e2e/patch-webrtc.mjs` | 不复制代码：在 E2E 时改写上游 `apps/server/src/gateway.ts`，按托管 Server 的行为打开 WebRTC 协商与 signaling 转发 |

### Libraries.dev（MIT）

| 项 | 内容 |
|---|---|
| 项目 | Libraries.dev，https://github.com/Jakubantalik/Libraries.dev （基于提交 `387b049`） |
| 版权人 | Copyright (c) 2026 Jakub Antalik |
| 许可 | MIT（只用代码；`LICENSE-MODEL.md` 管的模型文件 `Magnet.mfxl`、`VoicePosition.mfxl` 和 Pro 内容都没有用） |
| 用途 | 界面特效：思考光球、边框流光、语音辉光、语音光环、机器人头像等，从作者的 TypeScript / Swift / Metal 源码翻译成 Dart、Flutter 着色器和 Kotlin |

本仓库位置：`app/lib/ui/fx/`（每个文件第一行注明出处）及其 `app/shaders/fx/` 下的着色器。

金属质感的着色器 `app/shaders/fx/metal_liquid.frag` 是 metal-fx 用的 Paper Shaders `liquidMetal`（Apache-2.0，Paper Design, Inc.，`@paper-design/shaders` 0.0.80）的 GLSL 翻译，按 metal-fx 的 NOTICE 原文保留：

```text
This product includes software developed by Paper Design, Inc.

  Paper Shaders (https://github.com/paper-design/shaders)
  Copyright (c) Paper Design, Inc.
  Licensed under the Apache License, Version 2.0
  http://www.apache.org/licenses/LICENSE-2.0

The liquid-metal material in app/shaders/fx/metal_liquid.frag is the
`liquidMetal` fragment stage of @paper-design/shaders 0.0.80, as used by
Libraries.dev metal-fx, translated to Flutter GLSL.
```改动：换成 Flutter 的 CustomPainter / FragmentShader 绘制，默认颜色从 App 主题色取，跟随「减弱动态」，声音电平改用 App 自己的采集数据；桌面专用的鼠标效果没有移植。

### DSHA（MIT）

| 项 | 内容 |
|---|---|
| 项目 | DSHA，https://github.com/DSH-APP/DSHA |
| 版权人 | Copyright (c) 2026 qiannianhuanxiang |
| 许可 | MIT |
| 用途 | 不打扰模式特权进程的 `app_process` 入口 |
| 文件 | `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/phone/background/PrivilegedDisplayEntry.kt` |

### discourse_docker（MIT）

| 项 | 内容 |
|---|---|
| 项目 | discourse_docker，https://github.com/discourse/discourse_docker |
| 版权人 | Copyright (c) 2018 Civilized Discourse Construction Kit, Inc. |
| 许可 | MIT |
| 用途 | 社区论坛的容器配置，基于官方 `samples/standalone.yml` 改写 |
| 文件 | `infra/forum/containers/app.yml`、`infra/forum/containers/app.reverse-proxy.yml` |

### SillyTavern（AGPL-3.0）

| 项 | 内容 |
|---|---|
| 项目 | SillyTavern，https://github.com/SillyTavern/SillyTavern |
| 版本 | 1.19.0，提交 `7e8663cd9c184a550b37238218bdd32c6efc68e9` |
| 许可 | AGPL-3.0（与本项目相同） |
| 用途 | 酒馆引擎照 SillyTavern 的行为移植或改写：提示词组装、世界书、宏、斜杠命令、正则、角色卡与聊天文件的读写、人设 |
| 来源文件 | `public/script.js`；`public/scripts/` 下的 `PromptManager.js`、`openai.js`、`personas.js`、`world-info.js`、`macros.js`、`slash-commands.js`、`bookmarks.js`；`src/character-card-parser.js`、`src/prompt-converters.js`、`src/endpoints/characters.js`、`src/endpoints/chats.js`、`src/endpoints/backends/chat-completions.js` |
| 文件 | `packages/dsh_tavern/lib/src/` 下文件头写明 SillyTavern 来源和提交的文件 |

酒馆引擎里另有几处移植，许可写在各自的文件头或同目录的许可文件里：Fuse.js 7.1.0（Apache-2.0，`packages/dsh_tavern/lib/src/slash/FUSE-LICENSE.txt`）、json-logic-js（MIT，`packages/dsh_tavern/lib/src/state/JSONLOGIC-LICENSE.txt`）、Unicode 16.0.0 数据（Unicode 许可，`packages/dsh_tavern/lib/src/slash/UNICODE-NAME-LICENSE.txt`）、seedrandom 3.0.5（MIT，David Bau，许可原文在 `packages/dsh_tavern/lib/src/macros/macro_engine.dart`）、Handlebars 4.7.9 与 Moment 2.30.1 的有限行为（各自文件头注明）。

## 二、素材

### Phosphor Icons（MIT）

| 项 | 内容 |
|---|---|
| 项目 | Phosphor Icons 2.1.1，https://phosphoricons.com （`@phosphor-icons/core`） |
| 版权人 | Copyright (c) 2023 Phosphor Icons |
| 许可 | MIT |
| 用途 | 界面图标字体的字形；少数图标按它的网格与轮廓补画 |

- `app/tool/icons/phosphor/`：图标源文件与 LICENSE
- `app/assets/fonts/DshIcons.ttf`、`app/lib/ui/theme/dsh_glyphs.dart`：由 `app/tool/make_icon_font.py` 生成
- `app/android/.../phone/a11y/ControlOverlay.kt`：收起键的路径取自 `arrows-in-simple`

### Material Icons（Apache-2.0）

| 项 | 内容 |
|---|---|
| 项目 | Material Icons，https://github.com/google/material-design-icons |
| 版权人 | Google |
| 许可 | Apache License 2.0 |
| 用途 | 桌面快捷方式与快速设置磁贴的图标；按自适应图标画布缩放、居中 |

均在 `app/android/app/src/main/res/drawable/` 下：`ic_shortcut_chat_glyph.xml`（`chat_bubble_outline_rounded`）、`ic_shortcut_new_chat_glyph.xml`（`add_comment_outlined`）、`ic_shortcut_voice_glyph.xml`（`mic_none_rounded`）、`ic_tile_new_chat.xml`（`add_comment_outlined`）。

### discourse-emojis（MIT）

| 项 | 内容 |
|---|---|
| 项目 | discourse-emojis，https://github.com/discourse/discourse-emojis |
| 版权人 | Discourse（gemspec 作者 Joffrey Jaffeux） |
| 许可 | MIT（见其 `discourse-emojis.gemspec`） |
| 用途 | 论坛表情的名称与别名表，只用数据，不含图片 |
| 文件 | `app/lib/forum/emoji_data.g.dart`，由 `infra/forum/tools/gen_emoji_table.py` 从 `dist/emojis.json`、`dist/aliases.json` 生成 |

### jQuery 3.7.1（MIT）

| 项 | 内容 |
|---|---|
| 项目 | jQuery 3.7.1，https://jquery.com （npm 包 `jquery@3.7.1`） |
| 版权人 | Copyright OpenJS Foundation and other contributors, https://openjsf.org/ |
| 许可 | MIT（包内 `LICENSE.txt` 原文） |
| 用途 | 酒馆整页画布里给卡脚本用的 `$`／`jQuery`，和酒馆助手页面一样预先放好；「不运行卡的脚本」开着时不载入 |

- `app/assets/tavern/jquery-3.7.1.min.js`：包内 `dist/jquery.min.js` 原样，SHA256 `fc9a93dd241f6b045cbff0481cf4e1901becd0e12fb45166a8f17f95823f0b1a`
- `app/assets/licenses/jquery-3.7.1-LICENSE.txt`：包内 `LICENSE.txt` 原样，SHA256 `d4db9ebe6f29f5168eac45ad713f055623ac5d0dcd5ba92da23d650ae012020d`
- 来源：npm 镜像 registry.npmmirror.com 的 `jquery-3.7.1.tgz`，与 npm 公布的 integrity `sha512-m4avr8yL8kmFN8psrbFFFmB/If14iN5o9nw/NgnnM+kybDJpRsAynV2BsfpTYrTRysYUdADVD7CkUUizgkpLfg==` 一致（2026-11-12 核对）

### Lodash 4.17.21（MIT）

| 项 | 内容 |
|---|---|
| 项目 | Lodash 4.17.21，https://lodash.com （npm 包 `lodash@4.17.21`） |
| 版权人 | Copyright OpenJS Foundation and other contributors <https://openjsf.org/>；基于 Underscore.js（Jeremy Ashkenas, DocumentCloud and Investigative Reporters & Editors） |
| 许可 | MIT（包内 `LICENSE` 原文，含示例代码 CC0 一节） |
| 用途 | 酒馆整页画布里给卡脚本用的 `_`，同上 |

- `app/assets/tavern/lodash-4.17.21.min.js`：包内 `lodash.min.js` 原样，SHA256 `a9705dfc47c0763380d851ab1801be6f76019f6b67e40e9b873f8b4a0603f7a9`
- `app/assets/licenses/lodash-4.17.21-LICENSE.txt`：包内 `LICENSE` 原样，SHA256 `f71e8ed126b46346494aad5486874cd8f0aafe95092ed67d2e3cb6110f939abc`
- 来源：npm 镜像的 `lodash-4.17.21.tgz`，与 npm 公布的 integrity `sha512-v2kDEe57lecTulaDIuNTPy3Ry4gLGJ6Z1O3vE1krgXZNrsQ+LFTGHVxVjcXPs17LhbZVGedAJv8XZ1tvj5FvSg==` 一致（2026-11-12 核对）

### JetBrains Mono（SIL OFL 1.1）

| 项 | 内容 |
|---|---|
| 项目 | JetBrains Mono，https://github.com/JetBrains/JetBrainsMono |
| 版权人 | Copyright 2020 The JetBrains Mono Project Authors |
| 许可 | SIL Open Font License 1.1，全文见 `app/assets/fonts/OFL.txt` |
| 用途 | 代码字体，随 App 分发，也注入网页版 |
| 文件 | `app/assets/fonts/JetBrainsMono-*.ttf` |

## 三、随 App 分发的原生库

以下库作为 Gradle 依赖打包进 APK，未复制进源码。

| 库 | 版本 | 许可 | 版权人 | 用途 |
|---|---|---|---|---|
| Shizuku-API（`dev.rikka.shizuku:api`、`provider`） | 13.1.5 | MIT | Copyright (c) 2021 RikkaW | 不打扰模式经 Shizuku 获得 shell 权限 |
| libadb-android | 3.1.1 | Apache-2.0（GPL-3.0-or-later 与 Apache-2.0 双许可，按 Apache-2.0 使用） | Copyright 2021 Muntashir Al-Islam | 无线调试配对、ADB 协议与 mDNS |
| spake2-android（libadb-android 的依赖） | 2.2.1 | LGPL-3.0 | Copyright 2021 Muntashir Al-Islam | 无线调试配对的 SPAKE2 |
| Conscrypt（`org.conscrypt:conscrypt-android`） | 2.8.0 | Apache-2.0 | Copyright 2016 The Android Open Source Project | libadb 的 TLS；NOTICE 原文见文末 |
| Bouncy Castle（`bcprov`、`bcpkix-jdk15to18`） | 1.81 | Bouncy Castle Licence（MIT 条款） | Copyright (c) 2000-2023 The Legion of the Bouncy Castle Inc. | 自签名 ADB 客户端证书 |
| XZ for Java（`org.tukaani:xz`） | 1.10 | 0BSD | Copyright (C) The XZ for Java authors and contributors | 解压 `.tar.xz` 运行时包 |
| AndroidX WebKit | 1.15.0 | Apache-2.0 | The Android Open Source Project | 网页插件的深色模式 |
| flutter_webrtc（pub 包，含 Android 插件代码） | 1.6.3 | MIT；其 NOTICE 另含 react-native-webrtc（MIT，Copyright (c) 2015 Howard Yang）与 `SimulcastVideoEncoderFactoryWrapper.kt`（Apache-2.0，Copyright 2017, Lyo Kato；Copyright 2017-2021, Shiguredo Inc.），原文见文末 | Copyright (c) 2018 湖北捷智云技术有限公司 | DSH Remote 直连（P2P / TURN）的 DataChannel；只用数据通道，不碰麦克风、摄像头和音频会话 |
| WebRTC Android SDK（`io.github.webrtc-sdk:android`，libwebrtc m150） | 150.7871.04 | BSD-3-Clause，另附 Google 的专利授权（PATENTS） | Copyright (c) 2011, The WebRTC project authors | flutter_webrtc 的原生 WebRTC（`libjingle_peerconnection_so.so`，每个 ABI 一份） |
| AudioSwitch（`com.github.davidliu:audioswitch`，twilio/audioswitch 的分支） | `039a35aefab7747c557242fa216c9ea11743b604` | Apache-2.0 | Copyright 2020 Twilio, inc. | flutter_webrtc 的音频路由依赖；DSH Go 不建音频轨，不会启用 |
| mobile_scanner（pub 包，含 Android 插件代码） | 7.5.0 | BSD-3-Clause | Copyright (c) 2022, Julian Steenbakker | Remote「扫码配对电脑」的相机扫码和相册识图 |
| ML Kit Barcode Scanning（`com.google.mlkit:barcode-scanning`，模型随 APK 打包） | 17.3.0 | [ML Kit 服务条款](https://developers.google.com/ml-kit/terms)（Google 免费分发的二进制，非开源） | Google LLC | mobile_scanner 的二维码识别，在手机本地运行，不需要 Google Play 服务 |
| CameraX（`androidx.camera:*`，mobile_scanner 的依赖） | 随 mobile_scanner 7.5.0 | Apache-2.0 | The Android Open Source Project | 扫码时的相机预览 |
| ONNX Runtime（`com.microsoft.onnxruntime:onnxruntime-android`） | 1.23.2 | MIT | Copyright (c) Microsoft Corporation | 语音通话在手机上跑判停模型 |
| Silero VAD v6.2（模型文件 `assets/speech/silero_vad.onnx`） | `be95df9` | MIT | Copyright (c) 2020-present Silero Team | 语音通话判断有没有在说话 |
| smart-turn v3.2（模型文件 `assets/speech/smart-turn-v3.2-cpu.onnx`） | `f766f81` | BSD-2-Clause | Copyright (c) 2024–2025, Daily | 语音通话判断一句话说完没有 |
| sherpa-onnx（pub 包 `sherpa_onnx`、`sherpa_onnx_android`） | 1.12.36 | Apache-2.0 | Xiaomi Corporation 与 k2-fsa 贡献者 | 手机上的流式语音识别；它带的 `libonnxruntime.so` 与上面 ONNX Runtime 1.23.2 相同，只打包一份 |
| Streaming Zipformer 中英双语模型（不随 APK，按需下载，csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20） | `98590b7` | Apache-2.0 | csukuangfj；上游 pfluo/k2fsa-zipformer-chinese-english-mixed | 实时字幕；许可全文随 APK 的 `assets/licenses/streaming-asr-model-APACHE-2.0.txt` |

### tawcroot（tawc，MIT）

「tawcroot 加速启动」（设置 → 开发者选项，默认关闭）用的 `libtawcroot.so`，由 `runtime/tawcroot/build.py` 从 [tawc](https://github.com/wmww/tawc) 固定提交 `a49a4075228f4801dadc1eee584aed33fe8ea4ce`（源码归档 SHA-256 `74487243bde86c303e786e79cd4a13e98c3279cae4ab7725dcf5fa51c0b530c1`）的 `tawcroot/src`、`tawcroot/include` 原样编译，没有修改上游源码。tawc 的 README 写明 `deps/` 以外的代码都是 MIT（[LICENSE.MIT](https://github.com/wmww/tawc/blob/a49a4075228f4801dadc1eee584aed33fe8ea4ce/LICENSE.MIT)）；整个项目因 `deps/` 里的 GPLv3 代码按 GPLv3 发布，那部分我们不编译、不分发。

- 版权：Copyright (c) 2026 Sophie Winter
- 许可：MIT（全文见文末「MIT License」），App 内「开源许可」页的 `tawcroot (tawc)` 条目附全文

### WebRTC 150.7871.04 核对记录（2026-10-30）

已核对实际 Gradle 缓存中的两个 AAR 及其 `classes.jar`：均未包含 LICENSE、NOTICE 或 PATENTS 文件。AAR 摘要如下，用于区分实际消费的 Maven/JitPack 产物与其他同名下载：

```text
1872dda4e3bf7d6ea6f7c6e11861332081c57081a1e62fc82fab72415c69c84c  android-150.7871.04.aar  (49,068,339 B)
c8240221daa9a96d4ea01a4dc6f6f6b10b4903d2a71f9b57f838bdfeb6c3fcbc  audioswitch-039a35aefab7747c557242fa216c9ea11743b604.aar  (95,318 B)
```

| 来源 | 已确认内容 | 不能据此推断的内容 |
|---|---|---|
| `flutter_webrtc 1.6.3` pub 包的 `LICENSE`、`NOTICE`、`android/build.gradle` | MIT 版权与 NOTICE 原文；Android 依赖固定为上表两个版本。文末补入 NOTICE 全文及 MIT 版权行 | Flutter 自动收集包根 LICENSE 不保证额外 NOTICE 或原生静态依赖通知已自动收录 |
| [AudioSwitch 固定 commit 的 LICENSE.txt](https://github.com/davidliu/audioswitch/blob/039a35aefab7747c557242fa216c9ea11743b604/LICENSE.txt) | Apache-2.0 与 `Copyright 2020 Twilio, inc.`；与 App 已登记的版权及许可一致 | AAR 本身没有附正文，仍需由发行物提供 |
| [Android SDK v150.7871.04 的许可汇编](https://github.com/webrtc-sdk/android/blob/1d6a68a74162d3f218f9681d49c6b5eef8f02800/Licenses/WEBRTC.md) | 发布标签指向 `1d6a68a74162d3f218f9681d49c6b5eef8f02800`；该文件 blob 为 `f371735b3a706ff1401bce870f096efc9bbb5f51`，含 30 个许可章节，包括 WebRTC、Abseil、BoringSSL 等 | 该文件未附实际 AAR 的构建提交、GN 参数或各 ABI 目标依赖清单；不能直接认定 30 节恰好覆盖此 AAR 的所有实际链接组件 |
| [m150 源码 LICENSE](https://github.com/webrtc-sdk/webrtc/blob/a802fa9849e0dae7f54c7d3deb05820a674b2f46/LICENSE) 与 [PATENTS](https://github.com/webrtc-sdk/webrtc/blob/a802fa9849e0dae7f54c7d3deb05820a674b2f46/PATENTS) | 核查时将 `m150_release` 固定为 `a802fa9849e0dae7f54c7d3deb05820a674b2f46`；顶层 BSD 与 Google 专利文本可核对，全文见文末 | 该源码快照不是已经证明对应上述 AAR 的构建提交；顶层 BSD 与专利文本也不替代静态链接的第三方许可 |

上游 [v150.7871.04 发布流程](https://github.com/webrtc-sdk/android/blob/1d6a68a74162d3f218f9681d49c6b5eef8f02800/.github/workflows/fetch-webrtc-artifacts.yml) 从构建归档中取出 AAR，[发布附件](https://github.com/webrtc-sdk/android/releases/expanded_assets/v150.7871.04) 为三种 AAR 和两种仓库源码归档，没有单独的该次构建许可清单。Maven 发布还会按 [downloadAar.sh](https://github.com/webrtc-sdk/android/blob/1d6a68a74162d3f218f9681d49c6b5eef8f02800/downloadAar.sh) 修改 Java class 版本；不能把 GitHub AAR 的摘要与 Maven AAR 摘要混用。

### 完整上游通知的随包收录（2026-10-31）

App 现将 **同一发布标签的完整 `Licenses/WEBRTC.md`** 原样保存为 `app/assets/licenses/webrtc-150.7871.04.md`，通过 `pubspec.yaml` 打包；设置中的开源许可页在 `WebRTC` 条目展示全部 30 个章节，并继续展示顶层 BSD 与 PATENTS 文本。未按功能使用情况裁掉任何章节。这个改动补齐上游发布通知的随包收录，不代表逐一审计过所有静态链接组件。

来源固定为 `webrtc-sdk/android@1d6a68a74162d3f218f9681d49c6b5eef8f02800`（`v150.7871.04`）：该标签的 `gradle.properties` 明确 `VERSION_NAME=150.7871.04`；上述 `downloadAar.sh` 从同标签发布附件下载 `libwebrtc.aar` 再修改 Java class 版本。2026-10-31 实际下载此附件并与前述 Gradle 缓存 Maven AAR 比较，ZIP 条目列表一致，除 `classes.jar` 外全部条目的内容相同；JAR 条目列表亦一致，唯一内容差异为 433 个 class 的 major version 从 65 改为 61，其他字节均一致。这将实际消费的二进制与通知所在的官方发布标签对应起来，未将移动的 `m150_release` 分支冒充精确构建源码。

```text
f15e6bf94c1cbb9d6defaa95f04d1ae16b84e897f584032781091022d8366e30  官方 v150.7871.04/libwebrtc.aar（49,068,339 B）
d1f9382c6878ac024155fd6d44a5977329108bb8b0a01cea40e4a2f1d7de252e  webrtc-150.7871.04.md（788,358 B）
f371735b3a706ff1401bce870f096efc9bbb5f51  同一通知的 Git blob SHA-1
```

官方与 Maven AAR 的原生库 SHA-256 均为：

| ABI | `libjingle_peerconnection_so.so` SHA-256 |
|---|---|
| arm64-v8a | `2b561520298d9fec3e216baf58a53fbddf4a46dfd247880cbc3821875ed20200` |
| x86_64 | `b87bbb6d6c81c50f04538cd809575de633a789cc3555af2c5eb6ec414b148908` |
| armeabi-v7a | `5415e7a02ce83e983329575e7c2e46b8ced6c75baea3c41aa52b5699ccb54eda` |
| x86 | `9a532ef72dcda8b4b9874d4f578dbd3a5eb18bce01f9f91bee883bc0962dce3c` |

**核验边界：**本次选择完整保留发布方提供的许可汇编，未自行重建 Chromium、取得该构建的 GN 依赖图，亦未证明 30 个章节与二进制实际组件一一对应。此前表格中关于缺少逐组件构建清单的限制仍成立；它与“没有随包附带完整上游通知”是不同事项。后续升级 WebRTC 必须重新核对发布标签、二进制和通知，不得沿用此版本的汇编与摘要。

定向测试验证 `LicenseRegistry` 可加载完整 asset，核对原始摘要、30 个章节、现有 BSD/PATENTS 与其他许可条目。发行构建后还须对每个最终 APK 执行以下校验（将路径替换为实际待分发文件），成功时打印许可摘要与该 APK 含有的 WebRTC ABI：

```bash
python3 - path/to/final.apk <<'PY_APK'
import hashlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as apk:
    name = 'assets/flutter_assets/assets/licenses/webrtc-150.7871.04.md'
    data = apk.read(name)
    digest = hashlib.sha256(data).hexdigest()
    assert len(data) == 788358
    assert digest == 'd1f9382c6878ac024155fd6d44a5977329108bb8b0a01cea40e4a2f1d7de252e'
    libraries = [n for n in apk.namelist() if n.endswith('/libjingle_peerconnection_so.so')]
    assert libraries, 'No packaged WebRTC native library found'
    print(sys.argv[1], digest, libraries)
PY_APK
```

最终 App 的开源许可页还应能打开 `WebRTC` 条目并查看汇编末尾 `zlib` 章节。上述命令和定向测试不代表已经运行最终发行 APK；构建与 UI 检查结果应另记在实际发行验证记录中。默认关闭 P2P 不会移除这些已打包依赖或免除通知收录。


## 四、Linux 运行时组件

APK 内置的 Linux 运行时由 `runtime/build-runtime.sh` 构建，以下组件来自上游二进制或软件包，各自保留许可证；构建会裁剪文件，并为 APK 命名规则修改 proot 的 DT_NEEDED 和 libtalloc 的 DT_SONAME，具体修改记录在构建报告中：原生部分的许可证文本在 APK 的 `assets/runtime/licenses/` 下，Ubuntu 软件包的版权文件保留在运行时的 `/usr/share/doc/`。

| 组件 | 版本 | 来源 | 许可 |
|---|---|---|---|
| proot | 5.1.107.98 | Termux（源码 https://github.com/termux/proot） | GPL-2.0（`licenses/proot-COPYING.txt`） |
| libtalloc | 2.5.0 | Termux | LGPL-3.0-or-later（`licenses/libtalloc-notice.txt`） |
| libandroid-shmem | 0.7 | Termux | BSD-3-Clause（`licenses/libandroid-shmem-copyright.txt`） |
| Ubuntu Base 与软件包（tzdata、ca-certificates、git 及依赖） | 24.04.5 | Canonical / Ubuntu | 各包自带，见 `/usr/share/doc/` |
| Node.js | 24.22.1 | https://nodejs.org | MIT 及其捆绑组件的许可 |
| CPython | 3.12.15 | astral-sh/python-build-standalone | PSF-2.0 及其捆绑组件的许可 |
| pnpm | 11.28.5 | npm | MIT |
| DeepSeek Harness 主包（`@deepseek-ai/dsh`） | 0.2.1-rc.4 | npm | MIT；构建补丁集合由 `runtime/patches/pins.json` 决定 |

GPL / LGPL 组件的对应源码：proot、libtalloc、libandroid-shmem 的二进制取自 Termux 官方 apt 仓库（https://packages.termux.dev/apt/termux-main ），`runtime/build-runtime.sh` 固定了每个 .deb 的 SHA-256。源码分别在 https://github.com/termux/proot （tag `v5.1.107.98`，构建时一并下载并核对哈希）、https://www.samba.org/ftp/talloc/ （2.5.0）、https://github.com/termux/libandroid-shmem （0.7）；Termux 的构建配方在 https://github.com/termux/termux-packages 。本项目对这三个二进制的修改只有上面说的 DT_NEEDED / DT_SONAME 改名。

### npm 传递依赖与发行核验

主包的 MIT 许可不覆盖所有传递依赖。当前默认 `runtime/locks/dsh-0.2.1-rc.4/package-lock.json` 还锁定了以下需要单独核验的组件：

| 组件 | 固定版本 | 包声明的许可 | 发行边界 |
|---|---|---|---|
| `@deepseek-ai/libreoffice-kit` 及对应平台组件 | 0.1.5 | MPL-2.0 | 保留实际分发组件的 LICENSE/NOTICE；不能将整个 `@deepseek-ai/*` 范围归为 MIT |
| `@img/sharp-libvips-linux-arm64`、`@img/sharp-libvips-linux-x64` | 1.3.4 | LGPL-3.0-or-later | 按目标 ABI 的实际安装结果核对 libvips 及其捆绑组件许可与对应源码 |
| 其他 npm 直接及传递依赖 | 见 DSH 与 pnpm 的固定 lock | 各包各自许可 | lock 包含可选平台包，不能把全部条目当成每个 APK 都已打包；以实际 rootfs 文件清单为准 |

`runtime/lib/rtbuild.py` 保留 Node 发行包的 `LICENSE` 为 `/opt/node/LICENSE`，保留 Ubuntu `/usr/share/doc/*/copyright`，npm 的许可文件不属于常规开发元数据裁剪项。仍须对最终归档检查许可文件和 symlink 目标是否可用，特别是 npm 包未附许可正文的情形。保留许可文本与提供 GPL/LGPL 等组件适用的对应源码是不同检查项；应为具体发行物记录版本、构建配方、修改和可获取的对应源码，不能只用项目主页或一份声明代替。

### Unicode Character Database 15.0.0（Unicode 数据许可）

宠物 ZIP 文件名去重使用从 CPython 3.12 / Unicode 15.0.0 生成的 NFC 与 full casefold 数据表；生成脚本为 `app/tool/generate_pet_validation_data.py`，表为 `app/lib/pets/pet_unicode_data.g.dart`。未复制 CPython 实现代码。

Copyright © 1991-2026 Unicode, Inc.

数据版本来源：https://www.unicode.org/Public/15.0.0/ucd/ReadMe.txt （原始数据通知 © 2022 Unicode®, Inc.）。完整 Unicode 当前许可原文取自 https://www.unicode.org/license.txt ，检索于 2026-11-07；这是当前 V3 通知，不把它冒称为 2022 发布时的许可版本。许可全文原样存于 `app/tool/unicode-15.0-LICENSE.txt`，同字节打包为 `app/assets/licenses/unicode-15.0.txt`，由现有 LicenseRegistry 页面展示。

C710 新增的 `image` 4.12.0 是 MIT 许可 pub 依赖；其原许可由 Flutter 的依赖许可收集流程随包提供。Codex Pet 转换根据公开格式独立实现，不把源码许可当作第三方图集再分发授权。

## 五、格式兼容与致谢（未复制代码）

- **Clawd on Desk**（https://github.com/rullerzhou-afk/clawd-on-desk，AGPL-3.0）：桌宠的主题包格式、状态名、优先级与时长默认值与它兼容，宠物包可以在两边通用。本项目没有复制它的代码。
- **Streamdown**（https://github.com/vercel/streamdown）：`app/lib/ui/chat/render/stream_repair.dart` 修补流式 Markdown 末尾的方式参照了它的 `remend`。
- **DS Bot**：dsh-ui 组件的名称与 DS Bot 一致。
- **Open-Meteo**（https://open-meteo.com，数据 CC BY 4.0）：示例插件 `examples/plugins/dsh-go-example-weather` 使用它的天气数据，卡片上注明来源。

## 许可证全文

### MIT License

适用于以下版权声明：

```text
Copyright (c) 2026 CikeSeven                                   (PiPilot)
Copyright (c) 2026 DeepSeek                                    (DeepSeek Harness)
Copyright (c) 2026 DSH Remote contributors                     (ds-harness-remote)
Copyright (c) 2026 qiannianhuanxiang                           (DSHA)
Copyright (c) Microsoft Corporation                            (ONNX Runtime)
Copyright (c) 2020-present Silero Team                         (Silero VAD)
Copyright (c) 2026 Jakub Antalik                               (Libraries.dev)
Copyright (c) 2018 Civilized Discourse Construction Kit, Inc.  (discourse_docker)
Copyright (c) 2023 Phosphor Icons                              (Phosphor Icons)
Copyright (c) 2021 RikkaW                                      (Shizuku-API)
Copyright (c) 2018 湖北捷智云技术有限公司                        (flutter_webrtc)
Copyright (c) 2015 Howard Yang                                 (react-native-webrtc)
```

discourse-emojis 上游未附 LICENSE 文件与版权行，按其 gemspec 声明的 MIT 使用。

```text
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Apache License 2.0

适用于 DS Bot、Material Icons、libadb-android、Conscrypt、AndroidX WebKit。

```text
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS
```

### NOTICE：DS Bot（提交 `1bebe82`，原文照录）

```text
DS Bot
Copyright 2026 Fei2411 and the DS Bot contributors

This product is licensed under the Apache License, Version 2.0 (see LICENSE).

==============================================================================
Third-party code in this repository
==============================================================================

DeepSeek Harness (https://github.com/deepseek-ai/deepseek-harness)
MIT License, Copyright (c) 2026 DeepSeek

  - ds-bot/dev/desktop-linux/launch.mts follows the steps of
    apps/desktop/scripts/dev.ts in DeepSeek Harness and reuses a few of its
    lines (the release record and the Electron launch arguments). It is a
    developer script for screenshots on Linux and is not in the npm package.
  - app/src/host.mjs and app/src/profile.mjs follow
    apps/desktop-host/src/index.ts: the profile boot and the ready, fatal and
    shutdown messages.
  - app/src/host-process.mjs follows apps/desktop/src/host-process.ts: the
    Host in Electron's Node mode and the shutdown escalation.
  - app/src/main.mjs follows apps/desktop/src/main.ts for the Windows window
    options (the caption-button overlay, its colors and the native theme). app/src/preload.cjs adapts
    apps/desktop/src/preload-windows.ts, apps/desktop/src/preload-platform.ts
    and apps/desktop/src/preload-theme.ts: the caption-band marks, the
    fullscreen mark, the caption-color measure and the theme sync.
  - app/src/bot-browser.mjs adapts apps/desktop/src/browser-guests.ts, and
    the browser part of app/src/preload.cjs follows
    apps/desktop/src/preload-browser.ts: the webview leases, the attachment
    checks and fixed guest preferences, the session policy and the new-window
    requests.
  - app/engine/cordis.patch.yml follows the bundle patch of
    @deepseek-ai/dsh-web-app (packages/bundle/web-app/cordis.patch.yml): the
    transport and host-service rows and the agent-plane rows it turns off.
    app/engine/preset-standard.patch.yml copies its standard preset
    (presets/standard.patch.yml), including the plan-mode prompt text,
    without the goal rows.
  - .agents/skills/record-browser-gif/ comes from the skill of the same name
    in DeepSeek Harness (.agents/skills/record-browser-gif/): SKILL.md is
    adapted and translated for this repository; scripts/encode_gif.py and
    scripts/test_encode_gif.py are copied unchanged.

  Full license text:

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.

No other third-party code is copied into this repository. At run time the
plugin uses the @deepseek-ai/* packages of the DeepSeek Harness install it
runs in; they are not bundled. esbuild is a build tool only. The desktop app
in app/ installs the pinned @deepseek-ai/* packages, Electron and pnpm from
npm; they keep their own licenses. The build of its window (app/ui) bundles,
from npm, React and React DOM (MIT, Copyright (c) Meta Platforms, Inc. and
affiliates), and react-markdown and remark-gfm with the packages they use
(MIT, most of them Copyright (c) Titus Wormer; @ungap/structured-clone is ISC,
Copyright (c) Andrea Giammarchi). Vite is a build tool only.

==============================================================================
Projects that gave us ideas (no code copied)
==============================================================================

We thank these projects for the designs they published. DS Bot learned from
their ideas; it does not contain their code.

  - AgentMemoryRepo (https://github.com/AgentMemoryRepo/agentmemoryrepo), MIT:
    the Markdown format of Bot memory (one entry per line with [key: value]
    metadata, a MEMORY.md index that links topic files).
  - OpenAI Codex (https://github.com/openai/codex), Apache-2.0:
    keeping the user's messages next to the summary in a checkpoint, and
    message anchors for searching earlier chat.
  - OpenMausBot (https://github.com/milind-soni/OpenMausBot), Apache-2.0:
    group chat rounds and @mention relays between Bots.
  - Hermes Agent (https://github.com/NousResearch/hermes-agent) and
    Hermes Bot Mode (https://github.com/NousResearch/Hermes-Bot-Mode), MIT:
    one Session per member per group chat, and the list of earlier user
    messages that the plugin, not the model, writes into the handoff.
  - OpenCode (https://github.com/sst/opencode), MIT;
    goose (https://github.com/block/goose), Apache-2.0;
    pi (https://github.com/badlogic/pi-mono), MIT;
    Gemini CLI (https://github.com/google-gemini/gemini-cli), Apache-2.0:
    when to condense a long conversation, and what a handoff note holds.
  - obelisk (https://github.com/tommy0103/obelisk), AGPL-3.0:
    searching a Bot's own chat with a SQLite FTS5 index ranked by BM25.
  - DeepSeek Harness Voice Input plugin
    (packages/experimental/client-ui-voice-input), MIT: the voice chat
    records with the same steps (record, resample to 16 kHz mono, PCM16 WAV)
    before it calls the plugin's speech service.
```

### NOTICE：Conscrypt 2.8.0（原文照录）

```text
Copyright 2016 The Android Open Source Project

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

-----------------------------------------------------------------------
This product contains a modified portion of `Netty`, a configurable network
stack in Java, which can be obtained at:

  * LICENSE:
    * licenses/LICENSE.netty.txt (Apache License 2.0)
  * HOMEPAGE:
    * http://netty.io/

This product contains a modified portion of `Apache Harmony`, modular Java runtime,
which can be obtained at:

  * LICENSE:
    * licenses/LICENSE.harmony.txt (Apache License 2.0)
  * HOMEPAGE:
    * https://harmony.apache.org/
```

### Bouncy Castle Licence

```text
Copyright (c) 2000-2023 The Legion of the Bouncy Castle Inc. (https://www.bouncycastle.org)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software
and associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial
portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

### BSD Zero Clause License（XZ for Java）

```text
Copyright (C) The XZ for Java authors and contributors

Permission to use, copy, modify, and/or distribute this
software for any purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL
THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

### NOTICE：flutter_webrtc 1.6.3（pub 包原文照录）

```text
###################################################################################

The following modifications follow Apache License 2.0 from shiguredo.

SimulcastVideoEncoderFactoryWrapper.kt

Apache License 2.0

Copyright 2017, Lyo Kato <lyo.kato at gmail.com> (Original Author)
Copyright 2017-2021, Shiguredo Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

#####################################################################################

react-native-webrtc
https://github.com/react-native-webrtc/react-native-webrtc

The MIT License (MIT)

Copyright (c) 2015 Howard Yang

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

#####################################################################################
```

### WebRTC BSD 与 Google 专利授权

来源与版本边界见上面的 WebRTC 核对记录；以下正文与 App 登记的顶层许可对应。

```text
Copyright (c) 2011, The WebRTC project authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Additional IP Rights Grant (Patents)

"This implementation" means the copyrightable works distributed by
Google as part of the WebRTC code package.

Google hereby grants to you a perpetual, worldwide, non-exclusive,
no-charge, irrevocable (except as stated in this section) patent
license to make, have made, use, offer to sell, sell, import,
transfer, and otherwise run, modify and propagate the contents of this
implementation of the WebRTC code package, where such license applies
only to those patent claims, both currently owned by Google and
acquired in the future, licensable by Google that are necessarily
infringed by this implementation of the WebRTC code package. This
grant does not include claims that would be infringed only as a
consequence of further modification of this implementation. If you or
your agent or exclusive licensee institute or order or agree to the
institution of patent litigation against any entity (including a
cross-claim or counterclaim in a lawsuit) alleging that this
implementation of the WebRTC code package or any code incorporated
within this implementation of the WebRTC code package constitutes
direct or contributory patent infringement, or inducement of patent
infringement, then any patent rights granted to you under this License
for this implementation of the WebRTC code package shall terminate as
of the date such litigation is filed.
```

### 其他许可证

- SIL Open Font License 1.1：`app/assets/fonts/OFL.txt`
- GNU LGPL-3.0（spake2-android、libtalloc）：https://www.gnu.org/licenses/lgpl-3.0.txt ；它以 GNU GPL-3.0 为基础，两份全文一并附在 App 内许可页的 spake2-android 条目里：https://www.gnu.org/licenses/gpl-3.0.txt
- GNU GPL-2.0（proot）：随 APK 附带于 `assets/runtime/licenses/proot-COPYING.txt`

## Google ML Kit Text Recognition (Chinese)

Google ML Kit Text Recognition (Chinese)
com.google.mlkit:text-recognition-chinese:16.0.1

This bundled Google SDK is subject to the Google ML Kit terms:
https://developers.google.com/ml-kit/terms
Android SDK data disclosure:
https://developers.google.com/ml-kit/android-data-disclosure

Recognition runs on-device. Screenshots and recognized text are not sent to
Google by this SDK. The SDK collects usage statistics such as device model,
app version and processing time. Phone control may send screenshots and
recognized text to the user's configured model.

Local recognition is enabled by default. While off, recognition requests do not
trigger SDK loading or initialization. Turning it off prevents new recognition,
but does not uninstall
the SDK or promise to clear or stop sending previously accumulated SDK statistics.
The dsh-go anonymous usage statistics switch does not control this SDK.
The Apache 2.0 license for documentation sample code is not the license for
this SDK binary. This notice does not replace Google's SDK terms.
