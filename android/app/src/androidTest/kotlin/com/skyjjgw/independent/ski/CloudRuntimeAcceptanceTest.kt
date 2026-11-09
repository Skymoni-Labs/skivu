package com.skyjjgw.independent.ski

import android.os.Build
import androidx.test.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.UUID

/** Real bundled PRoot + Linux Node, no model mocks and no independent DSH use. */
class CloudRuntimeAcceptanceTest {
    private lateinit var context:android.content.Context
    private val owner="qa:cloud:"+UUID.randomUUID().toString().replace("-","")
    private val task="task_"+UUID.randomUUID().toString().replace("-","")
    private var count=0
    @Before fun setup(){context=InstrumentationRegistry.getTargetContext();assertTrue(context.packageName.endsWith(".engineqa"));assertTrue(Build.HARDWARE in setOf("ranchu","goldfish"))}
    private fun request(tool:String,args:Map<String,Any?> = emptyMap(),key:String="qa_${task}_${++count}")=CloudRuntime.invoke(context,"coding.$tool",args,owner,task,key)
    @Suppress("UNCHECKED_CAST") private fun call(tool:String,args:Map<String,Any?> = emptyMap()):Map<String,Any?>{val r=request(tool,args);assertEquals(r.toString(),"verified",r["outcome"]);return r["value"] as Map<String,Any?>}
    private fun project()=call("projects.create",mapOf("name" to "QA built-in coding"))["id"] as String
    private fun write(p:String,path:String,content:String,sha:String?=null)=call("files.write",mutableMapOf<String,Any?>("projectId" to p,"path" to path,"content" to content).apply{if(sha!=null)put("expectedSha256",sha)})
    private fun finish(value:Map<String,Any?>):Map<String,Any?>{var job=value;for(i in 0..30){if(job["state"]!="running")return job;job=call("jobs.read",mapOf("jobId" to job["id"],"waitMs" to 1000))};error("job did not finish")}
    @Test fun embeddedEnvironmentRunsMultiFileFailureRepairAndExplicitFinalManifest(){
        val environment=call("environment");File(context.filesDir,"qa-environment.json").writeText(org.json.JSONObject(environment).toString());assertTrue(environment["node"].toString().startsWith("v24."));val p=project()
        write(p,"lib/add.mjs","export const add=(a,b)=>a-b;\n")
        write(p,"test.mjs","import {add} from './lib/add.mjs';if(add(2,3)!==5)throw Error('intentional failing sum');console.log('CHECK_OK');\n")
        val first=finish(call("exec.start",mapOf("projectId" to p,"command" to "node test.mjs")))
        assertEquals("exited",first["state"]);assertTrue((first["exitCode"] as Number).toInt()!=0);assertTrue((first["stderr"] as Map<*,*>)["text"].toString().contains("intentional failing sum"))
        val original=call("files.read",mapOf("projectId" to p,"path" to "lib/add.mjs"))
        call("files.edit",mapOf("projectId" to p,"path" to "lib/add.mjs","oldText" to "a-b","newText" to "a+b","expectedSha256" to original["sha256"]))
        val repaired=finish(call("exec.start",mapOf("projectId" to p,"command" to "node test.mjs")))
        assertEquals(0,(repaired["exitCode"] as Number).toInt());assertTrue((repaired["stdout"] as Map<*,*>)["text"].toString().contains("CHECK_OK"))
        write(p,"result.txt","Final checked result: 5\n");write(p,"debug.log","not a deliverable\n")
        val manifest=call("deliver.prepare",mapOf("projectId" to p,"files" to listOf(mapOf("path" to "result.txt","purpose" to "最终核对结果"))))
        val artifacts=CloudArtifacts(context);val result=artifacts.publish(manifest,owner,task,"deliver_qa_$task")
        assertEquals(1,(result["artifacts"] as List<*>).size)
        val record=(result["artifacts"] as List<*>).single() as Map<*,*>;assertEquals("result.txt",record["name"])
        val (file,_)=artifacts.file(record["id"] as String);assertEquals("Final checked result: 5\n",file.readText())
        val repeated=artifacts.publish(manifest,owner,task,"deliver_qa_$task")["artifacts"] as List<*>;assertEquals(1,repeated.size);assertEquals(record["id"],(repeated.single() as Map<*,*>)["id"])
        val final=call("files.read",mapOf("projectId" to p,"path" to "result.txt"));write(p,"result.txt","changed source",final["sha256"] as String)
        assertEquals("Final checked result: 5\n",artifacts.file(record["id"] as String).first.readText())
        val again=call("deliver.prepare",mapOf("projectId" to p,"files" to listOf(mapOf("path" to "result.txt","purpose" to "新版本"),mapOf("path" to "missing.txt","purpose" to "不存在的成果"))))
        val version=artifacts.publish(again,owner,task,"deliver_second_$task");assertEquals(1,(version["artifacts"] as List<*>).size);assertEquals(1,(version["failed"] as List<*>).size)
        assertEquals(2,((version["artifacts"] as List<*>).single() as Map<*,*>)["version"])
        val nextRecord=(version["artifacts"] as List<*>).single() as Map<*,*>;assertNotEquals(record["phoneUri"],nextRecord["phoneUri"])
        assertTrue(CloudPhoneFiles(context).verifySavedCopy(android.net.Uri.parse(record["phoneUri"] as String),artifacts.file(record["id"] as String).first))
    }
    @Test fun cancellationIsOwnedOutputContinuesAndRequestsDoNotReplay(){
        val p=project();val other=project()
        val a=call("exec.start",mapOf("projectId" to p,"command" to "node -e \"let n=0;setInterval(()=>console.log(++n),100)\""))
        val b=call("exec.start",mapOf("projectId" to other,"command" to "node -e \"let n=0;setInterval(()=>console.log(++n),100)\""))
        val rejected=CloudRuntime.invoke(context,"coding.jobs.stop",mapOf("jobId" to a["id"]),"qa:another",task,"other_$task");assertEquals("failed",rejected["outcome"])
        val stopped=call("jobs.stop",mapOf("jobId" to a["id"]));assertEquals("stopped",stopped["state"])
        val running=call("jobs.read",mapOf("jobId" to b["id"],"waitMs" to 800));assertEquals("running",running["state"]);assertTrue((running["stdout"] as Map<*,*>)["text"].toString().isNotBlank())
        assertEquals("stopped",call("jobs.stop",mapOf("jobId" to b["id"]))["state"])
        val key="once_$task";val args=mapOf("projectId" to p,"command" to "echo once >> once.txt")
        val first=request("exec.start",args,key);val second=request("exec.start",args,key);assertEquals((first["value"] as Map<*,*>)["id"],(second["value"] as Map<*,*>)["id"])
        finish((first["value"] as Map<String,Any?>));assertEquals("once\n",call("files.read",mapOf("projectId" to p,"path" to "once.txt"))["text"])
    }
    @Test fun staleFileHashesAndTraversalAreRejected(){
        val p=project();write(p,"file.txt","a")
        write(p,"root.mjs","root");write(p,"nested/test.mjs","nested")
        val glob=request("files.glob",mapOf("projectId" to p,"pattern" to "**/*.mjs"));assertEquals("verified",glob["outcome"]);assertEquals(2,((glob["value"] as Map<*,*>)["items"] as List<*>).size)
        call("files.read",mapOf("projectId" to p,"path" to "file.txt"))
        File(context.filesDir,"cloud-projects/$p/file.txt").writeText("external change")
        assertEquals("failed",request("files.write",mapOf("projectId" to p,"path" to "file.txt","content" to "overwrite"))["outcome"])
        assertEquals("failed",request("files.read",mapOf("projectId" to p,"path" to "../cloud-home/secret"))["outcome"])
        assertEquals("failed",request("deliver.prepare",mapOf("projectId" to p,"files" to emptyList<Any>()))["outcome"])
        assertEquals("external change",call("files.read",mapOf("projectId" to p,"path" to "file.txt"))["text"])
    }
    @Test fun blankWorkbookUsesTheRealWriterAndPreservesOverwriteGuards(){
        val p=project();val created=call("workbook.create",mapOf("projectId" to p,"path" to "blank.xlsx"))
        assertEquals(true,created["blank"]);assertEquals(1,(created["sheets"] as Number).toInt());assertTrue((created["bytes"] as Number).toLong()>0)
        assertEquals("failed",request("workbook.create",mapOf("projectId" to p,"path" to "blank.xlsx"))["outcome"])
        assertEquals(created["sha256"],call("files.read",mapOf("projectId" to p,"path" to "blank.xlsx"))["sha256"])
        assertEquals("failed",request("workbook.create",mapOf("projectId" to p,"path" to "fake.csv"))["outcome"])
        val manifest=call("deliver.prepare",mapOf("projectId" to p,"files" to listOf(mapOf("path" to "blank.xlsx","purpose" to "最终空白Excel"))))
        val artifacts=CloudArtifacts(context);val delivery=artifacts.publish(manifest,owner,task,"blank_$task");val record=(delivery["artifacts"] as List<*>).single() as Map<*,*>
        val preview=artifacts.preview(record["id"] as String);assertEquals("text",preview["kind"]);assertTrue(preview["text"].toString().contains("[Sheet1]"));assertEquals(true,preview["complete"])
        File(context.filesDir,"qa-blank-artifact.json").writeText(org.json.JSONObject(record).toString())
        assertEquals("saved",record["phoneSaveState"]);assertTrue(record["phonePath"].toString().startsWith("Download/Skivu/"))
        val uri=android.net.Uri.parse(record["phoneUri"] as String);assertTrue(CloudPhoneFiles(context).verifySavedCopy(uri,artifacts.file(record["id"] as String).first))
        val again=artifacts.publish(manifest,owner,task,"blank_$task");assertEquals(record["phoneUri"],((again["artifacts"] as List<*>).single() as Map<*,*>)["phoneUri"])
        val intent=artifacts.openIntent(record["id"] as String,false);assertEquals(android.content.Intent.ACTION_VIEW,intent.action);assertEquals(uri,intent.data);assertEquals("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",intent.type);assertTrue(intent.flags and android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION!=0)
        context.contentResolver.openOutputStream(uri,"w")!!.use{it.write("edited phone copy".toByteArray())}
        assertEquals("changed",CloudPhoneFiles(context).inspect(record["id"] as String)["phoneSaveState"])
        assertEquals(uri,artifacts.openIntent(record["id"] as String,false).data)
        assertTrue(artifacts.preview(record["id"] as String)["kind"]=="text")
        assertEquals(1,context.contentResolver.delete(uri,null,null));assertEquals("missing",CloudPhoneFiles(context).inspect(record["id"] as String)["phoneSaveState"])
        try{artifacts.openIntent(record["id"] as String,false);fail("deleted phone file was silently recreated")}catch(_:IllegalStateException){}
    }
    @Test fun genuineWorkbookDocumentAndOnlyExplicitFinalFilesArePublished(){
        val p=project()
        val script="""
            import fs from 'node:fs';
            import {writeWorkbook,writeDocument} from '/opt/skivu-cloud/formats.mjs';
            writeWorkbook('final.xlsx',[{name:'数据',rows:[[{value:'项目',bold:true},{value:'数值',bold:true}],['一',2],['二',3],['合计',{formula:'SUM(B2:B3)',value:5,format:'0.00'}]],widths:[20,16],freezeRows:1},{name:'说明',rows:[['验证','实际生成的工作簿']]}]);
            writeDocument('final.docx',[{text:'小云实际成果',heading:1},{text:'已完成真实运行和检查。'}]);
            for(let i=0;i<20;i++)fs.writeFileSync('intermediate-'+i+'.txt','process only');
            fs.writeFileSync('fake.xlsx','a,b\\n1,2');
            console.log('FILES_READY');
        """.trimIndent()
        write(p,"produce.mjs",script)
        val done=finish(call("exec.start",mapOf("projectId" to p,"command" to "node produce.mjs")));assertEquals(0,(done["exitCode"] as Number).toInt())
        val manifest=call("deliver.prepare",mapOf("projectId" to p,"files" to listOf(mapOf("path" to "final.xlsx","purpose" to "最终表格"),mapOf("path" to "final.docx","purpose" to "最终文档"))))
        val artifacts=CloudArtifacts(context);val delivered=artifacts.publish(manifest,owner,task,"office_$task");val finalFiles=delivered["artifacts"] as List<*>;assertEquals(2,finalFiles.size);assertEquals(0,(delivered["failed"] as List<*>).size)
        val workbook=finalFiles.map{it as Map<*,*>}.single{it["format"]=="xlsx"};assertEquals(2,(workbook["sheets"] as Number).toInt());assertEquals("text",artifacts.preview(workbook["id"] as String)["kind"])
        val document=finalFiles.map{it as Map<*,*>}.single{it["format"]=="docx"};assertTrue(artifacts.preview(document["id"] as String)["text"].toString().contains("小云实际成果"))
        val fake=call("deliver.prepare",mapOf("projectId" to p,"files" to listOf(mapOf("path" to "fake.xlsx","purpose" to "无效格式"))))
        val rejected=artifacts.publish(fake,owner,task,"invalid_$task");assertEquals(0,(rejected["artifacts"] as List<*>).size);assertEquals(1,(rejected["failed"] as List<*>).size)
        File(context.filesDir,"qa-office-artifacts.json").writeText(org.json.JSONObject(mapOf("workbook" to workbook["id"],"document" to document["id"],"projectId" to p)).toString())
    }
    @Test fun prepareRealLongJobRecoveryCheckpoint(){
        val p=project();val value=call("exec.start",mapOf("projectId" to p,"command" to "echo started >> recovery.txt; node -e \"setInterval(()=>{},1000)\""));assertEquals("running",value["state"])
        // A queued/spawned process is not proof its first instruction ran.
        // Keep the fixture alive until its real checkpoint exists before the
        // instrumentation process exits and the host simulates app death.
        val marker=File(context.filesDir,"cloud-projects/$p/recovery.txt")
        for(i in 0 until 200){if(marker.isFile&&marker.readText()=="started\n")break;Thread.sleep(100)}
        assertTrue("Recovery fixture must actually begin before process death",marker.isFile)
        assertEquals("started\n",marker.readText())
        File(context.filesDir,"qa-coding-recovery.json").writeText(org.json.JSONObject(mapOf("owner" to owner,"task" to task,"projectId" to p,"jobId" to value["id"])).toString())
    }
    @Test fun interactiveInputAndDetachedDescendantsStopWithTheirOwner(){
        val p=project();val input=call("exec.start",mapOf("projectId" to p,"command" to "read line; printf 'INPUT:%s' \"\$line\""));assertEquals("running",input["state"])
        call("jobs.input",mapOf("jobId" to input["id"],"text" to "hello\n","end" to true))
        val done=finish(call("jobs.read",mapOf("jobId" to input["id"])));assertEquals("INPUT:hello",(done["stdout"] as Map<*,*>)["text"])
        val detached=call("exec.start",mapOf("projectId" to p,"command" to "setsid node -e \"setInterval(()=>require('fs').appendFileSync('heartbeat.txt','x'),100)\" >/dev/null 2>&1 & sleep 0.2","waitMs" to 500));assertEquals("running",detached["state"])
        val heartbeat=File(context.filesDir,"cloud-projects/$p/heartbeat.txt")
        for(i in 0..50){if(heartbeat.isFile&&heartbeat.length()>0)break;Thread.sleep(100)}
        assertTrue("Detached child must actually run before Stop",heartbeat.isFile&&heartbeat.length()>0)
        assertEquals("stopped",call("jobs.stop",mapOf("jobId" to detached["id"]))["state"])
        val original=call("files.read",mapOf("projectId" to p,"path" to "heartbeat.txt"))["sha256"];Thread.sleep(400);assertEquals(original,call("files.read",mapOf("projectId" to p,"path" to "heartbeat.txt"))["sha256"])
    }
    @Test fun largeFilesSearchLogsAndManifestContinueBeyondOldLimits(){
        val p=project();val script="""
          import fs from 'node:fs';
          fs.mkdirSync('search',{recursive:true});for(let i=0;i<2105;i++)fs.writeFileSync('search/'+i+'.txt','BOUNDARY_MATCH '+i+'\n');
          fs.writeFileSync('large.txt','中文😀 abc\n'.repeat(300000));
          fs.mkdirSync('final',{recursive:true});for(let i=0;i<120;i++)fs.writeFileSync('final/empty-'+i+'.txt','');
          const big=fs.openSync('final/big.bin','w');fs.ftruncateSync(big,201*1024*1024);fs.closeSync(big);
          const chunk=Buffer.alloc(1024*1024,120);for(let i=0;i<17;i++){fs.writeSync(1,chunk);fs.writeSync(2,chunk);}console.log('FULL_LOG_END');
        """.trimIndent()
        write(p,"boundary.mjs",script);val job=call("exec.start",mapOf("projectId" to p,"command" to "node boundary.mjs"));val done=call("jobs.wait",mapOf("jobId" to job["id"]));assertEquals("exited",done["state"]);assertEquals(0,(done["exitCode"] as Number).toInt());assertTrue((done["stdoutBytes"] as Number).toLong()>16*1024*1024);assertTrue((done["stderrBytes"] as Number).toLong()>16*1024*1024)
        val tail=call("jobs.read",mapOf("jobId" to job["id"],"stdoutOffset" to 17*1024*1024));assertTrue((tail["stdout"] as Map<*,*>)["text"].toString().contains("FULL_LOG_END"));assertEquals(false,tail["outputTruncated"])
        var cursor:String?=null;val matches=mutableSetOf<String>();do{val result=call("files.search",mapOf("projectId" to p,"path" to "search","query" to "BOUNDARY_MATCH","pageSize" to 333,"cursor" to cursor));assertEquals(2105,(result["total"] as Number).toInt());(result["items"] as List<*>).forEach{matches.add((it as Map<*,*>)["path"] as String)};cursor=result["nextCursor"] as? String}while(cursor!=null);assertEquals(2105,matches.size)
        val expected=File(context.filesDir,"cloud-projects/$p/large.txt").readText();var offset=0L;val text=StringBuilder();do{val page=call("files.read",mapOf("projectId" to p,"path" to "large.txt","offset" to offset,"length" to 1048576));text.append(page["text"]);offset=(page["nextOffset"] as Number).toLong()}while(page["complete"]!=true);assertEquals(expected,text.toString());assertTrue(offset>2*1024*1024)
        val manifest=call("deliver.prepare",mapOf("projectId" to p,"files" to ((0 until 120).map{mapOf("path" to "final/empty-$it.txt","purpose" to "用户要求的合法空文件")}+mapOf("path" to "final/big.bin","purpose" to "大文件流式交付核对"))))
        val artifacts=CloudArtifacts(context);val delivery=artifacts.publish(manifest,owner,task,"boundary_$task");assertEquals(delivery.toString(),121,(delivery["count"] as Number).toInt());assertEquals(0,(delivery["failedCount"] as Number).toInt());val batch=delivery["batchId"] as String
        var at=0;val ids=mutableSetOf<String>();do{val page=artifacts.page(owner,task,batches=listOf(batch),offset=at,count=23);for(raw in page["items"] as List<*>){val item=raw as Map<*,*>;ids.add(item["id"] as String);assertEquals("saved",item["phoneSaveState"]);if(item["name"]=="big.bin")assertEquals(201L*1024*1024,(item["bytes"] as Number).toLong())};val next=page["nextOffset"] as? Int?:break;at=next}while(true);assertEquals(121,ids.size)
        assertEquals(121,(artifacts.publish(manifest,owner,task,"boundary_$task")["count"] as Number).toInt())
        File(context.filesDir,"qa-unrestricted-boundaries.json").writeText(org.json.JSONObject(mapOf("projectId" to p,"jobId" to job["id"],"searchMatches" to matches.size,"readBytes" to offset,"stdoutBytes" to done["stdoutBytes"],"stderrBytes" to done["stderrBytes"],"artifactCount" to ids.size,"batchId" to batch)).toString())
    }
    @Test fun nativeAndroidUidExecutionSharesFilesAndHasRealPauseStop(){
        val p=project();fun start(command:String,key:String)=CloudAndroidRuntime.start(context,mapOf("projectId" to p,"command" to command),owner,task,key)
        val run=start("id; printf ANDROID_NATIVE > android.txt","android_$task");val done=CloudAndroidRuntime.invoke(context,"coding.jobs.wait",mapOf("jobId" to run["id"]),owner,"wait_$task") as Map<*,*>;assertEquals("exited",done["state"]);assertEquals(android.os.Process.myUid(),done["androidUid"]);assertTrue((done["stdout"] as Map<*,*>)["text"].toString().contains("uid=${android.os.Process.myUid()}"));assertEquals("ANDROID_NATIVE",call("files.read",mapOf("projectId" to p,"path" to "android.txt"))["text"])
        val long=start("while true; do printf x >> native-heartbeat; sleep 0.1; done","android_long_$task");val file=File(context.filesDir,"cloud-projects/$p/native-heartbeat");for(i in 0..50){if(file.length()>0)break;Thread.sleep(100)};assertTrue(file.length()>0)
        val paused=CloudAndroidRuntime.invoke(context,"coding.jobs.pause",mapOf("jobId" to long["id"]),owner,"pause_$task") as Map<*,*>;assertEquals("paused",paused["state"]);val before=file.length();Thread.sleep(400);assertEquals(before,file.length());CloudAndroidRuntime.invoke(context,"coding.jobs.resume",mapOf("jobId" to long["id"]),owner,"resume_$task");Thread.sleep(400);assertTrue(file.length()>before)
        val stopped=CloudAndroidRuntime.invoke(context,"coding.jobs.stop",mapOf("jobId" to long["id"]),owner,"stop_$task") as Map<*,*>;assertEquals("stopped",stopped["state"]);val final=file.length();Thread.sleep(300);assertEquals(final,file.length());assertEquals(run["id"],start("id; printf ANDROID_NATIVE > android.txt","android_$task")["id"])
    }

}

