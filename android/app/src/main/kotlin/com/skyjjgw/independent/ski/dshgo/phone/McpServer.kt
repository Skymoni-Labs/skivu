package com.skyjjgw.independent.ski.dshgo.phone

/** What a tool call returns to the model: one text block, optionally an image, and the MCP error flag. */
class ToolOutput(
    val text: String,
    val isError: Boolean = false,
    val image: ByteArray? = null,
    val imageMime: String? = null,
) {
    // Associated by the native producer with this call only; never serialized into MCP.
    internal var nativeReplyCommit: PhoneReplyCommit? = null
    internal var focusObservation: FocusObservation? = null
}

/** Host attribution, separate from tool arguments. It is not an approval or a task lease. */
data class PhoneCaller(val sessionId: String, val runId: String, val callId: String, val runLifecycle: Int = 0) {
    companion object {
        const val META_KEY = "dsh-go/phone-caller"

        fun identifier(value: Any?): String? = (value as? String)?.takeIf {
            it.length in 1..256 && it.none { c -> c < ' ' || c == '\u007f' }
        }

        fun parse(value: Any?): PhoneCaller? {
            val m = value as? Map<*, *> ?: return null
            if (m["v"] != 1L) return null
            val lifecycle = if (m.containsKey("runLifecycle")) m["runLifecycle"] else 0L
            if (lifecycle != 0L && lifecycle != 1L) return null
            return PhoneCaller(identifier(m["sessionId"]) ?: return null, identifier(m["runId"]) ?: return null, identifier(m["callId"]) ?: return null, (lifecycle as Long).toInt())
        }
    }
}

/**
 * The MCP side of the bridge: newline-delimited JSON-RPC 2.0 as MCP's stdio transport speaks it
 * (the guest relay forwards the bytes unchanged). Serves `initialize`, `ping`, `tools/list` and
 * `tools/call`; notifications and responses are ignored; anything else is "method not found"
 * (that is also how DSH 0.2.1's `server/discover` probe falls back to `initialize`).
 *
 * [dispatch] answers cheap methods immediately and hands tool calls back as a [Dispatch.Call], so
 * the connection keeps reading (and answering pings) while a call waits for the person.
 */
