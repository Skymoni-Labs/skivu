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
    private var storageReply:MethodChannel.Result?=null
    private var selectingDefault=false
    private var selectingFile=false
    fun register(messenger:BinaryMessenger){
        if(activity!=null)worker.execute{runCatching{CloudMigration(context).migrate()};runCatching{CloudAndroidRuntime.restore(context)}}
        val controls=MethodChannel(messenger,"skivu/cloud_controls")
        MethodChannel(messenger,"skivu/cloud_execution").setMethodCallHandler{call,result->
            @Suppress("UNCHECKED_CAST") val args=call.arguments as? Map<String,Any?>?:emptyMap()
            if(call.method in setOf("storage.authorize","storage.pick")){
                try{check(storageReply==null);storageReply=result;selectingDefault=args["makeDefault"]==true;selectingFile=call.method=="storage.pick";val intent=if(selectingFile)Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")else Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);(activity?:error("请在小云页面选择一次授权目录或文件。")).startActivityForResult(intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION),7565)}catch(e:Exception){storageReply=null;result.error("CLOUD_STORAGE",e.message,null)};return@setMethodCallHandler
            }
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
                        "programs.page"->{require(workerLease==null);CloudProgramIndex.page(context,(args["offset"] as? Number)?.toInt()?:0,(args["pageSize"] as? Number)?.toInt()?:50)}
                        "resource.policy"->CloudProgramIndex.policy(context)
                        "resource.configure"->{require(workerLease==null);CloudProgramIndex.configure(context,args)}
                        "status"->CloudRuntime.status()+mapOf("operations" to CloudOperations.status(),"migration" to CloudMigration(context).status())
                        "migration"->CloudMigration(context).migrate()
                        "invoke"->{
                            val tool=args["tool"] as String;require(tool.startsWith("coding."));val owner=args["owner"] as String;val task=args["taskId"] as String;val request=args["requestId"] as String
                            @Suppress("UNCHECKED_CAST") val parameters=args["arguments"] as? Map<String,Any?>?:emptyMap()
                            if(workerLease!=null&&tool!="coding.cancel"){
                                TaskScheduleStore(context).check(workerLease)
                                CloudRuntime.bindRun(context,workerLease.getString("id"),owner,task)
                                require(workerProject==null||parameters["projectId"].let{it==null||it==workerProject}){"编程计划不能切换到其他项目。"}
                                require(workerProject==null||tool !in setOf("coding.projects.create","coding.projects.archive","coding.projects.list")){"此计划只允许已保存的项目范围。"}
                            }
                            if(tool!="coding.cancel")CloudMigration(context).migrate()
                            val controls=setOf("coding.cancel","coding.pause","coding.resume")
                            val receipt:Map<String,Any?> = if(tool in controls){
                                val action=tool.removePrefix("coding.");if(action=="cancel")CloudOperations.cancel(context,owner,task)
                                val android=CloudAndroidRuntime.taskControl(context,owner,task,action)
                                val linux=if(CloudRuntime.hasOwnedJobs(context,owner,task)||CloudRuntime.status()["running"]==true||action=="cancel")CloudRuntime.invoke(context,tool,parameters,owner,task,request)else mapOf("outcome" to "verified","value" to mapOf("stopped" to true,"state" to action))
                                if(action=="cancel")CloudOperations.awaitStopped(owner,task)
                                val ok=linux["outcome"]=="verified"&&android["state"]!="unknown"&&(action!="cancel"||CloudOperations.stopPersisted(context,owner,task))&&(action!="cancel"||android["stopped"]==true&&(linux["value"] as? Map<*,*>)?.get("stopped")==true)
                                mapOf("outcome" to if(ok)"verified"else"unknown","value" to mapOf("stopped" to (action=="cancel"&&ok),"android" to android,"linux" to linux))
                            }else{
                                CloudOperations.enter(context,owner,task)
                                try{when{
                                    tool=="coding.artifacts.status"->mapOf("outcome" to "verified","value" to artifacts.batchStatus(parameters["batchId"] as String,owner))
                                    tool=="coding.artifacts.save"->mapOf("outcome" to "verified","value" to artifacts.saveToPhone(parameters["id"] as String,owner))
                                    tool=="coding.artifacts.list"->mapOf("outcome" to "verified","value" to artifacts.page(owner,parameters["taskId"] as? String,batches=(parameters["batchId"] as? String)?.let{listOf(it)},offset=(parameters["offset"] as? Number)?.toInt()?:0,count=(parameters["pageSize"] as? Number)?.toInt()?:100))
                                    tool=="coding.artifacts.open"->{val id=parameters["id"] as String;val record=artifacts.file(id).second;require(record.getString("owner")==owner){"成果不属于此会话。"};val plan=workerLease?.let{TaskDatabase.get(context).run(it.getString("id"))?.optJSONObject("planSnapshot")};val locked=context.getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked||!context.getSystemService(android.os.PowerManager::class.java).isInteractive
                                        if(workerLease!=null&&(plan?.optBoolean("allowForeground",true)==false||locked))mapOf("outcome" to "permission_required","message" to "等待屏幕可操作且计划允许前台步骤，文件已保留。")else{
                                            val intent=artifacts.openIntent(id,false);val completed=java.util.concurrent.CompletableFuture<Unit>();Handler(Looper.getMainLooper()).post{try{CloudOperations.checkScope(owner,task);(activity?:SkivuAccessibilityService.connected?:context).startActivity(intent.apply{if(activity==null)addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)});completed.complete(Unit)}catch(e:Exception){completed.completeExceptionally(e)}};completed.get();mapOf("outcome" to "verified","message" to "已将真实手机文件交给系统默认应用打开；实际界面可继续观察核对。","value" to mapOf("id" to id,"state" to "open_requested","verification" to "intent_accepted","businessVerified" to false))
                                        }}
                                    tool=="coding.android.start"->mapOf("outcome" to "verified","value" to CloudAndroidRuntime.start(context,parameters,owner,task,request))
                                    tool=="coding.jobs.list"->{val linux=if(CloudRuntime.hasOwnedJobs(context,owner))CloudRuntime.invoke(context,tool,parameters,owner,task,request)else mapOf("value" to emptyList<Any>(),"outcome" to "verified");mapOf("outcome" to linux["outcome"],"value" to ((linux["value"] as? List<*>)?:emptyList<Any>())+CloudAndroidRuntime.list(context,owner))}
                                    tool.startsWith("coding.jobs.")&&parameters["jobId"].toString().startsWith("android_")->{val value=CloudAndroidRuntime.invoke(context,tool,parameters,owner,request,task);@Suppress("UNCHECKED_CAST") if(value is Map<*,*>&&value.containsKey("outcome"))value as Map<String,Any?> else mapOf("outcome" to "verified","value" to value)}
                                    tool.startsWith("coding.storage.")->{val value=CloudStorage(context).invoke(tool.removePrefix("coding.storage."),parameters,owner,task,request);if(value.containsKey("outcome"))value else mapOf("outcome" to "verified","value" to value)}
                                    else->CloudRuntime.invoke(context,tool,parameters,owner,task,request)
                                }}finally{CloudOperations.leave()}
                            }
                            if(tool=="coding.deliver.prepare"&&receipt["outcome"]=="verified"){
                                @Suppress("UNCHECKED_CAST") val manifest=receipt["value"] as Map<String,Any?>
                                CloudOperations.enter(context,owner,task);val delivery=try{artifacts.publish(manifest,owner,task,request)}finally{CloudOperations.leave()};receipt+mapOf("outcome" to if((delivery["artifacts"] as List<*>).isEmpty())"failed" else "verified","value" to delivery,"message" to "最终清单已核对；成功文件已保存到手机可见目录，未完成的手机保存单独说明。")
                            }else receipt
                        }
                        "artifacts.page"->{@Suppress("UNCHECKED_CAST") val ids=args["ids"] as? List<String>;@Suppress("UNCHECKED_CAST") val batches=args["batches"] as? List<String>;artifacts.page(args["owner"] as? String,args["taskId"] as? String,ids,batches,(args["offset"] as? Number)?.toInt()?:0,(args["pageSize"] as? Number)?.toInt()?:20)}
                        "artifacts.failures"->artifacts.failures(args["batchId"] as String,(args["offset"] as? Number)?.toInt()?:0)
                        "artifacts"->artifacts.list(args["owner"] as? String,args["taskId"] as? String)
                        "storage.open"->{val storage=CloudStorage(context);val uri=storage.document(args["grantId"] as String,args["path"] as String);val info=storage.info(uri);val intent=Intent(Intent.ACTION_VIEW).setDataAndType(uri,info["mime"] as String).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);val completed=java.util.concurrent.CompletableFuture<Unit>();Handler(Looper.getMainLooper()).post{try{(activity?:error("请从小云页面打开授权文件。")).startActivity(intent);completed.complete(Unit)}catch(e:Exception){completed.completeExceptionally(e)}};completed.get();mapOf("state" to "open_requested")}
                        "storage.grants"->CloudStorage(context).grants()
                        "storage.revoke"->{require(activity!=null&&workerLease==null){"请从小云文件设置中取消授权。"};CloudStorage(context).revoke(args["grantId"] as String);mapOf("revoked" to true,"filesPreserved" to true)}
                        "storage.default"->{CloudStorage(context).setDefault(args["grantId"] as? String);mapOf("saved" to true)}
                        "artifact.preview"->artifacts.preview(args["id"] as String,(args["offset"] as? Number)?.toLong()?:0,(args["length"] as? Number)?.toInt()?:48000)
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
        if(code==7565){val reply=storageReply;storageReply=null;val makeDefault=selectingDefault;val directory=!selectingFile;selectingFile=false;selectingDefault=false;if(reply==null)return;if(resultCode!=Activity.RESULT_OK||data?.data==null){reply.success(mapOf("state" to "cancelled"));return};worker.execute{try{val storage=CloudStorage(context);val granted=storage.accept(data.data!!,data.flags,directory);if(makeDefault)storage.setDefault(granted["id"] as String);Handler(Looper.getMainLooper()).post{reply.success(granted)}}catch(e:Exception){Handler(Looper.getMainLooper()).post{reply.error("CLOUD_STORAGE",e.message,null)}}};return}
        if(code==7564){val reply=migrationReply;migrationReply=null;val uri=data?.data;if(reply==null)return;if(resultCode!=Activity.RESULT_OK||uri==null){reply.success(mapOf("state" to "cancelled","message" to (data?.getStringExtra("reason")?:"一次性连接未完成，原数据保留。")));return};worker.execute{try{val answer=CloudMigration(context).acceptSnapshot(context.contentResolver.openFileDescriptor(uri,"r")?:error("旧数据导出文件不可读取。"));Handler(Looper.getMainLooper()).post{reply.success(answer)}}catch(e:Exception){Handler(Looper.getMainLooper()).post{reply.error("CLOUD_MIGRATION",e.message,null)}}};return}
        if(code!=SAVE)return;val id=saving;val reply=saveReply;saving=null;saveReply=null
        if(id==null||reply==null)return
        if(resultCode!=Activity.RESULT_OK||data?.data==null){reply.success(mapOf("state" to "cancelled"));return}
        worker.execute{try{val(file,_)=artifacts.file(id);context.contentResolver.openOutputStream(data.data!!,"wt")!!.use{output->file.inputStream().use{it.copyTo(output)}};val verified=runCatching{CloudPhoneFiles(context).verifySavedCopy(data.data!!,file)}.getOrDefault(false);Handler(Looper.getMainLooper()).post{reply.success(mapOf("state" to if(verified)"saved" else "saved_unverified"))}}catch(e:Exception){Handler(Looper.getMainLooper()).post{reply.error("CLOUD_SAVE",e.message,null)}}}
    }
}
