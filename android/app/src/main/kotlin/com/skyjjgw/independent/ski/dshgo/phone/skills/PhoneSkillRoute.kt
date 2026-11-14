package com.skyjjgw.independent.ski.dshgo.phone.skills

import com.skyjjgw.independent.ski.dshgo.phone.Json
import com.skyjjgw.independent.ski.dshgo.phone.PhoneScreen
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.Collections

/** Finite, data-only v1 reader. No files, actions, permissions or invocation issuance.
 * Descriptors are native reviewed constants, never parsed from a bundle or model arguments.
 * Acceptance proves structure and that exact relation, not current App/page/target eligibility. */
internal object PhoneSkillRoute {
    enum class Op(val wire: String) {
        OPEN_APP("open_app"), TAP_NAVIGATION("tap_navigation"), SET_CHECKED("set_checked"),
        SELECT_OPTION("select_option"), TYPE_PARAMETER("type_parameter"), BACK_TO_PAGE("back_to_page")
    }
    enum class ParameterKind { BOOLEAN, ENUM, TEXT }
    data class Parameter(val key: String, val kind: ParameterKind,
        val choices: List<String> = emptyList(), val maxCodeUnits: Int? = null)
    sealed interface Value {
        data class BooleanLiteral(val value: Boolean) : Value
        data class OptionLiteral(val key: String) : Value
        data class Reference(val parameter: String) : Value
    }
    sealed interface Post {
        data class PageIs(val page: String) : Post
        data object CheckedEqualsValue : Post
        data object OptionSelected : Post
        data object TextEqualsParameter : Post
    }
    data class Step(val op: Op, val appSlot: String, val screen: PhoneScreen,
        val page: String? = null, val target: String? = null, val value: Value? = null, val post: Post)

    /** Full Step equality includes op, slot, screen, page, target, value/ref and post.
     * Independent membership in several bags of strings never grants a relation. */
    class Descriptor(val id: String, slots: Set<String>, parameters: List<Parameter>, steps: Set<Step>) {
        internal val slots: Set<String> = Collections.unmodifiableSet(LinkedHashSet(slots))
        internal val parameters: Map<String, Parameter>
        internal val steps: Set<Step> = Collections.unmodifiableSet(LinkedHashSet(steps))
        init {
            require(parameters.map { it.key }.toSet().size == parameters.size)
            this.parameters = Collections.unmodifiableMap(parameters.associate { it.key to PhoneSkillRoute.frozen(it) })
        }
    }
    data class Route(val skillName: String, val revision: String, val descriptorId: String,
        val slots: List<String>, val parameters: List<Parameter>, val steps: List<Step>)
    enum class Reason { SIZE, UTF8, JSON, SCHEMA, IDENTITY, UNSUPPORTED }
    sealed interface Read {
        data class Accepted(val route: Route) : Read
        data class Rejected(val reason: Reason) : Read
    }
    private class Invalid(val reason: Reason = Reason.SCHEMA) : RuntimeException()
    private val NAME = Regex("phone-task-[a-f0-9]{32}")
    private val REVISION = Regex("[a-f0-9]{32}")
    private val SLOTS = setOf("app1", "app2", "app3", "app4")

    fun parse(bytes: ByteArray, expectedName: String, expectedRevision: String,
        descriptors: Map<String, Descriptor>): Read {
        if (bytes.isEmpty() || bytes.size > 16 * 1024) return Read.Rejected(Reason.SIZE)
        val text = try {
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: CharacterCodingException) { return Read.Rejected(Reason.UTF8) }
        val parsed = try { Json.parseStrict(text, maxDepth = 8) }
            catch (_: Json.JsonException) { return Read.Rejected(Reason.JSON) }
        return try { Read.Accepted(route(parsed, expectedName, expectedRevision, descriptors)) }
            catch (failure: Invalid) { Read.Rejected(failure.reason) }
    }

    private fun route(raw: Any?, expectedName: String, expectedRevision: String,
        descriptors: Map<String, Descriptor>): Route {
        val root = obj(raw, "schema", "skillName", "bundleRevision", "descriptorSet", "appSlots", "parameters", "steps")
        if (root["schema"] != 1L) invalid()
        val name = string(root["skillName"])
        val revision = string(root["bundleRevision"])
        if (!NAME.matches(name) || !REVISION.matches(revision) || name != expectedName || revision != expectedRevision) {
            invalid(Reason.IDENTITY)
        }
        val descriptorId = string(root["descriptorSet"])
        val descriptor = descriptors[descriptorId]?.takeIf { it.id == descriptorId } ?: invalid(Reason.UNSUPPORTED)
        val slots = list(root["appSlots"], 1, 4).map {
            val slot = obj(it, "key", "kind")
            val key = string(slot["key"])
            if (slot["kind"] != "user_selected_app" || key !in SLOTS) invalid()
            if (key !in descriptor.slots) invalid(Reason.UNSUPPORTED)
            key
        }
        if (slots.toSet().size != slots.size) invalid()
        val parameters = list(root["parameters"], 0, 8).map(::parameter)
        if (parameters.map { it.key }.toSet().size != parameters.size) invalid()
        for (parameter in parameters) {
            val expected = descriptor.parameters[parameter.key] ?: invalid(Reason.UNSUPPORTED)
            val matches = if (parameter.kind == ParameterKind.TEXT) {
                parameter.copy(maxCodeUnits = expected.maxCodeUnits) == expected &&
                    parameter.maxCodeUnits!! <= (expected.maxCodeUnits ?: 0)
            } else parameter == expected
            if (!matches) invalid(Reason.UNSUPPORTED)
        }
        val byKey = parameters.associateBy { it.key }
        val steps = list(root["steps"], 1, 16).map { step(it, byKey) }
        val usedSlots = steps.map { it.appSlot }.toSet()
        val usedParameters = steps.mapNotNull { (it.value as? Value.Reference)?.parameter }.toSet()
        if (usedSlots != slots.toSet() || usedParameters != byKey.keys) invalid()
        for (step in steps) if (step !in descriptor.steps) invalid(Reason.UNSUPPORTED)
        return Route(name, revision, descriptorId, immutable(slots), immutable(parameters), immutable(steps))
    }

