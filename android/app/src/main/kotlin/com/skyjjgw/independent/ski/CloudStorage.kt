package com.skyjjgw.independent.ski

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/** Persisted SAF grants are the authority. A model supplies a grant ID and a
 * relative path, never a new content URI or a grant it can manufacture. */
class CloudStorage(private val context:Context){
    private val resolver=context.contentResolver
    private val preferences=context.getSharedPreferences("cloud-storage",0)
    private val base=File(context.filesDir,"cloud-storage").apply{mkdirs()}
    private fun records()=JSONArray(preferences.getString("grants","[]"))
    private fun digest(input:java.io.InputStream):Pair<String,Long>{val hash=MessageDigest.getInstance("SHA-256");var total=0L;val buffer=ByteArray(65536);while(true){CloudOperations.checkCurrent();val n=input.read(buffer);if(n<0)break;hash.update(buffer,0,n);total+=n};return hash.digest().joinToString(""){"%02x".format(it)} to total}
    fun accept(uri:Uri,flags:Int,directory:Boolean=true):Map<String,Any?>{val granted=flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION);require(granted and Intent.FLAG_GRANT_READ_URI_PERMISSION!=0);resolver.takePersistableUriPermission(uri,granted)
        val root=if(directory)DocumentsContract.buildDocumentUriUsingTree(uri,DocumentsContract.getTreeDocumentId(uri))else uri;val name=info(root)["name"]?.toString()?:"授权目录";val id="storage_"+TaskDatabase.digest(uri.toString()).take(32)
        val record=JSONObject(mapOf("id" to id,"uri" to uri.toString(),"name" to name,"kind" to if(directory)"directory"else"file","write" to (granted and Intent.FLAG_GRANT_WRITE_URI_PERMISSION!=0)))
        synchronized(lock){val all=records();val next=JSONArray();for(i in 0 until all.length())if(all.getJSONObject(i).getString("id")!=id)next.put(all.getJSONObject(i));next.put(record);check(preferences.edit().putString("grants",next.toString()).commit())}
        @Suppress("UNCHECKED_CAST") return plain(record) as Map<String,Any?>
    }
    fun grants():List<Any?>{val all=records();return (0 until all.length()).map{r->val row=all.getJSONObject(r);mapOf("id" to row.getString("id"),"name" to row.getString("name"),"kind" to row.optString("kind","directory"),"default" to (row.getString("id")==defaultId()),"write" to row.optBoolean("write"),"available" to resolver.persistedUriPermissions.any{it.uri.toString()==row.getString("uri")&&it.isReadPermission})}}
    private fun grant(id:String,write:Boolean=false):JSONObject{val all=records();val found=(0 until all.length()).map{all.getJSONObject(it)}.firstOrNull{it.getString("id")==id}?:error("目录尚未由用户授权。")
        require(!found.has("revokedAt")&&resolver.persistedUriPermissions.any{it.uri.toString()==found.getString("uri")&&it.isReadPermission&&(!write||it.isWritePermission)}){"目录授权已失效或没有写权限。"};return found}
    fun canReadDocument(uri:Uri):Boolean{
        val all=records();val permissions=resolver.persistedUriPermissions
        return (0 until all.length()).map{all.getJSONObject(it)}.any{row->
            val scope=Uri.parse(row.getString("uri"))
            !row.has("revokedAt")&&permissions.any{it.uri==scope&&it.isReadPermission}&&
                (scope==uri||row.optString("kind")=="directory"&&scope.authority==uri.authority&&
                    runCatching{DocumentsContract.isTreeUri(uri)&&DocumentsContract.getTreeDocumentId(scope)==DocumentsContract.getTreeDocumentId(uri)}.getOrDefault(false))
        }
    }
    private fun parts(path:String):List<String>{require(!path.startsWith('/')&&!path.contains('\u0000'));val parts=path.split('/').filter{it.isNotEmpty()&&it!="."};require(parts.none{it==".."});return parts}
    fun info(uri:Uri):Map<String,Any?> = resolver.query(uri,arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE,DocumentsContract.Document.COLUMN_MIME_TYPE,DocumentsContract.Document.COLUMN_LAST_MODIFIED),null,null,null)?.use{c->require(c.moveToFirst());mapOf("documentId" to c.getString(0),"name" to c.getString(1),"bytes" to if(c.isNull(2))null else c.getLong(2),"mime" to c.getString(3),"modified" to c.getLong(4),"uri" to uri.toString())}?:error("文档暂不可读。")
    private fun find(tree:Uri,parent:Uri,name:String):Uri?{val children=DocumentsContract.buildChildDocumentsUriUsingTree(tree,DocumentsContract.getDocumentId(parent));return resolver.query(children,arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,OpenableColumns.DISPLAY_NAME),null,null,null)?.use{c->while(c.moveToNext())if(c.getString(1)==name)return@use DocumentsContract.buildDocumentUriUsingTree(tree,c.getString(0));null}}
    fun document(id:String,path:String,write:Boolean=false,createParents:Boolean=false):Uri{val row=grant(id,write);val tree=Uri.parse(row.getString("uri"));if(row.optString("kind")=="file"){require(!createParents&&(parts(path).isEmpty()||parts(path)==listOf(row.getString("name")))){"此授权只对应所选文件。"};return tree};var current=DocumentsContract.buildDocumentUriUsingTree(tree,DocumentsContract.getTreeDocumentId(tree));for(part in parts(path))current=find(tree,current,part)?:if(createParents)DocumentsContract.createDocument(resolver,current,DocumentsContract.Document.MIME_TYPE_DIR,part)?:error("目录创建未完成。")else error("授权目录中没有此路径。请先列出当前目录。");return current}
    private fun observe(owner:String,id:String,path:String,sha:String){File(base,"read-${TaskDatabase.digest("$owner:$id:$path")}.json").writeText(JSONObject(mapOf("sha256" to sha)).toString())}
    fun invoke(tool:String,args:Map<String,Any?>,owner:String,task:String,request:String):Map<String,Any?>{
        val id=args["grantId"] as? String
        if(tool=="grants")return mapOf("items" to grants(),"defaultGrantId" to preferences.getString("defaultGrantId",null))
        if(tool=="list"){
            val row=grant(id?:error("缺少授权目录。"));if(row.optString("kind")=="file")return mapOf("items" to listOf(info(Uri.parse(row.getString("uri")))+mapOf("path" to row.getString("name"))),"total" to 1,"complete" to true,"nextOffset" to null);val tree=Uri.parse(row.getString("uri"));val path=args["path"]?.toString()?:"";val parent=document(id,path);val child=DocumentsContract.buildChildDocumentsUriUsingTree(tree,DocumentsContract.getDocumentId(parent));val offset=(args["offset"] as? Number)?.toInt()?:0;val count=(args["pageSize"] as? Number)?.toInt()?:100;require(offset>=0&&count>0);val result=mutableListOf<Map<String,Any?>>()
            var total=0;resolver.query(child,arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE,DocumentsContract.Document.COLUMN_MIME_TYPE),null,null,null)?.use{c->while(c.moveToNext()){if(total>=offset&&result.size<minOf(count,1000))result+=mapOf("name" to c.getString(0),"bytes" to if(c.isNull(1))null else c.getLong(1),"mime" to c.getString(2));total++}}
            return mapOf("items" to result,"total" to total,"nextOffset" to if(offset+result.size<total)offset+result.size else null,"complete" to (offset+result.size>=total),"grantId" to id,"path" to path)
        }
        if(tool=="read"){
            val path=args["path"] as String;val uri=document(id?:error("缺少授权目录。"),path);val metadata=info(uri)
            val offset=(args["offset"] as? Number)?.toLong()?:0;val requested=(args["length"] as? Number)?.toInt()?:48000;require(offset>=0&&requested>0)
            val contents=CloudNativeContents(context)
            fun version(row:Map<String,Any?>)=TaskDatabase.digest("${row["documentId"]}:${row["bytes"]}:${row["modified"]}")
            val previous=args["readId"] as? String
            val snapshot:JSONObject
            if(previous==null){
                val ref=(resolver.openInputStream(uri)?:error("文档不可读取。")).use{contents.import(owner,it){CloudOperations.checkCurrent()}}
                require(version(metadata)==version(info(uri))){"读取期间文件已改变，请重新读取当前版本。"}
                snapshot=JSONObject(ref+mapOf("grantId" to id,"path" to path,"sourceVersion" to version(metadata)))
                val receipt=File(base,"snapshot-${ref["contentId"]}.json");val temp=File(base,"${receipt.name}.tmp");temp.writeText(snapshot.toString());check(temp.renameTo(receipt))
            }else{
                require(Regex("content_[a-f0-9]{32}").matches(previous))
                snapshot=JSONObject(File(base,"snapshot-$previous.json").readText())
                require(snapshot.getString("owner")==owner&&snapshot.getString("grantId")==id&&snapshot.getString("path")==path){"读取快照不属于当前文件或调用方。"}
                require(snapshot.getString("sourceVersion")==version(metadata)){"手机文件已改变，请重新从头读取当前版本。"}
            }
            val readId=snapshot.getString("contentId");val sha=snapshot.getString("sha256");observe(owner,id,path,sha)
            val page=if(args["encoding"]=="base64")contents.read(owner,readId,offset,requested)else contents.readText(owner,readId,offset,requested)
            return metadata+page+mapOf("sha256" to sha,"readId" to readId,"snapshot" to true,"wholeFileRehashedPerPage" to false)
        }
        if(tool=="import"){
            val path=args["sourcePath"] as String;val uri=document(id?:error("缺少授权目录。"),path);val content="content_"+TaskDatabase.digest("$owner:$request").take(32);val directory=File(context.filesDir,"cloud-home/cloud/content").apply{mkdirs()};val data=File(directory,"$content.bin");val meta=File(directory,"$content.json");val signature=TaskDatabase.digest(JSONObject(args.toSortedMap()).toString());if(meta.isFile)require(JSONObject(meta.readText()).optString("sourceSignature")==signature){"原导入请求对应其他文件，未重用内容。"}
            if(!meta.isFile){val temp=File(directory,"$content.tmp");(resolver.openInputStream(uri)?:error("源文件不可读取。")).use{input->temp.outputStream().use{CloudOperations.copy(input,it,path)}};val hash=temp.inputStream().use{digest(it)};check(temp.renameTo(data));val m=File(directory,"$content.json.tmp");m.writeText(JSONObject(mapOf("id" to content,"owner" to owner,"complete" to true,"sourceSignature" to signature,"bytes" to hash.second,"sha256" to hash.first)).toString());check(m.renameTo(meta));observe(owner,id,path,hash.first)}
            val parameters=mutableMapOf<String,Any?>("projectId" to args["projectId"],"path" to args["path"],"contentId" to content);if(args["expectedSha256"]!=null)parameters["expectedSha256"]=args["expectedSha256"]
            val reply=CloudRuntime.invoke(context,"coding.files.write",parameters,owner,task,"import_"+TaskDatabase.digest(request).take(40));return reply+mapOf("sourceGrantId" to id,"sourcePath" to path,"linuxPath" to "/workspace/${args["projectId"]}/${args["path"]}")
        }
        if(tool=="export"){
            val project=args["projectId"] as String;require(Regex("project_[a-zA-Z0-9_-]+").matches(project));val root=File(context.filesDir,"cloud-projects/$project").canonicalFile;require(root.path==File(context.filesDir,"cloud-projects/$project").absolutePath&&root.isDirectory);val path=args["path"] as String;parts(path);val file=File(root,path).canonicalFile;require(file.path.startsWith(root.path+"/")&&file.isFile)
            val folder=args["folder"]?.toString()?:"";val parent=document(id?:error("缺少授权目录。"),folder,true,true);val name=args["name"]?.toString()?:file.name;require(parts(name).size==1)
            val receipt=File(base,"export-${TaskDatabase.digest("$owner:$request")}.json")
            val source=file.inputStream().use{digest(it)};val signature=TaskDatabase.digest(JSONObject(args.toSortedMap()).toString())
            var prepared=if(receipt.isFile)JSONObject(receipt.readText())else null
            if(prepared!=null){require(prepared.optString("signature")==signature){"原导出请求参数不同。"};require(prepared.optString("sourceSha256")==source.first){"原导出对应的项目文件已改变，未覆盖已有手机副本。"}}
            if(prepared?.optString("state")=="saved"){
                val uri=Uri.parse(prepared.getString("uri"));val actual=runCatching{(resolver.openInputStream(uri)?:error("副本不可读。")).use{digest(it)}}.getOrNull()
                @Suppress("UNCHECKED_CAST") return (plain(prepared) as Map<String,Any?>)+mapOf("state" to if(actual==null)"missing_or_unavailable"else if(actual==source)"saved"else"changed","sourcePreserved" to true)
            }
            var target=prepared?.optString("uri")?.takeIf{it.isNotBlank()}?.let(Uri::parse)
            if(target==null){require(prepared==null){"原导出创建结果未知，未重复创建文件。"};prepared=JSONObject(mapOf("state" to "prepared","signature" to signature,"grantId" to id,"sourcePath" to path,"sourceSha256" to source.first,"sourceBytes" to source.second));receipt.writeText(prepared.toString());target=DocumentsContract.createDocument(resolver,parent,CloudArtifacts(context).mime(file),name)?:error("目录提供方未创建文件。");prepared.put("uri",target.toString()).put("state","copying");receipt.writeText(prepared.toString())}
            else{val actual=(resolver.openInputStream(target)?:error("原副本暂不可读。")).use{digest(it)};require(actual.second<=source.second){"未覆盖外部改动。"};val hash=MessageDigest.getInstance("SHA-256");file.inputStream().use{input->val buffer=ByteArray(65536);var left=actual.second;while(left>0){CloudOperations.checkCurrent();val n=input.read(buffer,0,minOf(left,buffer.size.toLong()).toInt());require(n>0);hash.update(buffer,0,n);left-=n}};require(hash.digest().joinToString(""){"%02x".format(it)}==actual.first){"手机副本已外部修改，未覆盖。"}}
            (resolver.openOutputStream(target,"w")?:error("目录提供方未打开写入流。")).use{out->file.inputStream().use{CloudOperations.copy(it,out,file.name,file.length())}}
            val actual=(resolver.openInputStream(target)?:error("导出副本不可读取。")).use{digest(it)};require(actual==source){"导出回读完整性核对失败。"}
            val result=info(target)+mapOf("state" to "saved","signature" to signature,"sourceSha256" to source.first,"grantId" to id,"sha256" to actual.first,"bytes" to actual.second,"phonePath" to (grant(id).getString("name")+"/"+folder.trim('/')+"/"+info(target)["name"]).replace("//","/"),"sourcePreserved" to true)
            receipt.writeText(JSONObject(result).toString());return result
        }
        error("文件目录接口不存在。")
    }
    fun setDefault(id:String?){if(id!=null)require(grant(id,true).optString("kind","directory")=="directory"){"默认保存位置需要目录授权。"};check(preferences.edit().putString("defaultGrantId",id).commit())}
    fun revoke(id:String){synchronized(lock){
        val all=records();val record=(0 until all.length()).map{all.getJSONObject(it)}.firstOrNull{it.getString("id")==id}?:error("授权记录不存在。")
        val uri=Uri.parse(record.getString("uri"))
        resolver.persistedUriPermissions.firstOrNull{it.uri==uri}?.let{permission->
            var flags=0;if(permission.isReadPermission)flags=flags or Intent.FLAG_GRANT_READ_URI_PERMISSION;if(permission.isWritePermission)flags=flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            resolver.releasePersistableUriPermission(uri,flags)
        }
        record.put("revokedAt",System.currentTimeMillis())
        val editor=preferences.edit().putString("grants",all.toString());if(defaultId()==id)editor.remove("defaultGrantId")
        check(editor.commit())
    }}
    fun defaultId():String?=preferences.getString("defaultGrantId",null)
    fun createDefault(name:String,mime:String):Pair<Uri,String>?{val id=defaultId()?:return null;val parent=document(id,"",true);val uri=DocumentsContract.createDocument(resolver,parent,mime,name)?:error("授权目录无法创建文件。");return uri to (grant(id).getString("name")+"/")}
    companion object{private val lock=Any()}
}
