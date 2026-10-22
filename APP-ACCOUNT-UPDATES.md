# 中转站账号与 App 更新

Skivu Android 客户端使用固定的 `https://skymoni.com` 服务。账号可明确选择站内钱包/订阅或管理员批准的独立内测额度；自定义 API 连接与旧设备通道继续分别管理。服务端契约见 [Skymoni SKIVU_APP_API](https://github.com/skyjjgw/skymoni-source/blob/main/docs/SKIVU_APP_API.md)。

## App 内账号登录（主要入口）

“设置 → 中转站账号”直接填写普通账号和密码。客户端读取 `GET /api/app-account/login/options`，按站点当前要求使用 HTTPS 密码提交或原生 RSA-OAEP SHA-256/MGF1-SHA256 加密提交到 `POST /api/app-account/login`。App 不保存密码；只把受限、可撤销的 `AppAccount` 会话存入系统安全存储。

需要 TOTP/备用码时，在 App 中使用 `POST /api/app-account/login/verify` 完成验证。Passkey 或站点验证码需要额外网页验证时，保留下面的浏览器授权作为备用入口，不跳过原有账号保护、登录限流或会话上限。

## 备用网页登录

1. App 生成随机 PKCE verifier，把其 SHA-256 / base64url challenge 交给 `POST /api/app-account/authorize`。
2. 打开服务端返回的同域 HTTPS 授权页面。用户在网站完成原有登录、验证码、MFA 和设备确认。16 位授权码区分大小写，App 原样显示与复制。
3. App 按服务端间隔轮询 `POST /api/app-account/token`；授权码与 verifier 匹配后，获得受限、可撤销的 `AppAccount` 会话。不会读取或保存用户密码，也不自动创建人工 API Key。
4. `GET /api/app-account/me` 同步账号、钱包、订阅和会话；`GET /api/app-account/models` 同步账号权限下的模型及 chat/responses 协议。钱包和各项订阅分别展示，金额使用服务端 `quota_per_unit` 换算，不固定假设比例、不将钱包和订阅相加。
5. 聊天请求送至固定的 `/api/app-account/chat/completions` 或 `/api/app-account/responses`，仅发送约定文字字段。Responses 使用 `store:false`。聊天结束及打开账号页时同步额度，用户也可以手动刷新。
6. 账号页顶部可直接退出。先删除本机安全存储中的会话，再清除内存状态，并尝试调用 `DELETE /api/app-account/session`（最多等待 5 秒）；断网时本机仍可退出，服务端撤销失败会显示提示。退出时停止本机账号生成，迟到的同步响应不会恢复旧账号。过期或撤销的会话会从本机移除，账号通道不会自动回退到手动 API Key；会话上限错误不会自动踢下其他设备。

会话与备用登录中进行的 PKCE 凭据使用 `flutter_secure_storage` 保存，不进入聊天备份。服务端保留普通账号的资金和模型权限。新的账号内测通道按服务器批准资格与独立账本生效；旧硬件 BetaDevice 通道和正式签名门禁保持原状。

## 内测计划与模型选择

- `/me.beta` 和 `GET /api/app-account/beta-status` 同步 none/pending/approved/rejected/suspended、是否开通、渠道开关及真实内测余额。`balance` 已是可用额，不再减去 `reserved`；预留与已用分别显示。
- 未申请用户保留 `https://skymoni.com/creators` 网页申请入口；申请、审核、暂停和额度发放由管理员后台控制，App 无审批或自增额度能力。
- 已批准且额度有效的账号可直接选择内测资金，无需设备配对。输入框模型入口可搜索服务器返回的可聊天模型，并选择站内或内测额度；模型权限始终由账号原有组控制。
- 内测目录使用 `GET /api/app-account/models?funding=beta`；聊天显式携带 `funding:"beta"`。未指定资金仍为站内额度；内测未批准、暂停、耗尽或渠道不可用时拒绝，不转扣站内钱包。两类账本不相加。
- 普通账号聊天支持当前协议约定的最大输出和流式参数。输入区可直接调整，并访问角色卡、思考显示和单行统计开关。其他自定义连接的高级参数仍在模型设置。

## 手机内更新

- 启动及“设置 → 检查更新”请求 `GET /api/app-update/latest?platform=android&abi=…&version_code=…`。有新版本时提示查看更新；下载和安装由用户发起。
- APK 从同域 `/api/app-update/download/<release-id>/<abi>` 流式转发。客户端不跳转到任意第三方地址，不发送 Range 续传；失败后从头下载。
- 下载进应用私有缓存，完整校验字节数和 SHA-256 后才生成可安装文件。失败或取消时清理部分文件。
- 安装前再次核对 APK 内容摘要、包名、递增构建号及与当前安装版本相同的签名。系统可能要求允许 Skivu 请求安装包；最终安装仍由 Android 系统确认，不提供静默安装。
- 当前更新通道适配 Android 24+ 的 arm64-v8a / x86_64。当前开发签名沿用旧测试版以便覆盖升级；它不是内测后台信任的正式签名，不应据此打开内测门禁。

发布新 APK 时应同时公开准确的对应源码、版本、大小、SHA-256 和签名指纹，再更新服务端发布目录。接口读取新目录后，App 即可发现新版本，无需重新部署服务器二进制。APK 上游可使用本项目的 GitHub Release 资产，服务器负责转发，避免长期保存重复安装包。

## 品牌资源

安装名为 Skivu；启动图标和应用内标识来自已定稿的 `assets/branding/skivu-approved.png`。原图保持不变，`branding-assets.json` 记录源文件和各尺寸的 SHA-256。`scripts/generate_brand_assets.py` 使用开发机 Pillow 生成 Android legacy/adaptive 及 Web 图标，没有新增 App 运行依赖。

已保存的用户角色名称、聊天记录、壁纸和连接不会因品牌显示名变更而覆盖；新安装的默认角色使用 Skivu。Android applicationId 保留为 `com.skyjjgw.independent.ski`。
