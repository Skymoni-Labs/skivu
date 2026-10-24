# 技能与 MCP 工具

从插件市场进入“技能与 MCP 工具”。技能安装后需要开启“用于对话”，指令及参考资料才会随新请求发送给当前选择的模型。用户可以查看来源、许可和原文，关闭或卸载。它不具备本机进程或文件执行能力。

MCP 使用独立编写的 Streamable HTTP 客户端。支持协议协商、初始化、会话头、JSON/SSE 响应、工具分页和用户主动调用。填写 HTTPS 服务地址和可选 Bearer 密钥后连接，选择工具并按参数格式填写 JSON 对象。执行会将参数发送给该服务；结果可查看、复制。不会自动给模型新增工具调用，也不会复用账号或模型密钥。

安装目录：`https://skymoni.com/app-plugins/catalog/extensions.json`，GitHub 固定主仓库目录为备用来源。旧界面包目录继续使用协议 1.0。扩展包的不可变来源限定为个人主仓库 `skyjjgw/skivu-plugins` 的完整提交；校验精确下载字节 SHA-256、长度与元数据，成功保存后才替换原版本。

第三方指令只在用户主动开启后使用。参考资料以内嵌文本形式提供；不解释其中的脚本为可执行内容。启用指导总大小上限 64 KiB，单包上限 768 KiB，安装库上限 16 MiB。MCP 拒绝重定向、含凭据的 URL、非 HTTPS 地址和不支持的服务器能力；网络错误不会在提示中回显远端内容或密钥。连接密钥保存在独立的设备安全存储命名空间，卸载工具时一并移除。

实现仅使用现有 Flutter/http/crypto/shared_preferences/flutter_secure_storage 依赖，没有复制 Operit 宿主、运行时或素材。上游插件的许可、文件摘要及修改声明由插件仓库逐项保存。对于依赖 Operit 专有 API、Android terminal、Python/Node 或浏览器自动化的项目，须提供独立适配和验证后再按真实能力收录。

MCP 协议参考：<https://modelcontextprotocol.io/specification/2025-11-25/basic/transports>、<https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle>、<https://modelcontextprotocol.io/specification/2025-11-25/server/tools>。
