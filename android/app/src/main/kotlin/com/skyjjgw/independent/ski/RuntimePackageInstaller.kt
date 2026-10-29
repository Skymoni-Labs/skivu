package com.skyjjgw.independent.ski

import android.app.Activity
import android.app.PendingIntent
import android.content.*
import android.content.pm.*
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile

/** Installs only a verified provider APK from the host-private download area. */
class RuntimePackageInstaller(private val activity: Activity) {
    private val pm get() = activity.packageManager
    @Suppress("DEPRECATION") private val flags get() = (if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES) or PackageManager.GET_SERVICES or PackageManager.GET_META_DATA or PackageManager.GET_PERMISSIONS
    private fun identity(call: MethodCall): Pair<ComponentName,String> {
        val component=ComponentName.unflattenFromString(call.argument<String>("component") ?: "") ?: error("component")
        val signer=call.argument<String>("signerSha256") ?: error("signer")
        require(Regex("[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*){1,15}").matches(component.packageName))
        require(component.packageName!=activity.packageName && component.className.startsWith(component.packageName+"."))
        require(Regex("[a-f0-9]{64}").matches(signer));return component to signer
    }
    @Suppress("DEPRECATION") private fun version(p:PackageInfo)=if(Build.VERSION.SDK_INT>=28)p.longVersionCode else p.versionCode.toLong()
    @Suppress("DEPRECATION") private fun signers(p:PackageInfo):Set<String> = (if(Build.VERSION.SDK_INT>=28)p.signingInfo?.apkContentsSigners else p.signatures)?.map { hash(it.toByteArray()) }?.toSet() ?: emptySet()
    private fun validate(p:PackageInfo,component:ComponentName,signer:String) {
        require(p.packageName==component.packageName && signers(p)==setOf(signer))
        require(p.requestedPermissions?.contains(android.Manifest.permission.INTERNET)!=true)
        val service=p.services?.singleOrNull { it.name==component.className } ?: error("service")
        require(service.exported && service.enabled && service.permission==LocalRuntimePlatform.PERMISSION && service.metaData?.getInt("org.skivu.runtime.protocol")==1)
    }
    @Suppress("DEPRECATION") fun info(call:MethodCall):Map<String,Any> {
        val (component,signer)=identity(call)
        val p=try {pm.getPackageInfo(component.packageName,flags)} catch(_:PackageManager.NameNotFoundException){null}
        val valid=p!=null && runCatching {validate(p,component,signer)}.isSuccess
        return mapOf("installed" to (p!=null),"valid" to valid,"versionCode" to (p?.let {version(it)} ?: 0L),"sdk" to Build.VERSION.SDK_INT,"abis" to Build.SUPPORTED_ABIS.toList(),"message" to activity.getSharedPreferences("skivu_runtime_install",0).getString("message","").orEmpty())
    }
    private fun file(call:MethodCall):File {
        val (component,_)=identity(call)
        val version=call.argument<Number>("versionCode")?.toLong() ?: error("version")
        val digest=call.argument<String>("sha256") ?: error("hash")
        require(version>0 && Regex("[a-f0-9]{64}").matches(digest))
        val dir=File(activity.cacheDir,"runtime-installs").canonicalFile
        require(dir.isDirectory || dir.mkdirs())
        return File(dir,"${component.packageName}-$version-$digest.apk").canonicalFile.also {require(it.parentFile==dir)}
    }
    fun prepare(call:MethodCall):String {
        val target=file(call)
        val prefix=identity(call).first.packageName+"-"
        target.parentFile?.listFiles()?.filter {it.name.startsWith(prefix) && it!=target && it!=File(target.path+".part")}?.forEach {it.delete()}
        return target.absolutePath
    }
    @Suppress("DEPRECATION") fun install(call:MethodCall):String {
        val (component,signer)=identity(call)
        val target=file(call);require(File(call.argument<String>("path") ?: "").canonicalFile==target && target.isFile)
        val size=call.argument<Number>("size")?.toLong() ?: error("size")
        require(size in 1..(512L shl 20) && target.length()==size)
        val digest=MessageDigest.getInstance("SHA-256")
        target.inputStream().use {input -> val bytes=ByteArray(65536);while(true){val n=input.read(bytes);if(n<0)break;digest.update(bytes,0,n)}}
        require(hex(digest.digest())==call.argument<String>("sha256"))
        val apk=pm.getPackageArchiveInfo(target.path,flags) ?: error("apk")
        validate(apk,component,signer)
        val expected=call.argument<Number>("versionCode")?.toLong() ?: error("version")
        require(version(apk)==expected && Build.VERSION.SDK_INT>=26 && apk.applicationInfo!!.minSdkVersion<=Build.VERSION.SDK_INT)
        val abi=call.argument<String>("abi") ?: error("abi");require(abi in Build.SUPPORTED_ABIS)
        ZipFile(target).use {zip ->require(zip.entries().asSequence().any {it.name.startsWith("lib/$abi/") && it.name.endsWith(".so")})}
        val installed=try{pm.getPackageInfo(component.packageName,flags)}catch(_:PackageManager.NameNotFoundException){null}
        if(installed!=null){require(signers(installed)==setOf(signer) && expected>=version(installed))}
        if(!pm.canRequestPackageInstalls()) {
            activity.runOnUiThread {activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,Uri.parse("package:${activity.packageName}")))}
            return "permission_required"
        }
        val installer=pm.packageInstaller
        val params=PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(component.packageName);setSize(size)
            setInstallReason(PackageManager.INSTALL_REASON_USER)
            if(Build.VERSION.SDK_INT>=31)setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
        }
        val id=installer.createSession(params)
        activity.getSharedPreferences("skivu_runtime_install",0).edit().putInt("session",id).putString("message","").apply()
        try {
            installer.openSession(id).use {session ->
                session.openWrite("base.apk",0,size).use {output ->target.inputStream().use {it.copyTo(output)};session.fsync(output)}
                val callback=Intent(activity,RuntimePackageInstallReceiver::class.java).setAction("${activity.packageName}.RUNTIME_INSTALL.$id")
                val callbackFlags=PendingIntent.FLAG_UPDATE_CURRENT or (if(Build.VERSION.SDK_INT>=31)PendingIntent.FLAG_MUTABLE else 0)
                session.commit(PendingIntent.getBroadcast(activity,id,callback,callbackFlags).intentSender)
            }
        } catch(e:Exception){runCatching{installer.abandonSession(id)};throw e}
        return "opened"
    }
    private fun hash(bytes:ByteArray)=hex(MessageDigest.getInstance("SHA-256").digest(bytes))
    private fun hex(bytes:ByteArray)=bytes.joinToString(""){"%02x".format(it.toInt() and 255)}
}

