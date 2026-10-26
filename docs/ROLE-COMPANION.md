# 角色随身插件（SDK 1.0 增量，宿主 0.2.41 起）

角色随身插件把页面与正常聊天工具分开。安装及全局授权后，用户在“角色随身插件”中为角色单独绑定；默认仅手动使用，另行打开“随正常聊天读写本机记录”才会给该角色的普通聊天提供工具。不会自动替换主聊天界面，不是常驻后台服务。

## 声明

保留API版本1.0，设置 `minHostVersion: "0.2.41"` 并声明 `chat.tools`。页面、运行入口和业务资源仍全部在独立包内。

```json
{
  "launcher": false,
  "chatSurface": false,
  "chatActions": [{"id":"open","title":"查看角色道具"}],
  "roleCompanion": {
    "title":"角色道具",
    "entry":"tool-runtime.html",
    "tools":[{
      "id":"read_note",
      "description":"读取当前角色当前故事的道具记录。",
      "effect":"read",
      "parameters":{"type":"object","properties":{},"required":[],"additionalProperties":false}
    }]
  }
}
```

`roleCompanion`最多20个工具，ID为小写字母、数字和下划线，以字母开头。模型看到的标识为`插件ID/工具ID`，不能调用未绑定、未授权或其他角色的工具。宿主独立校验整批参数后执行，不依据模型给出的权限声明授权。

参数支持有界JSON-schema子集：type、properties、required、additionalProperties、items、enum、maxLength、maxItems、description；类型object/array/string/number/integer/boolean。结构最多6层，对象字段最多30个。每次参数最多32KiB、数组最多100项、字符串最多12000字符。对象须显式声明properties、required和additionalProperties，根参数为object。

## 短时执行

运行页加载SDK后，先注册事件，再报告ready：

```js
Skivu.on('companion.invoke', async ({tool, arguments: args}) => {
  const context = await Skivu.call('context.get');
  const result = await runOwnTool(tool, args, context);
  await Skivu.call('runtime.complete', {result});
});
await Skivu.call('runtime.ready', {});
```

宿主为单次工具创建与界面相同隔离策略的短时WebView，不打开页面路由。准备最多10秒，实际工具最多45秒，完成/取消/超时后销毁；App暂停或关闭会停止。每轮用户聊天最多4轮模型、4次工具，每批最多2次。不注册后台定时器，不在关闭App后继续生成，不增加自动模型请求。

运行上下文包含roleId、roleName、chatId、storageScope（story或role）、spaceId（角色与会话的不可逆摘要）、callId。story默认对应每段聊天独立空间；role由用户显式选择跨故事共用。插件负责按上下文隔离自己的业务存档，不应自行猜测其他角色或故事。解绑/停用/更新/切换角色故事后，后续操作会拒绝。已完成的本机操作保留，不因后续模型失败回滚。

`read`可使用已声明的只读存档/文件/插件自有密钥/GET或HEAD网络。`write`还可CAS写本机存档和管理本插件文件。`external`可请求`ui.openExternal`，仍逐次由宿主确认。短工具不提供模型生成、聊天追加、角色修改、文件选择或剪贴板；网络变更请求不在本版随聊执行面开放。effect不是现实平台业务已经完成的证明。

`storage.compareAndSet({key,expected,value})`在宿主插件队列中比较JSON并原子保存；冲突返回REVISION_CONFLICT。用于避免页面编辑和聊天工具互相覆盖。短工具不允许无条件storage.set/remove。模型、宿主账号与服务器私有凭据始终不进入运行上下文或插件API；模型编排继续走原有账号/内测/计费/模型发布保护。

宿主执行前保存意图，结果确认后标记完成。丢失回执的写入保持待核对，不自动重放；重新生成同一轮不能重复执行。插件应返回真实且有界的JSON回执，含`success`；回执作为不可信第三方数据进入后续模型，不能覆盖系统权限或用户要求。

插件存档提交后，打开的同插件页面收到`storage.changed`事件（只含revision，不广播存档值）。页面可重新读取并刷新；编辑中的表单应保留用户输入，并在保存时通过CAS/记录版本拒绝覆盖新内容。

## 记录卡片与返回聊天

成功回执可附`card:{title,summary,action,payload}`。action必须是本插件声明的聊天动作，payload只携带打开位置所需的小型JSON（卡片整体最多2KiB）。宿主持久保存卡片绑定的角色/会话，点击在对应上下文打开插件。插件从context.get的payload定位记录。不要在卡片或模型结果放媒体地址、凭据或运行配置。

页面可调用`ui.chatDraft({text})`（chat.write权限），将文字追加到原会话可编辑草稿，保留原草稿、不发送，并返回原聊天。空文字仅返回聊天。`ui.roleSettings({})`打开当前角色的随身插件设置，无自动授权。

旧的chatSurface能力继续供真正替换聊天界面的插件使用；角色随身物品通常声明false。官方目录新增apps-v3.json，旧apps.json和apps-v2.json保持旧客户端可解析内容。新宿主精确迁移旧官方目录URL，保留自定义目录和已有数据。
