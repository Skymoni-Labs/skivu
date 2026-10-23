# ski 第三方材料与分发说明

适用于本次固定版本的 Flutter Android/Web 应用与已核对的 Pub 包源码。原创业务代码按 GPL-3.0-only 开源；下列第三方组件和材料继续适用各自许可证与版权通知，不会因本项目的许可证选择而改标。这里不声称完成所有原生 Maven 产物或未来依赖的全量审计。

## 实际选定材料

| 材料 | 固定版本/来源 | 许可与处理 |
| --- | --- | --- |
| Flutter framework | 3.41.9 / `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694` | BSD-3-Clause；保留完整版权与免责声明 |
| Dart / Flutter engine | Dart 3.11.5；engine `42d3d75a56efe1a2e9902f52dc8006099c45d937` | SDK 完整复合通知随附；含 BSD、MIT、Apache、ICU、zlib、FreeType 等各自条款 |
| characters | 1.4.1 | BSD-3-Clause |
| collection | 1.19.1 | BSD-3-Clause |
| material_color_utilities | 0.13.0 | Apache-2.0 |
| meta | 1.17.0 | BSD-3-Clause |
| vector_math | 2.2.0 | BSD-3-Clause |
| Liquid Glass Easy | 5.0.0 / AhmeedGamil/liquid_glass_easy | MIT；Copyright (c) 2025 Ahmed Gamil；完整版权、授权与免责声明随包保留；作为依赖使用，未修改其源码 |
| image_picker | 1.2.4 / flutter.dev | BSD-3-Clause；系统选图及 Android 选图结果恢复，未修改插件源码 |
| path_provider | 2.1.6 / flutter.dev | BSD-3-Clause；将所选壁纸保存到应用私有持久目录，未修改插件源码 |
| shared_preferences | 2.5.6 / flutter.dev | BSD-3-Clause；壁纸参数与本地状态保存，未修改插件源码 |
| file_selector | 1.1.0 / flutter.dev | BSD-3-Clause；本机字体文件选择，未修改插件源码 |
| video_player | 2.11.1 / flutter.dev | BSD-3-Clause；本地背景视频播放，未修改插件源码；平台依赖版本与版权见锁文件及 packages 通知 |
| http | 1.6.0 / dart.dev | BSD-3-Clause；跨平台 HTTP/SSE 客户端，作为直接依赖使用，未修改源码 |
| flutter_secure_storage | 11.2.0 / mogol/flutter_secure_storage | BSD-3-Clause；平台加密凭据存储，完整版权与各平台实现通知随包保留，未修改源码 |
| crypto | 3.0.7 / dart.dev | BSD-3-Clause；内测请求摘要，未修改源码；P-256 私钥与签名独立使用 Android Keystore API |
| Noto Serif SC | google/fonts `8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5` | SIL OFL-1.1；原始字体自托管，Google 版权及完整许可保留 |
| Roboto Mono | google/fonts `aa24661a5ba24c8f8a550a16fb13198719fc2c23` | SIL OFL-1.1；原始字体自托管，Roboto Mono Project Authors 版权及完整许可保留 |
| Material Icons 字体 | 官方 SDK `material_fonts` 产物 | **实际随附字体许可为 CC BY 4.0**，按该正文处理；Google / Material Design Icons，构建时由 Flutter 进行字体子集化，保留署名、许可与修改说明。不以图标仓库 Apache 标签代替字体产物许可 |
| Noto Sans SC | 2.004-H2；google/fonts `47d54ca1ebb14fd864695f1d39dc734f39017c33` | SIL OFL-1.1；自托管、未修改，不单独销售字体；版权为 Adobe，Reserved Font Name 为 Source |
| 头像、示例文件、概念插件、文案 | 此工程自主编写 | 未导入旧 App 或第三方视觉素材 |
| 水滴光球组件与 Shader | 用户在旧星伴自行新增的模块；固定 bb34767，详见 `ORB-PROVENANCE.txt` | 2026-10-21 按用户明确要求迁移适配；不是 Operit2 官方原有光球，也没有导入其宿主/通话运行时 |

Flutter 的 CanvasKit / Skia Web 运行资源随构建自托管，不使用渲染 CDN。SDK 的 `sky_engine/LICENSE` 是跨平台汇总通知；保留完整文本不代表每个组件均被链接进本 Web 包。

汇总中出现的 `fallback_root_certificates` 是 MPL-2.0 通知，针对原生 Dart IO 后备根证书。壁纸的原生存储辅助文件现使用 `dart:io`，Web 使用条件导入后的浏览器存储；没有改动这类 SDK 文件，完整保留通知。原生分发仍须按实际 SDK/构建复核相应源文件可获取性，不能把 Web 检查当成原生发布结论。FreeType 使用 FTL 分发选项，保留原始通知，不选择其 GPL 替代选项。

## 核对方法与证据

`pubspec.lock` 固定解析版本与归档 SHA-256；`dependency-audit.json` 依据实际依赖图区分运行依赖和开发/测试依赖。现共 95 个包，其中 83 个属于运行依赖图（各平台实现由构建选择），12 个仅开发/测试；91 个托管包与 pub.dev 官方版本 API/归档校验一致。比对缓存中 `lib/`（含液态玻璃 shaders）、原生平台目录、`src/`、`hook/`、LICENSE、NOTICE、pubspec.yaml 的原始字节；已有官方归档按固定哈希复用。所有包许可正文与存在的 NOTICE 保存在 `licenses/packages/`。

