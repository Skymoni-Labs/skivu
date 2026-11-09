package com.skyjjgw.independent.ski

import android.content.Context
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile

/** Additive, repeatable import. The source APK/data and raw archive stay intact. */
class CloudMigration(private val context:Context){
    companion object{private val lock=Any()}
    private val base get()=File(context.filesDir,"cloud-migration").apply{mkdirs()}
    private val receipt get()=File(base,"receipt.json")
    fun acceptSnapshot(fd:android.os.ParcelFileDescriptor):Map<String,Any?> = synchronized(lock){
        val partial=File(base,"activation.partial")
        try{android.os.ParcelFileDescriptor.AutoCloseInputStream(fd).use{input->partial.outputStream().use{output->val b=ByteArray(65536);var total=0L;while(true){val n=input.read(b);if(n<0)break;total+=n;output.write(b,0,n)}}};ZipFile(partial).use{require(it.getEntry("migration-manifest.json")!=null)};check(partial.renameTo(File(base,"dsh-original-data.zip")));migrate()}catch(e:Exception){partial.delete();throw e}
    }
    fun status():Map<String,Any?> = synchronized(lock){
        @Suppress("UNCHECKED_CAST")
        if(receipt.exists())plain(JSONObject(receipt.readText())) as Map<String,Any?> else mapOf("state" to "not_checked")
    }
    fun migrate():Map<String,Any?> = synchronized(lock){
        if(receipt.exists())return@synchronized status()
        val installed=runCatching{context.packageManager.getPackageInfo("org.skivu.dsh.runtime",0)}.getOrNull()
            ?:return@synchronized mapOf("state" to "not_present","message" to "没有旧 DSH 组件；内置环境可直接使用。")
        require(context.packageManager.checkSignatures(context.packageName,"org.skivu.dsh.runtime")==android.content.pm.PackageManager.SIGNATURE_MATCH){"旧组件签名不匹配，未读取私有数据。"}
        val archive=File(base,"dsh-original-data.zip")
        if(!archive.exists()){
            val staging=File(base,"snapshot.partial")
            try{
                context.contentResolver.openInputStream(Uri.parse("content://org.skivu.dsh.runtime.migration/snapshot"))!!.use{input->staging.outputStream().use{out->val b=ByteArray(65536);var total=0L;while(true){val n=input.read(b);if(n<0)break;total+=n;out.write(b,0,n)}}}
                ZipFile(staging).use{require(it.getEntry("migration-manifest.json")!=null)};check(staging.renameTo(archive))
            }catch(e:Exception){staging.delete();return@synchronized mapOf("state" to "bridge_required","message" to "系统未允许直接读取旧组件。请使用一次性迁移连接；不会打开 DSH 编程页面或删除原数据。","reason" to e.javaClass.simpleName,"sourceVersion" to installed.versionName)}
        }
        val stage=File(base,"import-staging").apply{mkdirs()}
        var files=0;var bytes=0L;val retained=JSONArray();val links=mutableListOf<JSONObject>()
        ZipFile(archive).use{zip->
            val manifestEntry=zip.getEntry("migration-manifest.json")?:error("迁移清单缺失。")
            require(manifestEntry.size in 1..(40L*1024*1024))
            val manifest=JSONObject(zip.getInputStream(manifestEntry).bufferedReader().use{it.readText()});require(manifest.getInt("version")==1&&manifest.getString("sourcePackage")=="org.skivu.dsh.runtime")
            val entries=manifest.getJSONArray("entries");
            for(i in 0 until entries.length()){
                val item=entries.getJSONObject(i);val relative=item.getString("path");require(relative.length<=2000&&!relative.startsWith('/')&&!relative.contains('\\')&&relative.split('/').none{it.isEmpty()||it==".."||it=="."}&&relative.substringBefore('/') in setOf("home","projects"))
                val dest=File(stage,relative);require(dest.canonicalPath.startsWith(stage.canonicalPath+"/"))
                when(item.getString("type")){
                    "directory"->dest.mkdirs()
                    "file"->{val entry=zip.getEntry(relative)?:error("迁移文件缺失。");require(entry.size==item.getLong("bytes"));bytes+=entry.size;dest.parentFile!!.mkdirs();val sha=MessageDigest.getInstance("SHA-256");zip.getInputStream(entry).use{input->dest.outputStream().use{out->val b=ByteArray(65536);while(true){val n=input.read(b);if(n<0)break;sha.update(b,0,n);out.write(b,0,n)}}};require(sha.digest().joinToString(""){"%02x".format(it)}==item.getString("sha256"));files++}
                    // Link metadata remains in the original archive. Do not recreate
                    // an old Android-private absolute link into another app's UID.
                    "symlink"->links+=item
                    else->retained.put(item)
                }
            }
            File(base,"verified-manifest.json").writeText(manifest.toString())
            for(i in 0 until entries.length()){
                val item=entries.getJSONObject(i);if(item.optString("type")=="file"&&item.has("mode"))android.system.Os.chmod(File(stage,item.getString("path")).path,(item.getInt("mode") and 511) or 384)
            }
            for(link in links){
                val relative=link.getString("path");val target=link.getString("target");val dest=File(stage,relative)
                // Restore relative links only within the same exported top-level
                // tree. Absolute runtime links retain exact metadata in backup.
                val top=File(stage,relative.substringBefore('/')).canonicalPath
                val actual=File(dest.parentFile,target).canonicalPath
                val mapped=when{target=="/opt/dsh/node_modules"||target=="/opt/node/bin/node"->target;target=="/workspace"->"/workspace/project_legacy_dsh";target.startsWith("/workspace/")&&!target.split('/').contains("..")->"/workspace/project_legacy_dsh/"+target.removePrefix("/workspace/");else->null}
                if(mapped!=null||!target.startsWith('/')&&!target.contains('\\')&&(actual==top||actual.startsWith("$top/"))){dest.parentFile!!.mkdirs();if(!java.nio.file.Files.isSymbolicLink(dest.toPath())&&!dest.exists())android.system.Os.symlink(mapped?:target,dest.path)}else retained.put(link)
            }
        }
        val projectId="project_legacy_dsh";val project=File(context.filesDir,"cloud-projects/$projectId");project.parentFile!!.mkdirs()
        val oldProjects=File(stage,"projects");if(!project.exists()){if(oldProjects.exists())check(oldProjects.renameTo(project))else check(project.mkdir())}
        val home=File(context.filesDir,"cloud-home").apply{mkdirs()};val legacyHome=File(home,"legacy-dsh-home");val oldHome=File(stage,"home");if(oldHome.exists()&&!legacyHome.exists())check(oldHome.renameTo(legacyHome))
        val cloud=File(home,"cloud").apply{mkdirs()};val projectIndex=File(cloud,"migrated-projects.json");val projects=if(projectIndex.exists())JSONArray(projectIndex.readText())else JSONArray()
        if((0 until projects.length()).none{projects.getJSONObject(it).optString("id")==projectId}){
            projects.put(JSONObject(mapOf("id" to projectId,"name" to "DSH 原工作区","createdAt" to System.currentTimeMillis(),"migrated" to true)))
            val tmp=File(cloud,"projects.migration.tmp");tmp.writeText(projects.toString());check(tmp.renameTo(projectIndex))
        }
        val result=JSONObject(mapOf("state" to "verified","files" to files,"bytes" to bytes,"projectId" to projectId,"sourceVersion" to installed.versionName,"sourcePreserved" to true,"backup" to "app-private/cloud-migration/dsh-original-data.zip","legacyHome" to "/root/skivu-home/legacy-dsh-home","retainedLinkMetadata" to retained.length(),"completedAt" to System.currentTimeMillis()))
        val tmp=File(base,"receipt.tmp");tmp.writeText(result.toString());check(tmp.renameTo(receipt))
        @Suppress("UNCHECKED_CAST") (plain(result) as Map<String,Any?>)
    }
}
