# Phone local flows

The built-in phone engine exposes `ui.flow`, `ui.flow.read` and `ui.flow.resume` through the ordinary device catalog. A model plans a sequence once; fresh semantic lookup, action dispatch, condition waiting and evidence collection run locally. The executor has no model or network dependency. Existing single-action tools and screenshot fallback remain available.

This implementation works with accessible controls and local OCR text targets. It is not a Learning Tong-specific recognizer and does not validate the correctness of a question answer. The choice adapter can generate guarded flow parameters from an actual extracted RadioButton/CheckBox question and an explicitly matched answer.

## Local OCR and visual targeting

Android 11+ provides `recognitionMode: auto | visual | controls` on `ui.observe` and `ui.flow`. Omission follows the user's **手机操控 → 屏幕识别** preference (automatic or visual first). `controls` is also available to callers for comparisons. Older Android versions retain control observation in automatic mode; explicitly requesting visual recognition reports that screenshots are unavailable.

`auto` uses accessible controls when they contain the requested target; a missing query/semantic target or an empty text tree triggers local OCR. Once a window requires OCR, subsequent reads can go directly to OCR, with native state inspection retained when a step needs input/checkbox evidence. A native transition gets a short opportunity to finish before its missing result triggers OCR. `visual` goes directly to screenshot text recognition; reading minimal window/privacy metadata still enforces authorization and masks private fields.

The bundled Chinese ML Kit 16.0.1 recognizer runs offline from an in-memory bitmap, without image encoding, base64 or screenshot upload to the conversation model. See `licenses/MLKit-NOTICE.txt` for the SDK's separate terms and metrics disclosure. Both native controls and OCR rows include their `source`, physical screen bounds and display dimensions. OCR rows are text observations, not inferred buttons or editable/checked/selected controls.

OCR regions are `[left, top, right, bottom]` fractions from 0 to 1. `ui.observe.region` crops the recognition input; `selector.region` disambiguates a target on the physical screen. Cropping/resizing offsets are transformed back to screen pixels before dispatch. Password bounds and windows above the authorized app are masked before recognition. Raw pictures and pixel patches are not stored in checkpoints or returned as OCR tool data.

A visual action reacquires OCR and then a fresh screenshot, checks window/package, rotation, dimensions and scroll epoch, and compares the target and guard text patches before sending a gesture. Changed or ambiguous targets stop before dispatch. Cached OCR results are reused only for identical masked pixels and crop geometry; the screenshot and action checks are still fresh. Original OCR text is preserved. Matching applies NFKC, removes whitespace only between Chinese characters, and normalizes a katakana horizontal stroke between Chinese characters to `一`; it does not apply fuzzy edit-distance correction to arbitrary words.

For visual steps use `exists`, `absent` or `text` conditions tied to actual content, with guards for repeated layouts. `changed` remains a semantic accessible-control condition: OCR fluctuations and arbitrary pixel changes cannot prove success. Checkbox state needs native evidence. Raster icons, formula interpretation, pure image state classifiers and coordinate-only plans are outside this text-recognition stage. Visual input also needs an actual editable control. Stopping and durable resumption use the same existing flow checks and never replay uncertain gestures.

Example:

```json
{"package":"example.app","recognitionMode":"visual","steps":[
  {"id":"next","action":"tap","selector":{"textContains":"下一页","region":[0,0.5,1,1]},
   "guard":{"kind":"exists","selector":{"text":"第1页"}},
   "expect":{"kind":"exists","selector":{"text":"第2页"}},"timeoutMs":8000}
]}
```

OCR receipts include capture, recognition and total observation time, cache use and execution-stage model request count. These are device measurements, not promised real-app or model-answer latency. Synthetic acceptance renders Chinese raster text without accessible text/button nodes, navigates pages with real gestures, tests duplicate labels and moved targets, and runs with emulator network disabled. The physical phone and real study accounts are not used by these tests.

## Plan

`ui.flow` accepts `package` and a nonempty `steps` array. Every step needs a unique `id`, `action` and `expect` condition. Actions are `tap`, `input`, `scroll`, `swipe`, `back` and `wait`. All steps run serially in the specified authorized app. Launch a different app with the existing `apps.launch` tool before starting its flow.