官方元数据与归档在 `D:/CodexBuilds/ski-independent-ui/license-evidence`。字体 SHA-256 为 `a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da`，已与固定提交下载文件比对。

新增衬线与等宽字体的固定下载地址、提交、大小和 SHA-256 见 `appearance-font-sources.json`，已与固定提交的原始字体字节核对；OFL 正文分别在 `licenses/NotoSerifSC-OFL.txt`、`licenses/RobotoMono-OFL.txt`。自定义媒体与字体由用户从本机选取，不作为仓库资源发布。

SDK 产物许可在 `licenses/Flutter-engine-NOTICES.txt`；Flutter/Dart、图标字体和 Noto 字体正文也各自保留。发布构建中的 `assets/NOTICES` 由 Flutter 生成；工程许可目录与本说明另外复制到交付目录的 `third-party/`，应用内“关于 Skivu → 查看开源许可”可查看运行时许可。

## 条款依据

- [Flutter 官方许可](https://github.com/flutter/flutter/blob/00b0c91f06209d9e4a41f71b7a512d6eb3b9c694/LICENSE)
- [Liquid Glass Easy 5.0.0 发布包与 MIT 许可](https://pub.dev/packages/liquid_glass_easy/versions/5.0.0/license)
- [Noto 字体固定来源与 OFL](https://github.com/google/fonts/tree/47d54ca1ebb14fd864695f1d39dc734f39017c33/ofl/notosanssc)
- [SIL OFL 官方文本](https://openfontlicense.org/open-font-license-official-text/)
- [CC BY 4.0 官方文本](https://creativecommons.org/licenses/by/4.0/legalcode.en)
- [Mozilla MPL 2.0 FAQ：文件级义务与 proprietary larger works](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)

没有纳入 Operit1/2 官方宿主的业务代码、生成代码、补丁或素材。2026-10-21 用户要求迁入其旧星伴原创水滴光球，来源与适配记录另附；不再将该模块描述为全新从零编写。根据用户选择，纳入 Liquid Glass Easy 材质与触摸组件；没有导入其示例 App、照片或其他候选项目。新增后端、原生能力、模型、音色、插件或依赖时应重新核对实际版本和产物。

2026-10-22 又按用户明确要求迁入其自行新增的消息定位拨盘和通话界面，固定文件、提交和适配范围见 MODULE-MIGRATION.md 与 module-migration-sources.json。没有整份导入上游已有的 ChatScrollNavigator 或旧宿主；当前原生语音适配使用 Android 平台 API，没有新增音频库或音色/模型权重。原有第三方许可继续保留。


## 2026-10-23 内置 HTML 界面插件

2026-10-24 插件市场：新增独立编写的数据型界面包目录、安装/卸载及摘要校验，未增加第三方依赖或任意外部脚本运行时。QQ/微信渲染器仍随 App 发布并保留以下来源和许可；插件包仅选择已适配模式，资金仍为本机角色虚拟余额。

微信/QQ模式复用用户确认的自有HTML预览（固定提交2c29740），原创部分仍为GPL-3.0-only。assets/social_ui/PROVENANCE.json记录模板文件摘要；social.css、native.css与WeUI样式子集逐字保留，宿主适配样式另存host.css等文件。没有导入腾讯客户端私有代码、品牌图片、账号或聊天协议。

2026-10-24：先按用户手机UI参考新增独立编写的qq_chat.js/css；用户随后明确恢复QQ联系人、动态/空间和频道等生态入口。新增chat_interactions.js/css、原角色群聊和虚拟交易生命周期均为本工程自主编写，没有提取QQ/微信客户端代码、素材、账号数据或私有协议，没有新增第三方依赖。仅共用Skivu已有角色、消息与设置；转账/红包/礼物为本机角色虚拟资金，不接腾讯支付。手机参考只经用户允许的UI截图/点击/滑动/返回观察，私人截图不随源码或产品分发。本机媒体预览不构成真实多人视频通话能力。

Tencent/weui固定7a6f8ad7700d0d6f1361dbe5e2942b4b129e7a7e的MIT浅色变量和主按钮子集保留在assets/social_ui/vendor，完整许可证在同目录LICENSE.weui.txt。vue-weixin、uniapp-x-moments与vue-qq仅作结构研究参考，未整包复制或执行。

新增webview_flutter 4.14.1（锁定Android实现4.12.0、WKWebView实现3.25.1、platform_interface 2.15.1）与web 1.1.1；Flutter团队BSD-3-Clause许可由Flutter生成的NOTICES收录。只加载随App打包的可信HTML资源；外部插件包和脚本下载安装未开放。

2026-10-23 微信添加菜单与虚拟钱包：二维码在本机生成、识别，不上传相册图片。随包加入 jsQR 1.4.0（Apache-2.0，https://github.com/cozmo/jsQR）和 qrcode-generator 1.4.4（MIT，https://github.com/kazuhikoarase/qrcode-generator）。固定 npm 包 SHA-512 完整性已核对；文件 SHA-256、版本及许可来源见 assets/social_ui/vendor/qr-sources.json，完整许可证见同目录 LICENSE.jsQR.txt 和 LICENSE.qrcode-generator.txt，应用许可页已登记。两者不提供微信私有协议或真实支付能力。
