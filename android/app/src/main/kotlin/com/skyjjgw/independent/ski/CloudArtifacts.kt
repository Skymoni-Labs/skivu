package com.skyjjgw.independent.ski

import android.content.ClipData
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.util.zip.ZipFile

/** Android's parser does not implement Apache-specific feature URIs. Decode
 * strictly before parsing, reject DTD/entity declarations, and reject external
 * resolution. This works on the actual Android parser rather than ignoring a
 * failed security setting. */
private fun cloudXml(bytes:ByteArray):org.w3c.dom.Document{
    require(bytes.size<=20*1024*1024)
    val charset=if(bytes.size>=2&&((bytes[0]==(-1).toByte()&&bytes[1]==(-2).toByte())||(bytes[0]==(-2).toByte()&&bytes[1]==(-1).toByte())))Charsets.UTF_16 else Charsets.UTF_8
    val text=charset.newDecoder().onMalformedInput(java.nio.charset.CodingErrorAction.REPORT).decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    require(!text.contains("<!DOCTYPE",true)&&!text.contains("<!ENTITY",true)){"不允许带 DTD 或实体声明的成果 XML。"}
    val builder=javax.xml.parsers.DocumentBuilderFactory.newInstance().apply{isNamespaceAware=true;isExpandEntityReferences=false}.newDocumentBuilder()
    builder.setEntityResolver{_,_->throw org.xml.sax.SAXException("External entities are not allowed")}
    return builder.parse(org.xml.sax.InputSource(java.io.StringReader(text)))
}