Selectors match exact `text`, `description`, `viewId` and `className`, substring `textContains`/`descriptionContains`, and boolean `clickable`, `editable`, `scrollable`, `checked`, `selected`, `enabled`. `within` constrains ancestors. A write target must match exactly one visible non-password node. The native backend obtains a new observation and resolves the semantic selector atomically with dispatch on the Android main thread. Old observation IDs and coordinates are not accepted in a plan. Non-clickable semantic nodes can use a short gesture at their freshly resolved visible bounds; successful verification is still required.

Conditions:

* `exists` / `absent`: a selector appears/disappears.
* `checked` / `selected` / `text`: exactly one selected node has the corresponding `checked`, `selected` or `text` value.
* `changed`: the selected region and its descendants change meaningful content/state. Without a selector this compares the whole page. Dynamic nodes outside an explicitly selected region and newly assigned node IDs do not count. Choose a region that proves the intended transition; a clock changing does not prove navigation.
* `all` / `any`: a nonempty `conditions` list of conditions.

An optional `guard` must hold before dispatch and is checked again atomically with fresh lookup. Bind repeated layouts, including questions, to their actual content. An optional `when` skips the step when false. Neither may use `changed`, because it needs an action baseline.

`timeoutMs` is an optional per-step waiting deadline; omitted or zero adds no timeout and remains cancellable. `stableMs` defaults to 100 and requires the condition to remain true for that duration. Android accessibility events wake the waiter, with at most 100ms cancellation polling. The entire plan is validated before the first action. A condition already satisfied avoids redundant actions; an ambiguous target is never resolved by taking an arbitrary index.

```json
{
  "package": "example.exercise",
  "steps": [
    {
      "id": "choose_a",
      "action": "tap",
      "selector": {"text": "A. 2"},
      "guard": {"kind": "exists", "selector": {"text": "Select positive values"}},
      "expect": {"kind": "checked", "selector": {"text": "A. 2"}, "checked": true},
      "timeoutMs": 3000
    },
    {
      "id": "choose_b",
      "action": "tap",
      "selector": {"text": "B. 3"},
      "guard": {"kind": "exists", "selector": {"text": "Select positive values"}},
      "expect": {"kind": "checked", "selector": {"text": "B. 3"}, "checked": true},
      "timeoutMs": 3000
    }
  ]
}
```

## Authority, interruption and recovery

The native backend rechecks enabled/control permission, current package authorization, service connection, lock state, task lease and cancellation between steps and while waiting. The existing phone foreground arbiter remains the owner. No new shell authority, application grants or permission-setting controls are introduced.

A complete private checkpoint is durably written before every attempted action, including its before-condition evidence. Unknown/in-flight steps can only be verified on resume; they are never clicked again. Verified steps are skipped. A failure before an attempted action may be retried by an explicit resume after the cause is resolved. If an uncertain effect cannot be verified, the flow stays paused at that step. Cancellation with an uncertain effect retains the host effect fence.

`ui.flow.read({originalRequestId})` returns a compact checkpoint without raw plan arguments and can be inspected while execution owns the main worker. `ui.flow.resume({originalRequestId})` uses the same owner's stored original plan and original child identities; callers cannot substitute a new plan. A verified resumed flow reconciles the original host request. A process restart or task interruption does not automatically resume or repeat actions.

Pausing or stopping a conversation cancels its pending native flow. A model/authority change uses the existing cancellation and recovery path. The original prompt-only plugin payload is unrelated and remains unchanged.

## Timing and tests

Native receipts expose per-step dispatch/wait/elapsed time, completed/current/total steps, observation count and whether uncertain effects remain. Overall elapsed time includes explicit resumes. The assistant journal records model request count and elapsed time separately, accessible in `workflow.state`; it does not store credentials or extra prompt bodies in timing records.

Tests cover fresh IDs, external timer updates, 20-page/60-action sequences, unique targeting, already-satisfied states, scoped change conditions, branches, malformed plans, guards, cancellation, revocation, original-parent reconciliation and durable resumption. Native acceptance uses a synthetic Android test activity with a rapidly updating clock and actual input/CheckBox/navigation controls, without an external model or study account. These tests establish executor behavior, not real-model answer quality or Learning Tong end-to-end acceptance.
