package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.Json
import com.skyjjgw.independent.ski.dshgo.phone.PhoneScreen
import com.skyjjgw.independent.ski.dshgo.phone.skills.PhoneSkillRoute as R
import org.junit.Assert.*
import org.junit.Test

class PhoneSkillRouteTest {
    private val name = "phone-task-00000000000000000000000000000001"
    private val revision = "00000000000000000000000000000002"
    private val source = """{"schema":1,"skillName":"phone-task-00000000000000000000000000000001",
      "bundleRevision":"00000000000000000000000000000002","descriptorSet":"fixture-only",
      "appSlots":[{"key":"app1","kind":"user_selected_app"}],
      "parameters":[{"key":"desired","kind":"boolean","required":true},
        {"key":"choice","kind":"enum","required":true,"choices":["more","notebook"]},
        {"key":"query","kind":"text","required":true,"maxCodeUnits":32}],
      "steps":[
        {"op":"open_app","appSlot":"app1","screen":"main","post":{"kind":"page_is","pageKey":"home"}},
        {"op":"tap_navigation","appSlot":"app1","screen":"main","pageKey":"home","targetKey":"settings_link","post":{"kind":"page_is","pageKey":"settings"}},
        {"op":"set_checked","appSlot":"app1","screen":"main","pageKey":"settings","targetKey":"compact","value":{"parameter":"desired"},"post":{"kind":"checked_equals_value"}},
        {"op":"select_option","appSlot":"app1","screen":"main","pageKey":"settings","targetKey":"tabs","value":{"parameter":"choice"},"post":{"kind":"option_selected"}},
        {"op":"type_parameter","appSlot":"app1","screen":"main","pageKey":"settings","targetKey":"query_field","value":{"parameter":"query"},"post":{"kind":"text_equals_parameter"}},
        {"op":"back_to_page","appSlot":"app1","screen":"main","pageKey":"settings","post":{"kind":"page_is","pageKey":"home"}}
      ]}"""
    private val steps = setOf(
        R.Step(R.Op.OPEN_APP, "app1", PhoneScreen.MAIN, post = R.Post.PageIs("home")),
        R.Step(R.Op.TAP_NAVIGATION, "app1", PhoneScreen.MAIN, "home", "settings_link", post = R.Post.PageIs("settings")),
        R.Step(R.Op.TAP_NAVIGATION, "app1", PhoneScreen.MAIN, "settings", "about_link", post = R.Post.PageIs("about")),
        R.Step(R.Op.SET_CHECKED, "app1", PhoneScreen.MAIN, "settings", "compact", R.Value.Reference("desired"), R.Post.CheckedEqualsValue),
        R.Step(R.Op.SET_CHECKED, "app1", PhoneScreen.MAIN, "settings", "compact", R.Value.BooleanLiteral(true), R.Post.CheckedEqualsValue),
        R.Step(R.Op.SELECT_OPTION, "app1", PhoneScreen.MAIN, "settings", "tabs", R.Value.Reference("choice"), R.Post.OptionSelected),
        R.Step(R.Op.SELECT_OPTION, "app1", PhoneScreen.MAIN, "settings", "tabs", R.Value.OptionLiteral("more"), R.Post.OptionSelected),
        R.Step(R.Op.TYPE_PARAMETER, "app1", PhoneScreen.MAIN, "settings", "query_field", R.Value.Reference("query"), R.Post.TextEqualsParameter),
        R.Step(R.Op.BACK_TO_PAGE, "app1", PhoneScreen.MAIN, "settings", post = R.Post.PageIs("home")),
    )
    private val parameters = listOf(R.Parameter("desired", R.ParameterKind.BOOLEAN),
        R.Parameter("choice", R.ParameterKind.ENUM, listOf("more", "notebook")),
        R.Parameter("query", R.ParameterKind.TEXT, maxCodeUnits = 64))
    private val descriptor = R.Descriptor("fixture-only", setOf("app1", "app2"), parameters, steps)
    private val descriptors = mapOf("fixture-only" to descriptor) // Test constants only; no production registry.

    @Suppress("UNCHECKED_CAST") private fun document() = Json.parse(source) as MutableMap<String, Any?>
    @Suppress("UNCHECKED_CAST") private fun objects(root: Map<String, Any?>, key: String) = root[key] as MutableList<MutableMap<String, Any?>>
    private fun read(root: Map<String, Any?>) = raw(Json.write(root))
    private fun raw(text: String) = R.parse(text.toByteArray(Charsets.UTF_8), name, revision, descriptors)
    private fun rejected(reason: R.Reason, result: R.Read) = assertEquals(R.Read.Rejected(reason), result)
    private fun accepted(result: R.Read): R.Route {
        assertTrue(result is R.Read.Accepted)
        return (result as R.Read.Accepted).route
    }

