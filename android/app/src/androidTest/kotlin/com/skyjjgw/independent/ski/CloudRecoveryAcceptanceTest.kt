package com.skyjjgw.independent.ski

import android.content.Context
import android.content.ContextWrapper
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import androidx.test.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class CloudRecoveryAcceptanceTest {
    private fun context():Context {
        val original=InstrumentationRegistry.getTargetContext()
        check(original.packageName.endsWith(".engineqa")&&Build.HARDWARE in setOf("ranchu","goldfish"))
        val root=File(original.filesDir,"qa-artifact-migration-${UUID.randomUUID()}").apply{mkdirs()}
        return object:ContextWrapper(original){
            override fun getFilesDir()=File(root,"files").apply{mkdirs()}
            override fun getDatabasePath(name:String)=File(root,name)
            override fun openOrCreateDatabase(name:String,mode:Int,factory:SQLiteDatabase.CursorFactory?)=SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name),factory)
            override fun openOrCreateDatabase(name:String,mode:Int,factory:SQLiteDatabase.CursorFactory?,handler:DatabaseErrorHandler?)=SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name).path,factory,handler)
        }
    }
    @Test fun legacyMigrationPreservesNewerUrisAndRestoresBatchFailures() {
        val context=context();val store=CloudArtifactStore(context);val blobs=TaskBlobStore(context)
        val batch=TaskDatabase.digest("qa:original");val id="artifact_"+"a".repeat(32)
        val row=JSONObject(mapOf("id" to id,"owner" to "qa","taskId" to "task","requestId" to "original","projectId" to "project_qa","sourcePath" to "answer.txt","version" to 1,"name" to "answer.txt","phoneUri" to "content://old/location"))
        val dir=File(context.filesDir,"cloud-artifacts").apply{mkdirs()};File(dir,"manifest.json").writeText(JSONArray().put(row).toString())
        File(dir,"batch-$batch.json").writeText(JSONObject(mapOf("artifacts" to listOf(mapOf("id" to id)),"failed" to listOf(mapOf("path" to "answer.txt","stage" to "phone_save","error" to "interrupted")))).toString())
        store.put(row,batch);row.remove("batchId");row.put("phoneUri","content://newer/location")
        store.writableDatabase.execSQL("UPDATE artifacts SET body=? WHERE id=?",arrayOf(blobs.encode(row.toString()),id))
        store.writableDatabase.execSQL("INSERT INTO metadata VALUES('legacy-json','retained-and-imported')")
        store.migrateLegacy();assertEquals(batch,store.get(id)!!.getString("batchId"));assertEquals("content://newer/location",store.get(id)!!.getString("phoneUri"));assertEquals("qa",store.batch(batch)!!.getString("owner"));assertEquals(1L,store.failures(batch)["total"])
        store.migrateLegacy();assertEquals(1L,store.page(owner="qa")["total"]);assertTrue(File(dir,"manifest.json").isFile);store.close()
    }
    @Test fun lostPhoneUriReceiptRecoversSameMediaRowWithoutDuplicate() {
        val context=context();val owner="qa:phone-recovery:"+UUID.randomUUID();val task="task";val project="project_qa"
        val source=File(context.filesDir,"cloud-projects/$project/empty.txt");source.parentFile!!.mkdirs();source.writeText("")
        val sha=TaskDatabase.digest("");val manifest=mapOf("explicitManifest" to true,"owner" to owner,"taskId" to task,"files" to listOf(mapOf("projectId" to project,"path" to "empty.txt","name" to "empty.txt","bytes" to 0,"sha256" to sha,"purpose" to "用户要求的空文本文件")))
        val artifacts=CloudArtifacts(context);val result=artifacts.publish(manifest,owner,task,"publish")
        assertEquals(result.toString(),0L,(result["failedCount"] as Number).toLong())
        val record=(result["artifacts"] as List<*>).single() as Map<*,*>;val id=record["id"] as String;val uri=record["phoneUri"]
        val receipt=File(context.filesDir,"cloud-artifacts/exports/$id.json");val lost=JSONObject(receipt.readText());lost.remove("uri");lost.put("state","prepared");receipt.writeText(lost.toString())
        val restored=artifacts.saveToPhone(id,owner);assertEquals("saved",restored["phoneSaveState"]);assertEquals(uri,restored["phoneUri"])
        assertEquals(true,artifacts.batchStatus(result["batchId"] as String,owner)["verified"])
    }
    @Test fun nativeAndroidFullLogExportCreatesOneReusableProject() {
        val context=InstrumentationRegistry.getTargetContext();check(context.packageName.endsWith(".engineqa")&&Build.HARDWARE in setOf("ranchu","goldfish"))
        val owner="qa:android-export:"+UUID.randomUUID();val task="export_task"
        val job=CloudAndroidRuntime.start(context,mapOf("command" to "printf '中文😀 complete\\n'; printf 'error complete\\n' >&2"),owner,task,"start")
        CloudAndroidRuntime.invoke(context,"coding.jobs.wait",mapOf("jobId" to job["id"]),owner,"wait",task)
        val args=mapOf("jobId" to job["id"],"stream" to "stdout","path" to "full.log")
        val first=CloudAndroidRuntime.invoke(context,"coding.jobs.export",args,owner,"export",task) as Map<*,*>
        assertEquals(first.toString(),"verified",first["outcome"]);val value=first["value"] as Map<*,*>;assertNotNull(value["projectId"])
        val second=CloudAndroidRuntime.invoke(context,"coding.jobs.export",args,owner,"export",task) as Map<*,*>;assertEquals(value["projectId"],(second["value"] as Map<*,*>)["projectId"])
        val read=CloudRuntime.invoke(context,"coding.files.read",mapOf("projectId" to value["projectId"],"path" to "full.log"),owner,task,"read")
        assertEquals("verified",read["outcome"]);assertEquals("中文😀 complete\n",(read["value"] as Map<*,*>)["text"])
    }
}
