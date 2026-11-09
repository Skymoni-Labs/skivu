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
    private fun digest(file:File):String {val sha=MessageDigest.getInstance("SHA-256");file.inputStream().use{input->val b=ByteArray(65536);while(true){CloudOperations.checkCurrent();val n=input.read(b);if(n<0)break;sha.update(b,0,n)}};return sha.digest().joinToString(""){"%02x".format(it)}}
    private val store=CloudArtifactStore(context).apply{migrateLegacy()}
    private fun safeName(name:String)=name.isNotBlank()&&!name.contains('/')&&!name.contains('\\')&&name.none{it.code<32}
    private fun xmlStats(input:java.io.InputStream):Map<String,Int>{
        val parser=android.util.Xml.newPullParser();parser.setFeature(org.xmlpull.v1.XmlPullParser.FEATURE_PROCESS_NAMESPACES,true)
        parser.setFeature(org.xmlpull.v1.XmlPullParser.FEATURE_PROCESS_DOCDECL,false);parser.setInput(input,null)
        val counts=mutableMapOf<String,Int>();var event=parser.eventType
        while(event!=org.xmlpull.v1.XmlPullParser.END_DOCUMENT){
            require(event!=org.xmlpull.v1.XmlPullParser.DOCDECL&&event!=org.xmlpull.v1.XmlPullParser.ENTITY_REF){"不允许DTD或实体声明。"}
            if(event==org.xmlpull.v1.XmlPullParser.START_TAG)counts[parser.name]=(counts[parser.name]?:0)+1
            CloudOperations.checkCurrent();event=parser.nextToken()
        };return counts
    }
    private fun validate(file:File,extension:String=file.extension):Map<String,Any?> {
        val ext=extension.lowercase();val head=file.inputStream().use{input->ByteArray(16).let{b->val n=input.read(b);b.take(maxOf(0,n)).toByteArray()}}
        var sheets:Int?=null
        if(ext in setOf("xlsx","docx","pptx","zip")){
            require(head.size>=4&&head[0]==0x50.toByte()&&head[1]==0x4b.toByte()){"扩展名与ZIP/Office内容不一致。"}
            ZipFile(file).use { zip ->
                fun stats(name:String):Map<String,Int>{val entry=zip.getEntry(name)?:error("缺少 $name");return zip.getInputStream(entry).use{xmlStats(it)}}
                if(ext!="zip")stats("[Content_Types].xml")
                if(ext=="xlsx"){sheets=stats("xl/workbook.xml")["sheet"]?:0;require(sheets!!>0);var worksheets=0
                    val entries=zip.entries();while(entries.hasMoreElements()){val entry=entries.nextElement();if(entry.name.startsWith("xl/worksheets/")&&entry.name.endsWith(".xml")){zip.getInputStream(entry).use{xmlStats(it)};worksheets++}}
                    require(worksheets>0)
                }
                if(ext=="docx")require(stats("word/document.xml")["body"]==1)
                if(ext=="pptx")stats("ppt/presentation.xml")
                val entries=zip.entries();val buffer=ByteArray(65536)
                while(entries.hasMoreElements()){val entry=entries.nextElement();require(!entry.name.startsWith('/')&&!entry.name.split('/').contains(".."));if(entry.isDirectory)continue
                    val crc=java.util.zip.CRC32();var total=0L;zip.getInputStream(entry).use{input->while(true){CloudOperations.checkCurrent();val n=input.read(buffer);if(n<0)break;crc.update(buffer,0,n);total+=n}}
                    require((entry.size<0||entry.size==total)&&(entry.crc<0||entry.crc==crc.value)){"ZIP条目内容或CRC不一致。"}
                }
            }
        } else if(ext=="pdf"){
            require(String(head.take(5).toByteArray(),Charsets.US_ASCII)=="%PDF-"){"PDF 文件头无效。"}
            android.os.ParcelFileDescriptor.open(file,android.os.ParcelFileDescriptor.MODE_READ_ONLY).use{fd->android.graphics.pdf.PdfRenderer(fd).use{require(it.pageCount>0)}}
        }
        else if(ext=="png")require(head.take(8).toByteArray().contentEquals(byteArrayOf(-119,80,78,71,13,10,26,10))){"PNG 文件头无效。"}
        else if(ext in setOf("jpg","jpeg"))require(head.size>=3&&head[0]==(-1).toByte()&&head[1]==(-40).toByte()){"JPEG 文件头无效。"}
        if(ext in setOf("png","jpg","jpeg","webp","gif")){val options=android.graphics.BitmapFactory.Options().apply{inJustDecodeBounds=true};android.graphics.BitmapFactory.decodeFile(file.path,options);require(options.outWidth>0&&options.outHeight>0){"图像内容不可解码。"}}
        if(ext=="json")file.inputStream().bufferedReader().use{input->android.util.JsonReader(input).use{reader->reader.isLenient=false;reader.skipValue();require(reader.peek()==android.util.JsonToken.END_DOCUMENT)}}
        return mapOf("format" to ext,"sheets" to sheets,"validation" to "format_and_hash")
    }
    private fun sources(manifest:Map<String,Any?>,owner:String):Sequence<Map<String,Any?>> = sequence {
        val contentId=manifest["manifestContentId"] as? String
        if(contentId!=null){require(Regex("content_[a-f0-9]{32}").matches(contentId));val content=File(context.filesDir,"cloud-home/cloud/content");val meta=JSONObject(File(content,"$contentId.json").readText());val file=File(content,"$contentId.bin");require(meta.getString("owner")==owner&&meta.getBoolean("complete")&&digest(file)==meta.getString("sha256"));file.bufferedReader().use{reader->while(true){val line=reader.readLine()?:break;@Suppress("UNCHECKED_CAST") yield(plain(JSONObject(line)) as Map<String,Any?>)}}
        }else{@Suppress("UNCHECKED_CAST") val files=manifest["files"] as? List<Map<String,Any?>>?:error("缺少最终清单。");yieldAll(files)}
    }
    fun publish(manifest:Map<String,Any?>,owner:String,taskId:String,requestId:String):Map<String,Any?> = synchronized(lock) {
        require(manifest["explicitManifest"]==true&&manifest["owner"]==owner&&manifest["taskId"]==taskId)
        val batchId=TaskDatabase.digest("$owner:$requestId");val previous=store.batch(batchId)
        if(previous?.optString("state")!="complete"){
            store.saveBatch(batchId,JSONObject(mapOf("state" to "publishing","owner" to owner,"taskId" to taskId,"requestId" to requestId)))
            for(failure in (manifest["failed"] as? List<*>).orEmpty()){@Suppress("UNCHECKED_CAST") store.fail(batchId,failure as Map<String,Any?>)}
            for(item in sources(manifest,owner)){
                CloudOperations.checkCurrent()
                try{
                    val project=item["projectId"] as String;require(Regex("[a-zA-Z0-9_-]{1,120}").matches(project));val path=item["path"] as String;require(!path.startsWith('/')&&!path.contains('\\')&&!path.split('/').contains(".."))
                    val artifactId="artifact_"+TaskDatabase.digest("$batchId:$project:$path").take(32)
                    val committed=store.get(artifactId)
                    if(committed!=null){val original=File(base,"$artifactId/${committed.getString("name")}");require(original.isFile&&digest(original)==committed.getString("sha256")){"已保存成果版本缺失或改变，未覆盖旧版本。"};var phone=phoneFiles.inspect(artifactId);if(phone["phoneSaveState"] in setOf("not_saved","pending","failed","needs_location"))phone=phoneFiles.export(original,artifactId,committed.getString("sha256"),mime(original));phone.forEach{(key,value)->committed.put(key,value)};store.put(committed,batchId);if(phone["phoneSaveState"] in setOf("saved","changed"))store.clearFailure(batchId,path,"phone_save");continue}

                    val root=File(context.filesDir,"cloud-projects/$project").canonicalFile;val src=File(root,path).canonicalFile;require(src.path.startsWith(root.path+"/")&&src.isFile)
                    require(src.length()==(item["bytes"] as Number).toLong()&&digest(src)==item["sha256"]){"源文件已变化，请重新准备最终清单。"}
                    val name=item["name"] as String;require(safeName(name));val folder=File(base,artifactId).apply{check(isDirectory||mkdir())};val dest=File(folder,name);val temp=File(folder,".copying")
                    src.inputStream().use{input->temp.outputStream().use{CloudOperations.copy(input,it,name,src.length())}};require(digest(temp)==item["sha256"]);val metadata=validate(temp,File(name).extension);check(temp.renameTo(dest))
                    val record=JSONObject(mapOf("id" to artifactId,"batchId" to batchId,"owner" to owner,"taskId" to taskId,"requestId" to requestId,"projectId" to project,"sourcePath" to path,"name" to name,"bytes" to dest.length(),"sha256" to item["sha256"],"purpose" to item["purpose"],"version" to (store.version(project,path)+1),"createdAt" to System.currentTimeMillis(),"state" to "delivered")+metadata)
                    store.put(record,batchId) // commit private version before creating any public document
                    val phone=try{phoneFiles.export(dest,artifactId,item["sha256"] as String,mime(dest))}catch(e:Exception){mapOf("phoneSaveState" to "failed","phoneSaveError" to e.toString())};phone.forEach{(key,value)->record.put(key,value)};store.put(record,batchId)
                    if(phone["phoneSaveState"] !in setOf("saved","changed"))store.fail(batchId,mapOf("path" to path,"stage" to "phone_save","error" to (phone["phoneSaveError"]?:"手机文件保存尚未核对。")))
                }catch(e:Exception){CloudOperations.checkCurrent();store.fail(batchId,mapOf("path" to item["path"],"error" to e.toString()))}
            }
            store.saveBatch(batchId,JSONObject(mapOf("state" to "complete","owner" to owner,"taskId" to taskId,"requestId" to requestId)))
        }
        val page=page(owner,taskId,batches=listOf(batchId));val failures=store.failures(batchId);mapOf("artifacts" to page["items"],"failed" to failures["items"],"failedCount" to failures["total"],"batchId" to batchId,"count" to page["total"],"nextOffset" to page["nextOffset"],"complete" to page["complete"],"failureNextOffset" to failures["nextOffset"],"phoneSavedCount" to (page["items"] as List<*>).count{(it as Map<*,*>)["phoneSaveState"] in setOf("saved","changed")},"phoneCountIsPage" to true)
    }
    fun page(owner:String?=null,taskId:String?=null,ids:List<String>?=null,batches:List<String>?=null,offset:Int=0,count:Int=100):Map<String,Any?> = synchronized(lock){val page=store.page(owner,taskId,ids,batches,offset,count);val items=(page["records"] as List<*>).map{raw->val r=raw as JSONObject;val file=File(base,"${r.getString("id")}/${r.getString("name")}");val current=JSONObject(r.toString());if(!file.isFile)current.put("state","missing")else if(file.length()!=r.getLong("bytes")||digest(file)!=r.getString("sha256"))current.put("state","changed");@Suppress("UNCHECKED_CAST") val data=plain(current) as Map<String,Any?>;data+phoneFiles.inspect(r.getString("id"))};(page-"records")+mapOf("items" to items)}
    fun saveToPhone(id:String,owner:String):Map<String,Any?>{val(file,record)=file(id);require(record.getString("owner")==owner){"成果不属于本会话。"};val phone=phoneFiles.export(file,id,record.getString("sha256"),mime(file));phone.forEach{(key,value)->record.put(key,value)};store.put(record,record.getString("batchId"));if(phone["phoneSaveState"] in setOf("saved","changed"))store.clearFailure(record.getString("batchId"),record.getString("sourcePath"),"phone_save");@Suppress("UNCHECKED_CAST") return plain(record) as Map<String,Any?>}
    fun batchStatus(batch:String,owner:String):Map<String,Any?>{require(store.batch(batch)?.optString("owner")==owner){"成果组不属于本会话。"};var offset=0;var generated=0L;var saved=0L;var unavailable=0L;while(true){val page=page(owner,batches=listOf(batch),offset=offset,count=100);for(raw in page["items"] as List<*>){val item=raw as Map<*,*>;generated++;if(item["state"]=="delivered"&&item["phoneSaveState"]=="saved"){saved++;store.clearFailure(batch,item["sourcePath"] as String,"phone_save")}else unavailable++};offset=page["nextOffset"] as? Int?:break};val failures=store.failures(batch);return mapOf("batchId" to batch,"count" to generated,"phoneSavedCount" to saved,"unavailableCount" to unavailable,"failedCount" to failures["total"],"failed" to failures["items"],"failureNextOffset" to failures["nextOffset"],"verified" to (generated>0&&unavailable==0L&&(failures["total"] as Number).toLong()==0L))}
    fun failures(batch:String,offset:Int=0,count:Int=100)=store.failures(batch,offset,count)
    fun list(owner:String?=null,taskId:String?=null):List<Any?>{val result=mutableListOf<Any?>();var offset=0;while(true){val page=page(owner,taskId,offset=offset);result.addAll(page["items"] as List<*>);offset=page["nextOffset"] as? Int?:break};return result}
    fun file(id:String):Pair<File,JSONObject> = synchronized(lock){require(Regex("artifact_[a-f0-9]{32}").matches(id));val record=store.get(id)?:error("成果记录不存在。");val file=File(base,"$id/${record.getString("name")}");require(file.isFile&&digest(file)==record.getString("sha256")){"文件已缺失或变化，未打开其他版本。"};file to record}
    fun mime(file:File):String=when(file.extension.lowercase()){"xlsx"->"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";"docx"->"application/vnd.openxmlformats-officedocument.wordprocessingml.document";"pptx"->"application/vnd.openxmlformats-officedocument.presentationml.presentation";"pdf"->"application/pdf";"zip"->"application/zip";"png"->"image/png";"jpg","jpeg"->"image/jpeg";"json"->"application/json";"csv"->"text/csv";"webp"->"image/webp";"gif"->"image/gif";"txt","md","py","js","mjs","dart","kt","java","c","cpp","html","css","yaml","yml","sh"->"text/plain";else->android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())?:"application/octet-stream"}
    private fun officeText(file:File,record:JSONObject):File{
        val output=File(base,"preview-${record.getString("sha256")}.txt");if(output.isFile)return output
        val temporary=File(output.path+".tmp");val stringsFile=File(base,"preview-strings-${record.getString("id")}.db");val strings=android.database.sqlite.SQLiteDatabase.openOrCreateDatabase(stringsFile,null);strings.execSQL("CREATE TABLE IF NOT EXISTS strings(id INTEGER PRIMARY KEY,value TEXT)");strings.execSQL("DELETE FROM strings")
        fun parse(input:java.io.InputStream,visit:(org.xmlpull.v1.XmlPullParser,Int)->Unit){val parser=android.util.Xml.newPullParser();parser.setFeature(org.xmlpull.v1.XmlPullParser.FEATURE_PROCESS_NAMESPACES,true);parser.setFeature(org.xmlpull.v1.XmlPullParser.FEATURE_PROCESS_DOCDECL,false);parser.setInput(input,null);var event=parser.eventType;while(event!=org.xmlpull.v1.XmlPullParser.END_DOCUMENT){CloudOperations.checkCurrent();require(event!=org.xmlpull.v1.XmlPullParser.DOCDECL&&event!=org.xmlpull.v1.XmlPullParser.ENTITY_REF);visit(parser,event);event=parser.nextToken()}}
        try{temporary.bufferedWriter().use{out->ZipFile(file).use{zip->
            if(file.extension=="docx"){val entry=zip.getEntry("word/document.xml")?:error("正文缺失。");var text=false;zip.getInputStream(entry).use{parse(it){p,event->if(event==org.xmlpull.v1.XmlPullParser.START_TAG){if(p.name=="t")text=true;if(p.name in setOf("tab"))out.write("\t");if(p.name in setOf("br","cr"))out.newLine()};if(event==org.xmlpull.v1.XmlPullParser.TEXT&&text)out.write(p.text);if(event==org.xmlpull.v1.XmlPullParser.END_TAG){if(p.name=="t")text=false;if(p.name=="p")out.newLine()}}}}
            else{
                zip.getEntry("xl/sharedStrings.xml")?.let{entry->var index=0L;var text=false;val value=StringBuilder();strings.beginTransaction();try{zip.getInputStream(entry).use{parse(it){p,event->if(event==org.xmlpull.v1.XmlPullParser.START_TAG){if(p.name=="si")value.setLength(0);if(p.name=="t")text=true};if(event==org.xmlpull.v1.XmlPullParser.TEXT&&text)value.append(p.text);if(event==org.xmlpull.v1.XmlPullParser.END_TAG){if(p.name=="t")text=false;if(p.name=="si")strings.execSQL("INSERT INTO strings VALUES(?,?)",arrayOf(index++,value.toString()))}}};strings.setTransactionSuccessful()}finally{strings.endTransaction()}}
                val names=mutableMapOf<String,String>();val relationships=mutableMapOf<String,String>();zip.getEntry("xl/_rels/workbook.xml.rels")?.let{e->zip.getInputStream(e).use{parse(it){p,event->if(event==org.xmlpull.v1.XmlPullParser.START_TAG&&p.name=="Relationship"){val target=p.getAttributeValue(null,"Target");require(!target.split('/').contains(".."));relationships[p.getAttributeValue(null,"Id")]=if(target.startsWith('/'))target.removePrefix("/")else "xl/$target"}}}};zip.getEntry("xl/workbook.xml")?.let{e->zip.getInputStream(e).use{parse(it){p,event->if(event==org.xmlpull.v1.XmlPullParser.START_TAG&&p.name=="sheet"){val key=p.getAttributeValue("http://schemas.openxmlformats.org/officeDocument/2006/relationships","id");relationships[key]?.let{path->names[path]=p.getAttributeValue(null,"name")}}}}}
                val entries=zip.entries();while(entries.hasMoreElements()){val entry=entries.nextElement();if(entry.isDirectory||!entry.name.startsWith("xl/worksheets/")||!entry.name.endsWith(".xml"))continue;out.write("\n[${names[entry.name]?:entry.name}]\n");var type="";var column="";var tag="";val value=StringBuilder();val formula=StringBuilder();zip.getInputStream(entry).use{parse(it){p,event->if(event==org.xmlpull.v1.XmlPullParser.START_TAG){tag=p.name;if(p.name=="c"){type=p.getAttributeValue(null,"t")?:"";column=p.getAttributeValue(null,"r")?:"";value.setLength(0);formula.setLength(0)}};if(event==org.xmlpull.v1.XmlPullParser.TEXT){if(tag=="v"||tag=="t")value.append(p.text);if(tag=="f")formula.append(p.text)};if(event==org.xmlpull.v1.XmlPullParser.END_TAG){if(p.name=="c"){val text=if(type=="s")strings.rawQuery("SELECT value FROM strings WHERE id=?",arrayOf(value.toString())).use{c->if(c.moveToFirst())c.getString(0)else "[共享文本缺失]"}else value.toString().ifBlank{if(formula.isNotEmpty())"=$formula"else""};out.write("[$column] $text\t")};if(p.name=="row")out.newLine();tag=""}}}
                }
            }
        }};check(temporary.renameTo(output));return output}finally{strings.close();stringsFile.delete()}
    }
    fun preview(id:String,offset:Long=0,length:Int=48000):Map<String,Any?>{
        val(file,record)=file(id);val office=file.extension.lowercase() in setOf("xlsx","docx");require(office||mime(file).startsWith("text/")||file.extension=="json"){"此格式请用系统打开或保存。"};val text=if(office)officeText(file,record)else file
        return CloudRanges.file(text,offset,length)+mapOf("kind" to "text","name" to file.name,"version" to record.getInt("version"),"notice" to if(office)"正文按页完整读取；工作表用单元格地址标识。格式、公式和完整排版请用系统打开。"else null)
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
