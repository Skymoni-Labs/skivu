# 手机端 Skivu：复用 dsh-go 手机操控

本改动基于 Skivu `release/0.3.4-authority-4113` 的 `1b867959db24898653a69e67c2f530742610df43`，上游固定为 [dsh-Go](https://github.com/ccch1mneyyy/dsh-Go) `9cf96c531cfb9c654ac6df830d3c0b48acadbc58`。这是 Android App 的手机操控接入；桌面 Windows 客户端不在范围内。

## 执行路径

现有小云 AssistantEngine → DeviceEngine → DshGoPhoneHost → 原 PhoneBridge（同 UID、随机令牌认证的本机 socket）→ 原 MCP/PhoneCore/PhoneTaskSessions → 原无障碍或后台屏驱动。

没有第二个模型、独立 DSH 聊天入口或模拟执行器。原生 `phone/` 全部源文件直接纳入，工具定义和参数来自原 PhoneToolCatalog。14 个工具为 `phone.apps/open/intent/notify/clipboard/screen/collect/tap/type/scroll/key/tap_xy/handoff/android_shell`。屏幕操作沿用原 `screen`、`id` 参数、过期目标检查、应用限制、确认、停止、资源租约、任务日志和生命周期规则。

主屏操作使用原无障碍服务；Android 14+ 的后台屏沿用原 Shizuku/Sui/Root/自连 ADB 连接、配对与授权逻辑。实际可用性由原生模块检测，缺权限时不会退到旧执行器或冒充后台成功。应用最低 Android 版本随原模块提高到 API 26。无障碍本身不能保证所有应用都在后台运行。

## Skivu 适配范围

- `DshGoPhoneHost` 将既有小云任务身份转换为原协议的 sessionId/runId/callId，并使用原 run-end 封口规则处理停止和结束。
- 原手机运行身份在首次实际 phone 调用时才分配；普通对话和仅编程任务不占用原手机生命周期保留额度。
- 原生工具名称加 `phone.` 前缀以接入既有工具目录；schema、原 MCP 内容与图片保持原意义。图片进入原模型图片字段，不把整段 Base64 重复放进文本。
- 继续使用既有 DeviceReceiptStore。派发前保存待核对记录，同 owner/requestId 的重复请求返回原结果；参数顺序不改变请求身份。已发生动作但回执断开时保留 unknown，不重试动作。MCP 明确错误保留 isError；对可能产生动作的工具，错误不证明零副作用，因此同样保留 unknown/hasUnverifiedActions，不能按“未执行”重试。apps/screen 纯读取错误可标为 failed；API 返回不等于目标业务已完成。
- 原 EmbeddedTaskService 和 FlutterEngine 延续小云任务寿命；原生停止事件回到既有小云停止逻辑，来源对话入口使用原聊天记录，不另建聊天库。
- 原 `PhoneControl.prepareLaunch` 的生命周期序列用于新的 native-host 入口。桥重连时也先执行原 stopBridge/会话退役，避免旧主屏租约阻塞新读取。
- 支持类只提取原手机模块所需内容；RuntimeController 是明确标注的宿主生命周期/路线文件适配，不启动原完整 DSH rootfs 或其他模型。应用包身份使用实际 BuildConfig.APPLICATION_ID，支持正式 ID 与独立验收 ID。
- 后台探测 Activity 的组件包名使用实际 applicationId，类名固定为移植后的 Kotlin namespace；不能用安装包名拼接类名。
- 手机操控设置接入原 `dsh/phone` 和事件通道，沿用原生持久化、确认和权限闸门。提供主开关、无障碍、确认方式、本地 OCR、后台连接和配对、Shell、应用规则、悬浮条、任务暂停/继续/停止/清理重试、环境检查，以及中断状态的显式用户核对入口。
- 原路线记录、保存/回放协议及 native API 源码包含在模块中；现有设置页仅提供“成功后提示保存”开关，未复制原 DSH 的完整路线管理和 Workshop 页面。模型仍走本节所列 14 个原生工具。

旧 ui.*、apps.* 和旧手机场景适配器从新原生执行目录退出；旧定义/回执保留以便解释历史数据。旧无障碍服务不再注册。原模型连接、流式输出、编程能力、提示词插件和任务数据不迁移或覆写。

## 升级和授权

新无障碍服务是系统中的独立组件；升级后需要在系统设置中启用“Skivu 手机操控”。不会自动授予真实手机权限。后台连接与 Shell 分别按原模块要求授权。旧权限设置不被当成新授权。

中断任务提示必须由用户核对真实软件状态后确认；确认仅清理该批中断提示，不重做动作。原单次桥生命周期最多保留 256 个手机运行身份，保留原限制及提示；必要时停用再启用手机操控以创建新桥，不自动淘汰防重/结束屏障。

## 验证和可复现构建

独立验收包 ID 为 `com.skyjjgw.independent.ski.dshgoqa`，正式 App ID 不变。`-PskivuDshGoQa=true` 仅用于独立包；正常构建默认 `lib/main.dart`。显式测试入口 `lib/dsh_go_phone_qa.dart` 仅在指定 target 时使用；`SKIVU_DSH_GO_QA_AUTORUN=true` 只运行本地模拟模型，驱动真实原生控件。

```text
flutter analyze --no-pub lib/dsh_go_phone_settings.dart lib/dsh_go_phone_check.dart lib/device_engine.dart lib/assistant_engine.dart lib/cloud_conversations.dart
flutter test --no-pub test/dsh_go_phone_test.dart test/dsh_go_phone_settings_test.dart test/assistant_engine_test.dart
```

Android instrumentation 的 `DshGoPhoneAcceptanceTest` 只允许独立验收包，使用其测试 APK 中的真实计数和输入 Activity。测试后恢复无障碍设置。回执故障注入仅通过测试代码反射切断自有桥，不新增生产故障接口。

上游 JVM 测试保留全部用例。Windows 测试环境对源码路径、子进程 classpath 和 POSIX 引号夹具作适配，不改变生产 Root 驱动；引号测试使用 Git Bash。受控 Gradle init 文件只选择本次导入的测试，原 Skivu 桌面 AWT 夹具未混入 Android JVM 范围。

可从 Android 目录运行 `gradlew :app:testDebugUnitTest -I ../tool/dsh_go_phone_tests.gradle`。Windows 使用当前已有的 Git Bash；其他安装位置通过 `DSH_GO_TEST_SHELL` 指定，不安装或替换系统 shell。

本机 Flutter 工具快照会在 release 的自动生成注册文件中保留 dev-only integration_test，而 Gradle 已正确排除该依赖。可在 Gradle release 命令中显式使用 `-I ../tool/dsh_go_release_registrant.gradle`：只在本工程 release Java 编译前剔除该自动生成的测试注册块；不修改 SDK、应用逻辑、调试构建或其他插件。正常正确生成 release 注册文件的 SDK 下是无操作。本次没有把测试插件加入 release。

验证范围：1,403 个原模块 JVM 用例、22 个相关 Dart/界面用例、6 个模拟器真实原生用例，以及本地模拟模型的 7 次完整小云调用。原生用例包含真实读屏/点击/输入、重复 ID/参数排序、过期目标、停止、缺权限和动作已发生后的回执丢失。后台 Root/Shizuku/Sui/无线 ADB 真机矩阵及真实付费模型未在本次验证。环境检查按原报告展示未观察/未运行项目，不将其算作通过。

以上是功能开发阶段的独立验收范围。0.3.5（4114）使用正式 App ID、原签名以及分别构建的 ARM64/x64 包；发布页提供对应提交的完整组合源码和校验值。Android 最低版本为 8.0（API 26），升级后须启用新的“Skivu 手机操控”无障碍服务。高权限真机矩阵仍未验证。逐文件来源及改动哈希见 `dsh-go-phone-source.json`，失败尝试保留并与最终通过记录区分。

## 许可和回退

原 AGPL-3.0 许可与原项目完整第三方通知保留在 `licenses/dsh-go/`，App 许可页也可读取。仅手机模块及所需支持代码进入 App；无原桌宠美术。组合版本发布前须随相应版本提供对应源码，不能仅交付闭源 APK。

回退基于本分支相对上述 Skivu 基线的精确差异，保留后来其他分支的改动；不能覆盖最新正式目录或恢复旧整包。原手机数据、模型配置和回执未删除。仅恢复旧服务/执行目录和撤下本次 native 接入即可，不需要清除用户数据。

## 同日 UI 跟进：恢复 Skivu 原有设置样式

手机操控页重新使用基线版本的 ProductScaffold、ProductSection 和 MarketPanel，保留原渐变背景、圆角分组、字号及图标层级。常用操作、识屏、后台连接和应用规则独立分组；编程入口、Android Shell、后台屏细项及悬浮条记录放入默认收起的面板。展开仅改变显示状态，不修改授权。

应用规则复用原 EngineAppSelectionPage 的搜索、拼音索引及选择行为，并按真实的原生排除/每次确认规则显示文案；保留手动包名编辑和未安装软件的规则。新增 settings-only `policyApps` 只投影原 SystemApi.apps 与原 Skivu AppAlphabet 元数据，没有新增模型工具、执行后端或授权开关。确认、停止、持久回执及模型调用实现保持上一交付字节。

无线配对及手动规则对话框等到原 DialogRoute 完全退出后再释放输入控制器，取消不保存、不配对。折叠状态与滚动位置分别使用正确的存储标识，列表文字明确继承现有主题的前景色。

该轮通过 30 项相关 Dart/界面测试及 2 项原应用选择页回归，覆盖 360px、1.4 倍文字、深浅主题、文字对比度、折叠不写设置、拼音搜索、隐藏规则保留、手动编辑的保存/取消和配对对话框。真实模拟器页面与最终独立预览包的证据位于 `ops/skivu-dsh-go-phone-ui-20261114`；高权限真机覆盖范围仍与上一节一致。
