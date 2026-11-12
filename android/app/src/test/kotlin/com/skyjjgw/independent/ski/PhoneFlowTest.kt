package com.skyjjgw.independent.ski

import org.junit.Assert.*
import org.junit.Test

class PhoneFlowTest {
    private val pkg = "example.exercise"
    private fun selector(text: String) = mapOf("text" to text)
    private fun condition(kind: String, text: String, value: Any? = null): Map<String, Any?> =
        mapOf("kind" to kind, "selector" to selector(text)) + if (value == null) emptyMap() else mapOf(kind to value)
    private fun step(id: String, target: String, expected: Map<String, Any?>, guard: Map<String, Any?>? = null) =
        mapOf<String, Any?>("id" to id, "action" to "tap", "selector" to selector(target), "expect" to expected, "stableMs" to 0, "timeoutMs" to 300) +
            if (guard == null) emptyMap() else mapOf("guard" to guard)
    private fun plan(vararg steps: Map<String, Any?>) = mapOf("package" to pkg, "steps" to steps.toList())

    private inner class Device : PhoneFlow.Backend {
        var time = 0L
        var tick = 0
        var question = 1
        var selected = mutableSetOf<String>()
        var taps = 0
        var acceptedWithoutEffect = false
        var cancelAt = Long.MAX_VALUE
        var permission = true
        var duplicate = false
        var timerOnly = false
        var checkableOptions = true
        var saved: Map<String, Any?>? = null
        var beforePerform: (() -> Unit)? = null
        var afterPerform: (() -> Unit)? = null
        var beforeSnapshot: ((Int) -> Unit)? = null
        var beforeReuse: (() -> Unit)? = null
        var preparedEnabled = false
        var reuseEnabled = false
        var snapshotCalls = 0
        var reuseCalls = 0
        var captureTimes: Iterator<Pair<Long, Long>>? = null
        val capturedIds = mutableListOf<String>()
        val preparedIds = mutableListOf<String>()
        override fun check() {
            if (time >= cancelAt) throw PhoneFlow.Blocked("cancelled", "user stopped")
            if (!permission) throw PhoneFlow.Blocked("permission_required", "revoked")
        }
        override fun now() = time
        override fun awaitChange(milliseconds: Long) { time += milliseconds; tick++ }
        override fun snapshot(pkg: String): PhoneFlow.Snapshot {
            check(); tick++
            snapshotCalls++
            beforeSnapshot?.invoke(snapshotCalls)
            val root = "root_$tick"
            fun row(id: String, text: String, checked: Boolean = false, parent: String? = root) =
                mapOf<String, Any?>("id" to "${id}_$tick", "parentId" to parent, "text" to text, "viewId" to id, "class" to "Button", "checkable" to (checkableOptions && id in setOf("a","b")), "checked" to checked, "selected" to checked, "password" to false)
            val rows = listOf(
                mapOf<String, Any?>("id" to root, "text" to "", "viewId" to "content", "class" to "Group"),
                row("question", "Question $question"), row("a", "Option A", "A" in selected), row("b", "Option B", "B" in selected),
                row("next", "Next"), row("clock", "Timer $tick", parent = null),
            ) + if (duplicate) listOf(row("duplicate", "Option A")) else emptyList()
            val id = "observation_$tick"
            capturedIds.add(id)
            val capture = captureTimes?.next()
            if (capture != null) time = capture.second
            return PhoneFlow.Snapshot(pkg, 1, rows, mapOf("observationId" to id, "package" to pkg, "elements" to rows) +
                if (capture == null) emptyMap() else mapOf("capturedAtMs" to capture.first))
        }
        override fun perform(step: Map<String, Any?>, pkg: String, requestId: String): PhoneFlow.Dispatch =
            performUsing(step) { snapshot(pkg) }
        override fun performPrepared(step: Map<String, Any?>, pkg: String, requestId: String, prepared: PhoneFlow.Snapshot): PhoneFlow.Dispatch {
            if (!preparedEnabled) return super<PhoneFlow.Backend>.performPrepared(step, pkg, requestId, prepared)
            preparedIds.add(prepared.observation["observationId"] as String)
            return performUsing(step) { prepared }
        }
        override fun reuse(snapshot: PhoneFlow.Snapshot, pkg: String): PhoneFlow.Snapshot? {
            reuseCalls++
            beforeReuse?.invoke()
            check()
            return if (reuseEnabled) snapshot else null
        }
        override fun metrics() = mapOf("captures" to snapshotCalls.toLong(), "waitMs" to time)
        private fun performUsing(step: Map<String, Any?>, read: () -> PhoneFlow.Snapshot): PhoneFlow.Dispatch {
            assertEquals("in_flight", (saved!!["steps"] as List<*>).map { PhoneFlow.map(it, "step") }.first { it["id"] == step["id"] }["state"])
            val target = try {
                beforePerform?.invoke()
                val snapshot = read()
                step["guard"]?.let { require(PhoneFlow.satisfied(snapshot, PhoneFlow.map(it, "guard"))) }
                PhoneFlow.unique(snapshot, PhoneFlow.map(step["selector"], "selector"))
            } catch(error:Exception) { throw PhoneFlow.NotDispatched(error) }
            taps++
            if (!acceptedWithoutEffect && step["action"]=="set_checked") {
                val option=if(target["text"]=="Option A")"A" else "B"
                if(step["checked"]==true)selected.add(option)else selected.remove(option)
            } else if (!acceptedWithoutEffect) when (target["text"]) {
                "Option A" -> selected.add("A")
                "Option B" -> selected.add("B")
                "Next" -> if (!timerOnly) { question++; selected.clear() }
            }
            afterPerform?.invoke()
            return PhoneFlow.Dispatch(true, true)
        }
        fun run(plan: Map<String, Any?>, checkpoint: Map<String, Any?>? = null) =
            PhoneFlow.run(plan, "request", this, checkpoint) { saved = it }
    }