class CloudRestartAcceptanceTest{
    @Test fun restartRechecksProjectsFilesProcessesAndImmutableDeliveries(){
        val context=InstrumentationRegistry.getTargetContext();assertTrue(context.packageName.endsWith(".engineqa"));assertTrue(Build.HARDWARE in setOf("ranchu","goldfish"))
        val saved=org.json.JSONObject(File(context.filesDir,"qa-coding-recovery.json").readText())
        fun call(tool:String,args:Map<String,Any?>):Map<String,Any?>{
            val r=CloudRuntime.invoke(context,"coding.$tool",args,saved.getString("owner"),saved.getString("task"),"recovery_${UUID.randomUUID().toString().replace("-","")}");assertEquals("verified",r["outcome"]);@Suppress("UNCHECKED_CAST") return r["value"] as Map<String,Any?>
        }
        val job=call("jobs.read",mapOf("jobId" to saved.getString("jobId")));assertEquals("unknown",job["state"])
        assertEquals("started\n",call("files.read",mapOf("projectId" to saved.getString("projectId"),"path" to "recovery.txt"))["text"])
        val office=org.json.JSONObject(File(context.filesDir,"qa-office-artifacts.json").readText());val artifacts=CloudArtifacts(context);assertEquals("text",artifacts.preview(office.getString("workbook"))["kind"])
        assertTrue(artifacts.preview(office.getString("document"))["text"].toString().contains("小云实际成果"))
    }
}

