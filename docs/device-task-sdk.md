# Device tasks: development extension

This extension is developed for a candidate host **0.2.42 / build46**, after the independently coordinated build45 role-companion work. It is not present in released build44. Existing SDK1.0 package compatibility remains; new packages must declare a compatible `minHostVersion` and test `host.info.methods`. Keep incompatible entries out of old catalogs.

## Components

The independent device-control Web plugin supplies its UI. A separate Android 11+ accessibility companion provides device facts and input through a manually paired local Messenger protocol. The host owns the time-bounded task runner, task consent, model credentials and existing account/beta/custom connection path. Third-party business code is not embedded into the APK.

Sources: [device-control](https://github.com/skyjjgw/skivu-device-control), [device-bridge](https://github.com/skyjjgw/skivu-device-bridge). These names are examples, not hardcoded renderer or plugin-ID allowlists in the host.

## Permissions and methods

| Method | Permission | Input / result |
|---|---|---|
| `device.discover` | device.observe | `{}` → available version1 companion service components/labels |
| `device.connect` | device.control | `{component,signerSha256?}` → own opaque connection ID, signer and pairing state; same-owner bindings reused |
| `device.status` | device.observe | `{connectionId}` → protocol/service identity and pairing state |
| `device.apps` | device.observe | `{connectionId}` → launchable apps; controller/approval UI excluded |
| `device.openCompanion` | device.control | `{connectionId}` → open the selected companion's own UI |
| `device.disconnect` | device.control | `{connectionId}` → cancel matching active task and close the binding |
| `agent.tasks.start` | agent.tasks | `{connectionId,goal,allowedPackages,maxActions?,maxRounds?,timeoutSeconds?}` → asynchronous task card |
| `agent.tasks.get` | agent.tasks | `{taskId}` → state, summary, action/model-round counts |
| `agent.tasks.cancel` | agent.tasks | `{taskId}` → request cancellation; injected actions may complete |

Starting a task additionally requires `device.observe` and `device.control`. The optional manifest permission `device.direct` is an explicit ongoing-control grant disclosed during plugin enable. It skips repeated host connect/start dialogs; the actual Android caller must separately receive local direct-control trust in companion0.2. Legacy grants keep confirmation mode until explicitly changed. Connections and task IDs belong to the requesting plugin. The host checks current authorization/package digest before continuing. One task can own input at a time. The foreground plugin displays model/source, objective, software scope and budgets before Start. Notifications must be granted before starting.

Defaults: 20 device actions, 15 model requests and 300 seconds. Host maxima: 30 actions, 30 model requests and 600 seconds. Each model result is at most1024 output tokens; compact observations are bounded to18KiB before adding the at-most4000-character goal and recent sanitized execution receipts. Limits do not promise a fixed currency cost.

The model only returns a restricted action JSON. The host fills observation IDs, request IDs and device capability data. Completion needs evidence IDs from the current observation. Invalid plans, unauthorized app changes, expired observations and unknown execution receipts stop rather than silently replay. Subsequent `get` queries never start a new model call.

## Task lifetime

The Android foreground task service retains the Flutter engine while the app operates another selected app. The Web page can stop receiving events without owning the task's lifetime. The notification stop path cancels the model and revokes the companion task. Account/model changes, plugin disable/uninstall/digest changes, budget expiry and authorization revocation invalidate ongoing work.

`completed` means the planner ended using current UI evidence; it does not certify an external platform's transaction beyond observable evidence. A click receipt alone does not prove delivery or purchase. Unknown outcomes use `review_required`. Host-private receipts retain up to40 results across process death, without raw goals, screens, credentials or device capabilities. Interrupted receipts become `review_required/PROCESS_RESTART`; tasks never auto-resume. Leaving the allowed app waits briefly without reading the foreign screen, while Stop and deadlines remain effective. This extension offers start/get/cancel; pause/resume and screenshot-model planning are separate, unimplemented capabilities.

Passwords must be entered locally. With explicit direct-control trust, in-scope sensitive-label, coordinate and unlabeled taps do not prompt again. Legacy confirmation mode still uses companion-local one-shot approval. The companion authorization UI and controller app are never task targets. The companion does not accept arbitrary shell, reflection, or account credentials. Do not pass host credentials to a plugin or use a local-network POST to bypass the device-task authorization surface.

## Role chat integration

The independent plugin's `prepare_task` role tool uses `storage.compareAndSet` to prepare a local draft and returns a card. It does not call device methods or start a task. Clicking the card opens the corresponding role/chat page; the user then chooses the actual app and clicks Start. Existing4-round/4-call/45-second short-runtime limits and effect restrictions remain. Short runtimes cannot call device or task methods. Bindings and prepared cards are role/chat scoped; stale/superseded drafts are refused.

## Verification scope

A separately installable preview can be built from the normal, non-mock entrypoint with `flutter build apk --release --dart-define=SKIVU_DEVICE_PREVIEW=true`. Its ID is `com.skyjjgw.independent.ski.devicepreview`; it does not replace the ordinary App. Configure a model connection in this preview and import the independent plugin package. It is for manual testing, not the normal update channel. Signing follows the repository build configuration and must be reported separately from the official production certificate. Device methods reject Android versions below11 explicitly; the rest of the host remains usable on its ordinary minimum version.

The isolated `lib/device_qa.dart` entrypoint is built with `--dart-define=SKIVU_DEVICE_QA=true`; its app ID is separate. It supports test-only in-process planner injection, never exposed to Web plugins. Mock tests are not real-model quality evidence. Native fixture input/clicks and task scope use actual Android IPC/accessibility. The production `main.dart` path uses the ordinary protected model gateway and no mock planner.

Normal-entrypoint Android acceptance uses `flutter drive --keep-app-running --driver=test_driver/acceptance.dart --target=integration_test/app_acceptance_test.dart --dart-define=SKIVU_DEVICE_PREVIEW=true`. Keep the package installed and force-stop it before running `integration_test/restart_acceptance_test.dart` with the same driver. Flutter's default test cleanup uninstalls its application and cannot establish persistence across processes. Both tests use synthetic local data and a closed loopback port, with no real account or model.
