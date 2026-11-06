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
