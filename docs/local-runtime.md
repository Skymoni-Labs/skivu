# 本地运行组件协议 1

Skivu 0.2.44 的工作区显示已安装、启用并授权的独立 launcher 插件。
手机 DSH 的页面、DeepSeek Harness 引擎和 Linux 工具在独立项目
[skivu-dsh-runtime](https://github.com/skyjjgw/skivu-dsh-runtime) 分发；宿主没有内置其业务页面。

插件需声明 `runtime.local`，然后调用：

```js
const providers = await Skivu.call('runtime.providers', {});
await Skivu.call('runtime.open', { component, signerSha256 });
```

Skivu 0.2.45 起，`runtime.install({component, signerSha256})` 打开宿主安装页面，
按设备架构从 `https://skymoni.com/api/app-runtime/latest` 取版本信息，下载始终走
本站 `/api/app-runtime/download/…`，不跳转浏览器或 GitHub。安装页提供进度、取消、重试，
在 App 私有缓存校验长度及 SHA-256，原生层再次校验 APK 包名、版本、服务协议、权限和证书，
再提交要求用户确认的 Android PackageInstaller 会话。只信任服务器登记且与插件固定身份一致的组件，
不能提交任意下载地址。宿主自身更新的上游限制保持独立，不允许运行组件安装接口覆盖宿主。
安装来源授权和安装确认使用 Android 系统界面；不会静默安装或绕过系统许可。
此调用在安装页关闭后完成，SDK 超时30分钟；离开或撤销插件会停止下载。

`component` 必须来自用户选择且已核验来源的运行组件。插件应固定自己信任的签名摘要，
不能把任意安装包返回的摘要当作可信来源。宿主在发现和绑定后核验签名、不同 UID、
协议元数据、签名级服务权限，并拒绝具有 INTERNET 权限的运行组件。

Android 服务通过 `org.skivu.runtime.V1` 发现，元数据 `org.skivu.runtime.protocol=1`，
要求 `org.skivu.permission.RUN_RUNTIME`。每次运行使用新会话令牌，Binder 双向校验 UID。
Skivu 0.2.47 起，若系统拒绝绑定已验证的服务，宿主可打开服务元数据
`org.skivu.runtime.activation` 指定的同包、同 UID、已启用且导出的 Activity。
用户完成启用并返回 `RESULT_OK` 后重验签名与服务，再尝试连接一次；取消不启动运行环境。
该 Activity 不需要桌面入口，也不得自行授予模型或设备权限。若系统仍拦截，应提示用户
检查关联启动设置，不能把连接被拒绝误报为组件未安装。
启动消息传递 localhost listener、模型和设备 socketpair 的文件描述符，不传递账号令牌。
运行组件返回同端口的本地认证 URL。WebView 只加载这个来源，不附加宿主 JS bridge，
禁止文件访问、外部导航和外部资源；HTML 的 CSP 由宿主代理强制注入。

模型帧为换行 JSON：`{id,method:'model.generate',params:{messages,tools}}`，最多 256 KiB。
Skivu 0.2.47 在打开会话时一次确认模型调用和正常计费，后续每次请求只校验本次授权，
不逐次弹窗。账号、资金来源或自定义连接配置变化时结束本次授权；插件撤权及关闭立即取消。
设备帧最多 64 KiB，手机操作仍使用独立设备授权。

支持 `{id,method:'model.list',params:{}}` 返回同步的账号模型和宿主已保存的自定义连接，
只包含 `id/name/provider/supportsTools`。生成可增加 `params.model` 指定返回的 ID；
宿主只解析本次目录中的选择，拒绝任意地址或密钥参数。账号请求保持现有 AppAccount
模型发布/内测/计费保护；自定义密钥由宿主安全存储读取，组件不获得密钥或接口配置。
原生启动消息用 `modelCatalog=true` 声明此能力，组件给引擎设置
`SKIVU_MODEL_CATALOG=1`；旧宿主没有此标记时继续使用固定的当前模型，不能发送新目录帧。
当前编程调用支持 chat 协议的文字与结构化工具；目录中其他协议标注暂不支持，不伪装兼容。

未声明角色、聊天或角色伴侣能力的独立运行插件不显示角色选择，`context.get` 和
上下文事件不含角色/聊天标识；其模型调用不继承角色设定或角色聊天记录。
运行过程使用带停止入口的前台服务。厂商仍可能冻结后台组件，宿主运行设置可打开
组件启用页及其系统设置；OPPO/ColorOS 实测需在耗电管理选择完全允许后台行为。

关闭、插件撤权、服务断开或宿主退出都会取消模型与设备任务并要求运行组件停止。
运行组件必须确认所有自身 UID 子进程已停止，包含 detached 子进程。超时不能报告停止成功。
项目与 DSH 存档由组件自己的私有目录持久化；卸载组件会删除它们。

管理员能力、账号令牌、模型密钥、签名材料、内部配置与运维数据始终属于宿主/服务端私有边界。
模型发布、账号资格、内测、计费和服务端防护继续通过原有守卫校验。
