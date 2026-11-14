package com.skyjjgw.independent.ski.dshgo.phone

import org.junit.Assert.*
import org.junit.Test

class PhoneCallerTest {
    private fun request(id: Int, caller: Any?, includeCaller: Boolean = true, args: Map<String, Any?> = emptyMap()): String =
        Json.write(mapOf("jsonrpc" to "2.0", "id" to id, "method" to "tools/call", "params" to buildMap {
            put("name", "screen")
            put("arguments", args)
            if (includeCaller) put("_meta", mapOf(PhoneCaller.META_KEY to caller))
        }))

    private fun caller(session: String, run: String = "run-$session"): Map<String, Any?> =
        mapOf("v" to 1, "sessionId" to session, "runId" to run, "callId" to "call-$session")

    @Test fun dispatchKeepsEachCallerEvenWhenAnotherCallRunsFirst() {
        val seen = mutableListOf<PhoneCaller?>()
        val server = McpServer(emptyList(), { _, _, owner -> seen += owner; ToolOutput("ok") })
        val a = server.dispatch(request(1, caller("A"))) as McpServer.Dispatch.Call
        val b = server.dispatch(request(2, caller("B"))) as McpServer.Dispatch.Call
        b.run()
        a.run()
        assertEquals(listOf("B", "A"), seen.map { it?.sessionId })
        assertEquals(listOf("run-B", "run-A"), seen.map { it?.runId })
        assertEquals(PhoneCaller("A", "run-A", "call-A"), a.caller)
    }

    @Test fun legacyDoesNotBorrowIdentityFromArgumentsOrPreviousCall() {
        val seen = mutableListOf<PhoneCaller?>()
        val server = McpServer(emptyList(), { _, _, owner -> seen += owner; ToolOutput("ok") })
        server.handle(request(1, caller("A")))
        server.handle(request(2, null, includeCaller = false, args = mapOf(
            "sessionId" to "A", "_meta" to mapOf(PhoneCaller.META_KEY to caller("A")),
        )))
        assertEquals("A", seen[0]?.sessionId)
        assertNull(seen[1])
    }

    @Test fun malformedOrUnsupportedCallerNeverExecutesAndNeverBecomesLegacy() {
        var calls = 0
        val server = McpServer(emptyList(), { _, _, _ -> calls++; ToolOutput("ok") })
        val invalid = listOf(null, "A", caller("A") + ("v" to 2), caller(""),
            caller("A") + ("runId" to "x".repeat(257)), caller("A") + ("callId" to "x\ny"))
        for ((i, value) in invalid.withIndex()) {
            val reply = Json.parse(server.handle(request(i, value))!!) as Map<*, *>
            assertEquals(McpServer.INVALID_PARAMS.toLong(), (reply["error"] as Map<*, *>)["code"])
        }
        assertEquals(0, calls)
    }

    @Test fun capabilityReportsEnabledIsolationAndCatalogIsUnchanged() {
        val tools = listOf(mapOf("name" to "screen", "description" to "same catalog"))
        val server = McpServer(tools, { _, _, _ -> ToolOutput("ok") })
        fun result(method: String): Map<*, *> {
            val reply = server.handle(Json.write(mapOf("jsonrpc" to "2.0", "id" to 1, "method" to method)))!!
            return (Json.parse(reply) as Map<*, *>)["result"] as Map<*, *>
        }
        val capability = ((result("initialize")["capabilities"] as Map<*, *>)["experimental"] as Map<*, *>)[PhoneCaller.META_KEY] as Map<*, *>
        assertEquals(1L, capability["v"])
        assertEquals(1L, capability["taskIsolation"])
        assertEquals(1L, capability["parallelLimit"])
        assertEquals(mapOf("v" to 1L, "maxLimit" to 3L, "defaultLimit" to 1L), capability["backgroundParallelism"])
        assertEquals(tools, result("tools/list")["tools"])
        val callResult = server.handle(request(2, caller("A")))!!
        assertFalse(callResult.contains("run-A"))
        assertFalse(callResult.contains(PhoneCaller.META_KEY))
    }
    @Test fun runEndIsAPrivateAckRequestAndMalformedIdentityIsNotLegacy() {
        var calls = 0
        val server = McpServer(emptyList(), { _, _, _ -> calls++; ToolOutput("unexpected") })
        val params = mapOf("v" to 1, "sessionId" to "A", "runId" to "epoch:1")
        fun wire(value: Any?, id: Boolean = true) = Json.write(buildMap<String, Any?> {
            put("jsonrpc", "2.0"); if (id) put("id", 5); put("method", "dsh-go/phone-run-end"); put("params", value)
        })
        val end = server.dispatch(wire(params)) as McpServer.Dispatch.RunEnd
        assertEquals("A", end.sessionId); assertEquals("epoch:1", end.runId); assertEquals("unknown", end.completion)
        val ack = Json.parse(end.ack()) as Map<*, *>
        assertEquals(5L, ack["id"]); assertEquals(emptyMap<String, Any?>(), ack["result"])
        assertSame(McpServer.Dispatch.None, server.dispatch(wire(params, id = false)))
        for (bad in listOf(null, params + ("v" to 2), params + ("sessionId" to ""), params + ("runId" to "x\ny"), params + ("completion" to "success"), params + ("completion" to null), params + ("completion" to mapOf("kind" to "completed")))) {
            val reply = server.dispatch(wire(bad)) as McpServer.Dispatch.Reply
            assertEquals(McpServer.INVALID_PARAMS.toLong(), ((Json.parse(reply.line) as Map<*, *>)["error"] as Map<*, *>)["code"])
        }
        assertEquals(0, calls)
    }

    @Test fun onlyExactLifecycleIntegerEnablesModernAttribution() {
        val server = McpServer(emptyList(), { _, _, _ -> ToolOutput("ok") })
        val absent = server.dispatch(request(1, caller("A"))) as McpServer.Dispatch.Call
        assertEquals(0, absent.caller!!.runLifecycle)
        for (version in listOf(0, 1)) {
            val call = server.dispatch(request(2, caller("A") + ("runLifecycle" to version))) as McpServer.Dispatch.Call
            assertEquals(version, call.caller!!.runLifecycle)
        }
        // Preserve wire token types: Json.write normalizes the Double 1.0 to the valid integer 1.
        for (invalid in listOf("null", "false", "true", "\"1\"", "1.0", "2", "-1")) {
            val wire = """
                {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{
                  "name":"screen","arguments":{},"_meta":{
                    "${PhoneCaller.META_KEY}":{"v":1,"sessionId":"A","runId":"run-A","callId":"call-A","runLifecycle":$invalid}
                  }
                }}
            """.trimIndent()
            val reply = server.dispatch(wire) as McpServer.Dispatch.Reply
            assertEquals(McpServer.INVALID_PARAMS.toLong(), ((Json.parse(reply.line) as Map<*, *>)["error"] as Map<*, *>)["code"])
        }
    }

}
