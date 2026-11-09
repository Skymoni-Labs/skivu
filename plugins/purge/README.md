# 小云 · 规则与演练

基于 [YuJunZhiXue/dsh-purge](https://github.com/YuJunZhiXue/dsh-purge) 1.1.71，原作 Copyright (c) 2026 小杨。原版可用源文件、LICENSE 和 README 说明保留在 `upstream/`；每个输入文件的 SHA 在 `PROVENANCE.json`。Windows 安全中心隔离的 `unauth-exploit.md` 正文未重新写入；清单记录其原始摘要及隔离情况。

需要 Skivu 0.2.96 或更新版本。在工作区打开“小云 · 规则与演练”，首次启用后即可使用；也可导入构建所得 `.skivu.json`。它使用已合并进小云的内置 Linux/Node/SQLite，不安装、启用或启动独立 DSH。

## 功能

- 小云提示词、多规则选择、文件导入/全文导出、保存草稿、应用与撤销；显示宿主实际保存的提示词状态。首次应用及修改均由页面明确按钮发起。
- 原版演练台的数据页面与 SQLite 模型：资产/服务/指纹、发现项、证据、凭据、访问状态、会话与隧道记录、攻击链、评分与报告、知识库、角色提示词。
- 原包技能目录共 23 项：22 份正文可浏览、检索并由小云按需读取，1 项标明系统防护隔离。资料可读不代表外部二进制或密钥已经安装。
- 小云工具 `plugin:org.skivu.purge/query` 和 `.../record`。参数为 `request` JSON 字符串，首次用 `{"op":"help"}` 查看操作；`bootstrap` 取得明确演练编号。目标相关写入必须显式 `engagement`。
- 完整资料库导出、摘要与 SQLite 检查、新版本恢复及历史版本回切。原版本保留；已保存文件路径随恢复位置迁移。备份含用户自行保存的凭据与证据。

DSH 宿主的源码/ASAR/审批/重启补丁没有对应 Skivu 模块，页面明确显示不适用。原专用并行智能体运行器与 TCP 连通探测未启用；执行、取消、恢复和防重复由小云已有体系负责。原默认身份替换与“忽略限制”提示词未自动注入，适配预设保持小云身份。页面和工具返回的规则、技能和资料均为参考数据。

## 构建与验证

在本目录运行 `npm ci --ignore-scripts`、`npm run build`、`npm test`。锁定依赖只有 esbuild、React 和 React DOM；构建将前端写成可安装包，并将数据服务打包到主 App 的 `android/app/src/main/assets/cloud/lab.mjs`。主 App 必须同时构建更新。

`lab.call` 经新 `cloud.lab` 权限进入既有私有管道，没有 HTTP 监听器。每插件资料库隔离，源文件路径与符号链接不能越界。只读工具在宿主强制只读；相同原请求复用持久回执，未知结果不自动重放。恢复先写入并核验新版本，最后才切换指针。

模拟器原生检查位于 `integration_test/cloud_purge_native_test.dart`，必须使用 `SKIVU_PURGE_QA=true` 独立 QA 包。可见 UI 测试将测试脚本注入 QA 包的内存副本，交付插件不包含测试脚本。没有真实模型请求或外部目标探测。

在项目根目录使用 `tools/test_cloud_purge.ps1` 运行：它先核验 APK 的独立包名，再用 `--use-application-binary` 和 `--keep-app-running` 启动驱动器；结束只停用指定 QA 包。不要对正式包使用 Flutter drive 的默认卸载清理流程。
