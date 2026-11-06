package com.skyjjgw.independent.ski

import android.os.Build
import androidx.test.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.skivu.engine.adb.EmbeddedAdbEngine
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Opt-in on the disposable paired emulator only. Never resets grants or credentials. */
class EmbeddedAdbAcceptanceTest {
    @Before fun emulatorOnly() {
        assertEquals("emulator-5554", InstrumentationRegistry.getArguments().getString("skivuEngineAcceptance"))
        assertTrue(Build.HARDWARE in setOf("ranchu", "goldfish"))
    }
    private fun engine() = EmbeddedAdbEngine(InstrumentationRegistry.getTargetContext())
    private fun marker() = "/data/local/tmp/skivu-owned-qa-${UUID.randomUUID().toString().replace("-", "") }"
    private fun checkGone(engine: EmbeddedAdbEngine, file: String) {
        val proof = engine.execute("""
            read -r skivu_parent skivu_child < '$file'
            for skivu_pid in "${'$'}skivu_parent" "${'$'}skivu_child"; do
              [ ! -d /proc/${'$'}skivu_pid ] || { echo LIVE; exit 42; }
            done
            [ ! -f '$file.finished' ] || { echo FINISHED; exit 43; }
            printf 'OWNED_PROCESSES_GONE\n'
        """.trimIndent(), 10)
        assertEquals(proof.toString(), 0, proof["exitCode"])
        assertEquals("OWNED_PROCESSES_GONE", proof["stdout"].toString().trim())
    }
    private fun script(file: String) = """
        sleep 90 &
        skivu_child=${'$'}!
        printf '%s %s\n' "${'$'}${'$'}" "${'$'}skivu_child" > '$file'
        wait "${'$'}skivu_child"
        printf done > '$file.finished'
    """.trimIndent()
    private fun cleanup(engine: EmbeddedAdbEngine, file: String) {
        engine.execute("rm -f -- '$file' '$file.finished'", 10)
    }

    @Test fun preservesMultilineOutputAndActualExit() {
        val engine = engine()
        try {
            val result = engine.execute("printf '%s\\n' 'line one' 'quoted \"line\"'\nexit 7", 10)
            assertEquals(2000, result["uid"])
            assertEquals(7, result["exitCode"])
            assertEquals("line one\nquoted \"line\"\n", result["stdout"])
            assertEquals("", result["stderr"])
        } finally { engine.close() }
    }

    @Test fun timeoutReapsParentAndChildBeforeNextCommand() {
        val engine = engine()
        val file = marker()
        try {
            try { engine.execute(script(file), 3); fail("Expected actual timeout") }
            catch (expected: IllegalStateException) { assertTrue(expected.message.orEmpty().contains("超时")) }
            assertEquals("cancelled", engine.awaitCleanup()["outcome"])
            checkGone(engine, file)
        } finally { cleanup(engine, file); engine.close() }
    }

    @Test fun stoppingOneSessionLeavesAnotherSessionRunning() {
        val first = engine(); val second = engine(); val observer = engine()
        val firstFile = marker(); val secondFile = marker()
        val workers = Executors.newFixedThreadPool(2)
        val firstRun = workers.submit<Map<String, Any?>> { first.execute(script(firstFile), 120) }
        val secondRun = workers.submit<Map<String, Any?>> { second.execute(script(secondFile), 120) }
        try {
            var ready = false
            for (attempt in 0 until 20) {
                val result = observer.execute("test -s '$firstFile' && test -s '$secondFile'", 10)
                if (result["exitCode"] == 0) { ready = true; break }
                Thread.sleep(100)
            }
            assertTrue("Both real sessions must have started", ready)
            assertEquals("cancelled", first.awaitStop(first.stop())["outcome"])
            checkGone(observer, firstFile)
            assertFalse("Another session must not be stopped", secondRun.isDone)
            val living = observer.execute("read -r p c < '$secondFile'; kill -0 \"${'$'}p\" && kill -0 \"${'$'}c\"", 10)
            assertEquals(0, living["exitCode"])
            assertEquals("cancelled", second.awaitStop(second.stop())["outcome"])
            checkGone(observer, secondFile)
        } finally {
            first.awaitStop(first.stop()); second.awaitStop(second.stop())
            try { firstRun.get(10, TimeUnit.SECONDS) } catch (_: Exception) {}
            try { secondRun.get(10, TimeUnit.SECONDS) } catch (_: Exception) {}
            cleanup(observer, firstFile); cleanup(observer, secondFile)
            workers.shutdownNow(); first.close(); second.close(); observer.close()
        }
    }
}
