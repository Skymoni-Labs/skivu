# Skivu

独立开发的 Flutter Android 聊天应用，支持多模型文字对话、液态玻璃界面与外观自定义。同一套 Flutter 源码也可运行 Web 手机界面预览。

当前为开发中的第一版：Android 已通过真实中转接口的两轮对话、上下文记忆和冷启动恢复验收。安装名与默认角色仍有临时名称 `ski`，正式品牌资源正在逐步接入。

## 已实现

- OpenAI 兼容 Chat Completions、Responses、Claude Messages、Gemini Generate Content 文字协议；支持流式与非流式回复。
- 多模型连接、服务商预设、自定义 API 地址、模型列表、连接测试、鉴权及高级参数。
- 多轮历史、独立角色提示词、停止生成、失败重试、会话草稿与本地恢复。
- API Key 通过 `flutter_secure_storage` 单独保存；聊天备份不包含密钥。
- 液态玻璃顶栏、输入栏与两侧抽屉，浅角度翻页、弹簧吸附及触摸形变。
- 主题、字体、图片/视频背景、气泡、玻璃模糊与不透明度，以及命名外观方案。
- 分组设置、聊天备份/恢复/清理和隐私说明。

底部统计使用服务端返回的实际用量；暂缺的数据显示 `—`。预设名称表示协议配置入口，不表示已逐家验证服务商的所有产品。

## 运行

开发基线为 Flutter **3.41.9** / Dart **3.11.5**，Android 开发需要 Android SDK 与 JDK 17。项目中的包名 `ski` 和 Android applicationId `com.skyjjgw.independent.ski` 暂时保留。

```sh
git clone https://github.com/skyjjgw/skivu.git
cd skivu
flutter pub get
flutter devices
flutter run -d <android-device-id>
```

Web 手机预览：

```sh
flutter run -d chrome
```

在“设置 → 模型与服务”添加你自己的模型连接。仓库不提供 API Key 或可直接使用的付费额度。Web 能否直连接口取决于服务端 CORS 配置；Android 与 Web 的本地数据分别保存。

Android 构建：

```sh
flutter build apk --profile --target-platform android-arm64
```

当前签名配置仅用于开发，尚未提供正式发布签名。`scripts/` 中保留部分 Windows 开发辅助工具，路径参数需按本机环境调整；使用以上 Flutter 命令无需这些辅助脚本。

## 验证

```sh
flutter analyze
flutter test
```

首个公开快照覆盖 66 项自动检查，包括四种协议的 UTF-8 分片 SSE/JSON、错误与截断、取消与重试、多轮上下文、草稿与存储故障、密钥分离、侧栏交互及移动布局。真实联网验收仅覆盖一次指定中转模型的两轮短对话，不将模拟响应测试等同于全部厂商验收。

## 尚未实现或开放

语音/通话、附件、插件执行及右侧文件/浏览器/终端仍是界面演示。通话页的水滴光球已接入，但不代表录音或语音后端可用。

独立内测通道包含 Android Keystore 硬件证明与请求签名客户端；后台正式签名门禁尚未开放，普通 API Key 聊天不依赖该通道。不提供绕过硬件证明或生产认证的路径。

## 来源与许可证

本项目原创代码按 **GNU GPL version 3 only（SPDX: GPL-3.0-only）** 开源，见 [LICENSE](LICENSE) 与 [COPYRIGHT](COPYRIGHT)。第三方组件、字体和相关材料保留各自许可证，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 [licenses/](licenses/)。

界面与状态管理在此工程独立实现；液态玻璃使用 MIT 的 Liquid Glass Easy。按作者要求迁入其旧项目中自行新增的水滴光球，仅限绘制组件与 Shader，来源见 [ORB-PROVENANCE.txt](ORB-PROVENANCE.txt)。接口资料见 [API-INTEGRATION-SOURCES.md](API-INTEGRATION-SOURCES.md)。

首次公开从清理后的源码快照开始，内部开发交接、个人调试资料、运行数据与凭据不属于公开源码。
