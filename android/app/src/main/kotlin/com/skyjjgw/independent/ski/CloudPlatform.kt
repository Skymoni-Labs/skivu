package com.skyjjgw.independent.ski

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

class CloudPlatform(private val context:Context,private val activity:Activity?=null,private val workerLease:org.json.JSONObject?=null,private val workerProject:String?=null){
    companion object{private val worker=Executors.newCachedThreadPool();const val SAVE=7563}
    private val artifacts=CloudArtifacts(context)
    private var saving:String?=null
    private var saveReply:MethodChannel.Result?=null
    private var migrationReply:MethodChannel.Result?=null
    fun register(messenger:BinaryMessenger){
        if(activity!=null)worker.execute{runCatching{CloudMigration(context).migrate()}}
        val controls=MethodChannel(messenger,"skivu/cloud_controls")
        MethodChannel(messenger,"skivu/cloud_execution").setMethodCallHandler{call,result->
            @Suppress("UNCHECKED_CAST") val args=call.arguments as? Map<String,Any?>?:emptyMap()
            if(call.method=="migration.activate"){
                try{check(migrationReply==null);require(context.packageManager.checkSignatures(context.packageName,"org.skivu.dsh.runtime")==android.content.pm.PackageManager.SIGNATURE_MATCH);migrationReply=result;(activity?:error("一次性迁移需要从小云项目页发起。")).startActivityForResult(Intent().setComponent(android.content.ComponentName("org.skivu.dsh.runtime","org.skivu.dsh.runtime.MigrationActivity")),7564)}catch(e:Exception){migrationReply=null;result.error("CLOUD_MIGRATION",e.message,null)}
                return@setMethodCallHandler
            }
            if(call.method=="artifact.open"||call.method=="artifact.share"){
                worker.execute{try{val intent=artifacts.openIntent(args["id"] as String,call.method=="artifact.share",args["chooser"]==true)
                    Handler(Looper.getMainLooper()).post{try{(activity?:error("当前没有可打开成果的界面。")).startActivity(intent);result.success(mapOf("state" to "opened"))}catch(_:android.content.ActivityNotFoundException){result.error("CLOUD_FILE","手机没有可打开此格式的应用；文件已保存到 下载/Skivu，可选择安装对应查看器。",null)}catch(e:Exception){result.error("CLOUD_FILE",e.message,null)}}
                }catch(e:Exception){Handler(Looper.getMainLooper()).post{result.error("CLOUD_FILE",e.message,null)}}}
                return@setMethodCallHandler
            }
            if(call.method=="artifact.save"){
                try{
                    check(saveReply==null){"已有保存选择尚未结束。"};val id=args["id"] as String;val (file,_)=artifacts.file(id)
                    saving=id;saveReply=result;(activity?:error("请在小云页面选择保存位置。")).startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(artifacts.mime(file)).putExtra(Intent.EXTRA_TITLE,file.name),SAVE)
                }catch(e:Exception){saving=null;saveReply=null;result.error("CLOUD_FILE",e.message,null)}
                return@setMethodCallHandler
            }
            worker.execute{
                try{
                    val answer:Any?=when(call.method){
                        "status"->CloudRuntime.status()+mapOf("migration" to CloudMigration(context).status())
                        "migration"->CloudMigration(context).migrate()
                        "invoke"->{
                            val tool=args["tool"] as String;require(tool.startsWith("coding."));val owner=args["owner"] as String;val task=args["taskId"] as String;val request=args["requestId"] as String
                            @Suppress("UNCHECKED_CAST") val parameters=args["arguments"] as? Map<String,Any?>?:emptyMap()
                            if(workerLease!=null&&tool!="coding.cancel"){
                                TaskScheduleStore(context).check(workerLease)
                                CloudRuntime.bindRun(workerLease.getString("id"),owner,task)
                                require(workerProject!=null&&parameters["projectId"].let{it==null||it==workerProject}){"编程计划不能切换到其他项目。"}
                                require(tool !in setOf("coding.projects.create","coding.projects.archive","coding.projects.list")){"此计划只允许已保存的项目范围。"}
                            }
                            if(tool!="coding.cancel")CloudMigration(context).migrate()
                            val receipt=CloudRuntime.invoke(context,tool,parameters,owner,task,request)
                            if(tool=="coding.deliver.prepare"&&receipt["outcome"]=="verified"){
                                @Suppress("UNCHECKED_CAST") val manifest=receipt["value"] as Map<String,Any?>
                                val delivery=artifacts.publish(manifest,owner,task,request);receipt+mapOf("outcome" to if((delivery["artifacts"] as List<*>).isEmpty())"failed" else "verified","value" to delivery,"message" to "最终清单已核对；成功文件已保存到手机 下载/Skivu，未完成的手机保存单独说明。")
                            }else receipt
                        }
                        "artifacts"->artifacts.list(args["owner"] as? String,args["taskId"] as? String)
                        "artifact.preview"->artifacts.preview(args["id"] as String)
                        "execution.update"->{if(workerLease!=null)TaskScheduleStore(context).check(workerLease);ExecutionHub.bind(args["taskId"] as String){action->Handler(Looper.getMainLooper()).post{controls.invokeMethod("control",mapOf("taskId" to args["taskId"],"action" to action))}};ExecutionHub.update(context,if(workerLease==null)args else args+mapOf("runId" to workerLease.getString("id")))}
                        "execution.list"->ExecutionHub.list(context)
                        "overlay.mode"->ExecutionHub.setMode(context,args["mode"] as String)
                        "overlay.restore"->ExecutionHub.setMode(context,"compact")
                        "control"->ExecutionHub.control(args["taskId"] as String,args["action"] as String)
                        else->error("小云执行接口不存在。")
                    }
                    Handler(Looper.getMainLooper()).post{result.success(answer)}
                }catch(e:Exception){Handler(Looper.getMainLooper()).post{result.error("CLOUD_EXECUTION",e.message?:"执行未完成。",null)}}
            }
        }
    }
    fun onResult(code:Int,resultCode:Int,data:Intent?){
        if(code==7564){val reply=migrationReply;migrationReply=null;val uri=data?.data;if(reply==null)return;if(resultCode!=Activity.RESULT_OK||uri==null){reply.success(mapOf("state" to "cancelled","message" to (data?.getStringExtra("reason")?:"一次性连接未完成，原数据保留。")));return};worker.execute{try{val answer=CloudMigration(context).acceptSnapshot(context.contentResolver.openFileDescriptor(uri,"r")?:error("旧数据导出文件不可读取。"));Handler(Looper.getMainLooper()).post{reply.success(answer)}}catch(e:Exception){Handler(Looper.getMainLooper()).post{reply.error("CLOUD_MIGRATION",e.message,null)}}};return}
        if(code!=SAVE)return;val id=saving;val reply=saveReply;saving=null;saveReply=null
        if(id==null||reply==null)return
        if(resultCode!=Activity.RESULT_OK||data?.data==null){reply.success(mapOf("state" to "cancelled"));return}
        worker.execute{try{val(file,_)=artifacts.file(id);context.contentResolver.openOutputStream(data.data!!,"wt")!!.use{output->file.inputStream().use{it.copyTo(output)}};val verified=runCatching{CloudPhoneFiles(context).verifySavedCopy(data.data!!,file)}.getOrDefault(false);Handler(Looper.getMainLooper()).post{reply.success(mapOf("state" to if(verified)"saved" else "saved_unverified"))}}catch(e:Exception){Handler(Looper.getMainLooper()).post{reply.error("CLOUD_SAVE",e.message,null)}}}
    }
}
