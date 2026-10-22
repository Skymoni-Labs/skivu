# 第一版文字聊天的接口来源

实现由本工程独立编写。2026-10-22 按用户要求查看旧星伴的供应商选择菜单与新建供应商表单，只参考分类与字段含义；没有读取或迁入其宿主实现、认证代码、模型实现或现有 API 密钥。

已先查看 [Operit 插件市场](https://operit.app/#/developers/plugins) 的公开入口。此轮是移动端基础 HTTP 协议与本地配置接入，没有采用市场插件或宿主代码。入口为动态页面，静态读取没有可核对的具体插件实现，不能据此声称审计了整个市场。

依据的公开协议资料：

- [OpenAI API 公开规范](https://github.com/openai/openai-openapi)：Chat Completions、Responses、流式增量与用量字段；独立 REST 请求，Responses 使用 store:false。
- [Claude 流式消息](https://platform.claude.com/docs/en/build-with-claude/streaming)：message_start、content_block_delta、message_delta、message_stop；x-api-key 与 anthropic-version。
- [Gemini Generate Content](https://ai.google.dev/api/generate-content)：contents、systemInstruction、streamGenerateContent 与 usageMetadata。
- [Ollama 兼容接口](https://docs.ollama.com/api/openai-compatibility)：连接本地服务，没有引入嵌入式模型引擎。
- [百炼 Base URL](https://docs.bailian.console.aliyun.com/en/model-studio/base-url)、[硅基流动快速上手](https://api-docs.siliconflow.cn/docs/userguide/quickstart)、[OpenRouter 快速上手](https://openrouter.ai/docs/quickstart)、[xAI 文档](https://docs.x.ai/overview)、[DeepSeek API](https://api-docs.deepseek.com/)：常见服务地址预设。未核实地域/套餐地址的条目要求用户按控制台填写，一个预设名称不代表厂商的所有产品均已验证。
- [Azure OpenAI REST](https://learn.microsoft.com/en-us/azure/foundry/openai/latest)：支持完整部署地址、api-version 查询参数和 api-key 鉴权。

第三方实现仅依赖固定的 http 1.6.0、flutter_secure_storage 11.2.0 与 crypto 3.0.7，均保留 BSD-3-Clause 正文。95 个已解析包 / 91 份官方归档核对见 dependency-audit.json；不夸大为所有 Maven 产物审计。

内测通道依据另一用户会话提供的 skymoni-app-beta-v1 协议：固定 https://skymoni.com，令牌独立安全存储；P-256 私钥由 Android Keystore 生成和签名，不可导出，不回退软件密钥。服务器验证依据 [Android key attestation](https://developer.android.com/privacy-and-security/security-key-attestation)，核对证书链、硬件等级、锁定启动、包名和固定的正式签名。客户端不代替服务器作出可信判断；后台和正式签名未配置时，不能宣称内测已可用。

内测模型目录按后台返回的 model_protocols 选择 chat 或 responses，分别签名并请求固定的 /api/app-beta/chat/completions 或 /api/app-beta/responses。Responses 仅发送约定的 input、instructions、stream、max_output_tokens 与 store:false；未支持的协议标记不会作为可聊模型显示。

原文字聊天接入范围为流式/非流式、多轮历史、停止/重试、配置和消息本地保存。后续迁入的通话界面使用 Android 系统识别和可配置语音合成；嵌入式模型、附件和工具执行未实现。供应商列表是协议预设；本地协议测试不等于每家服务商真实账户均已逐一验收。

2026-10-22 新增普通 Skymoni 账号的系统浏览器 PKCE 授权、模型/钱包/订阅同步及同域服务器转发 APK 更新。依据独立服务端公开契约 [SKIVU_APP_API.md](https://github.com/skyjjgw/skymoni-source/blob/main/docs/SKIVU_APP_API.md) 实现；与 Codex 网页账号登录及硬件内测配对是不同能力。流程、限制和品牌源文件见 APP-ACCOUNT-UPDATES.md。

## 0.2.3 语音合成与流式呈现

独立实现语音连接、密钥安全存储、音色/语速、试听与通话适配；不复制旧项目的供应商实现、模板或响应管道代码。按用户要求核对旧星伴配置项，并参考以下官方资料：

- [SillyTavern TTS 配置](https://docs.sillytavern.app/extensions/tts/)：将语音服务商、声音选择和试听与聊天模型配置分开，是功能组织参考；未引入其扩展代码。
- [OpenAI Speech 文档](https://developers.openai.com/api/docs/guides/text-to-speech)：完整 `/v1/audio/speech` 地址、模型/音色、文本、语速与可选风格，返回 MP3。兼容服务的实际能力由其实现决定。
- [ElevenLabs Create speech](https://elevenlabs.io/docs/api-reference/text-to-speech/convert)：音色位于 URL、`xi-api-key`、`model_id` 与语音设置。
- [Azure Speech REST](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/rest-text-to-speech)：区域完整地址、订阅密钥、SSML 与音频输出头。

自定义 HTTP 支持 GET/POST、JSON 请求头/请求体变量、直接音频或 JSON Base64/Hex/音频 URL 字段。音频 URL 不继承鉴权，拒绝自动跳转，限制音频大小与超时；原始 PCM 要由服务包装成 WAV。全配置（含请求头、模板）只进入安全存储，不进入聊天备份。没有下载离线语音模型，也没有默认调用云端或共享中转站密钥。

流式呈现独立于 SSE 包边界，按字素逐帧显示并随积压量调节；停止保留收到的前缀，换会话/退出不会向新回复写入晚包。用 characters 1.4.1 处理组合字符与 emoji，保留其 BSD-3-Clause 通知。此机制不改变服务端推理速度、首包等待或请求用量。