    @Test fun realByteParserAcceptsSixFiniteRelationsAndReturnsImmutableValues() {
        val route = accepted(raw(source))
        assertEquals(R.Op.entries.toSet(), route.steps.map { it.op }.toSet())
        assertEquals(32, route.parameters.single { it.key == "query" }.maxCodeUnits) // Narrower than descriptor's 64.
        assertEquals(listOf("app1"), route.slots)
        assertEquals(R.Value.Reference("query"), route.steps[4].value)
        assertThrows(UnsupportedOperationException::class.java) { (route.steps as MutableList<R.Step>).clear() }
        assertThrows(UnsupportedOperationException::class.java) { (route.slots as MutableList<String>).add("app2") }
        assertThrows(UnsupportedOperationException::class.java) { (route.parameters as MutableList<R.Parameter>).clear() }
        assertThrows(UnsupportedOperationException::class.java) {
            (route.parameters.single { it.key == "choice" }.choices as MutableList<String>).add("private")
        }
    }

    @Test fun relationMatchingRejectsCrossProductsOfIndividuallyKnownFields() {
        val root = document()
        val tap = objects(root, "steps")[1]
        tap["targetKey"] = "about_link"
        tap["post"] = mapOf("kind" to "page_is", "pageKey" to "about")
        // home, about_link and about all exist, but only settings -> about_link -> about is allowed.
        rejected(R.Reason.UNSUPPORTED, read(root))
        tap["pageKey"] = "settings"
        accepted(read(root))
        tap["screen"] = "background"
        rejected(R.Reason.UNSUPPORTED, read(root))
    }

    @Test fun typedLiteralFormsDoNotPermitTextOrASecondValueSource() {
        val root = document()
        objects(root, "steps")[2]["value"] = mapOf("literal" to true)
        objects(root, "steps")[3]["value"] = mapOf("literal" to "more")
        objects(root, "parameters").removeAll { it["key"] != "query" }
        accepted(read(root))
        objects(root, "steps")[2]["value"] = mapOf("literal" to "true")
        rejected(R.Reason.SCHEMA, read(root))
        objects(root, "steps")[2]["value"] = mapOf("literal" to true, "parameter" to "desired")
        rejected(R.Reason.SCHEMA, read(root))
        objects(root, "steps")[2]["value"] = mapOf("literal" to true)
        objects(root, "steps")[4]["value"] = mapOf("literal" to "synthetic private message")
        rejected(R.Reason.SCHEMA, read(root))
    }

    @Test fun exactEnumSetAndParameterTypeCannotBeWeakened() {
        val root = document()
        val choiceParameter = objects(root, "parameters")[1]
        choiceParameter["choices"] = listOf("notebook", "more")
        accepted(read(root))
        choiceParameter["choices"] = listOf("more")
        rejected(R.Reason.UNSUPPORTED, read(root))
        choiceParameter["choices"] = listOf("more", "more")
        rejected(R.Reason.SCHEMA, read(root))
        choiceParameter["choices"] = listOf("more", "notebook")
        objects(root, "steps")[2]["value"] = mapOf("parameter" to "choice")
        rejected(R.Reason.SCHEMA, read(root))
    }

    @Test fun allSlotsAndParametersMustBeDeclaredAndUsed() {
        var root = document()
        objects(root, "appSlots").add(mutableMapOf("key" to "app2", "kind" to "user_selected_app"))
        rejected(R.Reason.SCHEMA, read(root))
        root = document()
        objects(root, "steps")[0]["appSlot"] = "app2"
        rejected(R.Reason.SCHEMA, read(root))
        root = document()
        objects(root, "steps")[2]["value"] = mapOf("literal" to true)
        rejected(R.Reason.SCHEMA, read(root)) // desired is declared but unused.
        root = document()
        objects(root, "parameters").removeAt(0)
        rejected(R.Reason.SCHEMA, read(root)) // The reference remains, so it is not silently defaulted.
    }