class CloudMigrationAcceptanceTest{
    @Test fun originalDshFilesAreBackedUpVerifiedAndImportedWithoutPluginLaunch(){
        val context=InstrumentationRegistry.getTargetContext();assertTrue(context.packageName.endsWith(".engineqa"));assertTrue(Build.HARDWARE in setOf("ranchu","goldfish"))
        val migration=CloudMigration(context);val first=migration.migrate();assertEquals(first.toString(),"verified",first["state"]);assertEquals(true,first["sourcePreserved"])
        assertEquals(first["files"],migration.migrate()["files"])
        val backup=File(context.filesDir,"cloud-migration/dsh-original-data.zip");assertTrue(backup.isFile)
        java.util.zip.ZipFile(backup).use{zip->val manifest=org.json.JSONObject(zip.getInputStream(zip.getEntry("migration-manifest.json")).bufferedReader().use{it.readText()});val entries=manifest.getJSONArray("entries");assertEquals((first["files"] as Number).toInt(),(0 until entries.length()).count{entries.getJSONObject(it).getString("type")=="file"})}
        val opened=CloudRuntime.invoke(context,"coding.projects.open",mapOf("projectId" to "project_legacy_dsh"),"qa:migration","qa_migration","migration_open_${System.currentTimeMillis()}")
        assertEquals("verified",opened["outcome"])
        File(context.filesDir,"qa-migration.json").writeText(org.json.JSONObject(first).toString())
    }
}
