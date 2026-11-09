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
        assertEquals("once\n",call("files.read",mapOf("projectId" to p,"path" to "once.txt"))["text"])
    }
    @Test fun staleFileHashesAndTraversalAreRejected(){
        val p=project();write(p,"file.txt","a")
        write(p,"root.mjs","root");write(p,"nested/test.mjs","nested")
        val glob=request("files.glob",mapOf("projectId" to p,"pattern" to "**/*.mjs"));assertEquals("verified",glob["outcome"]);assertEquals(2,(glob["value"] as List<*>).size)
        assertEquals("failed",request("files.write",mapOf("projectId" to p,"path" to "file.txt","content" to "overwrite"))["outcome"])
        assertEquals("failed",request("files.read",mapOf("projectId" to p,"path" to "../cloud-home/secret"))["outcome"])
        assertEquals("failed",request("deliver.prepare",mapOf("projectId" to p,"files" to emptyList<Any>()))["outcome"])
        assertEquals("a",call("files.read",mapOf("projectId" to p,"path" to "file.txt"))["text"])
    }
    @Test fun blankWorkbookUsesTheRealWriterAndPreservesOverwriteGuards(){
        val p=project();val created=call("workbook.create",mapOf("projectId" to p,"path" to "blank.xlsx"))
        assertEquals(true,created["blank"]);assertEquals(1,(created["sheets"] as Number).toInt());assertTrue((created["bytes"] as Number).toLong()>0)
        assertEquals("failed",request("workbook.create",mapOf("projectId" to p,"path" to "blank.xlsx"))["outcome"])
        assertEquals(created["sha256"],call("files.read",mapOf("projectId" to p,"path" to "blank.xlsx"))["sha256"])
        assertEquals("failed",request("workbook.create",mapOf("projectId" to p,"path" to "fake.csv"))["outcome"])
        val manifest=call("deliver.prepare",mapOf("projectId" to p,"files" to listOf(mapOf("path" to "blank.xlsx","purpose" to "最终空白Excel"))))
        val artifacts=CloudArtifacts(context);val delivery=artifacts.publish(manifest,owner,task,"blank_$task");val record=(delivery["artifacts"] as List<*>).single() as Map<*,*>
        val preview=artifacts.preview(record["id"] as String);assertEquals("workbook",preview["kind"]);val sheet=(preview["sheets"] as List<*>).single() as Map<*,*>;assertEquals("Sheet1",sheet["name"]);assertTrue((sheet["rows"] as List<*>).isEmpty())
        File(context.filesDir,"qa-blank-artifact.json").writeText(org.json.JSONObject(record).toString())
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
        val workbook=finalFiles.map{it as Map<*,*>}.single{it["format"]=="xlsx"};assertEquals(2,(workbook["sheets"] as Number).toInt());assertEquals("workbook",artifacts.preview(workbook["id"] as String)["kind"])
        val document=finalFiles.map{it as Map<*,*>}.single{it["format"]=="docx"};assertTrue(artifacts.preview(document["id"] as String)["text"].toString().contains("小云实际成果"))
        val fake=call("deliver.prepare",mapOf("projectId" to p,"files" to listOf(mapOf("path" to "fake.xlsx","purpose" to "无效格式"))))
        val rejected=artifacts.publish(fake,owner,task,"invalid_$task");assertEquals(0,(rejected["artifacts"] as List<*>).size);assertEquals(1,(rejected["failed"] as List<*>).size)
        File(context.filesDir,"qa-office-artifacts.json").writeText(org.json.JSONObject(mapOf("workbook" to workbook["id"],"document" to document["id"],"projectId" to p)).toString())
    }
    @Test fun prepareRealLongJobRecoveryCheckpoint(){
        val p=project();val value=call("exec.start",mapOf("projectId" to p,"command" to "echo started >> recovery.txt; node -e \"setInterval(()=>{},1000)\""));assertEquals("running",value["state"])
        File(context.filesDir,"qa-coding-recovery.json").writeText(org.json.JSONObject(mapOf("owner" to owner,"task" to task,"projectId" to p,"jobId" to value["id"])).toString())
    }
    @Test fun interactiveInputAndDetachedDescendantsStopWithTheirOwner(){
        val p=project();val input=call("exec.start",mapOf("projectId" to p,"command" to "read line; printf 'INPUT:%s' \"\$line\""));assertEquals("running",input["state"])
        call("jobs.input",mapOf("jobId" to input["id"],"text" to "hello\n","end" to true))
        val done=finish(call("jobs.read",mapOf("jobId" to input["id"])));assertEquals("INPUT:hello",(done["stdout"] as Map<*,*>)["text"])
        val detached=call("exec.start",mapOf("projectId" to p,"command" to "setsid node -e \"setInterval(()=>require('fs').appendFileSync('heartbeat.txt','x'),100)\" >/dev/null 2>&1 & sleep 0.2","waitMs" to 500));assertEquals("running",detached["state"])
        assertEquals("stopped",call("jobs.stop",mapOf("jobId" to detached["id"]))["state"])
        val original=call("files.read",mapOf("projectId" to p,"path" to "heartbeat.txt"))["sha256"];Thread.sleep(400);assertEquals(original,call("files.read",mapOf("projectId" to p,"path" to "heartbeat.txt"))["sha256"])
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
        val office=org.json.JSONObject(File(context.filesDir,"qa-office-artifacts.json").readText());val artifacts=CloudArtifacts(context);assertEquals("workbook",artifacts.preview(office.getString("workbook"))["kind"])
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