    @Test fun stabilityUsesCaptureTimesRatherThanOcrCompletionTimes() {
        val device = Device().apply {
            preparedEnabled = true
            captureTimes = listOf(0L to 10L, 100L to 400L, 434L to 450L).iterator()
        }
        val result = device.run(plan(step("next", "Next", condition("exists", "Question 2")) +
            mapOf("stableMs" to 100, "timeoutMs" to 1000)))
        assertEquals(result.toString(), "verified", result.outcome)
        assertEquals(3, device.snapshotCalls)
        assertEquals(1, device.taps)
    }

    @Test fun repeatedImageTimestampCannotProveStableEvenWhenRecognitionIsSlow() {
        val device = Device().apply {
            preparedEnabled = true
            captureTimes = listOf(0L to 10L, 100L to 400L, 100L to 600L, 434L to 650L).iterator()
        }
        val result = device.run(plan(step("next", "Next", condition("exists", "Question 2")) +
            mapOf("stableMs" to 100, "timeoutMs" to 1000)))
        assertEquals("verified", result.outcome)
        assertEquals(4, device.snapshotCalls)
        assertEquals(1, device.taps)
    }

    @Test fun twentyQuestionsRunWithoutModelOrStableNodeIds() {
        val device = Device()
        val steps = (1..20).flatMap { question ->
            val guard = condition("exists", "Question $question")
            listOf(
                step("q${question}a", "Option A", condition("checked", "Option A", true), guard),
                step("q${question}b", "Option B", condition("selected", "Option B", true), guard),
                step("q${question}next", "Next", condition("exists", "Question ${question + 1}"), guard),
            )
        }
        val result = device.run(plan(*steps.toTypedArray()))
        assertEquals("verified", result.outcome)
        assertEquals(60, device.taps)
        assertEquals(21, device.question)
        assertEquals(60, result.value["completedSteps"])
        assertEquals(0, result.value["modelRequestsDuringExecution"])
        assertEquals(false, result.value["hasUnverifiedActions"])
    }

    @Test fun preparedObservationAvoidsAnExtraReadInsideEachAction() {
        val actions = plan(step("a", "Option A", condition("checked", "Option A", true)),
            step("b", "Option B", condition("checked", "Option B", true)))
        val legacy = Device()
        assertEquals("verified", legacy.run(actions).outcome)
        assertEquals(6, legacy.snapshotCalls)
        val prepared = Device(); prepared.preparedEnabled = true
        assertEquals("verified", prepared.run(actions).outcome)
        assertEquals(4, prepared.snapshotCalls)
        assertEquals(listOf(prepared.capturedIds[0], prepared.capturedIds[2]), prepared.preparedIds)
        assertEquals(legacy.taps, prepared.taps)
    }

