# Shared companion chat features

All three presenters use the same conversations, character cards and media library.

- Conversation settings: enable confirmation to queue up to 20 separate user bubbles, then submit them as a single ordered model turn. The current unsent input is not included until added. Pending bubbles are stored per conversation and restored after restart; they can be removed before confirmation. A model connection is required only when confirming.
- Worlds: create shared worlds, classified background entries and classified scenes. Character cards reference a world and an optional scene. Changes affect future requests; only the selected scene is injected. Existing scenario prose is migrated to a separate world without dropping the content.
- Stickers: import local PNG/JPG/WebP/GIF images, organize groups and give each image a meaning/name. The model reads that name. Removing a sticker from the active library preserves already sent messages.
- Voice: type a description or use Android system speech recognition. Both are voice-category messages; microphone input is transcribed and editable. No synthesized speech or saved audio file is implied by these bubbles.
- Images: type a photo description or select/capture a real image. Descriptions are sent as explicit photo-category text; actual images are resized and sent through the selected vision-capable API. Images are never silently downgraded to a text-only request.

Real image wire formats support OpenAI Chat/Responses, Anthropic Messages and Gemini. Account relay accepts bounded inline PNG/JPG/WebP images on backend 168. A vision-capable upstream model is required; ordinary text models may reject images. The existing account request-size limit is preserved, so long image-heavy history may need a new conversation.

Media belongs to local chat backups and is sent only to the selected model service when submitting. App-owned presenter code does not access account credentials. Operit plugin catalog was checked; no usable audited implementation was selected or copied for this change.