class McpServer(
    private val tools: List<Map<String, Any?>>,
    private val call: (name: String, args: Map<String, Any?>, caller: PhoneCaller?) -> ToolOutput,
    private val serverVersion: String = "1",
) {
    sealed interface Dispatch {
        /** Nothing to send (notification, response, blank line). */
        object None : Dispatch

        class Reply(val line: String) : Dispatch
        class RunEnd(val id: Any?, val sessionId: String, val runId: String, val completion: String) : Dispatch {
            fun ack(): String = result(id, emptyMap<String, Any?>())
        }

        class Call(val id: Any?, val name: String, val args: Map<String, Any?>, val caller: PhoneCaller?, private val server: McpServer) : Dispatch {
            /** Runs the tool (blocking) and returns the response line. */
            fun run(handler: ((String, Map<String, Any?>, PhoneCaller?) -> ToolOutput)? = null): String =
                server.runCall(id, name, args, caller, handler)

            internal fun runWithCommit(commit: PhoneReplyCommit,
                handler: (String, Map<String, Any?>, PhoneCaller?) -> ToolOutput): String =
                server.runCall(id, name, args, caller, handler, commit)
        }
    }

    /** Synchronous convenience: dispatch and run any tool call inline. */
    fun handle(line: String): String? = when (val d = dispatch(line)) {
        Dispatch.None -> null
        is Dispatch.Reply -> d.line
        is Dispatch.Call -> d.run()
        is Dispatch.RunEnd -> null
    }

    fun dispatch(line: String): Dispatch {
        if (line.isBlank()) return Dispatch.None
        val msg = try {
            Json.parse(line)
        } catch (e: Json.JsonException) {
            return Dispatch.Reply(error(null, PARSE_ERROR, "Parse error"))
        }
        if (msg !is Map<*, *>) return Dispatch.Reply(error(null, INVALID_REQUEST, "Invalid Request"))
        val hasId = msg.containsKey("id")
        val id = msg["id"]
        val method = msg["method"] as? String
        if (method == null) {
            // A response to a request we never send, or garbage: nothing to answer unless it carries an id.
            return if (hasId && !msg.containsKey("result") && !msg.containsKey("error")) {
                Dispatch.Reply(error(id, INVALID_REQUEST, "Invalid Request"))
            } else {
                Dispatch.None
            }
        }
        if (!hasId) return Dispatch.None
        val params = msg["params"] as? Map<*, *> ?: emptyMap<String, Any?>()
        return when (method) {
            "initialize" -> Dispatch.Reply(result(id, initializeResult(params["protocolVersion"] as? String)))
            "ping" -> Dispatch.Reply(result(id, emptyMap<String, Any?>()))
            "tools/list" -> Dispatch.Reply(result(id, mapOf("tools" to tools)))
            "dsh-go/phone-run-end" -> {
                val session = PhoneCaller.identifier(params["sessionId"])
                val run = PhoneCaller.identifier(params["runId"])
                val completion = if (params.containsKey("completion")) params["completion"] else "unknown"
                if (params["v"] != 1L || session == null || run == null || completion !in setOf("completed", "other", "unknown")) {
                    Dispatch.Reply(error(id, INVALID_PARAMS, "Invalid phone run end context"))
                } else Dispatch.RunEnd(id, session, run, completion as String)
            }
            "tools/call" -> {
                val name = params["name"] as? String
                    ?: return Dispatch.Reply(error(id, INVALID_PARAMS, "tools/call needs a tool name"))
                @Suppress("UNCHECKED_CAST")
                val args = (params["arguments"] as? Map<String, Any?>) ?: emptyMap()
                val rawMeta = params["_meta"]
                if (rawMeta != null && rawMeta !is Map<*, *>) {
                    return Dispatch.Reply(error(id, INVALID_PARAMS, "Invalid call metadata"))
                }
                val meta = rawMeta as? Map<*, *>
                val caller = if (meta?.containsKey(PhoneCaller.META_KEY) == true) {
                    PhoneCaller.parse(meta[PhoneCaller.META_KEY])
                        ?: return Dispatch.Reply(error(id, INVALID_PARAMS, "Invalid phone caller context"))
                } else null
                Dispatch.Call(id, name, args, caller, this)
            }
            else -> Dispatch.Reply(error(id, METHOD_NOT_FOUND, "Method not found"))
        }
    }

    private fun initializeResult(requested: String?): Map<String, Any?> = linkedMapOf(
        "protocolVersion" to (requested?.takeIf { it in KNOWN_VERSIONS } ?: LATEST_VERSION),
        "capabilities" to mapOf(
            "tools" to mapOf("listChanged" to false),
            "experimental" to mapOf(PhoneCaller.META_KEY to mapOf("v" to 1, "taskIsolation" to 1, "parallelLimit" to 1, "runLifecycle" to 1,
                "backgroundParallelism" to mapOf("v" to 1, "maxLimit" to 3, "defaultLimit" to 1))),
        ),
        "serverInfo" to linkedMapOf("name" to "dsh-app-phone", "version" to serverVersion),
    )

    internal fun runCall(id: Any?, name: String, args: Map<String, Any?>, caller: PhoneCaller?, handler: ((String, Map<String, Any?>, PhoneCaller?) -> ToolOutput)? = null,
                         nativeReplyCommit: PhoneReplyCommit? = null): String {
        val out = try {
            (handler ?: call)(name, args, caller)
        } catch (e: Throwable) {
            // l10n:keep agent tool error
            ToolOutput("手机操控出错：${e.javaClass.simpleName}${e.message?.let { "：$it" } ?: ""}", isError = true)
        }
        val line = result(id, toolResult(out))
        // Only the exact, fully encoded original response can bind its displayed focus evidence.
        if (!out.isError && nativeReplyCommit != null && out.focusObservation?.bind(nativeReplyCommit) == true)
            out.nativeReplyCommit = nativeReplyCommit
        if (nativeReplyCommit != null && out.nativeReplyCommit === nativeReplyCommit)
            nativeReplyCommit.encoded()
        return line
    }

    companion object {
        const val PARSE_ERROR = -32700
        const val INVALID_REQUEST = -32600
        const val METHOD_NOT_FOUND = -32601
        const val INVALID_PARAMS = -32602

        /** Revisions whose tools surface is what we serve; anything else gets [LATEST_VERSION]. */
        val KNOWN_VERSIONS = listOf("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25")
        const val LATEST_VERSION = "2025-11-25"

        fun toolResult(out: ToolOutput): Map<String, Any?> {
            val content = ArrayList<Map<String, Any?>>()
            content += linkedMapOf("type" to "text", "text" to out.text)
            val image = out.image
            if (image != null && out.imageMime != null) {
                content += linkedMapOf(
                    "type" to "image",
                    "data" to java.util.Base64.getEncoder().encodeToString(image),
                    "mimeType" to out.imageMime,
                )
            }
            return linkedMapOf("content" to content, "isError" to out.isError)
        }

        fun result(id: Any?, result: Any?): String = Json.write(linkedMapOf("jsonrpc" to "2.0", "id" to id, "result" to result))

        fun error(id: Any?, code: Int, message: String): String =
            Json.write(linkedMapOf("jsonrpc" to "2.0", "id" to id, "error" to linkedMapOf("code" to code, "message" to message)))
    }
}