class RuntimePackageInstallReceiver:BroadcastReceiver() {
    @Suppress("DEPRECATION") override fun onReceive(context:Context,intent:Intent) {
        val prefs=context.getSharedPreferences("skivu_runtime_install",0)
        val id=intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID,-1)
        if(id<0 || id!=prefs.getInt("session",-1))return
        val status=intent.getIntExtra(PackageInstaller.EXTRA_STATUS,PackageInstaller.STATUS_FAILURE)
        val text=when(status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm=if(Build.VERSION.SDK_INT>=33)intent.getParcelableExtra(Intent.EXTRA_INTENT,Intent::class.java) else intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                runCatching {context.startActivity(requireNotNull(confirm).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}.fold({"请在系统页面确认安装"},{"系统安装页面未能打开，请返回后重试"})
            }
            PackageInstaller.STATUS_SUCCESS -> "运行组件已安装"
            PackageInstaller.STATUS_FAILURE_ABORTED -> "已取消安装，可再次安装"
            PackageInstaller.STATUS_FAILURE_STORAGE -> "存储空间不足，请清理后重试"
            PackageInstaller.STATUS_FAILURE_CONFLICT -> "安装签名或版本冲突，请核对已安装组件"
            else -> "系统未能完成安装，请返回后重试"
        }
        prefs.edit().putString("message",text).apply()
    }
}
