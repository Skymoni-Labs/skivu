package com.skyjjgw.independent.ski

import android.os.Build
import androidx.test.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.net.ServerSocket
import java.security.MessageDigest
import java.util.UUID

class CloudNetworkAcceptanceTest {
    private val context get()=InstrumentationRegistry.getTargetContext()
    private val owner="qa:network:"+UUID.randomUUID();private val task="network";private var serial=0
    @Suppress("UNCHECKED_CAST") private fun call(tool:String,args:Map<String,Any?> = emptyMap()):Map<String,Any?> {
        check(context.packageName.endsWith(".engineqa")&&Build.HARDWARE in setOf("ranchu","goldfish"))
        val result=CloudRuntime.invoke(context,"coding.$tool",args,owner,task,"network_${++serial}");assertEquals(result.toString(),"verified",result["outcome"]);return result["value"] as Map<String,Any?>
    }
    private fun done(job:Map<String,Any?>)=call("jobs.wait",mapOf("jobId" to job["id"]))
    @Test(timeout=240000) fun interruptedHttpDownloadResumesMatchingVersionAndPublishesRealPhoneFile() {
        val project=call("projects.create",mapOf("name" to "HTTP download recovery"))["id"] as String
        val data="item,中文😀,42\n".repeat(180000).toByteArray();val sha=MessageDigest.getInstance("SHA-256").digest(data).joinToString(""){"%02x".format(it)}
        val server=ServerSocket(0,8,java.net.InetAddress.getByName("127.0.0.1"));val requests=java.util.concurrent.CopyOnWriteArrayList<Map<String,String>>()
        val running=java.util.concurrent.atomic.AtomicBoolean(true)
        val thread=Thread {
            while(running.get())try{server.accept().use{socket->val input=socket.getInputStream().bufferedReader();input.readLine();val headers=mutableMapOf<String,String>();while(true){val line=input.readLine()?:break;if(line.isEmpty())break;val at=line.indexOf(':');if(at>0)headers[line.substring(0,at).lowercase()]=line.substring(at+1).trim()};requests.add(headers)
                val start=headers["range"]?.removePrefix("bytes=")?.removeSuffix("-")?.toInt()?:0;val partial=start>0;val output=socket.getOutputStream()
                val header="HTTP/1.1 ${if(partial)"206 Partial Content"else"200 OK"}\r\nContent-Length: ${data.size-start}\r\nETag: \"qa-v1\"\r\nContent-Type: text/csv\r\nConnection: close\r\n"+(if(partial)"Content-Range: bytes $start-${data.lastIndex}/${data.size}\r\n"else"")+"\r\n"
                output.write(header.toByteArray());output.write(data,start,if(requests.size==1)1200000 else data.size-start);output.flush()
            }}catch(error:Exception){if(running.get())throw error}
        }.apply{isDaemon=true;start()}
        try{
            val args=mapOf("projectId" to project,"url" to "http://127.0.0.1:${server.localPort}/data.csv","path" to "data.csv","sha256" to sha)
            val first=done(call("download.start",args));assertNotEquals(0,(first["exitCode"] as Number).toInt())
            val progress=first["progress"] as Map<*,*>;assertEquals("interrupted",progress["state"]);val retained=(progress["bytes"] as Number).toLong();assertTrue(retained>0);assertEquals("\"qa-v1\"",progress["etag"])
            val second=done(call("download.start",args));assertEquals(second.toString(),0,(second["exitCode"] as Number).toInt());assertEquals("bytes=$retained-",requests[1]["range"]);assertEquals("\"qa-v1\"",requests[1]["if-range"])
            val file=File(context.filesDir,"cloud-projects/$project/data.csv");assertArrayEquals(data,file.readBytes())
            val manifest=call("deliver.prepare",mapOf("projectId" to project,"files" to listOf(mapOf("path" to "data.csv","purpose" to "真实下载并核对的数据"))))
            val delivery=CloudArtifacts(context).publish(manifest,owner,task,"network_deliver");assertEquals(1,(delivery["count"] as Number).toInt());assertEquals(0L,(delivery["failedCount"] as Number).toLong());val record=(delivery["artifacts"] as List<*>).single() as Map<*,*>;assertEquals("saved",record["phoneSaveState"])
            File(context.filesDir,"qa-download-acceptance.json").writeText(org.json.JSONObject(mapOf("bytes" to data.size,"retainedBytes" to retained,"sha256" to sha,"range" to requests[1]["range"],"phonePath" to record["phonePath"],"phoneUri" to record["phoneUri"])).toString())
        }finally{running.set(false);server.close();thread.join(3000)}
    }
    @Test(timeout=300000) fun realPublicNpmDependencyInstallsAndRunsInEmbeddedLinux() {
        val project=call("projects.create",mapOf("name" to "Real npm dependency"))["id"] as String
        call("files.write",mapOf("projectId" to project,"path" to "package.json","content" to "{\"name\":\"skivu-qa-network\",\"version\":\"1.0.0\",\"private\":true}"))
        val install=done(call("exec.start",mapOf("projectId" to project,"command" to "npm install is-number@7.0.0 --no-audit --no-fund","timeoutMs" to 240000)))
        assertEquals(install.toString(),0,(install["exitCode"] as Number).toInt())
        val checked=done(call("exec.start",mapOf("projectId" to project,"command" to "node -e \"if(!require('is-number')('12.5'))process.exit(1);console.log('DEPENDENCY_OK')\"")))
        assertEquals(0,(checked["exitCode"] as Number).toInt());assertTrue((checked["stdout"] as Map<*,*>)["text"].toString().contains("DEPENDENCY_OK"))
        File(context.filesDir,"qa-npm-acceptance.json").writeText(org.json.JSONObject(mapOf("projectId" to project,"package" to "is-number@7.0.0","installExitCode" to install["exitCode"],"checkExitCode" to checked["exitCode"],"stdout" to (checked["stdout"] as Map<*,*>)["text"])).toString())
    }
}
