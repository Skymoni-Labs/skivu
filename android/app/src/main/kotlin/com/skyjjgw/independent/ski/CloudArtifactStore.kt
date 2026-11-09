package com.skyjjgw.independent.ski

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.JsonReader
import android.util.JsonToken
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Per-file transactions and immutable blob references replace one ever-growing
 * JSON array. Page windows do not limit total results or stored versions. */
class CloudArtifactStore(private val context:Context):SQLiteOpenHelper(context,"cloud-artifacts.db",null,1){
    private val blobs=TaskBlobStore(context)
    override fun onCreate(db:SQLiteDatabase){db.execSQL("CREATE TABLE artifacts(id TEXT PRIMARY KEY,batch TEXT,owner TEXT,task TEXT,project TEXT,path TEXT,version INTEGER,body TEXT)");db.execSQL("CREATE INDEX artifact_batch ON artifacts(batch,id)");db.execSQL("CREATE INDEX artifact_source ON artifacts(project,path,version)");db.execSQL("CREATE TABLE batches(id TEXT PRIMARY KEY,body TEXT)");db.execSQL("CREATE TABLE failures(batch TEXT,key TEXT,body TEXT,PRIMARY KEY(batch,key))");db.execSQL("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)")}
    override fun onUpgrade(db:SQLiteDatabase,oldVersion:Int,newVersion:Int){}
    fun migrateLegacy() = synchronized(lock) {
        val db=writableDatabase
        val done=db.rawQuery("SELECT value FROM metadata WHERE key='legacy-json-v2'",null).use{it.moveToFirst()}
        if(done)return@synchronized
        val legacy=File(context.filesDir,"cloud-artifacts/manifest.json")
        if(legacy.isFile)legacy.reader().use{source->JsonReader(source).use{reader->
            reader.beginArray()
            while(reader.hasNext()){
                val original=value(reader) as JSONObject
                // The SQLite copy may already contain a newer phone URI/version.
                if(get(original.getString("id"))==null)put(original,original.optString("batchId").ifBlank{TaskDatabase.digest("${original.getString("owner")}:${original.getString("requestId")}")})
            }
            reader.endArray()
        }}
        var after=0L
        while(true){
            val rows=db.rawQuery("SELECT rowid,batch,body FROM artifacts WHERE rowid>? ORDER BY rowid LIMIT 100",arrayOf(after.toString())).use{c->buildList{while(c.moveToNext())add(Triple(c.getLong(0),c.getString(1),c.getString(2)))}}
            if(rows.isEmpty())break
            for((rowid,batchId,body) in rows){
                val row=JSONObject(blobs.decode(body));row.put("batchId",batchId)
                db.execSQL("UPDATE artifacts SET body=? WHERE rowid=?",arrayOf(blobs.encode(row.toString()),rowid))
                if(batch(batchId)==null){
                    val oldBatch=File(context.filesDir,"cloud-artifacts/batch-$batchId.json")
                    if(oldBatch.isFile)oldBatch.reader().use{source->JsonReader(source).use{reader->
                        reader.beginObject();while(reader.hasNext()){
                            if(reader.nextName()=="failed"){
                                reader.beginArray();while(reader.hasNext()){
                                    @Suppress("UNCHECKED_CAST") val failure=plain(value(reader)) as Map<String,Any?>
                                    fail(batchId,failure)
                                };reader.endArray()
                            }else reader.skipValue()
                        };reader.endObject()
                    }}
                    saveBatch(batchId,JSONObject(mapOf("state" to "complete","owner" to row.getString("owner"),"taskId" to row.getString("taskId"),"requestId" to row.getString("requestId"),"migrated" to true)))
                }
                after=rowid
            }
        }
        db.execSQL("INSERT OR REPLACE INTO metadata(key,value) VALUES('legacy-json-v2','retained-and-imported')")
    }
    private fun value(r:JsonReader):Any?=when(r.peek()){
        JsonToken.BEGIN_OBJECT->{val v=JSONObject();r.beginObject();while(r.hasNext()){val name=r.nextName();v.put(name,value(r)?:JSONObject.NULL)};r.endObject();v}
        JsonToken.BEGIN_ARRAY->{val v=JSONArray();r.beginArray();while(r.hasNext())v.put(value(r));r.endArray();v}
        JsonToken.STRING->r.nextString();JsonToken.BOOLEAN->r.nextBoolean();JsonToken.NUMBER->{val n=r.nextString();n.toLongOrNull()?:n.toDouble()};JsonToken.NULL->{r.nextNull();null};else->error("历史成果记录格式无效，原记录保留。")}
    fun put(r:JSONObject,batch:String){r.put("batchId",batch);writableDatabase.insertWithOnConflict("artifacts",null,ContentValues().apply{put("id",r.getString("id"));put("batch",batch);put("owner",r.getString("owner"));put("task",r.getString("taskId"));put("project",r.getString("projectId"));put("path",r.getString("sourcePath"));put("version",r.getInt("version"));put("body",blobs.encode(r.toString()))},SQLiteDatabase.CONFLICT_REPLACE)}
    fun get(id:String):JSONObject?=readableDatabase.rawQuery("SELECT body FROM artifacts WHERE id=?",arrayOf(id)).use{if(it.moveToFirst())JSONObject(blobs.decode(it.getString(0)))else null}
    fun version(project:String,path:String):Int=readableDatabase.rawQuery("SELECT COALESCE(MAX(version),0) FROM artifacts WHERE project=? AND path=?",arrayOf(project,path)).use{it.moveToFirst();it.getInt(0)}
    fun batch(id:String):JSONObject?=readableDatabase.rawQuery("SELECT body FROM batches WHERE id=?",arrayOf(id)).use{if(it.moveToFirst())JSONObject(blobs.decode(it.getString(0)))else null}
    fun saveBatch(id:String,body:JSONObject){writableDatabase.insertWithOnConflict("batches",null,ContentValues().apply{put("id",id);put("body",blobs.encode(body.toString()))},SQLiteDatabase.CONFLICT_REPLACE)}
    fun fail(batch:String,row:Map<String,Any?>){writableDatabase.insertWithOnConflict("failures",null,ContentValues().apply{put("batch",batch);put("key",TaskDatabase.digest("${row["path"]}:${row["stage"]}"));put("body",blobs.encode(JSONObject(row).toString()))},SQLiteDatabase.CONFLICT_REPLACE)}
    fun clearFailure(batch:String,path:String,stage:String){writableDatabase.delete("failures","batch=? AND key=?",arrayOf(batch,TaskDatabase.digest("$path:$stage")))}
    fun failures(batch:String,offset:Int=0,count:Int=100):Map<String,Any?>{val total=readableDatabase.rawQuery("SELECT COUNT(*) FROM failures WHERE batch=?",arrayOf(batch)).use{it.moveToFirst();it.getLong(0)};val rows=readableDatabase.rawQuery("SELECT body FROM failures WHERE batch=? ORDER BY key LIMIT ? OFFSET ?",arrayOf(batch,count.toString(),offset.toString())).use{c->buildList{while(c.moveToNext())add(plain(JSONObject(blobs.decode(c.getString(0)))))}};return mapOf("items" to rows,"total" to total,"nextOffset" to if(offset+rows.size<total)offset+rows.size else null)}
    fun page(owner:String?=null,task:String?=null,ids:List<String>?=null,batches:List<String>?=null,offset:Int=0,count:Int=100):Map<String,Any?>{require(offset>=0&&count>0);val where=mutableListOf<String>();val parameters=mutableListOf<String>();if(owner!=null){where+="owner=?";parameters+=owner};if(task!=null){where+="task=?";parameters+=task}
        // Selectors are values, not SQL fragments. No SQLite variable-count cap:
        // a private temporary selector table is populated one row at a time.
        synchronized(lock){val db=writableDatabase;val selection=ids!=null||batches!=null;if(selection){db.execSQL("CREATE TEMP TABLE IF NOT EXISTS artifact_select(kind TEXT,value TEXT,PRIMARY KEY(kind,value))");db.execSQL("DELETE FROM artifact_select");for(id in ids.orEmpty())db.execSQL("INSERT OR IGNORE INTO artifact_select VALUES('id',?)",arrayOf(id));for(batch in batches.orEmpty())db.execSQL("INSERT OR IGNORE INTO artifact_select VALUES('batch',?)",arrayOf(batch));where+="(EXISTS(SELECT 1 FROM artifact_select s WHERE s.kind='id' AND s.value=artifacts.id) OR EXISTS(SELECT 1 FROM artifact_select s WHERE s.kind='batch' AND s.value=artifacts.batch))"};val clause=if(where.isEmpty())""else" WHERE "+where.joinToString(" AND ");val total=db.rawQuery("SELECT COUNT(*) FROM artifacts$clause",parameters.toTypedArray()).use{it.moveToFirst();it.getLong(0)};val rows=db.rawQuery("SELECT body FROM artifacts$clause ORDER BY rowid LIMIT ? OFFSET ?",(parameters+minOf(count,1000).toString()+offset.toString()).toTypedArray()).use{c->buildList{while(c.moveToNext())add(JSONObject(blobs.decode(c.getString(0))))}};return mapOf("records" to rows,"total" to total,"nextOffset" to if(offset+rows.size<total)offset+rows.size else null,"complete" to (offset+rows.size>=total))}
    }
    companion object{private val lock=Any()}
}
