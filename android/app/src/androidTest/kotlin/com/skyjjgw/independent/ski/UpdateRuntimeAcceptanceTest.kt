package com.skyjjgw.independent.ski

import android.os.Build
import androidx.test.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class UpdateRuntimeAcceptanceTest {
    @Test(timeout=900000) fun publishedArchiveInstallsIntoFreshHostAndExecutesNode() {
        val context=InstrumentationRegistry.getTargetContext()
        assertEquals("com.skyjjgw.independent.ski.updateqa",context.packageName)
        assertTrue(Build.HARDWARE in setOf("ranchu","goldfish"))
        val abi=Build.SUPPORTED_ABIS.first{it=="x86_64"||it=="arm64-v8a"}
        assertFalse(context.assets.list("cloud-runtime/$abi").orEmpty().contains("runtime.bin"))
        val metadata=JSONObject(context.assets.open("cloud-runtime/$abi/runtime.json").bufferedReader().use{it.readText()})
        val sha=metadata.getString("sha256")
        assertFalse("Fresh package is required for this acceptance",File(context.filesDir,"runtimes/$sha/.installed").exists())
        val owner="qa:update:"+UUID.randomUUID();val task="update-runtime"
        var serial=0
        @Suppress("UNCHECKED_CAST")
        fun call(tool:String,args:Map<String,Any?> = emptyMap()):Map<String,Any?>{
            val result=CloudRuntime.invoke(context,"coding.$tool",args,owner,task,"update_${++serial}")
            assertEquals(result.toString(),"verified",result["outcome"])
            return result["value"] as Map<String,Any?>
        }
        val project=call("projects.create",mapOf("name" to "Fresh verified runtime"))["id"] as String
        var job=call("exec.start",mapOf("projectId" to project,"command" to "node -e \"console.log(process.version);console.log(6*7)\""))
        while(job["state"]=="running")job=call("jobs.read",mapOf("jobId" to job["id"],"waitMs" to 1000))
        assertEquals(0,(job["exitCode"] as Number).toInt())
        val output=(job["stdout"] as Map<*,*>)["text"].toString()
        assertTrue(output.contains("v24."))
        assertTrue(output.lineSequence().any{it=="42"})
        val status=CloudRuntime.status()
        assertEquals("ready",status["phase"])
        assertEquals(metadata.getLong("size"),(status["downloadedBytes"] as Number).toLong())
        assertEquals(sha,File(context.filesDir,"runtimes/$sha/.installed").readText())
        val before=(status["downloadedBytes"] as Number).toLong()
        val reused=CloudRuntimeInstaller(context).install(downloadProgress={_,_->fail("Existing runtime was downloaded again")})
        assertEquals(sha,reused.name)
        File(context.filesDir,"qa-update-runtime-proof.json").writeText(JSONObject(mapOf("abi" to abi,"sha256" to sha,"downloadedBytes" to before,"jobExitCode" to job["exitCode"],"stdout" to output,"runtimeReused" to true,"archiveBundled" to false,"projectId" to project)).toString())
    }
}
