# App reliability in 0.2.32

This release changes the Android client and its optional Web preview. It does not
change model publication rules, server billing, or the plugin execution boundary.

- Local account restoration is separate from remote profile/model synchronization.
  Startup reads local data first. Account-backed generation still requires current
  permissions and model metadata; stale network replies cannot overwrite logout
  or a newer login.
- `model_not_available` retains its code and explicitly asks the user to refresh
  the model list and choose an available model. It never automatically retries
  with another model or asks the user to buy access to a retired model.
- Requests use a shared context budget. It preserves the current user turn,
  retains complete older turns while possible, and removes older images or turns
  from the request when necessary. Saved local messages remain intact. Notices
  are separate from failures. Account requests also obey exact serialized byte
  and message-count limits. Text and image token estimates are conservative
  heuristics, not an exact provider tokenizer.
- Public custom model endpoints require HTTPS. Explicit private IP and loopback
  HTTP endpoints remain available for trusted local services; HTTP is plaintext.
- On IO platforms, chat archives migrate from preferences to validated atomic
  files in the app support `chats` directory. A previous verified generation can
  recover from interruption or damage. The old preference remains a migration
  source until an explicit clear. Autosaves merge pending changes instead of
  queuing an unbounded sequence of whole archives; JSON encoding uses an isolate.
  This is still a JSON snapshot format, not SQLite or incremental message storage.
  The Web preview continues to use browser preferences.
- File backup export uses Android's system document picker; import validates the
  archive before replacement. Explicit recovery retains damaged originals.
  Clearing chats clears managed recovery copies and the legacy chat preference;
  separately exported files and clipboard contents remain under user control.
  Backups contain role/world/chat/media data, never API keys or account tokens.
- The original chat list creates visible messages on demand. History navigation,
  locating distant messages, and bottom following remain available.
- Group rules distinguish mention priority from strict rotation. Each member's
  request is still sequential, with cancellation preventing later members.
  The original UI may stream; social modes retain their complete-bubble behavior.
- Voice binds to assistant replies in the current turn and keeps group authors.
  A mention-only group without a matching member produces no assistant speech.

No database migration, new executable plugin API, offline language model,
certificate replacement, or font/ABI download system is introduced in this batch.
Existing package signing is retained for upgrade compatibility.
