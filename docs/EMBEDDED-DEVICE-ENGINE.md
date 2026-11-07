# Embedded device engine: implementation and acceptance contract

Baseline: `2093d3718663db8147bc7e56a180c8d4ea755818`, installed preview 0.2.80+84.
Development branch: `feature/embedded-device-engine-20261107`.
This work is local/emulator-only. Do not modify the USB phone, publish, or replace the baseline checkpoint.

## Required outcome

1. A single Skivu APK contains the native permission/status UI, device observation/input service, and an elevated execution backend. No separately installed Shizuku or device companion is required for the new path. ADB/root execution remains a separate process with real Android identity; it cannot be replaced by an ordinary app process labelled "shell".
2. The user activates the supported backend through Android's actual authorization flow. Show actual permission/backend state, restart requirements, revocation, and errors. Opening a settings page is not proof of authorization.
3. A discoverable, versioned interface catalog describes built-in Android capabilities. Include explicit Clock alarm/timer/show actions, app discovery/launch, supported settings, observation and input, plus an authorized code/shell path. Shizuku supplies transport/identity, not Clock business APIs.
4. The main Cloud assistant accepts natural-language objectives, discovers tools, runs a persistent observe/plan/act/verify loop, and reports real receipts in the conversation. It does not require opening a plugin and manually starting the task. Reuse configured models without role/persona prompts or shared chat history.
5. Plugins can discover and invoke authorized tools and register additional model-callable tools. Preserve existing SDK compatibility, per-plugin ownership/digest checks and revocation. A plugin cannot request an arbitrary owner identity or silently add privileges.
6. DSH uses the same engine through its host-owned SDK transport. A code/script task and a main assistant task share the same execution authorization and cancellation rules.
7. Preserve in-progress state and sanitized receipts, support Stop and permission-wait/resume, avoid replay of uncertain writes, and cancel on model/account or authorization changes. A dispatched Intent/click/shell command is not automatically verified business success.
8. The original roles, models, chats/drafts/quotes, personal modules, plugin/DSH paths, wallpaper, fullscreen underlap, drawer geometry/shadows, glass and navigation remain functional. Avoid modifying optical/layout code unless a demonstrated integration issue requires it.

## Evidence gates (completion must cover all)

- Baseline full Flutter suite and baseline emulator screenshots before integration.
- Capability/schema/ownership/revocation, malformed-call and uncertain-write tests; native functional tests on the emulator.
- A real ADB/shell-identity engine run without installing Shizuku; in-app activation tested separately from development ADB bootstrapping. Root compatibility and unsupported devices must be reported with their actual test scope.
- Built-in Clock operation visible in the emulator's Clock app, a settings/app operation, and a generic UI task that has no dedicated business wrapper.
- A model-driven assistant conversation, plugin tool invocation/extension, and DSH SDK invocation that each reach the real engine and expose results. Fake/model-fixture tests are not real-model acceptance.
- Stop/revoke, process restart, permission loss, unknown-result handling and continued ordinary chat after failure.
- Full regression suite plus emulator inspection of chat/composer/dock, Today/Tasks/Memory/Cloud, both drawers, settings, roles/models/plugins, DSH and scrolling.
- Delivery records distinguish passed, missing and unverified gates. No "all complete" claim from a build or a small unit-test subset.

## Initial state

The baseline has a companion-backed generic task runner, a role tool that prepares task cards, and a DSH gateway restricted to that companion task API. It does not contain the embedded elevated engine, a main-assistant execution loop, or a built-in Android interface catalog. These must be implemented, not represented by mock status or UI-only controls.

## Owned shell lifecycle

Each dispatched script runs in its own UUID-owned POSIX session. Explicit Stop and
timeout use a separate authenticated connection and verify the supervisor PID,
process-group ID and start time before signalling that group. Other sessions are
outside this cancellation scope.

Socket closure alone did not stop a running shell in the first forced-host-exit
acceptance test. The host therefore sends a per-job heartbeat over the same
authenticated ADB stream every two seconds. A supervisor-side reader terminates
its own group on EOF, an invalid heartbeat, or eight seconds without a heartbeat.
The user script receives its heredoc on stdin with the heartbeat descriptor closed.
An expired lease is reported as an unknown result, never successful completion.
Completed effects are not rolled back. This is process-group ownership, not a
sandbox against deliberately detached privileged code.

Emulator API36 acceptance covered preserved multiline output/exit7, a silent
12-second job, timeout cleanup, and independent sessions (four native tests).
A real native host API request was interrupted by force-stopping the App: the
owned supervisor/script/child disappeared, its counter stayed one, and restarting
the same request returned persisted unknown without replay. Suspending the host
while retaining its socket also expired the lease and returned unknown after
resuming. Main Dart assistant restart recovery and plugin/DSH UI acceptance are
separate gates and are not proven by these native tests.

## Tool envelope and Stop admission

The DSH wrapper accepts `{tool: "shell.execute", arguments: {command: "id -u"}}`.
`tool` is the native catalog ID, not the wrapper name `skivu_engine_invoke`.
Malformed envelopes and wrapper IDs are rejected before dispatch with a concrete
example. The host also returns `INVALID_ARGUMENT` for unknown IDs or arguments
that fail the catalog schema, without exposing an exception or changing the call.

The plugin bridge preserves eight normal in-flight calls and a separately
bounded lane for eight `device.engine.cancel` requests. A full normal queue must
not block Stop. Admission to that lane does not grant authority: the existing
runtime scope still matches the exact owned request ID before native cancellation.

## DSH route shutdown

Model configuration changes and plugin revocation close the DSH model/device
brokers and cancel the exact active native request. A missing or uncertain Stop
receipt is displayed in the DSH page rather than escaping as an unhandled
asynchronous error. It does not mean that earlier device effects were reversed.

The shared runtime channel belongs to the latest route. An older route may await
native shutdown while a new route opens; its delayed disposal cannot remove the
new route's handler. Widget regressions cover both this handoff and uncertain
revocation. These use test platform channels and do not replace real-model,
emulator-UI acceptance.