    @Test fun limitsApplyToRawBytesIntegerTokensAndListLengths() {
        rejected(R.Reason.SIZE, R.parse(ByteArray(0), name, revision, descriptors))
        rejected(R.Reason.SIZE, raw(" ".repeat(16 * 1024) + source))
        rejected(R.Reason.SIZE, raw("\"" + "中".repeat(6000) + "\"")) // <16K chars, >16K bytes.
        val compact = Json.write(document())
        for (token in listOf("1.0", "1e0", "2", "null")) {
            rejected(R.Reason.SCHEMA, raw(compact.replace("\"schema\":1", "\"schema\":$token")))
        }
        for (token in listOf("0", "2001", "32.0", "32e0")) {
            rejected(R.Reason.SCHEMA, raw(compact.replace("\"maxCodeUnits\":32", "\"maxCodeUnits\":$token")))
        }
        rejected(R.Reason.UNSUPPORTED, raw(compact.replace("\"maxCodeUnits\":32", "\"maxCodeUnits\":65")))
        val root = document(); val first = objects(root, "steps").first()
        root["steps"] = List(17) { first }
        rejected(R.Reason.SCHEMA, read(root))
        root["steps"] = emptyList<Any>()
        rejected(R.Reason.SCHEMA, read(root))
    }

    @Test fun malformedUtf8DuplicateEscapedKeysAndSurrogatesAreNotNormalized() {
        for (bytes in listOf(byteArrayOf(0xc3.toByte(), 0x28), byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte()), byteArrayOf(0xf0.toByte()))) {
            rejected(R.Reason.UTF8, R.parse(bytes, name, revision, descriptors))
        }
        val compact = Json.write(document())
        for (prefix in listOf("\"schema\":1,", "\"schem\\u0061\":1,")) {
            rejected(R.Reason.JSON, raw("{" + prefix + compact.drop(1)))
        }
        rejected(R.Reason.JSON, raw(compact.replace("\"schema\":1", "\"schema\":01")))
        rejected(R.Reason.JSON, raw(compact.replace("fixture-only", "\\uD800")))
        rejected(R.Reason.JSON, raw("[".repeat(9) + "0" + "]".repeat(9)))
    }

    @Test fun unknownFieldsOperationsAndPrivateIdentifiersAreRejectedWhole() {
        for (field in listOf("requiresConfirmation", "stepsToSkip", "text", "format", "revision")) {
            val root = document(); root[field] = "synthetic private data"
            rejected(R.Reason.SCHEMA, read(root))
        }
        for (operation in listOf(null, 1L, true)) {
            val root = document(); objects(root, "steps")[1]["op"] = operation
            rejected(R.Reason.SCHEMA, read(root))
        }
        val missingOp = document(); objects(missingOp, "steps")[1].remove("op")
        rejected(R.Reason.SCHEMA, read(missingOp))
        var root = document(); objects(root, "steps")[1]["targetKey"] = "contact_alice"
        rejected(R.Reason.UNSUPPORTED, read(root))
        root = document(); objects(root, "steps")[1]["op"] = "tap_xy"
        rejected(R.Reason.UNSUPPORTED, read(root))
        root = document(); objects(root, "parameters")[2]["default"] = "synthetic private data"
        rejected(R.Reason.SCHEMA, read(root))
        root = document(); objects(root, "steps")[2]["post"] = mapOf("kind" to "page_is", "pageKey" to "home")
        rejected(R.Reason.SCHEMA, read(root))
        root = document(); root["descriptorSet"] = "not_registered"
        rejected(R.Reason.UNSUPPORTED, read(root))
        rejected(R.Reason.UNSUPPORTED, R.parse(source.toByteArray(), name, revision, emptyMap()))
    }

    @Test fun fixedBundleIdentityAndDescriptorSnapshotsCannotBeRetargetedByMutation() {
        rejected(R.Reason.IDENTITY, R.parse(source.toByteArray(), "phone-task-" + "3".repeat(32), revision, descriptors))
        rejected(R.Reason.IDENTITY, R.parse(source.toByteArray(), name, "4".repeat(32), descriptors))
        val slots = mutableSetOf("app1"); val allowed = steps.toMutableSet(); val choices = mutableListOf("more", "notebook")
        val definitions = parameters.map { if (it.kind == R.ParameterKind.ENUM) it.copy(choices = choices) else it }.toMutableList()
        val snapshot = R.Descriptor("fixture-only", slots, definitions, allowed)
        slots.clear(); allowed.clear(); choices.clear(); definitions.clear()
        accepted(R.parse(source.toByteArray(), name, revision, mapOf("fixture-only" to snapshot)))
    }
}
