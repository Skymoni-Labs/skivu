# Skivu

独立开发的 Flutter Android 聊天应用，提供多模型文字对话、液态玻璃界面、角色卡与外观配置。同一套源码支持 Web 手机界面预览。

当前版本 **0.2.0+4**，Android 24+，完整 Flutter ABI 为 arm64-v8a / x86_64。安装名、图标与应用内品牌为 Skivu；包标识保留 `com.skyjjgw.independent.ski`，覆盖升级保留已有数据。

## 已实现

- App 内直接使用 Skymoni 普通账号/密码登录；按站点策略处理 RSA 加密、TOTP/备用码。需要 Passkey/网页验证码时保留浏览器额外验证入口，不跳过账号保护。
- 自动同步可用模型、站内钱包/订阅与独立内测计划。申请保留网页入口，资格与额度由管理员控制；批准账号可直接使用内测额度，不要求设备配对、不在不足时改扣钱包。
- 输入框直接搜索选择模型和资金来源，旁边提供回复长度、流式、角色卡与显示偏好；自定义连接可设置温度、上下文和超时。
- OpenAI 兼容 Chat Completions、Responses、Claude Messages、Gemini Generate Content；流式/非流式、多轮历史、停止/重试、草稿和本地恢复。
- 点击对话头像编辑角色描述、性格、场景、关系、示例对话、开场白与回复边界；自己的头像可编辑用户身份卡，设定实际用于之后的模型请求。
- 深色文字、玻璃气泡、圆矩形/直角/尾角/柔和圆角，主题/字体/图片和视频背景、模糊与透明度、命名外观方案。
- 覆盖式折射胶囊顶栏，可切换不透明长方形；生成时显示“对方正在输入中”。底部实际统计可关闭，开启时保持一行。
- 原创多圈消息导航拨盘、搜索/收藏定位；左右侧栏保留跟手与弹簧吸附。
- 迁入作者旧项目自行新增的通话界面与水滴光球，适配当前聊天和 Android 系统识别/朗读，支持字幕、静音、打断、挂断。系统语音可能联网，并需要本机服务及中文语言包；没有打包旧工程的离线语音模型或权重。
- 通过服务器转发 APK 的应用内更新，验证摘要、大小、包名、递增版本与同签名，再交由 Android 系统确认安装。

附件、插件运行和右侧文件/工具/浏览器/终端统一显示“即将开放”，不提供假文件或假执行。统计缺少服务端数据时显示 `—`。

## 运行与构建

开发基线 Flutter **3.41.9** / Dart **3.11.5**，Android 需要 Android SDK 与 JDK 17。

```sh
git clone https://github.com/skyjjgw/skivu.git
cd skivu
flutter pub get
flutter run -d <android-device-id>
# Web 手机预览
flutter run -d chrome
# Android release
flutter build apk --release --target-platform android-arm64,android-x64
```

在“设置 → 中转站账号”登录自己的账号，也可在“模型与服务”使用自己的连接。仓库不提供密码、API Key 或付费额度；密钥和会话通过 `flutter_secure_storage` 单独保存，不包含在聊天备份中。Web 直连接口取决于服务端 CORS，手机和浏览器的数据分别保存。

已分发 APK 当前沿用开发证书，便于覆盖既有测试安装，不代表正式生产签名；不同开发者的调试证书不能彼此覆盖。旧硬件 BetaDevice 通道与新的账号资格内测通道分别控制，不能把开发证书当作正式硬件证明信任。

Windows 辅助脚本中的本机路径可按环境调整；上述 Flutter 命令不依赖这些脚本。安装包与对应源码见 [Releases](https://github.com/skyjjgw/skivu/releases)。

## 验证与范围

```sh
flutter analyze
flutter test
```

当前 97 项全套检查通过，覆盖协议增量响应、错误/取消/重试、多轮/存储、密码与会话分离、原生登录与 MFA 契约、内测资金隔离和撤销、角色卡实际请求与备份、通话迟到结果、侧栏与移动布局。

生产接口已用零额度专用账号实测 App 内登录、模型同步/切换、未开通内测阻断和退出；未发付费模型请求。已检查模拟器系统语音权限、收音入口、试听回调和挂断，实体手机完整语音对话仍取决于实际语音服务和声音环境。此前普通接口的两轮文字聊天、上下文和冷启动恢复已验收，不将这些范围扩大成所有厂商/模型均已实测。

## 来源与许可证

原创代码按 **GNU GPL version 3 only（GPL-3.0-only）** 开源，见 [LICENSE](LICENSE) 与 [COPYRIGHT](COPYRIGHT)。第三方组件、字体保留各自许可，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 [licenses/](licenses/)。

液态玻璃使用 MIT Liquid Glass Easy。用户指定的原创水滴、消息拨盘与通话界面迁移来源和适配边界见 [ORB-PROVENANCE.txt](ORB-PROVENANCE.txt)、[MODULE-MIGRATION.md](MODULE-MIGRATION.md) 与 [module-migration-sources.json](module-migration-sources.json)。没有整份导入旧版上游聊天宿主。账号/内测/更新契约见 [APP-ACCOUNT-UPDATES.md](APP-ACCOUNT-UPDATES.md)，接口资料见 [API-INTEGRATION-SOURCES.md](API-INTEGRATION-SOURCES.md)。

公开历史从清理后的源码快照开始，内部交接、个人调试资料、运行数据库与凭据不属于公开源码。
