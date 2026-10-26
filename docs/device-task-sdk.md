# Device tasks: development extension

This extension is developed for a candidate host **0.2.42 / build46**, after the independently coordinated build45 role-companion work. It is not present in released build44. Existing SDK1.0 package compatibility remains; new packages must declare a compatible `minHostVersion` and test `host.info.methods`. Keep incompatible entries out of old catalogs.

## Components

The independent device-control Web plugin supplies its UI. A separate Android 11+ accessibility companion provides device facts and input through a manually paired local Messenger protocol. The host owns the time-bounded task runner, task consent, model credentials and existing account/beta/custom connection path. Third-party business code is not embedded into the APK.

Sources: [device-control](https://github.com/skyjjgw/skivu-device-control), [device-bridge](https://github.com/skyjjgw/skivu-device-bridge). These names are examples, not hardcoded renderer or plugin-ID allowlists in the host.

## Permissions and methods

| Method | Permission | Input / result |
|---|---|---|
| `device.discover` | device.observe | `{}` → available version1 companion service components/labels |
| `device.connect` | device.control | `{component}` → own opaque connection ID and pairing state; host consent plus companion-local approval |
| `device.status` | device.observe | `{connectionId}` → protocol/service identity and pairing state |
| `device.apps` | device.observe | `{connectionId}` → launchable apps; controller/approval UI excluded |
| `device.openCompanion` | device.control | `{connectionId}` → open the selected companion's own UI |
| `agent.tasks.start` | agent.tasks | `{connectionId,goal,allowedPackages,maxActions?,maxRounds?,timeoutSeconds?}` → asynchronous task card |
| `agent.tasks.get` | agent.tasks | `{taskId}` → state, summary, action/model-round counts |
| `agent.tasks.cancel` | agent.tasks | `{taskId}` → request cancellation; injected actions may complete |

Starting a task additionally requires `device.observe` and `device.control`. Connections and task IDs belong to the requesting plugin. The host checks current authorization/package digest before continuing. One task can own input at a time. Task consent names the model, objective, software scope and budgets. Notifications must be granted before starting.

Defaults: 20 device actions, 15 model requests and 300 seconds. Host maxima: 30 actions, 15 model requests and 600 seconds. Each model result is at most1024 output tokens; compact observations are bounded to18KiB before adding the at-most4000-character goal and recent sanitized execution receipts. Limits do not promise a fixed currency cost.

The model only returns a restricted action JSON. The host fills observation IDs, request IDs and device capability data. Completion needs evidence IDs from the current observation. Invalid plans, unauthorized app changes, expired observations and unknown execution receipts stop rather than silently replay. Subsequent `get` queries never start a new model call.

## Task lifetime

The Android foreground task service retains the Flutter engine while the app operates another selected app. The Web page can stop receiving events without owning the task's lifetime. The notification stop path cancels the model and revokes the companion task. Account/model changes, plugin disable/uninstall/digest changes, budget expiry and authorization revocation invalidate ongoing work.

`completed` means the planner ended using current UI evidence; it does not certify an external platform's transaction beyond observable evidence. A click receipt alone does not prove delivery or purchase. Unknown outcomes use `review_required`. Tasks never auto-resume across process death. This initial extension offers start/get/cancel; pause/resume and screenshot-model planning are separate, unimplemented capabilities.

Passwords must be entered locally. Sensitive-label, coordinate and unlabeled taps require companion-local one-shot approval. This heuristic cannot classify every risky UI action, so the task must still have explicit scope and user intent. The companion does not accept arbitrary shell, reflection, or account credentials. Do not pass host credentials to a plugin or use a local-network POST to bypass the device-task authorization surface.

## Role chat integration

Role tools should return an asynchronous task ID rather than run the full device task inside the foreground short-tool instance. Preserve `chat.tools` role bindings, story scope, the existing4-round/4-call/45-second limits and effect restrictions. The explicit task start consent is separate from granting normal role tools. Integration is coordinated against the stable build45 contract, not its in-progress working files.

## Verification scope

The isolated `lib/device_qa.dart` entrypoint is built with `--dart-define=SKIVU_DEVICE_QA=true`; its app ID is separate. It supports test-only in-process planner injection, never exposed to Web plugins. Mock tests are not real-model quality evidence. Native fixture input/clicks and task scope use actual Android IPC/accessibility. The production `main.dart` path uses the ordinary protected model gateway and no mock planner.
