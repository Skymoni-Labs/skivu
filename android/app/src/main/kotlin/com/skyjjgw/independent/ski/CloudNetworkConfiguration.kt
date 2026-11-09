package com.skyjjgw.independent.ski

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import org.json.JSONObject
import java.io.File

/** Linux uses the phone's real network DNS instead of an empty image resolver.
 * An external edit of resolv.conf is retained as an explicit custom choice. */
object CloudNetworkConfiguration {
    private val lock=Any()
    private var target:File?=null
    private var context:Context?=null
    private var registered=false
    @Volatile private var current:Map<String,Any?> = mapOf("source" to "not_prepared")
    fun status()=current
    fun attach(app:Context,root:File)=synchronized(lock){
        context=app.applicationContext;target=File(root,"etc/resolv.conf")
        refresh(app)
        if(!registered){
            app.getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(object:ConnectivityManager.NetworkCallback(){
                override fun onAvailable(network:Network){context?.let{refresh(it)}}
                override fun onLinkPropertiesChanged(network:Network,properties:LinkProperties){context?.let{refresh(it)}}
                override fun onLost(network:Network){context?.let{refresh(it)}}
            });registered=true
        }
    }
    fun refresh(app:Context)=synchronized(lock){
        val resolver=target?:return@synchronized
        try{
            val metadata=File(app.filesDir,"cloud-home/cloud/network-policy.json");metadata.parentFile!!.mkdirs()
            val previous=if(metadata.isFile)JSONObject(metadata.readText())else JSONObject()
            val existing=if(resolver.isFile)resolver.readText()else ""
            val oldDefault="nameserver 1.1.1.1\nnameserver 8.8.8.8\n"
            if(previous.optString("mode")=="custom" || (previous.has("lastGenerated")&&existing!=previous.getString("lastGenerated")) || (!previous.has("lastGenerated")&&existing.isNotBlank()&&existing!=oldDefault)){
                previous.put("mode","custom");metadata.writeText(previous.toString());current=mapOf("source" to "user_resolver","path" to "/etc/resolv.conf");return@synchronized
            }
            val manager=app.getSystemService(ConnectivityManager::class.java)
            val addresses=manager.getLinkProperties(manager.activeNetwork)?.dnsServers.orEmpty().mapNotNull{it.hostAddress}.distinct()
            if(addresses.isEmpty()){current=mapOf("source" to "android_network","available" to false,"reason" to "当前网络尚未提供 DNS；已有配置保留，等待网络变化。");return@synchronized}
            val text=addresses.joinToString("\n",postfix="\n"){"nameserver $it"}
            if(existing!=text){val temp=File(resolver.parentFile,".skivu-resolv.tmp");temp.writeText(text);check(temp.renameTo(resolver))}
            previous.put("mode","system").put("lastGenerated",text);val temp=File(metadata.path+".tmp");temp.writeText(previous.toString());check(temp.renameTo(metadata))
            current=mapOf("source" to "android_network","available" to true,"dnsServers" to addresses)
        }catch(error:Exception){current=mapOf("source" to "android_network","available" to false,"reason" to error.toString())}
    }
}