/** Final manifests only. No directory discovery, extension sweep or chat parsing. */
class CloudArtifacts(private val context:Context) {
    companion object { private val lock=Any() }
    private val phoneFiles=CloudPhoneFiles(context)
    private val base get()=File(context.filesDir,"cloud-artifacts").apply{mkdirs()}
    private fun digest(file:File):String {val sha=MessageDigest.getInstance("SHA-256");file.inputStream().use{input->val b=ByteArray(65536);while(true){val n=input.read(b);if(n<0)break;sha.update(b,0,n)}};return sha.digest().joinToString(""){"%02x".format(it)}}
    private fun index()=File(base,"manifest.json")
    private fun records()=if(index().exists())JSONArray(index().readText())else JSONArray()
    private fun save(items:JSONArray){val tmp=File(base,"manifest.tmp");tmp.writeText(items.toString());check(tmp.renameTo(index()))}
    private fun safeName(name:String)=name.isNotBlank()&&name.length<=180&&!name.contains('/')&&!name.contains('\\')&&name.none{it.code<32}
    private fun validate(file:File):Map<String,Any?> {
        val ext=file.extension.lowercase();val head=file.inputStream().use{input->ByteArray(16).let{b->val n=input.read(b);b.take(maxOf(0,n)).toByteArray()}}
        var sheets:Int?=null
        if(ext in setOf("xlsx","docx","pptx","zip")){
            require(head.size>=4&&head[0]==0x50.toByte()&&head[1]==0x4b.toByte()){"扩展名与 ZIP/Office 内容不一致。"}
            ZipFile(file).use { zip ->
                val entries=zip.entries().asSequence().toList();require(entries.size<=30000)
                require(entries.all{!it.name.startsWith('/')&&!it.name.split('/').contains("..")&&it.size<=200L*1024*1024})
                fun text(name:String):String {val entry=zip.getEntry(name)?:error("缺少 $name");require(entry.size in 1..(2L*1024*1024));return zip.getInputStream(entry).bufferedReader().use{it.readText()}}
                if(ext!="zip")text("[Content_Types].xml")
                if(ext=="xlsx"){
                    val xml=text("xl/workbook.xml");val doc=cloudXml(xml.toByteArray());sheets=doc.getElementsByTagNameNS("*","sheet").length;require(sheets!!>0)
                    require(entries.any{it.name.startsWith("xl/worksheets/")&&it.name.endsWith(".xml")})
                    for(entry in entries.filter{it.name.startsWith("xl/worksheets/")&&it.name.endsWith(".xml")}){require(entry.size<=20L*1024*1024);zip.getInputStream(entry).use{cloudXml(it.readBytes())}}
                }
                if(ext=="docx")require(cloudXml(text("word/document.xml").toByteArray()).getElementsByTagNameNS("*","body").length==1)
                if(ext=="pptx")cloudXml(text("ppt/presentation.xml").toByteArray())
                // Reading all entries verifies CRC/truncation; bounded total avoids bombs.
                var total=0L;for(entry in entries){if(entry.isDirectory)continue;zip.getInputStream(entry).use{input->val b=ByteArray(65536);while(true){val n=input.read(b);if(n<0)break;total+=n;require(total<=512L*1024*1024)}}}
            }
        } else if(ext=="pdf"){
            require(String(head.take(5).toByteArray(),Charsets.US_ASCII)=="%PDF-"){"PDF 文件头无效。"}
            android.os.ParcelFileDescriptor.open(file,android.os.ParcelFileDescriptor.MODE_READ_ONLY).use{fd->android.graphics.pdf.PdfRenderer(fd).use{require(it.pageCount>0)}}
        }
        else if(ext=="png")require(head.take(8).toByteArray().contentEquals(byteArrayOf(-119,80,78,71,13,10,26,10))){"PNG 文件头无效。"}
        else if(ext in setOf("jpg","jpeg"))require(head.size>=3&&head[0]==(-1).toByte()&&head[1]==(-40).toByte()){"JPEG 文件头无效。"}
        if(ext in setOf("png","jpg","jpeg","webp","gif")){val options=android.graphics.BitmapFactory.Options().apply{inJustDecodeBounds=true};android.graphics.BitmapFactory.decodeFile(file.path,options);require(options.outWidth>0&&options.outHeight>0){"图像内容不可解码。"}}
        if(ext=="json"){val token=org.json.JSONTokener(file.readText());token.nextValue();require(token.nextClean()=='\u0000')}
        return mapOf("format" to ext,"sheets" to sheets,"validation" to "format_and_hash")
    }
    fun publish(manifest:Map<String,Any?>,owner:String,taskId:String,requestId:String):Map<String,Any?> = synchronized(lock) {
        require(manifest["explicitManifest"]==true&&manifest["owner"]==owner&&manifest["taskId"]==taskId)
        val batchId=MessageDigest.getInstance("SHA-256").digest("$owner:$requestId".toByteArray()).joinToString(""){"%02x".format(it)}
        val batch=File(base,"batch-$batchId.json")
        if(batch.exists()){@Suppress("UNCHECKED_CAST") return@synchronized plain(JSONObject(batch.readText())) as Map<String,Any?>}
        val all=records();val existing=(0 until all.length()).map{all.getJSONObject(it)}.filter{it.optString("requestId")==requestId&&it.optString("owner")==owner}
        if(existing.isNotEmpty())return@synchronized mapOf("artifacts" to existing.map{plain(it)},"failed" to emptyList<Any>())
        @Suppress("UNCHECKED_CAST") val source=manifest["files"] as? List<Map<String,Any?>>?:error("缺少最终清单。")
        require(source.size<=40)
        val published=mutableListOf<Map<String,Any?>>()
        val failed=mutableListOf<Any?>().apply{addAll(manifest["failed"] as? List<*>?:emptyList<Any>())}
        for(item in source){
            try {
                val project=item["projectId"] as String;require(Regex("[a-zA-Z0-9_-]{1,120}").matches(project))
                val path=item["path"] as String;require(!path.startsWith('/')&&!path.contains('\\')&&!path.split('/').contains(".."))
                val root=File(context.filesDir,"cloud-projects/$project").canonicalFile
                val src=File(root,path).canonicalFile;require(src.path.startsWith(root.path+"/")&&src.isFile&&src.length() in 1..(200L*1024*1024))
                require(src.length()==(item["bytes"] as Number).toLong()&&digest(src)==item["sha256"]){"源文件已变化，请重新准备最终清单。"}
                val name=item["name"] as String;require(safeName(name))
                val artifactId="artifact_"+MessageDigest.getInstance("SHA-256").digest("$batchId:$project:$path".toByteArray()).joinToString(""){"%02x".format(it)}.take(32)
                val folder=File(base,artifactId).apply{check(isDirectory||mkdir())};val dest=File(folder,name)
                try {FileInputStream(src).use{input->dest.outputStream().use{input.copyTo(it)}};require(digest(dest)==item["sha256"]);val metadata=validate(dest)
                    val versions=(0 until all.length()).map{all.getJSONObject(it)}.filter{it.optString("projectId")==project&&it.optString("sourcePath")==path}.map{it.optInt("version")}
                    val record=mapOf("id" to artifactId,"owner" to owner,"taskId" to taskId,"requestId" to requestId,"projectId" to project,"sourcePath" to path,"name" to name,"bytes" to dest.length(),"sha256" to item["sha256"],"purpose" to item["purpose"],"version" to ((versions.maxOrNull()?:0)+1),"createdAt" to System.currentTimeMillis(),"state" to "delivered")+metadata
                    val phone=try{phoneFiles.export(dest,artifactId,item["sha256"] as String,mime(dest))}catch(e:Exception){mapOf("phoneSaveState" to "failed","phoneSaveError" to (e.message?:"手机文件保存未完成。"))}
                    if(phone["phoneSaveState"] !in setOf("saved","changed"))failed+=mapOf("path" to path,"stage" to "phone_save","error" to (phone["phoneSaveError"]?:"手机文件保存尚未核对。"))
                    val finalRecord=record+phone;all.put(JSONObject(finalRecord));published+=finalRecord
                }catch(e:Exception){dest.delete();folder.delete();throw e}
            }catch(e:Exception){failed+=mapOf("path" to item["path"],"error" to (e.message?:"交付检查失败。"))}
        }
        save(all);val result=mapOf("artifacts" to published,"failed" to failed,"count" to published.size,"phoneSavedCount" to published.count{it["phoneSaveState"] in setOf("saved","changed")});val tmp=File(base,"batch-$batchId.tmp");tmp.writeText(JSONObject(result).toString());check(tmp.renameTo(batch));result
    }
    fun list(owner:String?=null,taskId:String?=null):List<Any?> = synchronized(lock) {
        val all=records();(0 until all.length()).map{all.getJSONObject(it)}.filter{(owner==null||it.optString("owner")==owner)&&(taskId==null||it.optString("taskId")==taskId)}.map{r->
            val file=File(base,"${r.getString("id")}/${r.getString("name")}")
            val current=JSONObject(r.toString());if(!file.isFile)current.put("state","missing")else if(file.length()!=r.getLong("bytes")||digest(file)!=r.getString("sha256"))current.put("state","changed")
            plain(current) as Map<String,Any?> + phoneFiles.inspect(r.getString("id"))
        }
    }
    fun file(id:String):Pair<File,JSONObject> = synchronized(lock) {
        require(Regex("artifact_[a-f0-9]{32}").matches(id));val all=records();val record=(0 until all.length()).map{all.getJSONObject(it)}.first{it.getString("id")==id};val file=File(base,"$id/${record.getString("name")}")
        require(file.isFile&&digest(file)==record.getString("sha256")){"文件已缺失或变化，未打开其他版本。"};file to record
    }
    fun mime(file:File):String=when(file.extension.lowercase()){"xlsx"->"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";"docx"->"application/vnd.openxmlformats-officedocument.wordprocessingml.document";"pptx"->"application/vnd.openxmlformats-officedocument.presentationml.presentation";"pdf"->"application/pdf";"zip"->"application/zip";"png"->"image/png";"jpg","jpeg"->"image/jpeg";"json"->"application/json";"csv"->"text/csv";"webp"->"image/webp";"gif"->"image/gif";"txt","md","py","js","mjs","dart","kt","java","c","cpp","html","css","yaml","yml","sh"->"text/plain";else->android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())?:"application/octet-stream"}
    fun preview(id:String):Map<String,Any?>{
        val(file,record)=file(id)
        fun texts(node:org.w3c.dom.Element,tag:String):String{val all=node.getElementsByTagNameNS("*",tag);return (0 until all.length).joinToString(""){all.item(it).textContent}}
        if(file.extension in setOf("xlsx","docx"))return ZipFile(file).use{zip->
            fun document(name:String):org.w3c.dom.Document{val e=zip.getEntry(name)?:error("格式内容缺失。");require(e.size<=20L*1024*1024);return zip.getInputStream(e).use{cloudXml(it.readBytes())}}
            if(file.extension=="docx"){
                val paragraphs=document("word/document.xml").getElementsByTagNameNS("*","p")
                mapOf("kind" to "text","name" to file.name,"text" to (0 until paragraphs.length).take(10000).joinToString("\n"){texts(paragraphs.item(it) as org.w3c.dom.Element,"t")})
            }else{
                val shared=mutableListOf<String>();if(zip.getEntry("xl/sharedStrings.xml")!=null){val strings=document("xl/sharedStrings.xml").getElementsByTagNameNS("*","si");for(i in 0 until strings.length)shared+=texts(strings.item(i) as org.w3c.dom.Element,"t")}
                val rels=document("xl/_rels/workbook.xml.rels").getElementsByTagNameNS("*","Relationship");val paths=mutableMapOf<String,String>();for(i in 0 until rels.length){val e=rels.item(i) as org.w3c.dom.Element;val target=e.getAttribute("Target");require(!target.split('/').contains(".."));paths[e.getAttribute("Id")]=if(target.startsWith('/'))target.removePrefix("/")else "xl/$target"}
                val sheets=document("xl/workbook.xml").getElementsByTagNameNS("*","sheet");val data=(0 until sheets.length).map{i->
                    val sheet=sheets.item(i) as org.w3c.dom.Element;val target=paths[sheet.getAttributeNS("http://schemas.openxmlformats.org/officeDocument/2006/relationships","id")]?:error("工作表关系缺失。")
                    val rows=document(target).getElementsByTagNameNS("*","row");val result=(0 until minOf(rows.length,200)).map{r->
                        val cells=(rows.item(r) as org.w3c.dom.Element).getElementsByTagNameNS("*","c");val row=mutableListOf<String>();for(c in 0 until cells.length){val cell=cells.item(c) as org.w3c.dom.Element;val reference=cell.getAttribute("r");val col=reference.takeWhile{it in 'A'..'Z'}.fold(0){v,ch->v*26+(ch-'A'+1)}-1;if(col !in 0..99)continue;while(row.size<=col)row+="";val value=texts(cell,"v");val formula=texts(cell,"f");row[col]=when(cell.getAttribute("t")){"s"->shared.getOrElse(value.toIntOrNull()?:-1){""};"inlineStr"->texts(cell,"t");"b"->if(value=="1")"TRUE" else "FALSE";else->value.ifBlank{if(formula.isNotBlank())"=$formula" else ""}}};row
                    };mapOf("name" to sheet.getAttribute("name"),"rows" to result,"totalRows" to rows.length)
                };mapOf("kind" to "workbook","name" to file.name,"sheets" to data,"notice" to "内容预览最多每表 200 行、100 列；完整格式与公式请保存或用表格软件打开。")
            }
        }
        require(mime(file).startsWith("text/")||file.extension=="json"){"此格式请用系统打开或保存。"};require(file.length()<=2*1024*1024)
        return mapOf("kind" to "text","name" to file.name,"text" to file.readText(),"version" to record.getInt("version"))
    }
    fun openIntent(id:String,share:Boolean,chooser:Boolean=false):Intent {
        val (file,record)=file(id)
        val phone=phoneFiles.export(file,id,record.getString("sha256"),mime(file))
        val uri=if(phone["phoneSaveState"] in setOf("saved","changed"))android.net.Uri.parse(phone["phoneUri"] as String)
            else if(android.os.Build.VERSION.SDK_INT<29)FileProvider.getUriForFile(context,"${context.packageName}.cloud_files",file)
            else error(phone["phoneSaveError"]?.toString()?:"文件尚未保存到手机下载目录。")
        val intent=if(share)Intent(Intent.ACTION_SEND).setType(mime(file)).putExtra(Intent.EXTRA_STREAM,uri)else Intent(Intent.ACTION_VIEW).setDataAndType(uri,mime(file))
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        if(!share&&phone["phoneSaveState"] in setOf("saved","changed"))intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        intent.clipData=ClipData.newRawUri(phone["phoneName"]?.toString()?:file.name,uri)
        return if(share||chooser)Intent.createChooser(intent,if(share)"分享成果" else "选择打开方式")else intent
    }
}
