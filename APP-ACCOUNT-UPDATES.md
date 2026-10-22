# 中转站账号与 App 更新

Skivu Android 客户端使用固定的 `https://skymoni.com` 服务。账号授权与普通钱包/订阅相连；自定义 API 连接和内测设备通道继续分别管理。服务端契约见 [Skymoni SKIVU_APP_API](https://github.com/skyjjgw/skymoni-source/blob/main/docs/SKIVU_APP_API.md)。

## 账号登录

1. App 生成随机 PKCE verifier，把其 SHA-256 / base64url challenge 交给 `POST /api/app-account/authorize`。
2. 打开服务端返回的同域 HTTPS 授权页面。用户在网站完成原有登录、验证码、MFA 和设备确认。16 位授权码区分大小写，App 原样显示与复制。
3. App 按服务端间隔轮询 `POST /api/app-account/token`；授权码与 verifier 匹配后，获得受限、可撤销的 `AppAccount` 会话。不会读取或保存用户密码，也不自动创建人工 API Key。
4. `GET /api/app-account/me` 同步账号、钱包、订阅和会话；`GET /api/app-account/models` 同步账号权限下的模型及 chat/responses 协议。钱包和各项订阅分别展示，金额使用服务端 `quota_per_unit` 换算，不固定假设比例、不将钱包和订阅相加。
5. 聊天请求送至固定的 `/api/app-account/chat/completions` 或 `/api/app-account/responses`，仅发送约定文字字段。Responses 使用 `store:false`。聊天结束及打开账号页时同步额度，用户也可以手动刷新。
6. 退出会调用 `DELETE /api/app-account/session`。过期或撤销的会话会从本机移除，账号通道不会自动回退到手动 API Key；会话上限错误不会自动踢下其他设备。

会话与进行中的 PKCE 凭据使用 `flutter_secure_storage` 保存，不进入聊天备份。服务端保留普通账号的原有资金与权限规则，内测资金和正式签名门禁不因账号登录而开放。

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
