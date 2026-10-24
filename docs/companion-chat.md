# Shared companion chat features

All three presenters use the same conversations, character cards and media library.

- Conversation settings: enable confirmation to queue up to 20 separate user bubbles, then submit them as a single ordered model turn. The current unsent input is not included until added. Pending bubbles are stored per conversation and restored after restart; they can be removed before confirmation. A model connection is required only when confirming.
- Worlds: create shared worlds, classified background entries and classified scenes. Character cards reference a world and an optional scene. Changes affect future requests; only the selected scene is injected. Existing scenario prose is migrated to a separate world without dropping the content.
- Stickers: import local PNG/JPG/WebP/GIF images, organize groups and give each image a meaning/name. The model reads that name. Removing a sticker from the active library preserves already sent messages.
- Voice: type a description or use Android system speech recognition. Both are voice-category messages; microphone input is transcribed and editable. No synthesized speech or saved audio file is implied by these bubbles.
- Images: type a photo description or select/capture a real image. Descriptions are sent as explicit photo-category text; actual images are resized and sent through the selected vision-capable API. Images are never silently downgraded to a text-only request.

Real image wire formats support OpenAI Chat/Responses, Anthropic Messages and Gemini. Account relay accepts bounded inline PNG/JPG/WebP images on backend 168. A vision-capable upstream model is required; ordinary text models may reject images. The existing account request-size limit is preserved, so long image-heavy history may need a new conversation.

Media belongs to local chat backups and is sent only to the selected model service when submitting. App-owned presenter code does not access account credentials. Operit plugin catalog was checked; no usable audited implementation was selected or copied for this change.

## Direct media entry points

Album actions in Skivu, WeChat and QQ open the shared bottom list: system album, system camera and typed voice description. Camera shortcuts call the phone camera directly through the existing Android image-picker integration. Selecting/confirming a photo sends it directly, or queues it when conversation confirmation is enabled; there is no additional photo-mode/editor screen. Cancelling either system surface sends nothing, and a conversation change while picking prevents cross-chat delivery.

Typed photo descriptions remain separate entries. Typed voice descriptions open one text form, without a real/description mode switch. Microphone speech-recognition entries remain available. The app does not introduce a custom camera UI or request broad photo-library access.

`flutter test test/chat_media_menu_test.dart` checks the shared sheet, cancellation, system source selection, queued photos, stale-conversation isolation and voice-category text. `node --test test/social_media_bridge_test.mjs` checks that both presenters consume gallery/camera clicks and route them to the host instead of their standalone camera simulation.

## 视频通话状态（0.2.28）

视频通话暂未开放。微信、QQ 的聊天工具与通话列表中保留灰显入口，并标注“开发中”；旧视频动作也会被拦截，不再打开本机视频预览。原版语音通话页的视频控制保持停用，并显示“开发中”。相册、系统拍照、图片描述、角色语音通话及已有视频附件不受此开关影响。

## 未读消息（0.2.29）

只有完成的角色回复会产生未读；流式片段、失败/中断回复与用户发送内容不计数。头像右上方、首页标题和底部消息标签共用宿主聊天数据；99以上显示99+。免打扰会话保留头像红点，不加入顶栏/底栏总数；QQ频道单独计入频道标签。进入对应聊天页清除该段对话未读，首页、联系人与后台不算已读。读取状态由页面可见性、当前对话稳定ID及App前后台共同决定，原版与语音页也会同步已读。未读标记随聊天记录保存，旧记录默认已读；删除/清空消息后角标随记录更新。