    @Test fun nextStepUsesTheLastVerifiedObservationWhenBackendAllowsIt() {
        val device = Device(); device.preparedEnabled = true; device.reuseEnabled = true
        val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true)),
            step("b", "Option B", condition("checked", "Option B", true))))
        assertEquals("verified", result.outcome)
        assertEquals(3, device.snapshotCalls)
        assertEquals(1, device.reuseCalls)
        assertEquals(listOf(device.capturedIds[0], device.capturedIds[1]), device.preparedIds)
        assertEquals(2, device.taps)
    }

    @Test fun invalidatedObservationIsReadAgainBeforeCheckingTheNextGuard() {
        val device = Device(); device.preparedEnabled = true; device.reuseEnabled = true
        device.beforeReuse = { device.reuseEnabled = false; device.question = 2 }
        val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true)),
            step("b", "Option B", condition("checked", "Option B", true), condition("exists", "Question 1"))))
        assertEquals("failed", result.outcome)
        assertEquals(3, device.snapshotCalls)
        assertEquals(1, device.reuseCalls)
        assertEquals(1, device.taps)
    }

    @Test fun waitStepStartsWithANewObservation() {
        val device = Device(); device.preparedEnabled = true; device.reuseEnabled = true
        val wait = mapOf("id" to "wait", "action" to "wait", "expect" to condition("checked", "Option A", true),
            "stableMs" to 0, "timeoutMs" to 300)
        assertEquals("verified", device.run(plan(step("a", "Option A", condition("checked", "Option A", true)), wait)).outcome)
        assertEquals(4, device.snapshotCalls)
        assertEquals(0, device.reuseCalls)
        assertEquals(1, device.taps)
    }

    @Test fun stableChecksUseNewObservationsAndResetAfterATransientMismatch() {
        val device = Device(); device.preparedEnabled = true; device.reuseEnabled = true
        device.beforeSnapshot = { capture ->
            if (capture == 3) device.selected.clear() else device.selected.add("A")
        }
        val action = step("a", "Option A", condition("checked", "Option A", true)) +
            mapOf("stableMs" to 200, "timeoutMs" to 1000)
        assertEquals("verified", device.run(plan(action)).outcome)
        assertEquals(400L, device.time)
        assertEquals(6, device.snapshotCalls)
        assertEquals(6, device.capturedIds.toSet().size)
        assertEquals(0, device.reuseCalls)
    }

    @Test fun resumedUnknownActionGetsFreshEvidenceWithoutDispatchingAgain() {
        val device = Device(); device.preparedEnabled = true; device.reuseEnabled = true
        device.acceptedWithoutEffect = true
        val actions = plan(step("a", "Option A", condition("checked", "Option A", true)))
        assertEquals("unknown", device.run(actions).outcome)
        val checkpoint = device.saved!!
        val capturesBeforeResume = device.snapshotCalls
        device.selected.add("A")
        val result = device.run(actions, checkpoint)
        assertEquals("verified", result.outcome)
        assertEquals(capturesBeforeResume + 2, device.snapshotCalls)
        assertEquals(0, device.reuseCalls)
        assertEquals(1, device.taps)
        assertEquals(1, device.preparedIds.size)
        assertEquals(2L, PhoneFlow.map(result.value["performance"], "performance")["captures"])
    }

    @Test fun performanceReportsOnlyCountersAccumulatedDuringThisRun() {
        val device = Device(); device.preparedEnabled = true
        device.snapshot(pkg)
        device.awaitChange(50)
        val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true))))
        val performance = PhoneFlow.map(result.value["performance"], "performance")
        assertEquals(2L, performance["captures"])
        assertEquals(0L, performance["waitMs"])
    }

    @Test fun brieflyMissingInitialObservationIsRetriedBeforeDispatch() {
        val device = Device(); device.preparedEnabled = true
        device.beforeSnapshot = {
            if (device.time < 200) throw PhoneFlow.ObservationUnavailable("当前没有可观察的界面。")
        }
        val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true))))
        assertEquals("verified", result.outcome)
        assertEquals(200L, device.time)
        assertEquals(1, device.taps)
        assertEquals(2, result.value["observationRetryCount"])
        assertEquals(2, result.value["observationCount"])
        assertEquals(4, device.snapshotCalls)
    }

    @Test fun missingObservationAfterDispatchRecoversWithoutAnotherTap() {
        val device = Device(); device.preparedEnabled = true
        device.beforeSnapshot = {
            if (device.taps > 0 && device.time < 200) throw PhoneFlow.ObservationUnavailable("temporarily missing")
        }
        val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true))))
        assertEquals("verified", result.outcome)
        assertEquals(1, device.taps)
        assertEquals(200L, device.time)
        assertEquals(2, result.value["observationRetryCount"])
        assertEquals(2, result.value["observationCount"])
    }

    @Test fun missingObservationTimesOutAndRepeatedResumeNeverReplaysTheAction() {
        val device = Device(); device.preparedEnabled = true
        device.beforeSnapshot = {
            if (device.taps > 0) throw PhoneFlow.ObservationUnavailable("still missing")
        }
        val actions = plan(step("a", "Option A", condition("checked", "Option A", true)) + ("timeoutMs" to 250))
        val first = device.run(actions)
        assertEquals("unknown", first.outcome)
        assertEquals(250L, device.time)
        assertEquals(1, device.taps)
        assertEquals(3, first.value["observationRetryCount"])
        assertEquals(1, first.value["observationCount"])
        val stillMissing = device.run(actions, device.saved)
        assertEquals("unknown", stillMissing.outcome)
        assertEquals(500L, device.time)
        assertEquals(1, device.taps)
        assertEquals(0, stillMissing.value["observationCount"])
        assertEquals("unknown", PhoneFlow.map((device.saved!!["steps"] as List<*>).single(), "step")["state"])
        device.beforeSnapshot = null
        assertEquals("verified", device.run(actions, device.saved).outcome)
        assertEquals(1, device.taps)
    }

    @Test fun missingObservationWithUnlimitedTimeoutCanBeCancelled() {
        val device = Device(); device.cancelAt = 100
        device.beforeSnapshot = { throw PhoneFlow.ObservationUnavailable("missing until cancellation") }
        val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true)) + ("timeoutMs" to 0)))
        assertEquals("cancelled", result.outcome)
        assertEquals(100L, device.time)
        assertEquals(1, device.snapshotCalls)
        assertEquals(1, result.value["observationRetryCount"])
        assertEquals(0, device.taps)
    }

    @Test fun revokedPermissionStopsObservationRetryImmediately() {
        val device = Device()
        device.beforeSnapshot = {
            device.permission = false
            throw PhoneFlow.ObservationUnavailable("missing while authorization changes")
        }
        val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true))))
        assertEquals("permission_required", result.outcome)
        assertEquals(0L, device.time)
        assertEquals(1, device.snapshotCalls)
        assertEquals(0, result.value["observationRetryCount"])
        assertEquals(0, device.taps)
    }

    @Test fun unrelatedObservationFailuresAreNotRetriedEvenWithTheSameMessage() {
        for (failure in listOf(IllegalStateException("当前没有可观察的界面。"),
            IllegalArgumentException("foreign package"), IllegalArgumentException("foreign owner"))) {
            val device = Device()
            device.beforeSnapshot = { throw failure }
            val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true))))
            assertEquals("failed", result.outcome)
            assertEquals(0L, device.time)
            assertEquals(1, device.snapshotCalls)
            assertEquals(0, result.value["observationRetryCount"])
            assertEquals(0, device.taps)
        }
    }

    @Test fun observationUnavailableInsideDispatchDoesNotRetryTheAction() {
        val device = Device(); device.preparedEnabled = true
        var attempts = 0
        device.beforePerform = { attempts++; throw PhoneFlow.ObservationUnavailable("missing at dispatch") }
        val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true))))
        assertEquals("failed", result.outcome)
        assertEquals(1, attempts)
        assertEquals(0, device.taps)
        assertEquals(0L, device.time)
        assertEquals(0, result.value["observationRetryCount"])
    }

    @Test fun alreadySelectedDoesNotToggleAgain() {
        val device = Device(); device.selected.add("A")
        assertEquals("verified", device.run(plan(step("a", "Option A", condition("checked", "Option A", true)))).outcome)
        assertEquals(0, device.taps)
    }

    @Test fun uncertainActionResumesByVerificationOnly() {
        val device = Device(); device.acceptedWithoutEffect = true
        val plan = plan(step("a", "Option A", condition("checked", "Option A", true)), step("b", "Option B", condition("checked", "Option B", true)))
        val first = device.run(plan)
        assertEquals("unknown", first.outcome); assertEquals(1, device.taps)
        val pending = device.saved!!
        assertEquals(true, pending["hasUnverifiedActions"])
        val stillUnknown = device.run(plan, pending)
        assertEquals("unknown", stillUnknown.outcome); assertEquals(1, device.taps)
        device.selected.add("A"); device.acceptedWithoutEffect = false
        val resumed = device.run(plan, device.saved)
        assertEquals("verified", resumed.outcome)
        assertEquals(2, device.taps)
        assertTrue((resumed.value["elapsedMs"] as Long) >= 600)
    }

    @Test fun cancelWhileWaitingRetainsOriginalActionAndStopsQuickly() {
        val device = Device(); device.acceptedWithoutEffect = true; device.cancelAt = 100
        val plan = plan(step("a", "Option A", condition("checked", "Option A", true)))
        val cancelled = device.run(plan)
        assertEquals("cancelled", cancelled.outcome); assertEquals(1, device.taps)
        assertEquals(true, cancelled.value["hasUnverifiedActions"])
        assertEquals(100, device.time)
        device.cancelAt = Long.MAX_VALUE; device.selected.add("A")
        assertEquals("verified", device.run(plan, device.saved).outcome)
        assertEquals(1, device.taps)
    }

    @Test fun revokedPermissionBlocksFurtherActions() {
        val device = Device(); device.afterPerform = { device.permission = false }
        val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true)), step("b", "Option B", condition("checked", "Option B", true))))
        assertEquals("permission_required", result.outcome)
        assertEquals(1, device.taps); assertEquals(true, result.value["hasUnverifiedActions"])
    }

    @Test fun malformedLaterStepIsRejectedBeforeAnyAction() {
        val device = Device()
        try {
            device.run(plan(step("a", "Option A", condition("checked", "Option A", true)), mapOf("id" to "bad", "action" to "shell", "expect" to condition("exists", "Next"))))
            fail("malformed plan accepted")
        } catch (_: IllegalArgumentException) { assertEquals(0, device.taps) }
    }

    @Test fun pageGuardStopsCrossQuestionClicks() {
        val device = Device(); device.question = 2
        val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true), condition("exists", "Question 1"))))
        assertEquals("failed", result.outcome); assertEquals(0, device.taps)
    }

    @Test fun guardIsCheckedAgainImmediatelyBeforeDispatch() {
        val device = Device(); device.beforePerform = { device.question = 2 }
        val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true), condition("exists", "Question 1"))))
        assertEquals("failed", result.outcome); assertEquals(0, device.taps)
    }

    @Test fun ambiguousTargetsNeverPickAnArbitraryMatch() {
        val device = Device(); device.duplicate = true
        val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true))))
        assertEquals("failed", result.outcome); assertEquals(0, device.taps)
    }

    @Test fun defaultTargetsPreferMatchedNativeIdentityOverItsLinkedOcrRow() {
        val native = mapOf<String, Any?>("id" to "native-a", "text" to "Option A",
            "source" to "accessibility", "checkable" to true,"checked" to true, "selected" to true)
        val ocr = mapOf<String, Any?>("id" to "ocr-a", "text" to "Option A",
            "source" to "ocr", "nativeElementId" to "native-a")
        val snapshot = PhoneFlow.Snapshot(pkg, 1, listOf(native, ocr), emptyMap())
        assertEquals(listOf(native), PhoneFlow.targets(snapshot, selector("Option A")))
        assertEquals(native, PhoneFlow.unique(snapshot, selector("Option A")))
        assertTrue(PhoneFlow.satisfied(snapshot, condition("checked", "Option A", true)))
        assertTrue(PhoneFlow.satisfied(snapshot, condition("selected", "Option A", true)))
    }

    @Test fun explicitSourceSelectionRetainsTheRequestedLinkedRepresentation() {
        val native = mapOf<String, Any?>("id" to "native-a", "text" to "Option A",
            "source" to "accessibility", "checked" to true)
        val ocr = mapOf<String, Any?>("id" to "ocr-a", "text" to "Option A",
            "source" to "ocr", "nativeElementId" to "native-a")
        val snapshot = PhoneFlow.Snapshot(pkg, 1, listOf(native, ocr), emptyMap())
        val visualSelector = selector("Option A") + ("source" to "ocr")
        assertEquals(listOf(ocr), PhoneFlow.targets(snapshot, visualSelector))
        assertEquals(listOf(native), PhoneFlow.targets(snapshot, selector("Option A") + ("source" to "accessibility")))
        assertFalse(PhoneFlow.satisfied(snapshot, mapOf("kind" to "checked", "checked" to true, "selector" to visualSelector)))
    }

    @Test fun linkedOcrTargetRemainsWhenItsNativeIdentityDoesNotMatchTheSelector() {
        val native = mapOf<String, Any?>("id" to "native-a", "text" to "Different native label",
            "source" to "accessibility")
        val ocr = mapOf<String, Any?>("id" to "ocr-a", "text" to "Option A",
            "source" to "ocr", "nativeElementId" to "native-a")
        val snapshot = PhoneFlow.Snapshot(pkg, 1, listOf(native, ocr), emptyMap())
        assertEquals(listOf(ocr), PhoneFlow.targets(snapshot, selector("Option A")))
        assertEquals(ocr, PhoneFlow.unique(snapshot, selector("Option A")))
    }

    @Test fun regionChangeIgnoresExternalTimerAndNewNodeIds() {
        val device = Device()
        val condition = mapOf("kind" to "changed", "selector" to mapOf("viewId" to "content"))
        val before = PhoneFlow.evidence(device.snapshot(pkg), condition)
        assertFalse(PhoneFlow.satisfied(device.snapshot(pkg), condition, before))
        device.question = 2
        assertTrue(PhoneFlow.satisfied(device.snapshot(pkg), condition, before))
    }

    @Test fun stablePredicateMustRemainTrueForTheRequestedDuration() {
        val device = Device(); device.selected.add("A")
        val result = device.run(plan(step("a", "Option A", condition("checked", "Option A", true)) + mapOf("stableMs" to 200)))
        assertEquals("verified", result.outcome); assertEquals(200, device.time)
    }

    @Test fun falseConditionalBranchIsSkippedWithoutDispatch() {
        val device = Device()
        val result = device.run(plan(step("optional", "Option A", condition("checked", "Option A", true)) + mapOf("when" to condition("exists", "Missing popup"))))
        assertEquals("verified", result.outcome); assertEquals(0, device.taps)
        assertEquals("skipped", PhoneFlow.map((result.value["steps"] as List<*>).single(), "step")["state"])
    }

    @Test fun allAnyAndAncestorScopeUseActualRows() {
        val device = Device(); device.selected.add("A")
        val snapshot = device.snapshot(pkg)
        val target = PhoneFlow.unique(snapshot, selector("Option A") + mapOf("within" to mapOf("viewId" to "content")))
        assertEquals("Option A", target["text"])
        val all = mapOf("kind" to "all", "conditions" to listOf(condition("checked", "Option A", true), mapOf("kind" to "any", "conditions" to listOf(condition("exists", "Missing"), condition("exists", "Next")))))
        PhoneFlow.validateCondition(all)
        assertTrue(PhoneFlow.satisfied(snapshot, all))
    }

    @Test fun passwordsCannotBeTargetsOrEvidence() {
        val row = mapOf<String, Any?>("id" to "secret", "text" to "Option A", "password" to true)
        val snapshot = PhoneFlow.Snapshot(pkg, 1, listOf(row), emptyMap())
        assertFalse(PhoneFlow.satisfied(snapshot, condition("exists", "Option A")))
        try { PhoneFlow.unique(snapshot, selector("Option A")); fail("password selected") } catch (_: IllegalArgumentException) {}
    }

    @Test fun changedConditionCannotServeAsGuardOrBranch() {
        val invalid = step("a", "Option A", condition("checked", "Option A", true)) + mapOf("guard" to mapOf("kind" to "changed"))
        try { PhoneFlow.validate(plan(invalid)); fail("unstable guard accepted") } catch (_: IllegalArgumentException) {}
    }

    @Test fun foreignCheckpointCannotResume() {
        val device = Device(); val plan = plan(step("a", "Option A", condition("checked", "Option A", true)))
        device.run(plan)
        try { device.run(plan, device.saved!! + mapOf("rootRequestId" to "other")); fail("foreign checkpoint accepted") } catch (_: IllegalArgumentException) {}
    }

    @Test fun sixRecordedAnswerPlansCannotTreatExistingQuestionTextAsCompletedActions() {
        val examples=listOf(
            "tapA" to condition("exists","缓冲池"),
            "pick" to mapOf("kind" to "exists","selector" to mapOf("textContains" to "缓冲池","source" to "ocr")),
            "a7" to mapOf("kind" to "exists","selector" to mapOf("textContains" to "7/20","source" to "ocr")),
            "a8" to condition("exists","选项A.JCB"),
            "a9" to mapOf("kind" to "exists","selector" to mapOf("textContains" to "SPOOLing","source" to "ocr")),
            "a10" to mapOf("kind" to "exists","selector" to mapOf("textContains" to "10/20","source" to "ocr")))
        val rows=listOf("缓冲池","7/20","选项A.JCB","SPOOLing","10/20").mapIndexed{i,text->
            mapOf<String,Any?>("id" to "v_$i","text" to text,"source" to "ocr")}
        val snapshot=PhoneFlow.Snapshot(pkg,1,rows,emptyMap())
        for((id,expected)in examples) {
            val action=step(id,"答案选项",expected)
            val device=Device()
            val backend=object:PhoneFlow.Backend by device {
                override fun snapshot(pkg:String)=snapshot
            }
            val result=PhoneFlow.run(plan(action),"recorded-$id",backend){}
            assertEquals("failed",result.outcome)
            assertTrue(result.summary.contains("invalid_postcondition"))
            assertEquals(0,device.taps)
            val record=PhoneFlow.map((result.value["steps"] as List<*>).single(),"step")
            assertEquals(false,record["attempted"]);assertEquals(false,record["dispatched"])
            assertEquals(false,record["businessVerified"]);assertEquals(false,record["alreadySatisfied"])
        }
    }

    @Test fun defaultFalseFlagsOnNonCheckableTextCannotEstablishEitherState() {
        val device=Device();device.checkableOptions=false
        for(wanted in listOf(true,false)) {
            val result=device.run(plan(step("answer","Option A",condition("checked","Option A",wanted))))
            assertEquals("failed",result.outcome);assertTrue(result.summary.contains("invalid_postcondition"))
        }
        val result=device.run(plan(step("answer","Option A",condition("selected","Option A",false))))
        assertEquals("failed",result.outcome);assertEquals(0,device.taps)
    }

    @Test fun strongStateMustBelongToTheActualActionTarget() {
        val device=Device();device.selected.add("B")
        val result=device.run(plan(step("answer","Option A",condition("checked","Option B",true))))
        assertEquals("failed",result.outcome);assertEquals(0,device.taps)
    }

    @Test fun anyCannotBeSatisfiedByAnUnchangedWeakBranch() {
        val device=Device()
        val expected=mapOf("kind" to "any","conditions" to listOf(condition("exists","Question 1"),condition("checked","Option A",true)))
        val result=device.run(plan(step("answer","Option A",expected)))
        assertEquals("failed",result.outcome);assertEquals(0,device.taps)
    }

    @Test fun allAllowsInvariantPageGuardsWhenTheTargetStateReallyChanges() {
        val device=Device()
        val expected=mapOf("kind" to "all","conditions" to listOf(condition("exists","Question 1"),condition("checked","Option A",true)))
        val result=device.run(plan(step("answer","Option A",expected)))
        assertEquals("verified",result.outcome);assertEquals(1,device.taps)
        assertEquals(true,result.value["businessVerified"])
        val record=PhoneFlow.map((result.value["steps"] as List<*>).single(),"step")
        assertEquals(true,record["attempted"]);assertEquals(true,record["dispatched"])
        assertEquals(true,record["businessVerified"]);assertEquals("native_checked",record["verificationKind"])
    }

    @Test fun changedMustReferToTheActionTargetInsteadOfAnUnrelatedRegion() {
        val device=Device()
        val unrelated=mapOf("kind" to "changed","selector" to mapOf("viewId" to "content"))
        val result=device.run(plan(step("answer","Option A",unrelated)))
        assertEquals("failed",result.outcome);assertEquals(0,device.taps)
    }

    @Test fun selectedFalseRequiresAnActualSupportedTrueToFalseTransition() {
        val device=Device();device.selected.add("A");device.afterPerform={device.selected.remove("A")}
        val result=device.run(plan(step("answer","Option A",condition("selected","Option A",false))))
        assertEquals("verified",result.outcome);assertEquals(1,device.taps)
    }

    @Test fun setCheckedConstructsAnUnreplaceableHostStateConditionAndDoesNotToggleAgain() {
        val device=Device()
        val action=mapOf<String,Any?>("id" to "check","action" to "set_checked","selector" to selector("Option A"),
            "checked" to true,"expect" to condition("exists","Question 1"),"stableMs" to 0,"timeoutMs" to 300)
        assertEquals("verified",device.run(plan(action)).outcome);assertEquals(1,device.taps)
        val already=device.run(plan(action))
        assertEquals("verified",already.outcome);assertEquals(1,device.taps)
        val record=PhoneFlow.map((already.value["steps"] as List<*>).single(),"step")
        assertEquals(true,record["alreadySatisfied"]);assertEquals(false,record["dispatched"])
        assertEquals(true,record["businessVerified"])
        val clear=action-mapOf("expect" to null).keys+mapOf("checked" to false)
        assertEquals("verified",device.run(plan(clear)).outcome);assertEquals(2,device.taps)
        assertFalse("A" in device.selected)
    }

    @Test fun oldUnknownCheckpointWithoutTransitionBaselineNeverReplaysOrInfersNavigation() {
        val device=Device();device.acceptedWithoutEffect=true
        val action=plan(step("next","Next",condition("exists","Question 2")))
        assertEquals("unknown",device.run(action).outcome)
        val saved=device.saved!!
        val legacy=saved+mapOf("steps" to (saved["steps"] as List<*>).map{PhoneFlow.map(it,"step")-"completionBefore"})
        device.question=2
        val resumed=device.run(action,legacy)
        assertEquals("unknown",resumed.outcome);assertEquals(1,device.taps)
    }

    @Test fun inputAlreadySatisfiedRequiresTheSameEditableTargetAndIntendedText() {
        val row=mapOf<String,Any?>("id" to "input","viewId" to "field","class" to "EditText","text" to "ready","editable" to true)
        val snapshot=PhoneFlow.Snapshot(pkg,1,listOf(row),emptyMap())
        val action=mapOf<String,Any?>("action" to "input","selector" to mapOf("viewId" to "field"),"text" to "ready",
            "expect" to mapOf("kind" to "text","selector" to mapOf("viewId" to "field"),"text" to "ready"))
        assertTrue(PhoneFlow.shouldSkip(snapshot,action))
        for(invalid in listOf(action+mapOf("text" to "different"),action+mapOf("selector" to mapOf("viewId" to "other")))) {
            try { PhoneFlow.shouldSkip(snapshot,invalid);fail("unrelated input evidence accepted") }
            catch(error:PhoneFlow.Blocked){assertTrue(error.message!!.contains("invalid_postcondition"))}
        }
        try { PhoneFlow.shouldSkip(snapshot.copy(rows=listOf(row+mapOf("editable" to false))),action);fail("noneditable text accepted") }
        catch(error:PhoneFlow.Blocked){assertTrue(error.message!!.contains("invalid_postcondition"))}
    }

    @Test fun visualCheckedRequiresConfidenceAndTheExactFrameBinding() {
        val observation=mapOf<String,Any?>("observationId" to "ocr:frame","capturedAtMs" to 100L,"imageHash" to "pixels")
        val row=mapOf<String,Any?>("id" to "option","text" to "答案","source" to "ocr","visualChecked" to true,
            "visualStateConfidence" to 0.99,"visualStateKind" to "radio","visualMarkBounds" to listOf(20,50,50,80),
            "visualStateObservationId" to "ocr:frame","visualStateCapturedAtMs" to 100L,"visualStateImageHash" to "pixels")
        val snapshot=PhoneFlow.Snapshot(pkg,1,listOf(row),observation)
        val expected=mapOf<String,Any?>("kind" to "visual_checked","selector" to selector("答案"),"checked" to true)
        val action=mapOf<String,Any?>("action" to "tap","selector" to selector("答案"),"expect" to expected)
        assertTrue(PhoneFlow.shouldSkip(snapshot,action))
        for(invalid in listOf(row+mapOf("visualStateConfidence" to 0.89),row+mapOf("visualStateObservationId" to "old"),
            row+mapOf("visualStateCapturedAtMs" to 99L),row+mapOf("visualStateImageHash" to "old"),row-"visualChecked",
            row+mapOf("visualMarkBounds" to listOf(20,50,20,80)),row+mapOf("visualMarkBounds" to listOf(20,Double.NaN,50,80)))) {
            assertNull(PhoneFlow.checkedState(snapshot,invalid))
            assertFalse(PhoneFlow.satisfied(snapshot.copy(rows=listOf(invalid)),expected))
        }
        val native=row+mapOf("source" to "accessibility","checkable" to true,"checked" to false)
        assertNull(PhoneFlow.checkedState(snapshot,native))
        val linked=row+mapOf("nativeElementId" to "native")
        assertNull(PhoneFlow.checkedState(snapshot.copy(rows=listOf(linked,native+mapOf("id" to "native"))),linked))
        assertNull(PhoneFlow.checkedState(snapshot.copy(observation=observation-"imageHash"),row))
    }

    @Test fun setCheckedDoesNotToggleAnAlreadySatisfiedTargetWhileAdditionalEvidenceIsPending() {
        val device=Device();device.selected.add("A")
        val action=mapOf<String,Any?>("id" to "check","action" to "set_checked","selector" to selector("Option A"),"checked" to true,
            "expect" to condition("exists","Missing confirmation"),"stableMs" to 0,"timeoutMs" to 100)
        val result=device.run(plan(action))
        assertEquals("unknown",result.outcome);assertEquals(0,device.taps)
        assertEquals(false,result.value["businessVerified"])
        val record=PhoneFlow.map((result.value["steps"] as List<*>).single(),"step")
        assertEquals(true,record["alreadySatisfied"]);assertEquals(false,record["dispatched"])
    }

    @Test fun oldVerifiedRecordsWithoutBusinessEvidenceAreReportedAsUnknown() {
        val device=Device()
        val action=plan(step("answer","Option A",condition("checked","Option A",true)))
        assertEquals("verified",device.run(action).outcome)
        val saved=device.saved!!
        val legacy=saved+mapOf("steps" to (saved["steps"] as List<*>).map{PhoneFlow.map(it,"step")-"businessVerified"})
        val resumed=device.run(action,legacy)
        assertEquals("unknown",resumed.outcome);assertEquals(1,device.taps)
        assertEquals(false,resumed.value["businessVerified"]);assertNull(resumed.value["verifiedRequestId"])
    }

    @Test fun oldUnprovenCompletionCannotReleaseANewDependentAction() {
        val device=Device()
        val actions=plan(step("first","Option A",condition("checked","Option A",true)),step("dependent","Option B",condition("checked","Option B",true)))
        assertEquals("verified",device.run(actions).outcome)
        val saved=device.saved!!
        val records=(saved["steps"] as List<*>).map{PhoneFlow.map(it,"step")}
        val legacy=saved+mapOf("steps" to listOf(records[0]-"businessVerified",records[1]+mapOf("state" to "queued","businessVerified" to false)))
        device.selected.remove("B")
        val resumed=device.run(actions,legacy)
        assertEquals("unknown",resumed.outcome);assertEquals(2,device.taps)
        assertFalse("B" in device.selected)
    }
}
