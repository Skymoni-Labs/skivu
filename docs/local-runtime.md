# 本地运行组件协议 1

Skivu 0.2.44 的工作区显示已安装、启用并授权的独立 launcher 插件。
手机 DSH 的页面、DeepSeek Harness 引擎和 Linux 工具在独立项目
[skivu-dsh-runtime](https://github.com/skyjjgw/skivu-dsh-runtime) 分发；宿主没有内置其业务页面。

插件需声明 `runtime.local`，然后调用：

```js
const providers = await Skivu.call('runtime.providers', {});
await Skivu.call('runtime.open', { component, signerSha256 });
```

`component` 必须来自用户选择且已核验来源的运行组件。插件应固定自己信任的签名摘要，
不能把任意安装包返回的摘要当作可信来源。宿主在发现和绑定后核验签名、不同 UID、
协议元数据、签名级服务权限，并拒绝具有 INTERNET 权限的运行组件。

Android 服务通过 `org.skivu.runtime.V1` 发现，元数据 `org.skivu.runtime.protocol=1`，
要求 `org.skivu.permission.RUN_RUNTIME`。每次运行使用新会话令牌，Binder 双向校验 UID。
启动消息传递 localhost listener、模型和设备 socketpair 的文件描述符，不传递账号令牌。
运行组件返回同端口的本地认证 URL。WebView 只加载这个来源，不附加宿主 JS bridge，
禁止文件访问、外部导航和外部资源；HTML 的 CSP 由宿主代理强制注入。

模型帧为换行 JSON：`{id,method:'model.generate',params:{messages,tools}}`，最多 256 KiB。
设备帧最多 64 KiB，使用公开设备能力与宿主授权。每次模型请求需确认，模型、资金来源、
输出上限和服务器鉴权由宿主决定。当前只支持 chat 协议的文字与结构化工具调用。
Responses、多模态、任意第三方模型地址和密钥不通过此接口开放。

关闭、插件撤权、服务断开或宿主退出都会取消模型与设备任务并要求运行组件停止。
运行组件必须确认所有自身 UID 子进程已停止，包含 detached 子进程。超时不能报告停止成功。
项目与 DSH 存档由组件自己的私有目录持久化；卸载组件会删除它们。

管理员能力、账号令牌、模型密钥、签名材料、内部配置与运维数据始终属于宿主/服务端私有边界。
模型发布、账号资格、内测、计费和服务端防护继续通过原有守卫校验。
