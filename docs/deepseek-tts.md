# DeepSeek 语音合成预设

设置 → 语音与通话 → 声音合成中可直接选择 **DeepSeek 语音合成**。
预设填好官方接口地址，默认音色为海星（女声）；也可选择暗潮（男声）。
填写自己的 DeepSeek API Key，保存并使用后，可通过原来的“试听声音”或语音通话使用。
原自定义 HTTP、系统语音及其他服务继续可用，已有连接不自动切换。

未填写密钥时，点击预设打开配置；取消不会保存或切换。密钥仍保存在原本机安全存储，
不自动复制聊天模型密钥，不进入聊天备份。语音合成由所配置服务的账户计费。
地址可按实际服务修改；中转服务需要支持 DeepSeek 的独立 TTS 协议。

使用 `POST https://api.deepseek.com/v1/tools/tts` 和 Bearer 鉴权，发送
`text`、`voice_id`、`format: wav`、`filter_markdown: true`，复用原音频播放和取消流程。
DeepSeek 当前没有模型参数，也不支持调节语速，因此此预设不显示模型和语速控件。
HTTP 音频按原整段合成路径接收完成后播放；本功能未新增 WebSocket 流式播放。
接收错误、可识别的 WAV 截断或无效音频均不交给播放器，也不自动重试付费请求。
服务返回流式 WAV 长度占位值时，完整接收并校验后会补上实际 RIFF/data 长度，
让 Android 原生播放器可按普通音频文件加载；音频采样和其他元数据保持不变。

依据 2026-11-14 核对的[官方接口](https://api-docs.deepseek.com/api/tts/)及
[中文指南](https://api-docs.deepseek.com/zh-cn/guides/tts/)。
