# Device engine SDK (host 0.2.81 development)

This is an additional host capability. Existing companion tasks, role tools and
DSH model settings keep their original behavior. Engine setup lives in the main
Cloud assistant and Settings → phone control. Android grants are checked by the
native host on every call; opening a settings page is not a grant.

## Discover and invoke

Declare the actual permissions needed (`device.observe`, `device.control`,
`device.system`, `device.shell`). Enabling the plugin authorizes its exact package
digest. This never activates Android permissions or the shell backend by itself.

```js
const catalog = await Skivu.call('device.engine.catalog');
const result = await Skivu.call('device.engine.invoke', {
  tool: 'clock.alarm.create',
  arguments: {hour: 8, minute: 15, label: 'Morning'},
  requestId: 'alarm_20261107_1'
});
```

`requestId` is optional, but preserve it when querying an uncertain mutation.
Reusing it with different arguments fails. Receipts distinguish `verified`,
`dispatched`, `permission_required`, `failed`, `unknown`, and `cancelled`.
`dispatched` never means the business operation succeeded. Shell receipts verify
the process exit and include the actual UID, exit code, stdout/stderr and
truncation flag; verify the intended business result separately.

`ui.observe` returns observation and element IDs. UI input requires fresh IDs,
an allowed package, the native accessibility grant and a non-password target.
Skivu's own UI and system permission management cannot be controlled by this
accessibility path. Shell execution is separately authorized and carries Android
shell privileges; the UI package selection does not sandbox arbitrary shell code.

Closing a plugin/DSH session cancels its outstanding native calls. Revoking or
replacing an authorized plugin rejects future calls and cancels active calls.
Previously dispatched mutations can already have taken effect. A missing callback
or app restart is not permission to replay a write.

## Register independent assistant tools

Add `assistant.tools` to permissions and an `assistantTools` contribution. This
registration does not bind a role, read role history, or select a persona.

```json
"contributes": {
  "launcher": true,
  "chatActions": [],
  "assistantTools": {
    "title": "My assistant tools",
    "entry": "assistant.html",
    "tools": [{
      "id": "read_brightness",
      "description": "Read the phone's actual brightness",
      "effect": "read",
      "parameters": {
        "type": "object", "properties": {},
        "required": [], "additionalProperties": false
      }
    }]
  }
}
```

Use the existing isolated tool event transport in that entry:

```js
Skivu.on('companion.invoke', async ({tool, arguments: args}) => {
  const value = await Skivu.call('device.engine.invoke', {
    tool: 'settings.brightness.read', arguments: {}
  });
  await Skivu.call('runtime.complete', {result: value});
});
Skivu.call('runtime.ready');
```

The event name is retained for SDK compatibility. Its host context contains only
the independent assistant scope and call ID. Device writes require `external`
effect and the selected device permission; local plugin writes require `write`.
Declare `minHostVersion` at least `0.2.81` and include the entry file in the package.
Tools become discoverable to Cloud only while that exact package is enabled.
The assistant catalog uses `plugin:<plugin-id>/<tool-id>` names.

DSH uses the same `device.engine.*` methods over its existing host-owned SDK
gateway; it cannot supply its own caller identity or obtain host credentials.

## Current acceptance scope

See `EMBEDDED-DEVICE-ENGINE.md` for completion gates. Passing a parser test or an
APK build does not establish wireless activation, generic UI operation, plugin
runtime execution or DSH end-to-end success on the emulator.
