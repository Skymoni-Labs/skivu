# 原创模块迁移与界面配置来源

2026-10-22 用户明确要求迁入其旧星伴二次开发中自行设计的消息导航和电话模块。来源仓库为 `skyjjgw/starcompanion-operit2`，固定到已提交的 `51f29da6f68407b0c4aaa651536b5f83054bcb58`，文件及原始 Git blob 摘要见 [module-migration-sources.json](module-migration-sources.json)。没有读取正在其他工作树中修改但尚未提交的语音运行时代码作为本轮迁移来源。

- `ChatMessageDial.dart` 与 `ChatMessageDialModel.dart` 首次新增于 `123a583f`。迁入原有多圈、速度分档、反向清除加速、死区重定位、预览和取消处理；本工程提供消息索引/预览及中文文案适配，复用当前搜索/收藏定位列表。
- `VoiceCallScreen.dart` 首次新增于 `a6df0480`。迁入通话布局、字幕、状态、静音/挂断、打断和更多菜单，接回本工程已迁入的原创水滴光球。屏幕退出方式、减少动态效果和状态说明按当前 App 适配。
- 旧工程的 `ChatScrollNavigator` 在上游基线已存在，因此没有整份复制；没有导入旧 ChatViewModel、Rust Core、宿主工具、生成代码或上游聊天运行时。当前消息持久化和模型通道保持本工程实现。
- 通话会话/原生语音适配器在当前工程编写，使用当前聊天模型、角色、历史及资金来源；Android `SpeechRecognizer` 负责识别、`TextToSpeech` 负责朗读，系统可能需要联网或语言包。没有把旧工程的 Collei 模型、权重、其他语音提供商或录音插件一并打包。退出/后台停止收音，挂断会取消本次模型请求并丢弃迟到结果；App 不保存录音文件。

上述迁移依照用户对其原创新增材料的明确授权，不把旧版整个衍生工程重新许可。原始提交链用于记录来源，第三方通知继续保留；若发现另有具体贡献来源，应继续核对并保留相应声明。原有光球来源另见 [ORB-PROVENANCE.txt](ORB-PROVENANCE.txt)。

## 玻璃与配置参考

用户同时授权参考自有 Skymoni 玻璃源码。已查看其 `frontend/web/src/styles/site-glass.css` 与 `features/auth/auth-glass.css`：借鉴“只模糊背景、内容清晰、薄亮边和柔和投影”的材料组织，按 Flutter 实现，未将网站 React/CSS 运行时搬入 App。折射透镜仍由现有 MIT Liquid Glass Easy 提供。顶栏以覆盖布局让消息能滚到真实胶囊后方；关闭胶囊时绘制不透明长方形。

输入区参数参考 [Open WebUI 官方模型控制说明](https://docs.openwebui.com/features/workspace/models/)：模型入口旁提供对话参数按钮，当前暴露真实支持的输出上限、流式、角色和显示偏好；自定义连接可进入温度/上下文/超时等高级配置。没有给服务端未支持的账号参数做假开关。

角色卡参考 [SillyTavern Character Design](https://docs.sillytavern.app/usage/core-concepts/characterdesign/) 和 [Prompts](https://docs.sillytavern.app/usage/prompts/)：提供描述、性格/说话方式、场景、关系、示例对话、开场白与回复边界。填入的设定会组合进之后请求的系统提示词，`{{char}}` / `{{user}}` 仅做文本替换；开场白只在新会话本地显示，不产生模型调用。用户身份卡可从自己的头像编辑。界面和字段实现由本工程编写，没有复制这些产品的前端源码。

Android 语音 API 行为依据 [SpeechRecognizer](https://developer.android.com/reference/android/speech/SpeechRecognizer) 和 [TextToSpeech](https://developer.android.com/reference/android/speech/tts/TextToSpeech) 官方文档。