    private fun parameter(raw: Any?): Parameter {
        val base = raw as? Map<*, *> ?: invalid()
        val key = string(base["key"])
        if (base["required"] != true) invalid()
        return when (base["kind"]) {
            "boolean" -> {
                obj(raw, "key", "kind", "required")
                Parameter(key, ParameterKind.BOOLEAN)
            }
            "enum" -> {
                obj(raw, "key", "kind", "required", "choices")
                val choices = list(base["choices"], 1, 16).map(::string)
                if (choices.toSet().size != choices.size) invalid()
                Parameter(key, ParameterKind.ENUM, immutable(choices.sorted()))
            }
            "text" -> {
                obj(raw, "key", "kind", "required", "maxCodeUnits")
                val max = base["maxCodeUnits"] as? Long ?: invalid()
                if (max !in 1L..2000L) invalid()
                Parameter(key, ParameterKind.TEXT, maxCodeUnits = max.toInt())
            }
            else -> invalid()
        }
    }

    private fun step(raw: Any?, parameters: Map<String, Parameter>): Step {
        val base = raw as? Map<*, *> ?: invalid()
        val operation = string(base["op"])
        val op = Op.entries.firstOrNull { it.wire == operation } ?: invalid(Reason.UNSUPPORTED)
        val extra = when (op) {
            Op.OPEN_APP -> emptyArray<String>()
            Op.TAP_NAVIGATION -> arrayOf("pageKey", "targetKey")
            Op.SET_CHECKED, Op.SELECT_OPTION, Op.TYPE_PARAMETER -> arrayOf("pageKey", "targetKey", "value")
            Op.BACK_TO_PAGE -> arrayOf("pageKey")
        }
        obj(raw, "op", "appSlot", "screen", "post", *extra)
        val slot = string(base["appSlot"])
        val screen = when (base["screen"]) {
            "main" -> PhoneScreen.MAIN
            "background" -> PhoneScreen.BACKGROUND
            else -> invalid()
        }
        val page = if ("pageKey" in base) string(base["pageKey"]) else null
        val target = if ("targetKey" in base) string(base["targetKey"]) else null
        val value = if ("value" in base) value(base["value"], op, parameters) else null
        val post = when (op) {
            Op.OPEN_APP, Op.TAP_NAVIGATION, Op.BACK_TO_PAGE -> {
                val p = obj(base["post"], "kind", "pageKey")
                if (p["kind"] != "page_is") invalid()
                Post.PageIs(string(p["pageKey"]))
            }
            Op.SET_CHECKED -> fixedPost(base["post"], "checked_equals_value", Post.CheckedEqualsValue)
            Op.SELECT_OPTION -> fixedPost(base["post"], "option_selected", Post.OptionSelected)
            Op.TYPE_PARAMETER -> fixedPost(base["post"], "text_equals_parameter", Post.TextEqualsParameter)
        }
        return Step(op, slot, screen, page, target, value, post)
    }

    private fun value(raw: Any?, op: Op, parameters: Map<String, Parameter>): Value {
        val map = raw as? Map<*, *> ?: invalid()
        if (map.keys == setOf("parameter")) {
            val key = string(map["parameter"])
            val parameter = parameters[key] ?: invalid()
            val expected = when (op) {
                Op.SET_CHECKED -> ParameterKind.BOOLEAN
                Op.SELECT_OPTION -> ParameterKind.ENUM
                Op.TYPE_PARAMETER -> ParameterKind.TEXT
                else -> invalid()
            }
            if (parameter.kind != expected) invalid()
            return Value.Reference(key)
        }
        obj(raw, "literal")
        return when (op) {
            Op.SET_CHECKED -> Value.BooleanLiteral(map["literal"] as? Boolean ?: invalid())
            Op.SELECT_OPTION -> Value.OptionLiteral(string(map["literal"]))
            else -> invalid() // Input text never has a persistent literal.
        }
    }

    private fun fixedPost(raw: Any?, kind: String, result: Post): Post {
        if (obj(raw, "kind")["kind"] != kind) invalid()
        return result
    }
    private fun obj(raw: Any?, vararg keys: String): Map<*, *> {
        val map = raw as? Map<*, *> ?: invalid()
        if (map.keys != keys.toSet()) invalid()
        return map
    }
    private fun string(raw: Any?): String = raw as? String ?: invalid()
    private fun list(raw: Any?, min: Int, max: Int): List<*> {
        val values = raw as? List<*> ?: invalid()
        if (values.size !in min..max) invalid()
        return values
    }
    private fun frozen(parameter: Parameter) = parameter.copy(choices = immutable(parameter.choices.sorted()))
    private fun <T> immutable(values: List<T>): List<T> = Collections.unmodifiableList(ArrayList(values))
    private fun invalid(reason: Reason = Reason.SCHEMA): Nothing = throw Invalid(reason)
}
